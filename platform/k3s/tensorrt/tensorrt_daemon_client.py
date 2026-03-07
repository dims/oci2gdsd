import gc
import hashlib
import io
import json
import os
import re
import shutil
import socket
import subprocess
import threading
import time
import tarfile
from pathlib import Path

import torch
from transformers import AutoTokenizer


def parse_bool_env(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


GPU_UUID_PATTERN = re.compile(r"^GPU-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


def resolve_device_uuid(device_index: int) -> str:
    explicit = os.environ.get("DEVICE_UUID", "").strip()
    if explicit:
        if not GPU_UUID_PATTERN.match(explicit):
            raise RuntimeError(f"DEVICE_UUID is not a canonical GPU UUID: {explicit}")
        return explicit

    visible = os.environ.get("NVIDIA_VISIBLE_DEVICES", "").strip()
    if visible and visible.lower() not in {"none", "void"}:
        first = visible.split(",")[0].strip()
        if GPU_UUID_PATTERN.match(first):
            return first

    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=uuid", "--format=csv,noheader"],
            text=True,
            stderr=subprocess.STDOUT,
        )
    except Exception as exc:
        raise RuntimeError(f"failed to resolve GPU UUID via nvidia-smi: {exc}") from exc

    uuids = [line.strip() for line in out.splitlines() if line.strip()]
    if device_index < 0 or device_index >= len(uuids):
        raise RuntimeError(f"device index {device_index} out of range for discovered GPU UUIDs: {uuids}")
    candidate = uuids[device_index]
    if not GPU_UUID_PATTERN.match(candidate):
        raise RuntimeError(f"nvidia-smi returned non-canonical GPU UUID: {candidate}")
    return candidate


def _decode_chunked_body(body_raw: bytes) -> bytes:
    out = bytearray()
    pos = 0
    total = len(body_raw)
    while True:
        line_end = body_raw.find(b"\r\n", pos)
        if line_end < 0:
            raise RuntimeError("malformed chunked response: missing chunk-size line")
        size_line = body_raw[pos:line_end].decode("ascii", errors="replace")
        size_token = size_line.split(";", 1)[0].strip()
        try:
            size = int(size_token, 16)
        except ValueError as exc:
            raise RuntimeError(f"malformed chunked response: invalid chunk size {size_token!r}") from exc
        pos = line_end + 2
        if size == 0:
            return bytes(out)
        if pos + size > total:
            raise RuntimeError("malformed chunked response: truncated chunk payload")
        out.extend(body_raw[pos:pos + size])
        pos += size
        if body_raw[pos:pos + 2] != b"\r\n":
            raise RuntimeError("malformed chunked response: missing chunk terminator")
        pos += 2


def unix_http_request(socket_path: str, method: str, path: str, payload=None, timeout_seconds: int = 120):
    body = b""
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    req_lines = [
        f"{method} {path} HTTP/1.1",
        "Host: localhost",
        "Connection: close",
    ]
    if body:
        req_lines.append("Content-Type: application/json")
        req_lines.append(f"Content-Length: {len(body)}")
    raw = ("\r\n".join(req_lines) + "\r\n\r\n").encode("utf-8") + body

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout_seconds)
    try:
        sock.connect(socket_path)
        sock.sendall(raw)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        sock.close()

    data = b"".join(chunks)
    header_raw, sep, body_raw = data.partition(b"\r\n\r\n")
    if not sep:
        raise RuntimeError("malformed daemon HTTP response")
    status_line = header_raw.decode("utf-8", errors="replace").splitlines()[0]
    parts = status_line.split(" ")
    if len(parts) < 2:
        raise RuntimeError(f"invalid daemon status line: {status_line}")
    status_code = int(parts[1])
    headers = {}
    for line in header_raw.decode("utf-8", errors="replace").splitlines()[1:]:
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        headers[k.strip().lower()] = v.strip()
    transfer_encoding = headers.get("transfer-encoding", "").lower()
    if "chunked" in transfer_encoding:
        body_raw = _decode_chunked_body(body_raw)
    else:
        content_length = headers.get("content-length", "")
        if content_length:
            try:
                body_raw = body_raw[: int(content_length)]
            except ValueError:
                pass
    return status_code, headers, body_raw


def unix_http_json(socket_path: str, method: str, path: str, payload=None, timeout_seconds: int = 120):
    status_code, _, body_raw = unix_http_request(
        socket_path=socket_path,
        method=method,
        path=path,
        payload=payload,
        timeout_seconds=timeout_seconds,
    )
    payload_out = {}
    if body_raw.strip():
        text = body_raw.decode("utf-8", errors="replace").strip()
        start_obj = [idx for idx in (text.find("{"), text.find("[")) if idx >= 0]
        if start_obj:
            text = text[min(start_obj):]
        try:
            payload_out = json.loads(text)
        except json.JSONDecodeError:
            decoder = json.JSONDecoder()
            payload_out, consumed = decoder.raw_decode(text)
            trailing = text[consumed:].strip()
            if trailing:
                print(f"WARN_DAEMON_HTTP_TRAILING_BYTES bytes={len(trailing)}")
    return status_code, payload_out


def assert_http_ok(code: int, payload, action: str):
    if code >= 300:
        raise RuntimeError(f"{action} failed: code={code} payload={payload}")
    if isinstance(payload, dict) and str(payload.get("status", "")).upper() == "FAILED":
        raise RuntimeError(f"{action} returned FAILED payload={payload}")


def ensure_model_ready(socket_path: str, model_ref: str, model_id: str, lease_holder: str):
    req = {
        "ref": model_ref,
        "model_id": model_id,
        "lease_holder": lease_holder,
        "strict_integrity": True,
        "wait": True,
    }
    code, payload = unix_http_json(socket_path, "POST", "/v1/model/ensure", req, timeout_seconds=1800)
    assert_http_ok(code, payload, "model/ensure")
    if str(payload.get("status", "")).upper() != "READY":
        raise RuntimeError(f"model/ensure did not return READY: {payload}")
    print(f"DAEMON_MODEL_ENSURE_READY model_id={payload.get('model_id', model_id)} digest={payload.get('manifest_digest', '')}")


def hydrate_model_root(socket_path: str, model_root: Path, model_id: str, model_digest: str):
    if model_root.exists():
        shutil.rmtree(model_root)
    model_root.mkdir(parents=True, exist_ok=True)
    req = {
        "model_id": model_id,
        "digest": model_digest,
        "include_weights": False,
    }
    code, _, payload = unix_http_request(
        socket_path=socket_path,
        method="POST",
        path="/v1/model/runtime-bundle",
        payload=req,
        timeout_seconds=600,
    )
    if code >= 300:
        text = payload.decode("utf-8", errors="replace")
        raise RuntimeError(f"model/runtime-bundle failed: code={code} body={text}")
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:") as tf:
        tf.extractall(path=str(model_root))
    if not (model_root / "metadata" / "model.json").exists():
        raise RuntimeError(f"runtime bundle missing metadata/model.json in {model_root}")
    if not (model_root / "shards" / "config.json").exists():
        raise RuntimeError(f"runtime bundle missing shards/config.json in {model_root}")
    print(f"DAEMON_RUNTIME_BUNDLE_READY files_root={model_root}")


def _native_cpp_source_path() -> Path:
    raw = os.environ.get("OCI2GDS_NATIVE_CPP_PATH", "").strip()
    if raw:
        return Path(raw)
    return Path("/scripts/oci2gds_torch_native.cpp")


def _load_native_cpp_source() -> str:
    source_path = _native_cpp_source_path()
    if not source_path.exists():
        raise RuntimeError(f"native C++ source not found: {source_path}")
    return source_path.read_text(encoding="utf-8")


def _native_enabled() -> bool:
    flag = os.environ.get("OCI2GDS_TORCH_ENABLE_NATIVE", "1").strip().lower()
    return flag not in {"0", "false", "no"}


def _ensure_cuda_linkage_paths():
    cuda_lib = Path(os.environ.get("CUDA_LIB_DIR", "/usr/local/cuda/lib64"))
    cufile_soname = cuda_lib / "libcufile.so.0"
    cufile_link = cuda_lib / "libcufile.so"
    if not cufile_link.exists() and cufile_soname.exists():
        cufile_link.symlink_to(cufile_soname.name)
    usr_link = Path("/usr/lib/x86_64-linux-gnu/libcufile.so")
    if not usr_link.exists() and cufile_link.exists():
        usr_link.symlink_to(cufile_link)

    libcuda_soname = cuda_lib / "libcuda.so.1"
    compat_libcuda = Path("/usr/local/cuda/compat/libcuda.so.1")
    if not libcuda_soname.exists() and compat_libcuda.exists():
        libcuda_soname.symlink_to(compat_libcuda)


def load_native_module():
    if not _native_enabled():
        raise RuntimeError("native backend disabled")
    if not torch.cuda.is_available():
        raise RuntimeError("cuda unavailable")
    try:
        from torch.utils.cpp_extension import load_inline
    except Exception as exc:
        raise RuntimeError(f"torch cpp extension unavailable: {exc}") from exc

    _ensure_cuda_linkage_paths()

    build_dir = Path(os.environ.get("OCI2GDS_TORCH_BUILD_DIR", "/tmp/oci2gds_tensorrt_build"))
    build_dir.mkdir(parents=True, exist_ok=True)

    include_paths = []
    cuda_include = os.environ.get("CUDA_INCLUDE_DIR", "").strip()
    if cuda_include:
        include_paths.append(cuda_include)
    ldflags = []
    cuda_lib = os.environ.get("CUDA_LIB_DIR", "").strip()
    if cuda_lib:
        ldflags.append(f"-L{cuda_lib}")
    ldflags.extend(["-lcuda", "-lcufile"])

    native_cpp = _load_native_cpp_source()
    verbose = os.environ.get("OCI2GDS_TORCH_NATIVE_VERBOSE", "0").strip() == "1"
    name = f"oci2gds_tensorrt_native_{os.getpid()}"
    module = load_inline(
        name=name,
        cpp_sources=[native_cpp],
        functions=None,
        extra_cflags=["-O3", "-std=c++17"],
        extra_ldflags=ldflags,
        extra_include_paths=include_paths,
        with_cuda=False,
        build_directory=str(build_dir),
        verbose=verbose,
    )
    if hasattr(module, "init_native"):
        module.init_native()
    if not hasattr(module, "import_ipc_copy_to_tensor"):
        raise RuntimeError("native module missing import_ipc_copy_to_tensor")
    return module


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


def profile_shards_from_metadata(metadata: dict):
    profile = metadata.get("profile", {})
    shard_entries = sorted(profile.get("shards", []), key=lambda s: int(s.get("ordinal", 0)))
    if not shard_entries:
        raise RuntimeError("profile.shards is empty")
    return shard_entries


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


def build_engine(runtime_dir: Path, model_root: Path, source_mode: str, force_rebuild_override: bool = False) -> Path:
    cache_root = model_root / ".trt-cache"
    checkpoint_dir = Path(os.environ.get("TRT_CHECKPOINT_DIR", str(cache_root / "checkpoint")))
    engine_dir = Path(os.environ.get("TRT_ENGINE_DIR", str(cache_root / "engine")))
    force_rebuild = parse_bool_env("TRT_FORCE_REBUILD", False) or force_rebuild_override

    if force_rebuild:
        shutil.rmtree(checkpoint_dir, ignore_errors=True)
        shutil.rmtree(engine_dir, ignore_errors=True)

    if engine_ready(engine_dir):
        print(f"TENSORRT_ENGINE_BUILD_OK reused=true source={source_mode} engine_dir={engine_dir}")
        return engine_dir

    convert_script = find_qwen_convert_script()
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    engine_dir.mkdir(parents=True, exist_ok=True)

    dtype = os.environ.get("TRT_DTYPE", "float16").strip() or "float16"
    max_input_len = int(os.environ.get("TRT_MAX_INPUT_LEN", "512"))
    max_seq_len = int(os.environ.get("TRT_MAX_SEQ_LEN", "640"))

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
    print(f"TENSORRT_ENGINE_BUILD_OK reused=false source={source_mode} engine_dir={engine_dir}")
    return engine_dir



def run_tensorrt_infer(engine_dir: Path, runtime_dir: Path, require_direct: bool, device_index: int) -> str:
    from tensorrt_llm.runtime import ModelRunnerCpp

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

    max_input_len = max(int(os.environ.get("TRT_MAX_INPUT_LEN", "512")), len(input_ids))
    max_output_len = int(os.environ.get("TRT_MAX_OUTPUT_LEN", "64"))
    runner_use_gds = parse_bool_env("TENSORRT_RUNNER_USE_GDS", False) and require_direct

    runner = ModelRunnerCpp.from_dir(
        engine_dir=str(engine_dir),
        rank=0,
        max_batch_size=1,
        max_input_len=max_input_len,
        max_output_len=max_output_len,
        max_beam_width=1,
        use_gpu_direct_storage=runner_use_gds,
        gpu_weights_percent=1.0,
    )
    print(
        "TENSORRT_GDS_RUNNER_READY "
        f"use_gpu_direct_storage={runner_use_gds} "
        f"engine_dir={engine_dir}"
    )

    outputs = runner.generate(
        batch_input_ids=[torch.tensor(input_ids, dtype=torch.int32)],
        max_new_tokens=max_output_len,
        end_id=tokenizer.eos_token_id,
        pad_id=tokenizer.eos_token_id,
        temperature=0.7,
        top_p=0.9,
        top_k=40,
        output_sequence_lengths=True,
        return_dict=True,
    )

    output_ids = outputs["output_ids"]
    sequence_lengths = outputs["sequence_lengths"]
    seq_len = int(sequence_lengths[0][0].item())
    tokens = output_ids[0][0].tolist()
    generated_ids = tokens[len(input_ids):seq_len]
    answer = tokenizer.decode(generated_ids, skip_special_tokens=True).strip()
    if not answer:
        answer = tokenizer.decode(tokens, skip_special_tokens=True).strip()
    if not answer:
        raise RuntimeError("TensorRT inference returned empty answer")

    answer_sha = hashlib.sha256(answer.encode("utf-8")).hexdigest()
    print(f"TENSORRT_QWEN_INFER_OK answer_sha256={answer_sha}")
    return answer_sha


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
                code, body = unix_http_json(self.socket_path, "POST", "/v1/gpu/heartbeat", self.payload, timeout_seconds=60)
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
    model_root = Path(os.environ.get("MODEL_ROOT_PATH", "/tmp/oci2gdsd-model-root"))
    model_ref = os.environ["MODEL_REF"]
    model_id = os.environ["MODEL_ID"]
    model_digest = os.environ["MODEL_DIGEST"]
    lease_holder = os.environ["LEASE_HOLDER"]
    socket_path = os.environ.get("OCI2GDS_DAEMON_SOCKET", "/run/oci2gdsd/daemon.sock")
    device_index = int(os.environ.get("DEVICE_INDEX", "0"))
    device_uuid = resolve_device_uuid(device_index)
    require_direct = parse_bool_env("REQUIRE_DIRECT_GDS", True)
    strict_load = parse_bool_env("OCI2GDS_STRICT", True)

    parity_mode = str(os.environ.get("RUNTIME_PARITY_MODE", "full")).strip().lower()
    if parity_mode != "full":
        raise RuntimeError("TensorRT daemon-client requires RUNTIME_PARITY_MODE=full; path-backed modes are removed")

    ensure_model_ready(socket_path, model_ref, model_id, lease_holder)
    hydrate_model_root(socket_path, model_root, model_id, model_digest)

    metadata_path = model_root / "metadata" / "model.json"
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
    attach_client_id = f"{lease_holder}-trt-{os.getpid()}"

    try:
        load_req = {
            "model_id": model_id,
            "digest": model_digest,
            "lease_holder": lease_holder,
            "device_uuid": device_uuid,
            "chunk_bytes": 4 * 1024 * 1024,
            "strict": strict_load,
            "mode": "persistent",
        }
        load_code, load_payload = unix_http_json(socket_path, "POST", "/v1/gpu/load", load_req, timeout_seconds=900)
        assert_http_ok(load_code, load_payload, "gpu/load")
        files = load_payload.get("files", []) if isinstance(load_payload, dict) else []
        if not files:
            raise RuntimeError(f"gpu/load returned no files: {load_payload}")
        direct_files = sum(1 for entry in files if bool(entry.get("direct", False)))
        if require_direct and direct_files == 0:
            raise RuntimeError(f"gpu/load returned zero direct files in strict run: {load_payload}")
        load_ready = True
        print(
            "DAEMON_GPU_LOAD_READY "
            f"files={len(files)} direct_files={direct_files} "
            f"mode={load_payload.get('mode', '')} persistent={load_payload.get('persistent', False)} "
            f"strict={strict_load}"
        )

        status_code, status_payload = unix_http_json(
            socket_path,
            "GET",
            f"/v1/gpu/status?device_uuid={device_uuid}",
            payload=None,
            timeout_seconds=60,
        )
        assert_http_ok(status_code, status_payload, "gpu/status")
        status_files = status_payload.get("files", []) if isinstance(status_payload, dict) else []
        if not status_files:
            raise RuntimeError(f"gpu/status returned no files after load: {status_payload}")
        print(f"DAEMON_GPU_STATUS_OK files={len(status_files)}")

        attach_req = {
            "model_id": model_id,
            "digest": model_digest,
            "device_uuid": device_uuid,
            "client_id": attach_client_id,
            "ttl_seconds": 300,
        }
        attach_code, attach_payload = unix_http_json(socket_path, "POST", "/v1/gpu/attach", attach_req, timeout_seconds=120)
        assert_http_ok(attach_code, attach_payload, "gpu/attach")
        attached = True
        print(
            "DAEMON_GPU_ATTACH_OK "
            f"client_id={attach_client_id} "
            f"attached_files={attach_payload.get('attached_files', 0)} "
            f"expires_at={attach_payload.get('expires_at', '')}"
        )

        hb_req = {
            "model_id": model_id,
            "digest": model_digest,
            "device_uuid": device_uuid,
            "client_id": attach_client_id,
            "ttl_seconds": 300,
        }
        hb_code, hb_payload = unix_http_json(socket_path, "POST", "/v1/gpu/heartbeat", hb_req, timeout_seconds=60)
        assert_http_ok(hb_code, hb_payload, "gpu/heartbeat")
        print(f"DAEMON_GPU_HEARTBEAT_OK expires_at={hb_payload.get('expires_at', '')}")
        heartbeat = HeartbeatKeeper(socket_path, hb_req, interval_seconds=90)
        heartbeat.start()

        tensor_req = {
            "model_id": model_id,
            "digest": model_digest,
            "device_uuid": device_uuid,
            "max_shards": 0,
            "max_tensors": int(os.environ.get("MAX_TENSOR_MAP_TENSORS", "0")),
            "include_handles": True,
        }
        tensor_code, tensor_payload = unix_http_json(socket_path, "POST", "/v1/gpu/tensor-map", tensor_req, timeout_seconds=300)
        assert_http_ok(tensor_code, tensor_payload, "gpu/tensor-map")
        tensors = tensor_payload.get("tensors", []) if isinstance(tensor_payload, dict) else []
        if not tensors:
            raise RuntimeError(f"gpu/tensor-map returned no tensors: {tensor_payload}")
        tensor_bytes = sum(int(t.get("byte_length", 0)) for t in tensors)
        print(f"TENSORRT_IPC_TENSOR_MAP_OK tensors={len(tensors)} tensor_bytes={tensor_bytes}")

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

        shard_entries = profile_shards_from_metadata(metadata)
        native_module = load_native_module()
        runtime_dir, import_stats = build_runtime_dir_from_ipc(
            model_root=model_root,
            shard_entries=shard_entries,
            tensor_map=tensors,
            native_module=native_module,
            device_index=device_index,
        )
        source_mode = "ipc_materialized"
        fallback_reads = 0
        print(
            "TENSORRT_IPC_IMPORT_OK "
            f"status={import_stats.get('status', 'unknown')} "
            f"imported_shards={import_stats.get('imported_shards', 0)} "
            f"imported_bytes={import_stats.get('imported_bytes', 0)} "
            f"linked_runtime_files={import_stats.get('linked_runtime_files', 0)} "
            f"required_ipc_shards={import_stats.get('required_ipc_shards', 0)} "
            f"unresolved_shards={import_stats.get('unresolved_shards', 0)} "
            f"parity_mode={parity_mode}"
        )
        print(
            "TENSORRT_FULL_SOURCE_OK "
            f"source={source_mode} "
            f"fallback_reads={fallback_reads} "
            f"parity_mode={parity_mode}"
        )

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

        engine_dir = build_engine(
            runtime_dir,
            model_root=model_root,
            source_mode=source_mode,
            force_rebuild_override=True,
        )
        if heartbeat is not None:
            heartbeat.assert_healthy()
        answer_sha = run_tensorrt_infer(engine_dir, runtime_dir, require_direct=require_direct, device_index=device_index)
        if heartbeat is not None:
            heartbeat.stop()
            heartbeat = None

        detach_req = {
            "model_id": model_id,
            "digest": model_digest,
            "device_uuid": device_uuid,
            "client_id": attach_client_id,
        }
        detach_code, detach_payload = unix_http_json(socket_path, "POST", "/v1/gpu/detach", detach_req, timeout_seconds=120)
        assert_http_ok(detach_code, detach_payload, "gpu/detach")
        attached = False
        print(f"DAEMON_GPU_DETACH_OK detached_files={detach_payload.get('detached_files', 0)}")

        unload_req = {
            "model_id": model_id,
            "digest": model_digest,
            "lease_holder": lease_holder,
            "device_uuid": device_uuid,
        }
        unload_code, unload_payload = unix_http_json(socket_path, "POST", "/v1/gpu/unload", unload_req, timeout_seconds=300)
        assert_http_ok(unload_code, unload_payload, "gpu/unload")
        load_ready = False
        print("DAEMON_GPU_UNLOAD_OK")

        post_code, post_payload = unix_http_json(
            socket_path,
            "GET",
            f"/v1/gpu/status?device_uuid={device_uuid}",
            payload=None,
            timeout_seconds=60,
        )
        assert_http_ok(post_code, post_payload, "post-unload gpu/status")
        post_files = post_payload.get("files", []) if isinstance(post_payload, dict) else []
        still_loaded = []
        digest_token = model_digest.replace(":", "-")
        for entry in post_files:
            p = str(entry.get("path", "")).strip()
            if p and f"/{model_id}/{digest_token}/" in p:
                still_loaded.append(p)
        if still_loaded:
            raise RuntimeError(f"model paths still loaded after unload: {still_loaded}")
    finally:
        if heartbeat is not None:
            try:
                heartbeat.stop()
            except Exception as exc:
                print(f"DAEMON_GPU_HEARTBEAT_WARN keepalive=true finalizer_error={exc}")

        if attached:
            detach_req = {
                "model_id": model_id,
                "digest": model_digest,
                "device_uuid": device_uuid,
                "client_id": attach_client_id,
            }
            try:
                detach_code, detach_payload = unix_http_json(
                    socket_path,
                    "POST",
                    "/v1/gpu/detach",
                    detach_req,
                    timeout_seconds=120,
                )
                assert_http_ok(detach_code, detach_payload, "gpu/detach(finalizer)")
                print(f"DAEMON_GPU_DETACH_OK detached_files={detach_payload.get('detached_files', 0)} finalizer=true")
            except Exception as exc:
                print(f"DAEMON_GPU_DETACH_WARN error={exc}")

        if load_ready:
            unload_req = {
                "model_id": model_id,
                "digest": model_digest,
                "lease_holder": lease_holder,
                "device_uuid": device_uuid,
            }
            try:
                unload_code, unload_payload = unix_http_json(
                    socket_path,
                    "POST",
                    "/v1/gpu/unload",
                    unload_req,
                    timeout_seconds=300,
                )
                assert_http_ok(unload_code, unload_payload, "gpu/unload(finalizer)")
                print("DAEMON_GPU_UNLOAD_OK finalizer=true")
            except Exception as exc:
                print(f"DAEMON_GPU_UNLOAD_WARN error={exc}")

    cuda_name = torch.cuda.get_device_name(device_index)
    print(
        "TENSORRT_DAEMON_CLIENT_SUCCESS "
        f"model_id={metadata.get('modelId')} "
        f"manifest={metadata.get('manifestDigest')} "
        f"sample_sha256={sample_sha} "
        f"direct_files={direct_files} "
        f"answer_sha256={answer_sha} "
        f"parity_mode={parity_mode} "
        f"mapped_tensors={map_stats.get('mapped_tensors', 0)} "
        f"mapped_bytes={map_stats.get('mapped_bytes', 0)} "
        f"imported_shards={import_stats.get('imported_shards', 0)} "
        f"imported_bytes={import_stats.get('imported_bytes', 0)} "
        f"source_mode={source_mode} "
        f"fallback_reads={fallback_reads} "
        f"cuda_device={cuda_name}"
    )


if __name__ == "__main__":
    main()
