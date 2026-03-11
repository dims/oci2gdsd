import gc
import datetime
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path

import torch
from transformers import AutoTokenizer

from daemon_client_common import (
    assert_http_ok,
    assert_no_runtime_artifact_access,
    create_gpu_allocation,
    dtype_size_bytes,
    emit_phase_timing,
    ensure_model_ready,
    hydrate_runtime_bundle,
    monotonic_ms,
    parse_bool_env,
    resolve_device_uuid,
    torch_dtype_from_safetensors,
    unix_http_json,
    load_native_module as _load_native_module_common,
)


def load_native_module():
    return _load_native_module_common(
        build_dir_default="/tmp/oci2gds_tensorrt_build",
        module_name_prefix="oci2gds_tensorrt_native",
        required_symbol="import_ipc_tensor_view",
    )


def run_cmd(cmd, cwd=None, timeout_seconds=7200):
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout_seconds,
        check=False,
    )
    if proc.returncode != 0:
        tail_out = "\n".join(proc.stdout.strip().splitlines()[-40:])
        tail_err = "\n".join(proc.stderr.strip().splitlines()[-40:])
        raise RuntimeError(
            f"command failed rc={proc.returncode}: {' '.join(cmd)}\n"
            f"stdout_tail:\n{tail_out}\n"
            f"stderr_tail:\n{tail_err}"
        )
    return proc.stdout


def _shape_numel(shape):
    total = 1
    for dim in shape:
        total *= int(dim)
    return total


def profile_shards_from_metadata(metadata: dict):
    profile = metadata.get("profile", {})
    shard_entries = sorted(profile.get("shards", []), key=lambda s: int(s.get("ordinal", 0)))
    if not shard_entries:
        raise RuntimeError("profile.shards is empty")
    return shard_entries


def profile_content_key(shard_entries) -> str:
    normalized = []
    for shard in sorted(shard_entries, key=lambda s: str(s.get("name", ""))):
        normalized.append(
            {
                "name": str(shard.get("name", "")),
                "digest": str(shard.get("digest", "")),
                "size": int(shard.get("size", 0)),
                "kind": str(shard.get("kind", "")),
                "ordinal": int(shard.get("ordinal", 0)),
            }
        )
    return hashlib.sha256(json.dumps(normalized, sort_keys=True).encode("utf-8")).hexdigest()


def reset_runtime_dir() -> Path:
    runtime_dir = Path(os.environ.get("LOCAL_MODEL_DIR", "/tmp/oci2gdsd-trt-model"))
    if runtime_dir.exists():
        shutil.rmtree(runtime_dir)
    runtime_dir.mkdir(parents=True, exist_ok=True)
    return runtime_dir


def link_metadata_assets(model_root: Path, runtime_dir: Path):
    metadata_dir = model_root / "metadata"
    if metadata_dir.is_dir():
        for src in sorted(metadata_dir.iterdir(), key=lambda p: p.name):
            if not src.is_file() or src.name == "model.json":
                continue
            dst = runtime_dir / src.name
            if not dst.exists():
                os.symlink(src, dst)
    if not (runtime_dir / "config.json").exists():
        raise RuntimeError("runtime_dir is missing config.json")


def build_runtime_dir_symlink(model_root: Path, shard_entries) -> Path:
    runtime_dir = reset_runtime_dir()
    for shard in shard_entries:
        name = str(shard.get("name", "")).strip()
        if not name:
            raise RuntimeError("empty shard name in profile")
        src = model_root / "shards" / name
        if not src.exists():
            raise RuntimeError(f"missing shard file: {src}")
        os.symlink(src, runtime_dir / name)
    link_metadata_assets(model_root, runtime_dir)
    return runtime_dir


def build_runtime_dir_metadata_only(model_root: Path, shard_entries) -> Path:
    runtime_dir = reset_runtime_dir()
    for shard in shard_entries:
        name = str(shard.get("name", "")).strip()
        if not name:
            raise RuntimeError("empty shard name in profile")
        src = model_root / "shards" / name
        if not src.exists():
            kind = str(shard.get("kind", "")).strip().lower()
            is_weight = kind in {"", "weight"} or name.endswith(".safetensors")
            if is_weight:
                continue
            raise RuntimeError(f"missing runtime shard file: {src}")
        kind = str(shard.get("kind", "")).strip().lower()
        is_weight = kind in {"", "weight"} or name.endswith(".safetensors")
        if is_weight:
            continue
        os.symlink(src, runtime_dir / name)
    link_metadata_assets(model_root, runtime_dir)
    return runtime_dir


def collect_shard_ipc_map(tensor_map):
    by_shard = {}
    for entry in tensor_map:
        shard_name = str(entry.get("shard_name", "")).strip()
        if not shard_name:
            continue
        handle = str(entry.get("ipc_handle", "")).strip()
        shard_size = int(entry.get("shard_size", 0))
        existing = by_shard.get(shard_name)
        if existing is None:
            by_shard[shard_name] = {
                "ipc_handle": handle,
                "shard_size": shard_size,
            }
            continue
        if existing["ipc_handle"] and handle and existing["ipc_handle"] != handle:
            raise RuntimeError(f"tensor-map shard {shard_name} has conflicting IPC handles")
        if not existing["ipc_handle"] and handle:
            existing["ipc_handle"] = handle
        if existing["shard_size"] > 0 and shard_size > 0 and existing["shard_size"] != shard_size:
            raise RuntimeError(f"tensor-map shard {shard_name} has conflicting shard_size values")
        if existing["shard_size"] <= 0 and shard_size > 0:
            existing["shard_size"] = shard_size
    return by_shard


def build_runtime_dir_from_ipc(model_root: Path, shard_entries, tensor_map, native_module, device_index: int):
    if native_module is None:
        raise RuntimeError("native module required for IPC-backed runtime materialization")
    runtime_dir = reset_runtime_dir()
    by_shard = collect_shard_ipc_map(tensor_map)
    imported_shards = 0
    imported_bytes = 0
    linked_runtime_files = 0
    required_ipc_shards = 0
    unresolved = []

    for shard in shard_entries:
        name = str(shard.get("name", "")).strip()
        if not name:
            raise RuntimeError("empty shard name in profile")
        src = model_root / "shards" / name
        kind = str(shard.get("kind", "")).strip().lower()
        is_weight_shard = kind == "weight" or name.endswith(".safetensors")
        if is_weight_shard:
            required_ipc_shards += 1

        info = by_shard.get(name)
        if info is None:
            if (not is_weight_shard) and src.exists():
                os.symlink(src, runtime_dir / name)
                linked_runtime_files += 1
                continue
            unresolved.append(name)
            continue
        handle = str(info.get("ipc_handle", "")).strip()
        shard_size = int(info.get("shard_size", 0))
        if not handle or shard_size <= 0:
            if (not is_weight_shard) and src.exists():
                os.symlink(src, runtime_dir / name)
                linked_runtime_files += 1
                continue
            unresolved.append(name)
            continue

        tensor = native_module.import_ipc_copy_to_tensor(handle, shard_size, int(device_index))
        if not isinstance(tensor, torch.Tensor):
            raise RuntimeError(f"native import returned non-tensor for shard {name}")
        if not tensor.is_cuda:
            raise RuntimeError(f"native import returned non-cuda tensor for shard {name}")
        data = tensor.detach().cpu().numpy().tobytes()
        del tensor
        if len(data) != shard_size:
            raise RuntimeError(f"native import size mismatch for shard {name}: got={len(data)} want={shard_size}")

        digest = hashlib.sha256(data).hexdigest()
        expected = str(shard.get("digest", "")).strip()
        if expected.startswith("sha256:"):
            want = expected.split(":", 1)[1].strip()
            if want and digest != want:
                raise RuntimeError(f"IPC materialized shard digest mismatch for {name}: got={digest} want={want}")

        dst = runtime_dir / name
        with dst.open("wb") as f:
            f.write(data)
        imported_shards += 1
        imported_bytes += shard_size

    if unresolved:
        raise RuntimeError(f"IPC materialization missing shard coverage: unresolved={len(unresolved)} {unresolved[:8]}")

    link_metadata_assets(model_root, runtime_dir)
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.synchronize(int(device_index))
        torch.cuda.empty_cache()
    return runtime_dir, {
        "status": "ok",
        "imported_shards": imported_shards,
        "imported_bytes": imported_bytes,
        "linked_runtime_files": linked_runtime_files,
        "required_ipc_shards": required_ipc_shards,
        "unresolved_shards": len(unresolved),
    }


def build_tensor_binding_index(tensor_map):
    tensor_index = {}
    shard_names = set()
    total_bytes = 0
    for entry in tensor_map:
        name = str(entry.get("name", "")).strip()
        if not name:
            continue
        if name in tensor_index:
            raise RuntimeError(f"duplicate tensor {name} found in tensor map")
        handle = str(entry.get("ipc_handle", "")).strip()
        if not handle:
            raise RuntimeError(f"tensor map entry {name} is missing ipc_handle")
        shard_size = int(entry.get("shard_size", 0))
        byte_offset = int(entry.get("byte_offset", 0))
        byte_length = int(entry.get("byte_length", 0))
        if byte_offset < 0 or byte_length <= 0:
            raise RuntimeError(f"invalid tensor map byte range for {name}")
        if shard_size > 0 and byte_offset + byte_length > shard_size:
            raise RuntimeError(f"tensor map byte range exceeds shard size for {name}")
        dtype_code = str(entry.get("dtype", "")).strip()
        shape = [int(x) for x in entry.get("shape", [])]
        shard_name = str(entry.get("shard_name", "")).strip()
        if shard_name:
            shard_names.add(shard_name)
        tensor_index[name] = {
            "dtype": dtype_code,
            "shape": shape,
            "byte_offset": byte_offset,
            "byte_length": byte_length,
            "handle": handle,
            "shard_bytes": shard_size,
            "shard_name": shard_name,
        }
        total_bytes += byte_length
    if not tensor_index:
        raise RuntimeError("gpu/tensor-map returned no tensor descriptors")
    return tensor_index, {
        "tensor_count": len(tensor_index),
        "tensor_bytes": total_bytes,
        "shard_count": len(shard_names),
    }


def collect_parameter_alias_stats(model, imported_tensors):
    imported_ptrs = {int(t.data_ptr()): t for t in imported_tensors.values()}
    aliased_params = []
    aliased_bytes = 0
    same_name_params = 0
    same_name_compatible = 0
    same_name_aliasable = 0
    skipped_tied_aliasable = 0
    required_alias_params = 0
    first_compatible_param = ""
    tie_word_embeddings = bool(getattr(getattr(model, "config", None), "tie_word_embeddings", False))
    for name, param in model.named_parameters():
        ptr = int(param.data_ptr())
        if ptr not in imported_ptrs:
            src = imported_tensors.get(name)
            if src is None:
                continue
            same_name_params += 1
            if src.device == param.device and src.shape == param.shape and src.dtype == param.dtype:
                same_name_compatible += 1
                if not first_compatible_param:
                    first_compatible_param = name
                if src.is_contiguous():
                    same_name_aliasable += 1
                    if tie_word_embeddings and name.startswith("lm_head"):
                        skipped_tied_aliasable += 1
                    else:
                        required_alias_params += 1
            continue
        aliased_params.append(name)
        aliased_bytes += int(param.element_size()) * int(param.nelement())
    return {
        "status": "ok" if aliased_params else "none",
        "aliased_params": len(aliased_params),
        "aliased_bytes": aliased_bytes,
        "first_aliased_param": aliased_params[0] if aliased_params else "",
        "same_name_params": same_name_params,
        "same_name_compatible": same_name_compatible,
        "same_name_aliasable": same_name_aliasable,
        "skipped_tied_aliasable": skipped_tied_aliasable,
        "required_alias_params": required_alias_params,
        "first_compatible_param": first_compatible_param,
    }


def load_tensorrtllm_pytorch_model(runtime_dir: Path, tensor_map, native_module, device_index: int):
    os.environ["TRTLLM_DISABLE_FLASHINFER"] = "1"
    if torch.cuda.is_available():
        torch.cuda.set_device(int(device_index))
    from tensorrt_llm import LLM
    from tensorrt_llm._torch.models.checkpoints.base_weight_loader import (
        BaseWeightLoader,
        ConsumableWeightsDict,
    )
    from tensorrt_llm._torch.models.checkpoints.hf.checkpoint_loader import HfCheckpointLoader

    class TensorMapWeightLoader(BaseWeightLoader):
        def __init__(self, tensors, native, device: int):
            self._tensors = list(tensors)
            self._native = native
            self._device = int(device)
            self.imported_tensors = {}
            self.stats = {
                "status": "skipped",
                "imported_tensors": 0,
                "imported_bytes": 0,
                "shard_count": 0,
            }

        def load_weights(self, checkpoint_dir: str, mapping) -> ConsumableWeightsDict:
            tensor_index, tensor_stats = build_tensor_binding_index(self._tensors)
            imported = {}
            imported_bytes = 0
            for name, spec in tensor_index.items():
                dtype_code = str(spec["dtype"]).strip()
                expected_shape = tuple(int(x) for x in spec["shape"])
                byte_offset = int(spec["byte_offset"])
                byte_length = int(spec["byte_length"])
                shard_bytes = int(spec["shard_bytes"])
                if byte_offset < 0 or byte_length <= 0:
                    raise RuntimeError(f"invalid byte range for {name}")
                if shard_bytes > 0 and byte_offset + byte_length > shard_bytes:
                    raise RuntimeError(
                        f"tensor byte range exceeds shard size for {name}: offset={byte_offset} length={byte_length} shard_bytes={shard_bytes}"
                    )
                tensor = self._native.import_ipc_tensor_view(
                    str(spec["handle"]),
                    int(byte_offset),
                    list(expected_shape),
                    dtype_code,
                    int(self._device),
                )
                if not isinstance(tensor, torch.Tensor):
                    raise RuntimeError(f"native import returned non-tensor for {name}")
                if not tensor.is_cuda:
                    raise RuntimeError(f"native import returned non-cuda tensor for {name}")
                expected_dtype = torch_dtype_from_safetensors(dtype_code)
                if tensor.dtype != expected_dtype:
                    raise RuntimeError(f"imported tensor dtype mismatch for {name}: {tensor.dtype} vs {expected_dtype}")
                if tuple(tensor.shape) != expected_shape:
                    raise RuntimeError(
                        f"imported tensor shape mismatch for {name}: {tuple(tensor.shape)} vs {expected_shape}"
                    )
                expected_bytes = _shape_numel(expected_shape) * dtype_size_bytes(dtype_code)
                if expected_bytes != byte_length:
                    raise RuntimeError(
                        f"tensor byte length mismatch for {name}: got={byte_length} expected={expected_bytes}"
                    )
                imported[name] = tensor
                imported_bytes += byte_length

            self.imported_tensors = imported
            self.stats = {
                "status": "ok",
                "imported_tensors": len(imported),
                "imported_bytes": imported_bytes,
                "shard_count": tensor_stats["shard_count"],
            }
            return ConsumableWeightsDict(imported)

        def cleanup(self) -> None:
            self.imported_tensors = {}

    weight_loader = TensorMapWeightLoader(tensor_map, native_module, device_index)
    checkpoint_loader = HfCheckpointLoader(weight_loader=weight_loader)
    # Keep TP1 PyTorch startup in-process so the custom checkpoint loader can
    # consume preloaded GPU tensors without going through MPI pickle transport.
    os.environ["TLLM_WORKER_USE_SINGLE_PROCESS"] = "1"
    llm = LLM(
        model=str(runtime_dir),
        backend="pytorch",
        checkpoint_loader=checkpoint_loader,
        tensor_parallel_size=1,
        trust_remote_code=True,
    )
    executor = getattr(llm, "_executor", None)
    py_executor = getattr(executor, "engine", executor) if executor is not None else None
    model_engine = getattr(py_executor, "model_engine", None) if py_executor is not None else None
    model = getattr(model_engine, "model", None) if model_engine is not None else None
    if model is None:
        checkpoint_loader.cleanup()
        raise RuntimeError("TensorRT-LLM PyTorch executor did not expose model_engine.model")
    alias_stats = collect_parameter_alias_stats(model, weight_loader.imported_tensors)
    return llm, checkpoint_loader, weight_loader.stats, alias_stats


def run_tensorrtllm_pytorch_infer(llm):
    from tensorrt_llm import SamplingParams

    prompt = os.environ.get(
        "PROMPT",
        "Explain in one sentence why loading model weights directly into GPU memory is useful.",
    )
    sampling_params = SamplingParams(max_tokens=48)
    infer_start_ms = monotonic_ms()
    output = llm.generate(prompt, sampling_params=sampling_params, use_tqdm=False)
    if isinstance(output, list):
        if not output:
            raise RuntimeError("TensorRT-LLM generate returned no outputs")
        output = output[0]
    if not output.outputs:
        raise RuntimeError("TensorRT-LLM generate returned no completion outputs")
    answer = str(output.outputs[0].text or "").strip()
    if not answer:
        raise RuntimeError("TensorRT-LLM generate returned empty text")
    answer_sha = hashlib.sha256(answer.encode("utf-8")).hexdigest()
    print(f"TENSORRT_QWEN_INFER_OK answer_sha256={answer_sha} tokens={len(answer.split())} backend=pytorch")
    return answer_sha, monotonic_ms() - infer_start_ms


def shutdown_tensorrtllm_pytorch(llm, checkpoint_loader, device_index: int):
    try:
        if llm is not None:
            llm.shutdown()
    finally:
        if checkpoint_loader is not None:
            checkpoint_loader.cleanup()
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.synchronize(int(device_index))
        torch.cuda.empty_cache()


def find_qwen_convert_script() -> Path:
    override = os.environ.get("TRTLLM_CONVERT_SCRIPT", "").strip()
    if override:
        p = Path(override)
        if not p.exists():
            raise RuntimeError(f"TRTLLM_CONVERT_SCRIPT does not exist: {p}")
        return p

    candidates = [
        Path("/opt/TensorRT-LLM/examples/models/core/qwen/convert_checkpoint.py"),
        Path("/workspace/TensorRT-LLM/examples/models/core/qwen/convert_checkpoint.py"),
        Path("/app/tensorrt_llm/examples/models/core/qwen/convert_checkpoint.py"),
        Path("/app/TensorRT-LLM/examples/models/core/qwen/convert_checkpoint.py"),
        Path("/usr/local/src/TensorRT-LLM/examples/models/core/qwen/convert_checkpoint.py"),
    ]
    for p in candidates:
        if p.exists():
            return p

    raise RuntimeError("failed to locate qwen convert_checkpoint.py in TensorRT-LLM image")


def engine_ready(engine_dir: Path) -> bool:
    if not engine_dir.is_dir():
        return False
    if not (engine_dir / "config.json").exists():
        return False
    plans = list(engine_dir.glob("*.engine"))
    return len(plans) > 0


def _safe_token(raw: str, fallback: str) -> str:
    text = "".join(ch if ch.isalnum() or ch in "-._" else "-" for ch in str(raw).strip())
    text = text.strip("-._")
    return text or fallback


def _digest_token(raw_digest: str) -> str:
    digest = str(raw_digest or "").strip()
    if digest.startswith("sha256:"):
        digest = digest.split(":", 1)[1]
    return _safe_token(digest, "unknown-digest")


def _engine_cache_metadata_path(engine_dir: Path) -> Path:
    return engine_dir / ".oci2gdsd_engine_cache.json"


def _engine_cache_lock_path(engine_dir: Path) -> Path:
    return engine_dir / ".oci2gdsd_engine_cache.lock"


def _expected_engine_cache_metadata(
    model_id: str,
    manifest_digest: str,
    content_key: str,
    dtype: str,
    max_input_len: int,
    max_seq_len: int,
    max_output_len: int,
    startup_mode: str,
):
    return {
        "schema_version": 1,
        "model_id": str(model_id),
        "manifest_digest": str(manifest_digest),
        "content_key": str(content_key),
        "dtype": str(dtype),
        "max_input_len": int(max_input_len),
        "max_seq_len": int(max_seq_len),
        "max_output_len": int(max_output_len),
        "startup_mode": str(startup_mode),
    }


def _load_engine_cache_metadata(engine_dir: Path):
    path = _engine_cache_metadata_path(engine_dir)
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def _engine_cache_metadata_matches(actual: dict, expected: dict) -> bool:
    if not isinstance(actual, dict):
        return False
    for key, value in expected.items():
        if actual.get(key) != value:
            return False
    return True


def _write_engine_cache_metadata(engine_dir: Path, metadata: dict):
    path = _engine_cache_metadata_path(engine_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(metadata, sort_keys=True), encoding="utf-8")
    tmp.replace(path)


class _EngineBuildLock:
    def __init__(self, lock_path: Path):
        self._lock_path = lock_path
        self._fd = None

    def __enter__(self):
        self._lock_path.parent.mkdir(parents=True, exist_ok=True)
        self._fd = self._lock_path.open("a+")
        fcntl.flock(self._fd.fileno(), fcntl.LOCK_EX)
        return self

    def __exit__(self, exc_type, exc, tb):
        if self._fd is not None:
            try:
                fcntl.flock(self._fd.fileno(), fcntl.LOCK_UN)
            finally:
                self._fd.close()
                self._fd = None


def resolve_engine_dirs(
    model_root: Path,
    model_id: str,
    manifest_digest: str,
    content_key: str,
    dtype: str,
    max_input_len: int,
    max_seq_len: int,
    max_output_len: int,
):
    checkpoint_override = str(os.environ.get("TRT_CHECKPOINT_DIR", "")).strip()
    engine_override = str(os.environ.get("TRT_ENGINE_DIR", "")).strip()
    if checkpoint_override or engine_override:
        cache_root = model_root / ".trt-cache"
        checkpoint_dir = Path(checkpoint_override or str(cache_root / "checkpoint"))
        engine_dir = Path(engine_override or str(cache_root / "engine"))
        cache_key = "override-paths"
        return checkpoint_dir, engine_dir, cache_key

    cache_root = Path(os.environ.get("TENSORRT_ENGINE_CACHE_ROOT", "/var/cache/oci2gdsd/tensorrt"))
    profile = {
        "model_id": str(model_id),
        "content_key": str(content_key),
        "dtype": str(dtype),
        "max_input_len": int(max_input_len),
        "max_seq_len": int(max_seq_len),
        "max_output_len": int(max_output_len),
    }
    cache_key = hashlib.sha256(json.dumps(profile, sort_keys=True).encode("utf-8")).hexdigest()[:24]
    model_token = _safe_token(model_id, "model")
    digest_token = _safe_token(content_key, _digest_token(manifest_digest))
    base = cache_root / model_token / digest_token / cache_key
    return base / "checkpoint", base / "engine", cache_key


def build_engine(
    runtime_dir: Path,
    model_root: Path,
    source_mode: str,
    model_id: str,
    manifest_digest: str,
    content_key: str,
    startup_mode: str,
    force_rebuild_override: bool = False,
) -> Path:
    dtype = os.environ.get("TRT_DTYPE", "float16").strip() or "float16"
    max_input_len = int(os.environ.get("TRT_MAX_INPUT_LEN", "512"))
    max_seq_len = int(os.environ.get("TRT_MAX_SEQ_LEN", "640"))
    max_output_len = int(os.environ.get("TRT_MAX_OUTPUT_LEN", "64"))
    checkpoint_dir, engine_dir, cache_key = resolve_engine_dirs(
        model_root=model_root,
        model_id=model_id,
        manifest_digest=manifest_digest,
        content_key=content_key,
        dtype=dtype,
        max_input_len=max_input_len,
        max_seq_len=max_seq_len,
        max_output_len=max_output_len,
    )
    force_rebuild = parse_bool_env("TRT_FORCE_REBUILD", False) or force_rebuild_override
    expected_cache_meta = _expected_engine_cache_metadata(
        model_id=model_id,
        manifest_digest=manifest_digest,
        content_key=content_key,
        dtype=dtype,
        max_input_len=max_input_len,
        max_seq_len=max_seq_len,
        max_output_len=max_output_len,
        startup_mode=startup_mode,
    )
    lock_path = _engine_cache_lock_path(engine_dir)

    with _EngineBuildLock(lock_path):
        if force_rebuild:
            shutil.rmtree(checkpoint_dir, ignore_errors=True)
            shutil.rmtree(engine_dir, ignore_errors=True)

        if engine_ready(engine_dir):
            existing_meta = _load_engine_cache_metadata(engine_dir)
            if _engine_cache_metadata_matches(existing_meta, expected_cache_meta):
                print(
                    "TENSORRT_ENGINE_BUILD_OK "
                    f"reused=true source={source_mode} startup_mode={startup_mode} "
                    f"cache_key={cache_key} engine_dir={engine_dir}"
                )
                if startup_mode == "fast":
                    print(
                        "TENSORRT_ENGINE_FASTPATH_OK "
                        f"cache_hit=true built=false cache_key={cache_key} engine_dir={engine_dir}"
                    )
                return engine_dir
            shutil.rmtree(checkpoint_dir, ignore_errors=True)
            shutil.rmtree(engine_dir, ignore_errors=True)

        convert_script = find_qwen_convert_script()
        checkpoint_dir.mkdir(parents=True, exist_ok=True)
        engine_dir.mkdir(parents=True, exist_ok=True)

        run_cmd(
            [
                "python3",
                str(convert_script),
                "--model_dir",
                str(runtime_dir),
                "--output_dir",
                str(checkpoint_dir),
                "--dtype",
                dtype,
                "--tp_size",
                "1",
                "--pp_size",
                "1",
                "--cp_size",
                "1",
            ],
            timeout_seconds=7200,
        )

        run_cmd(
            [
                "trtllm-build",
                "--checkpoint_dir",
                str(checkpoint_dir),
                "--output_dir",
                str(engine_dir),
                "--gemm_plugin",
                "auto",
                "--max_batch_size",
                "1",
                "--max_input_len",
                str(max_input_len),
                "--max_seq_len",
                str(max_seq_len),
                "--max_beam_width",
                "1",
                "--workers",
                "1",
            ],
            timeout_seconds=7200,
        )

        if not engine_ready(engine_dir):
            raise RuntimeError(f"TensorRT engine build did not produce expected outputs in {engine_dir}")
        _write_engine_cache_metadata(engine_dir, expected_cache_meta)
        print(
            "TENSORRT_ENGINE_BUILD_OK "
            f"reused=false source={source_mode} startup_mode={startup_mode} "
            f"cache_key={cache_key} engine_dir={engine_dir}"
        )
        if startup_mode == "fast":
            print(
                "TENSORRT_ENGINE_FASTPATH_OK "
                f"cache_hit=false built=true cache_key={cache_key} engine_dir={engine_dir}"
            )
        return engine_dir



def build_managed_weights_from_tensor_map(tensor_map, native_module, device_index: int):
    if native_module is None:
        raise RuntimeError("native module required for TensorRT managed-weights aliasing")

    managed_weights = {}
    mapped = 0
    mapped_bytes = 0
    for entry in tensor_map:
        name = str(entry.get("name", "")).strip()
        if not name:
            raise RuntimeError("tensor-map entry missing tensor name")
        if name in managed_weights:
            raise RuntimeError(f"duplicate tensor-map tensor name encountered: {name}")

        handle = str(entry.get("ipc_handle", "")).strip()
        if not handle:
            raise RuntimeError(f"tensor-map entry is missing ipc_handle for tensor={name}")

        dtype_code = str(entry.get("dtype", "")).strip().upper()
        if not dtype_code:
            raise RuntimeError(f"tensor-map entry is missing dtype for tensor={name}")

        shape_raw = entry.get("shape", [])
        if not isinstance(shape_raw, list) or not shape_raw:
            raise RuntimeError(f"tensor-map entry has invalid shape for tensor={name}")
        shape = [int(dim) for dim in shape_raw]
        if any(dim < 0 for dim in shape):
            raise RuntimeError(f"tensor-map entry has negative shape dimension for tensor={name}")

        byte_offset = int(entry.get("byte_offset", 0))
        byte_length = int(entry.get("byte_length", 0))
        if byte_offset < 0 or byte_length <= 0:
            raise RuntimeError(
                f"tensor-map entry has invalid byte range for tensor={name}: "
                f"byte_offset={byte_offset} byte_length={byte_length}"
            )

        tensor = native_module.import_ipc_tensor_view(handle, byte_offset, shape, dtype_code, int(device_index))
        if not isinstance(tensor, torch.Tensor):
            raise RuntimeError(f"native tensor view import returned non-tensor for tensor={name}")
        if not tensor.is_cuda:
            raise RuntimeError(f"native tensor view import returned non-cuda tensor for tensor={name}")

        want_numel = _shape_numel(shape)
        got_numel = int(tensor.numel())
        if got_numel != want_numel:
            raise RuntimeError(f"tensor-map view numel mismatch for tensor={name}: got={got_numel} want={want_numel}")
        want_bytes = int(want_numel * tensor.element_size())
        if want_bytes != byte_length:
            raise RuntimeError(
                f"tensor-map view byte-length mismatch for tensor={name}: "
                f"got={want_bytes} want={byte_length}"
            )

        managed_weights[name] = tensor
        mapped += 1
        mapped_bytes += byte_length

    if mapped == 0:
        raise RuntimeError("managed weights map is empty")

    return managed_weights, {
        "status": "ok",
        "mapped_weights": mapped,
        "mapped_bytes": mapped_bytes,
    }


def _resolve_single_engine_file(engine_dir: Path) -> Path:
    plans = sorted(engine_dir.glob("*.engine"), key=lambda p: p.name)
    if not plans:
        raise RuntimeError(f"TensorRT engine directory has no *.engine files: {engine_dir}")
    if len(plans) > 1:
        raise RuntimeError(f"TensorRT engine directory must contain exactly one *.engine for TP=1: {engine_dir}")
    return plans[0]


def run_tensorrt_infer(
    engine_dir: Path,
    runtime_dir: Path,
    tensors,
    native_module,
    require_direct: bool,
    device_index: int,
):
    from tensorrt_llm.bindings import executor as trtllm

    tokenizer = AutoTokenizer.from_pretrained(str(runtime_dir), local_files_only=True, trust_remote_code=True)
    prompt = os.environ.get(
        "PROMPT",
        "Explain in one sentence why loading model weights directly into GPU memory is useful.",
    )

    if not torch.cuda.is_available():
        raise RuntimeError("torch.cuda.is_available() is false")
    torch.cuda.set_device(device_index)

    input_ids = tokenizer.encode(prompt, add_special_tokens=True)
    if not input_ids:
        raise RuntimeError("tokenizer returned empty input ids")

    max_output_len = int(os.environ.get("TRT_MAX_OUTPUT_LEN", "64"))
    runner_use_gds = parse_bool_env("TENSORRT_RUNNER_USE_GDS", False) and require_direct
    kv_cache_fraction = float(os.environ.get("TRT_KV_CACHE_FREE_GPU_MEMORY_FRACTION", "0.5"))

    managed_weights, managed_stats = build_managed_weights_from_tensor_map(
        tensors,
        native_module=native_module,
        device_index=device_index,
    )

    executor_cfg_kwargs = {
        "max_batch_size": 1,
        "max_beam_width": 1,
        "kv_cache_config": trtllm.KvCacheConfig(free_gpu_memory_fraction=kv_cache_fraction),
        "use_gpu_direct_storage": runner_use_gds,
        "gpu_weights_percent": 1.0,
    }
    try:
        executor_cfg = trtllm.ExecutorConfig(
            alias_managed_weights_from_gpu=True,
            **executor_cfg_kwargs,
        )
    except TypeError as exc:
        raise RuntimeError(
            "TensorRT-LLM image does not support alias_managed_weights_from_gpu; "
            "use a runtime image built from the PR branch"
        ) from exc

    config_path = engine_dir / "config.json"
    if not config_path.exists():
        raise RuntimeError(f"TensorRT engine config.json missing: {config_path}")
    engine_path = _resolve_single_engine_file(engine_dir)

    engine_buffer = engine_path.read_bytes()
    json_config_str = config_path.read_text(encoding="utf-8")

    executor = trtllm.Executor(
        engine_buffer,
        json_config_str,
        trtllm.ModelType.DECODER_ONLY,
        executor_cfg,
        managed_weights,
    )
    print(
        "TENSORRT_GDS_RUNNER_READY "
        f"use_gpu_direct_storage={runner_use_gds} "
        "managed_weights_source=tensor_map "
        f"engine_dir={engine_dir}"
    )
    print(
        "TENSORRT_MANAGED_WEIGHTS_ALIAS_OK "
        f"status={managed_stats.get('status', 'unknown')} "
        f"mapped_weights={managed_stats.get('mapped_weights', 0)} "
        f"mapped_bytes={managed_stats.get('mapped_bytes', 0)} "
        "alias_enabled=true"
    )

    infer_start_ms = monotonic_ms()
    wait_slice_ms = int(os.environ.get("TRT_EXECUTOR_WAIT_SLICE_MS", "100"))
    if wait_slice_ms <= 0:
        wait_slice_ms = 100
    max_wait_ms = int(os.environ.get("TRT_EXECUTOR_MAX_WAIT_MS", "120000"))
    if max_wait_ms <= 0:
        max_wait_ms = 120000

    request = trtllm.Request(
        input_token_ids=input_ids,
        max_tokens=max_output_len,
        pad_id=tokenizer.eos_token_id,
        end_id=tokenizer.eos_token_id,
        streaming=False,
        sampling_config=trtllm.SamplingConfig(
            beam_width=1,
            top_k=40,
            top_p=0.9,
            temperature=0.7,
        ),
    )

    tokens = []
    elapsed_ms = 0
    done = False
    req_id = executor.enqueue_request(request)
    try:
        while not done and elapsed_ms < max_wait_ms:
            responses = executor.await_responses(req_id, datetime.timedelta(milliseconds=wait_slice_ms))
            elapsed_ms += wait_slice_ms
            for response in responses:
                if response.has_error():
                    raise RuntimeError(
                        f"TensorRT executor request failed: request_id={response.request_id} "
                        f"error={response.error_msg}"
                    )
                result = response.result
                done = done or bool(result.is_final)
                new_tokens = result.output_token_ids[0]
                if new_tokens:
                    tokens.extend(int(t) for t in new_tokens)
    finally:
        executor.shutdown()

    if not done:
        raise RuntimeError(f"TensorRT executor timed out waiting for final response: max_wait_ms={max_wait_ms}")
    if not tokens:
        raise RuntimeError("TensorRT inference returned no output tokens")

    answer = tokenizer.decode(tokens, skip_special_tokens=True).strip()
    if not answer:
        raise RuntimeError("TensorRT inference returned empty answer")

    answer_sha = hashlib.sha256(answer.encode("utf-8")).hexdigest()
    print(f"TENSORRT_QWEN_INFER_OK answer_sha256={answer_sha} tokens={len(tokens)}")
    return answer_sha, monotonic_ms() - infer_start_ms, managed_stats


def validate_tensor_map_handles(tensors, parity_mode: str):
    missing_handle = 0
    bad_range = 0
    mapped = 0
    total_bytes = 0

    for entry in tensors:
        handle = str(entry.get("ipc_handle", "")).strip()
        if not handle:
            missing_handle += 1
            continue

        byte_offset = int(entry.get("byte_offset", 0))
        byte_length = int(entry.get("byte_length", 0))
        shard_size = int(entry.get("shard_size", 0))
        if byte_offset < 0 or byte_length <= 0:
            bad_range += 1
            continue
        if shard_size > 0 and (byte_offset + byte_length > shard_size):
            bad_range += 1
            continue

        mapped += 1
        total_bytes += byte_length

    status = "ok"
    if missing_handle > 0 or bad_range > 0:
        status = "partial"

    if parity_mode == "full":
        if status != "ok":
            raise RuntimeError(
                f"full parity mode requires complete tensor-map handle coverage; "
                f"missing_handle={missing_handle} bad_range={bad_range} mapped={mapped} total={len(tensors)}"
            )
        if mapped != len(tensors):
            raise RuntimeError(f"full parity mode requires mapped==total; mapped={mapped} total={len(tensors)}")

    if parity_mode == "partial" and mapped <= 0:
        raise RuntimeError("partial parity mode requires mapped tensors > 0")

    return {
        "status": status,
        "mapped_tensors": mapped,
        "missing_handle": missing_handle,
        "bad_range": bad_range,
        "mapped_bytes": total_bytes,
        "total_tensors": len(tensors),
    }


class HeartbeatKeeper:
    def __init__(self, socket_path: str, payload: dict, interval_seconds: int):
        self.socket_path = socket_path
        self.payload = dict(payload)
        self.interval_seconds = max(30, int(interval_seconds))
        self._stop = threading.Event()
        self._thread = None
        self._error = None

    def _loop(self):
        while not self._stop.wait(self.interval_seconds):
            try:
                code, body = unix_http_json(self.socket_path, "POST", "/v2/gpu/heartbeat", self.payload, timeout_seconds=60)
                assert_http_ok(code, body, "gpu/heartbeat(keepalive)")
                print(f"DAEMON_GPU_HEARTBEAT_OK keepalive=true expires_at={body.get('expires_at', '')}")
            except Exception as exc:
                self._error = exc
                print(f"DAEMON_GPU_HEARTBEAT_WARN keepalive=true error={exc}")
                return

    def start(self):
        self._thread = threading.Thread(target=self._loop, name="oci2gdsd-heartbeat", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
        if self._error is not None:
            raise RuntimeError(f"heartbeat keepalive failed: {self._error}") from self._error

    def assert_healthy(self):
        if self._error is not None:
            raise RuntimeError(f"heartbeat keepalive failed: {self._error}") from self._error


def main():
    runtime_root = Path(os.environ.get("RUNTIME_BUNDLE_ROOT", "/tmp/oci2gdsd-runtime-bundle"))
    perf_mode = str(os.environ.get("PERF_MODE", "unspecified")).strip().lower() or "unspecified"
    assert_no_runtime_artifact_access()
    model_ref = os.environ["MODEL_REF"]
    model_id = os.environ["MODEL_ID"]
    model_digest = os.environ.get("MODEL_DIGEST", "").strip()
    lease_holder = os.environ["LEASE_HOLDER"]
    socket_path = os.environ.get("OCI2GDS_DAEMON_SOCKET", "/run/oci2gdsd/daemon.sock")
    requested_device_index = int(os.environ.get("DEVICE_INDEX", "0"))
    device_index = requested_device_index
    runtime_device_index = device_index
    device_uuid = resolve_device_uuid(device_index)
    require_direct = parse_bool_env("REQUIRE_DIRECT_GDS", True)
    strict_load = parse_bool_env("OCI2GDS_STRICT", True)
    tensorrtllm_backend = str(os.environ.get("TENSORRTLLM_BACKEND", "pytorch")).strip().lower()
    if tensorrtllm_backend not in {"pytorch", "tensorrt"}:
        raise RuntimeError("TENSORRTLLM_BACKEND must be one of: pytorch, tensorrt")
    startup_mode = str(os.environ.get("TENSORRT_STARTUP_MODE", "parity")).strip().lower()
    if startup_mode not in {"parity", "fast"}:
        raise RuntimeError("TENSORRT_STARTUP_MODE must be one of: parity, fast")
    if tensorrtllm_backend != "tensorrt" and startup_mode != "parity":
        raise RuntimeError("TENSORRT_STARTUP_MODE=fast is supported only when TENSORRTLLM_BACKEND=tensorrt")

    parity_mode = str(os.environ.get("RUNTIME_PARITY_MODE", "full")).strip().lower()
    if parity_mode != "full":
        raise RuntimeError("TensorRT daemon-client requires RUNTIME_PARITY_MODE=full; path-backed modes are removed")
    print(f"TENSORRTLLM_BACKEND_OK backend={tensorrtllm_backend}")
    print(f"TENSORRT_STARTUP_MODE_OK mode={startup_mode} backend={tensorrtllm_backend}")

    ensure_phase_start = monotonic_ms()
    ensure_payload = ensure_model_ready(
        socket_path=socket_path,
        model_ref=model_ref,
        model_id=model_id,
        lease_holder=lease_holder,
    )
    emit_phase_timing("ensure", monotonic_ms() - ensure_phase_start, mode=perf_mode)
    model_id = str(ensure_payload.get("model_id", model_id)).strip() or model_id
    model_digest = str(ensure_payload.get("manifest_digest", model_digest)).strip() or model_digest

    load_phase_start = monotonic_ms()
    allocation = create_gpu_allocation(
        socket_path=socket_path,
        model_ref="",
        model_id=model_id,
        model_digest=model_digest,
        lease_holder=lease_holder,
        device_uuid=device_uuid,
        strict=strict_load,
    )
    emit_phase_timing("load", monotonic_ms() - load_phase_start, mode=perf_mode)
    allocation_id = str(allocation.get("allocation_id", "")).strip()
    if not allocation_id:
        raise RuntimeError(f"gpu/allocate returned empty allocation_id: {allocation}")
    device_index = int(allocation.get("device_index", device_index))
    allocation_device_uuid = str(allocation.get("device_uuid", device_uuid)).strip()
    if allocation_device_uuid:
        device_uuid = allocation_device_uuid
    os.environ["CUDA_VISIBLE_DEVICES"] = str(device_index)
    runtime_device_index = 0
    runtime_bundle_token = str(allocation.get("runtime_bundle_token", "")).strip()
    if not runtime_bundle_token:
        raise RuntimeError(f"gpu/allocate returned empty runtime_bundle_token: {allocation}")
    model_digest = str(allocation.get("manifest_digest", model_digest)).strip()
    if not model_digest:
        raise RuntimeError(f"gpu/allocate returned empty manifest digest: {allocation}")
    print(
        "DAEMON_GPU_TARGET_DEVICE "
        f"requested_index={requested_device_index} "
        f"allocation_index={device_index} "
        f"runtime_index={runtime_device_index} "
        f"device_uuid={device_uuid}"
    )
    bundle_phase_start = monotonic_ms()
    hydrate_runtime_bundle(socket_path, runtime_root, runtime_bundle_token)
    emit_phase_timing("bundle", monotonic_ms() - bundle_phase_start, mode=perf_mode)

    metadata_path = runtime_root / "metadata" / "model.json"
    if not metadata_path.exists():
        raise RuntimeError(f"metadata missing at {metadata_path}")

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    shards = metadata.get("profile", {}).get("shards", [])
    if not shards:
        raise RuntimeError("no shards listed in metadata profile")

    sample_sha = ""

    load_ready = False
    attached = False
    direct_files = 0
    answer_sha = ""
    heartbeat = None
    source_mode = "symlink"
    managed_weights_source = "none"
    fallback_reads = 1
    map_stats = {
        "status": "skipped",
        "mapped_tensors": 0,
        "missing_handle": 0,
        "bad_range": 0,
        "mapped_bytes": 0,
        "total_tensors": 0,
    }
    import_stats = {
        "status": "skipped",
        "imported_shards": 0,
        "imported_bytes": 0,
        "unresolved_shards": 0,
    }
    managed_stats = {
        "status": "skipped",
        "mapped_weights": 0,
        "mapped_bytes": 0,
    }
    alias_stats = {
        "status": "skipped",
        "aliased_params": 0,
        "aliased_bytes": 0,
        "first_aliased_param": "",
    }
    attach_client_id = f"{lease_holder}-trt-{os.getpid()}"

    try:
        total_files = int(allocation.get("files", 0))
        direct_files = int(allocation.get("direct_files", 0))
        if total_files <= 0:
            raise RuntimeError(f"gpu/allocate returned no files: {allocation}")
        if require_direct and direct_files == 0:
            raise RuntimeError(f"gpu/allocate returned zero direct files in strict run: {allocation}")
        load_ready = True
        print(
            "DAEMON_GPU_LOAD_READY "
            f"files={total_files} direct_files={direct_files} "
            "mode=persistent persistent=True "
            f"strict={strict_load}"
        )

        status_code, status_payload = unix_http_json(
            socket_path,
            "GET",
            f"/v2/gpu/status?device_uuid={device_uuid}",
            payload=None,
            timeout_seconds=60,
        )
        assert_http_ok(status_code, status_payload, "gpu/status")
        status_files = status_payload.get("files", []) if isinstance(status_payload, dict) else []
        if not status_files:
            raise RuntimeError(f"gpu/status returned no files after load: {status_payload}")
        print(f"DAEMON_GPU_STATUS_OK files={len(status_files)}")

        attach_req = {
            "allocation_id": allocation_id,
            "client_id": attach_client_id,
            "ttl_seconds": 300,
        }
        attach_code, attach_payload = unix_http_json(socket_path, "POST", "/v2/gpu/attach", attach_req, timeout_seconds=120)
        assert_http_ok(attach_code, attach_payload, "gpu/attach")
        attached = True
        print(
            "DAEMON_GPU_ATTACH_OK "
            f"client_id={attach_client_id} "
            f"attached_files={attach_payload.get('attached_files', 0)} "
            f"expires_at={attach_payload.get('expires_at', '')}"
        )

        hb_req = {
            "allocation_id": allocation_id,
            "client_id": attach_client_id,
            "ttl_seconds": 300,
        }
        hb_code, hb_payload = unix_http_json(socket_path, "POST", "/v2/gpu/heartbeat", hb_req, timeout_seconds=60)
        assert_http_ok(hb_code, hb_payload, "gpu/heartbeat")
        print(f"DAEMON_GPU_HEARTBEAT_OK expires_at={hb_payload.get('expires_at', '')}")
        heartbeat = HeartbeatKeeper(socket_path, hb_req, interval_seconds=90)
        heartbeat.start()

        tensor_phase_start = monotonic_ms()
        tensor_req = {
            "allocation_id": allocation_id,
            "max_shards": 0,
            "max_tensors": int(os.environ.get("MAX_TENSOR_MAP_TENSORS", "0")),
            "include_handles": True,
        }
        tensor_code, tensor_payload = unix_http_json(socket_path, "POST", "/v2/gpu/tensor-map", tensor_req, timeout_seconds=300)
        assert_http_ok(tensor_code, tensor_payload, "gpu/tensor-map")
        tensor_device_index = int(tensor_payload.get("device_index", device_index))
        if tensor_device_index != int(device_index):
            raise RuntimeError(
                f"gpu/tensor-map device_index mismatch: allocation={device_index} tensor_map={tensor_device_index}"
            )
        tensors = tensor_payload.get("tensors", []) if isinstance(tensor_payload, dict) else []
        if not tensors:
            raise RuntimeError(f"gpu/tensor-map returned no tensors: {tensor_payload}")
        tensor_bytes = sum(int(t.get("byte_length", 0)) for t in tensors)
        print(f"TENSORRT_IPC_TENSOR_MAP_OK tensors={len(tensors)} tensor_bytes={tensor_bytes}")
        emit_phase_timing("tensor-map", monotonic_ms() - tensor_phase_start, mode=perf_mode)

        bind_phase_start = monotonic_ms()
        map_stats = validate_tensor_map_handles(tensors, parity_mode=parity_mode)
        print(
            "TENSORRT_IPC_BIND_OK "
            f"status={map_stats.get('status', 'unknown')} "
            f"mapped_tensors={map_stats.get('mapped_tensors', 0)} "
            f"mapped_bytes={map_stats.get('mapped_bytes', 0)} "
            f"missing_handle={map_stats.get('missing_handle', 0)} "
            f"bad_range={map_stats.get('bad_range', 0)} "
            f"total_tensors={map_stats.get('total_tensors', 0)} "
            f"parity_mode={parity_mode}"
        )

        native_module = load_native_module()
        shard_entries = profile_shards_from_metadata(metadata)
        if tensorrtllm_backend == "pytorch":
            runtime_dir = build_runtime_dir_metadata_only(runtime_root, shard_entries)
            source_mode = "ipc_tensor_map"
            managed_weights_source = "checkpoint_loader"
            fallback_reads = 0
            llm = None
            checkpoint_loader = None
            try:
                llm, checkpoint_loader, import_stats, alias_stats = load_tensorrtllm_pytorch_model(
                    runtime_dir=runtime_dir,
                    tensor_map=tensors,
                    native_module=native_module,
                    device_index=runtime_device_index,
                )
                print(
                    "TENSORRT_IPC_IMPORT_OK "
                    f"status={import_stats.get('status', 'unknown')} "
                    f"imported_tensors={import_stats.get('imported_tensors', 0)} "
                    f"imported_bytes={import_stats.get('imported_bytes', 0)} "
                    f"shard_count={import_stats.get('shard_count', 0)} "
                    f"parity_mode={parity_mode} "
                    "backend=pytorch"
                )
                print(
                    "TENSORRTLLM_PYTORCH_RUNNER_READY "
                    f"status=ok backend=pytorch runtime_dir={runtime_dir}"
                )
                print(
                    "TENSORRT_PYTORCH_ALIAS_OK "
                    f"status={alias_stats.get('status', 'unknown')} "
                    f"aliased_params={alias_stats.get('aliased_params', 0)} "
                    f"aliased_bytes={alias_stats.get('aliased_bytes', 0)} "
                    f"first_aliased_param={alias_stats.get('first_aliased_param', '')} "
                    f"same_name_params={alias_stats.get('same_name_params', 0)} "
                    f"same_name_compatible={alias_stats.get('same_name_compatible', 0)} "
                    f"same_name_aliasable={alias_stats.get('same_name_aliasable', 0)} "
                    f"skipped_tied_aliasable={alias_stats.get('skipped_tied_aliasable', 0)} "
                    f"required_alias_params={alias_stats.get('required_alias_params', 0)} "
                    f"first_compatible_param={alias_stats.get('first_compatible_param', '')}"
                )
                print(
                    "TENSORRT_FULL_SOURCE_OK "
                    f"source={source_mode} "
                    f"managed_weights_source={managed_weights_source} "
                    f"fallback_reads={fallback_reads} "
                    f"parity_mode={parity_mode} "
                    "backend=pytorch"
                )
                emit_phase_timing("bind", monotonic_ms() - bind_phase_start, mode=perf_mode)

                if heartbeat is not None:
                    heartbeat.assert_healthy()
                if import_stats.get("status") != "ok":
                    raise RuntimeError(f"full parity mode requires import status=ok; got {import_stats}")
                if int(import_stats.get("imported_tensors", 0)) != int(map_stats.get("total_tensors", 0)):
                    raise RuntimeError(
                        "full parity mode requires imported_tensors to match tensor-map coverage; "
                        f"imported={import_stats.get('imported_tensors', 0)} tensor_map={map_stats.get('total_tensors', 0)}"
                    )
                if int(import_stats.get("imported_bytes", 0)) != int(map_stats.get("mapped_bytes", 0)):
                    raise RuntimeError(
                        "full parity mode requires imported_bytes to match mapped_bytes; "
                        f"imported={import_stats.get('imported_bytes', 0)} mapped={map_stats.get('mapped_bytes', 0)}"
                    )
                required_alias_params = int(alias_stats.get("required_alias_params", 0))
                if int(alias_stats.get("aliased_params", 0)) < required_alias_params:
                    raise RuntimeError(
                        "full parity mode requires aliased_params to cover all required direct-alias candidates; "
                        f"required={required_alias_params} got={alias_stats}"
                    )
                if fallback_reads != 0:
                    raise RuntimeError(f"full parity mode requires fallback_reads=0; got {fallback_reads}")
                if managed_weights_source != "checkpoint_loader":
                    raise RuntimeError(
                        f"full parity mode requires managed_weights_source=checkpoint_loader; got {managed_weights_source}"
                    )

                answer_sha, first_token_ms = run_tensorrtllm_pytorch_infer(llm)
                emit_phase_timing("first-token", first_token_ms, mode=perf_mode)
            finally:
                shutdown_tensorrtllm_pytorch(llm, checkpoint_loader, runtime_device_index)
        else:
            content_key = profile_content_key(shard_entries)
            runtime_dir, import_stats = build_runtime_dir_from_ipc(
                model_root=runtime_root,
                shard_entries=shard_entries,
                tensor_map=tensors,
                native_module=native_module,
                device_index=runtime_device_index,
            )
            source_mode = "ipc_materialized"
            managed_weights_source = "tensor_map"
            fallback_reads = 0
            print(
                "TENSORRT_IPC_IMPORT_OK "
                f"status={import_stats.get('status', 'unknown')} "
                f"imported_shards={import_stats.get('imported_shards', 0)} "
                f"imported_bytes={import_stats.get('imported_bytes', 0)} "
                f"linked_runtime_files={import_stats.get('linked_runtime_files', 0)} "
                f"required_ipc_shards={import_stats.get('required_ipc_shards', 0)} "
                f"unresolved_shards={import_stats.get('unresolved_shards', 0)} "
                f"parity_mode={parity_mode} "
                "backend=tensorrt"
            )
            print(
                "TENSORRT_FULL_SOURCE_OK "
                f"source={source_mode} "
                f"managed_weights_source={managed_weights_source} "
                f"fallback_reads={fallback_reads} "
                f"parity_mode={parity_mode} "
                "backend=tensorrt"
            )
            emit_phase_timing("bind", monotonic_ms() - bind_phase_start, mode=perf_mode)

            if heartbeat is not None:
                heartbeat.assert_healthy()
            if import_stats.get("status") != "ok":
                raise RuntimeError(f"full parity mode requires import status=ok; got {import_stats}")
            required_ipc_shards = int(import_stats.get("required_ipc_shards", 0))
            if int(import_stats.get("imported_shards", 0)) != required_ipc_shards:
                raise RuntimeError(
                    f"full parity mode requires imported_shards={required_ipc_shards}; got {import_stats.get('imported_shards', 0)}"
                )
            if int(import_stats.get("unresolved_shards", 0)) != 0:
                raise RuntimeError(f"full parity mode requires unresolved_shards=0; got {import_stats}")
            if fallback_reads != 0:
                raise RuntimeError(f"full parity mode requires fallback_reads=0; got {fallback_reads}")
            if managed_weights_source != "tensor_map":
                raise RuntimeError(f"full parity mode requires managed_weights_source=tensor_map; got {managed_weights_source}")

            engine_dir = build_engine(
                runtime_dir,
                model_root=runtime_root,
                source_mode=source_mode,
                model_id=model_id,
                manifest_digest=model_digest,
                content_key=content_key,
                startup_mode=startup_mode,
                force_rebuild_override=(startup_mode != "fast"),
            )
            if heartbeat is not None:
                heartbeat.assert_healthy()
            answer_sha, first_token_ms, managed_stats = run_tensorrt_infer(
                engine_dir,
                runtime_dir,
                tensors=tensors,
                native_module=native_module,
                require_direct=require_direct,
                device_index=runtime_device_index,
            )
            if managed_stats.get("status") != "ok":
                raise RuntimeError(f"full parity mode requires managed weights status=ok; got {managed_stats}")
            mapped_weights = int(managed_stats.get("mapped_weights", 0))
            if mapped_weights != int(map_stats.get("total_tensors", 0)):
                raise RuntimeError(
                    "full parity mode requires managed weights coverage to equal tensor-map coverage; "
                    f"managed={mapped_weights} tensor_map={map_stats.get('total_tensors', 0)}"
                )
            emit_phase_timing("first-token", first_token_ms, mode=perf_mode)
        if heartbeat is not None:
            heartbeat.stop()
            heartbeat = None

        detach_req = {
            "allocation_id": allocation_id,
            "client_id": attach_client_id,
        }
        detach_code, detach_payload = unix_http_json(socket_path, "POST", "/v2/gpu/detach", detach_req, timeout_seconds=120)
        assert_http_ok(detach_code, detach_payload, "gpu/detach")
        attached = False
        print(f"DAEMON_GPU_DETACH_OK detached_files={detach_payload.get('detached_files', 0)}")

        unload_req = {"allocation_id": allocation_id}
        unload_code, unload_payload = unix_http_json(socket_path, "POST", "/v2/gpu/unload", unload_req, timeout_seconds=300)
        assert_http_ok(unload_code, unload_payload, "gpu/unload")
        load_ready = False
        print("DAEMON_GPU_UNLOAD_OK")

        post_code, post_payload = unix_http_json(
            socket_path,
            "GET",
            f"/v2/gpu/status?device_uuid={device_uuid}",
            payload=None,
            timeout_seconds=60,
        )
        assert_http_ok(post_code, post_payload, "post-unload gpu/status")
        post_files = post_payload.get("files", []) if isinstance(post_payload, dict) else []
        if post_files:
            raise RuntimeError(f"persistent allocations still loaded after unload: count={len(post_files)}")
    finally:
        if heartbeat is not None:
            try:
                heartbeat.stop()
            except Exception as exc:
                print(f"DAEMON_GPU_HEARTBEAT_WARN keepalive=true finalizer_error={exc}")

        if attached:
            detach_req = {
                "allocation_id": allocation_id,
                "client_id": attach_client_id,
            }
            try:
                detach_code, detach_payload = unix_http_json(
                    socket_path,
                    "POST",
                    "/v2/gpu/detach",
                    detach_req,
                    timeout_seconds=120,
                )
                assert_http_ok(detach_code, detach_payload, "gpu/detach(finalizer)")
                print(f"DAEMON_GPU_DETACH_OK detached_files={detach_payload.get('detached_files', 0)} finalizer=true")
            except Exception as exc:
                print(f"DAEMON_GPU_DETACH_WARN error={exc}")

        if load_ready:
            unload_req = {"allocation_id": allocation_id}
            try:
                unload_code, unload_payload = unix_http_json(
                    socket_path,
                    "POST",
                    "/v2/gpu/unload",
                    unload_req,
                    timeout_seconds=300,
                )
                assert_http_ok(unload_code, unload_payload, "gpu/unload(finalizer)")
                print("DAEMON_GPU_UNLOAD_OK finalizer=true")
            except Exception as exc:
                print(f"DAEMON_GPU_UNLOAD_WARN error={exc}")

    cuda_name = torch.cuda.get_device_name(runtime_device_index)
    print(
        "TENSORRT_DAEMON_CLIENT_SUCCESS "
        f"model_id={metadata.get('modelId')} "
        f"manifest={metadata.get('manifestDigest')} "
        f"sample_sha256={sample_sha} "
        f"direct_files={direct_files} "
        f"answer_sha256={answer_sha} "
        f"backend={tensorrtllm_backend} "
        f"parity_mode={parity_mode} "
        f"mapped_tensors={map_stats.get('mapped_tensors', 0)} "
        f"mapped_bytes={map_stats.get('mapped_bytes', 0)} "
        f"imported_shards={import_stats.get('imported_shards', 0)} "
        f"imported_tensors={import_stats.get('imported_tensors', 0)} "
        f"imported_bytes={import_stats.get('imported_bytes', 0)} "
        f"source_mode={source_mode} "
        f"managed_weights_source={managed_weights_source} "
        f"managed_weights={managed_stats.get('mapped_weights', 0)} "
        f"aliased_params={alias_stats.get('aliased_params', 0)} "
        f"aliased_bytes={alias_stats.get('aliased_bytes', 0)} "
        f"startup_mode={startup_mode} "
        f"fallback_reads={fallback_reads} "
        f"cuda_device={cuda_name}"
    )


if __name__ == "__main__":
    main()
