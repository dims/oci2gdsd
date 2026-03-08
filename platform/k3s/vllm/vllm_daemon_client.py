import gc
import hashlib
import json
import os
import shutil
import subprocess
from importlib.util import find_spec
from pathlib import Path

import torch

from daemon_client_common import (
    assert_http_ok,
    assert_no_runtime_artifact_access,
    create_gpu_allocation,
    hydrate_runtime_bundle,
    parse_bool_env,
    resolve_device_uuid,
    torch_dtype_from_safetensors,
    unix_http_json,
    load_native_module as _load_native_module_common,
)


def load_native_module():
    return _load_native_module_common(
        build_dir_default="/tmp/oci2gds_vllm_build",
        module_name_prefix="oci2gds_vllm_native",
        required_symbol="import_ipc_tensor_view",
    )


def bind_parameters_from_tensor_map(model, tensor_map, native_module, device_index: int, require_full: bool):
    by_name = {}
    for entry in tensor_map:
        name = str(entry.get("name", "")).strip()
        if not name:
            continue
        by_name[name] = entry

    imported_source_views = {}
    imported_source_bytes = {}

    def import_source_tensor(source_name: str, expected_dtype: torch.dtype):
        if source_name in imported_source_views:
            return imported_source_views[source_name], imported_source_bytes[source_name]

        spec = by_name.get(source_name)
        if spec is None:
            return None, 0

        handle = str(spec.get("ipc_handle", "")).strip()
        if not handle:
            raise RuntimeError(f"tensor {source_name} is missing ipc_handle")

        shape = [int(x) for x in spec.get("shape", [])]
        if not shape:
            raise RuntimeError(f"tensor {source_name} has empty shape in tensor map")

        dtype_code = str(spec.get("dtype", "")).strip()
        source_dtype = torch_dtype_from_safetensors(dtype_code)
        if source_dtype != expected_dtype:
            raise RuntimeError(
                f"dtype mismatch for {source_name}: map={source_dtype} expected={expected_dtype}"
            )

        byte_offset = int(spec.get("byte_offset", 0))
        byte_length = int(spec.get("byte_length", 0))
        if byte_offset < 0 or byte_length <= 0:
            raise RuntimeError(
                f"invalid byte range for {source_name}: offset={byte_offset} length={byte_length}"
            )

        view = native_module.import_ipc_tensor_view(
            handle,
            int(byte_offset),
            shape,
            dtype_code,
            int(device_index),
        )
        if view.dtype != expected_dtype:
            raise RuntimeError(
                f"imported view dtype mismatch for {source_name}: view={view.dtype} expected={expected_dtype}"
            )

        imported_source_views[source_name] = view
        imported_source_bytes[source_name] = byte_length
        return view, byte_length

    def maybe_import_fused_tensor(param_name: str, expected_dtype: torch.dtype):
        if ".self_attn.qkv_proj.weight" in param_name:
            prefix = param_name.rsplit(".self_attn.qkv_proj.weight", 1)[0]
            source_names = [
                f"{prefix}.self_attn.q_proj.weight",
                f"{prefix}.self_attn.k_proj.weight",
                f"{prefix}.self_attn.v_proj.weight",
            ]
        elif ".mlp.gate_up_proj.weight" in param_name:
            prefix = param_name.rsplit(".mlp.gate_up_proj.weight", 1)[0]
            source_names = [
                f"{prefix}.mlp.gate_proj.weight",
                f"{prefix}.mlp.up_proj.weight",
            ]
        else:
            return None

        parts = []
        total_bytes = 0
        for source_name in source_names:
            view, byte_length = import_source_tensor(source_name, expected_dtype)
            if view is None:
                return None
            parts.append(view)
            total_bytes += byte_length

        if not parts:
            return None
        return torch.cat(parts, dim=0), total_bytes

    rebound_names = set()
    rebound_ptrs = set()
    rebound_params = 0
    rebound_bytes = 0
    fused_params = 0
    unresolved = []

    for name, param in model.named_parameters():
        spec = by_name.get(name)
        if spec is None:
            fused = maybe_import_fused_tensor(name, param.dtype)
            if fused is None:
                if require_full:
                    unresolved.append(name)
                continue
            view, byte_length = fused
            fused_params += 1
        else:
            view, byte_length = import_source_tensor(name, param.dtype)
            if view is None:
                if require_full:
                    unresolved.append(name)
                continue

        if tuple(view.shape) != tuple(param.shape):
            raise RuntimeError(f"shape mismatch for {name}: view={tuple(view.shape)} model={tuple(param.shape)}")
        if view.dtype != param.dtype:
            raise RuntimeError(f"dtype mismatch for {name}: view={view.dtype} model={param.dtype}")

        param.data.copy_(view)
        param.requires_grad_(False)

        rebound_names.add(name)
        rebound_ptrs.add(int(param.data_ptr()))
        rebound_params += 1
        rebound_bytes += byte_length

    if hasattr(model, "tie_weights"):
        model.tie_weights()

    unresolved_after_tie = []
    for name, param in model.named_parameters():
        if name in rebound_names:
            continue
        if int(param.data_ptr()) in rebound_ptrs:
            continue
        unresolved_after_tie.append(name)

    if require_full and unresolved_after_tie:
        raise RuntimeError(f"unresolved parameters not rebound from IPC: {unresolved_after_tie[:10]}")

    status = "ok"
    if not require_full and unresolved_after_tie:
        status = "partial"

    return {
        "status": status,
        "rebound_params": rebound_params,
        "rebound_bytes": rebound_bytes,
        "fused_params": fused_params,
        "unresolved": len(unresolved_after_tie),
    }


def build_runtime_dir(model_root: Path) -> Path:
    profile = json.loads((model_root / "metadata" / "model.json").read_text(encoding="utf-8")).get("profile", {})
    shard_entries = sorted(profile.get("shards", []), key=lambda s: int(s.get("ordinal", 0)))
    if not shard_entries:
        raise RuntimeError("profile.shards is empty")

    runtime_dir = Path(os.environ.get("LOCAL_MODEL_DIR", "/tmp/oci2gdsd-vllm-model"))
    if runtime_dir.exists():
        for p in runtime_dir.iterdir():
            if p.is_symlink() or p.is_file():
                p.unlink()
            else:
                raise RuntimeError(f"runtime dir contains non-file entry: {p}")
    else:
        runtime_dir.mkdir(parents=True, exist_ok=True)

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
        os.symlink(src, runtime_dir / name)

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
    return runtime_dir


OCI2GDS_BIND_STATS = {
    "status": "skipped",
    "rebound_params": 0,
    "rebound_bytes": 0,
    "fused_params": 0,
    "unresolved": 0,
}
OCI2GDS_NATIVE_MODULE = None
OCI2GDS_PARITY_MODE = "probe"
OCI2GDS_TENSOR_MAP = []
OCI2GDS_DEVICE_INDEX = 0


def register_oci2gds_loader():
    if getattr(register_oci2gds_loader, "_done", False):
        return

    from vllm.config.load import LoadConfig
    from vllm.model_executor.model_loader import register_model_loader
    from vllm.model_executor.model_loader.base_loader import BaseModelLoader
    from vllm.model_executor.model_loader.default_loader import DefaultModelLoader

    @register_model_loader("oci2gds")
    class OCI2GDSModelLoader(BaseModelLoader):
        def __init__(self, load_config: LoadConfig):
            super().__init__(load_config)
            extra = dict(load_config.model_loader_extra_config or {})
            self._resolved_path = str(extra.get("resolved_model_path", "")).strip()
            self._parity_mode = str(extra.get("oci2gds_parity_mode", OCI2GDS_PARITY_MODE)).strip().lower()
            self._device_index = int(extra.get("oci2gds_device_index", OCI2GDS_DEVICE_INDEX))
            self._bind_stats_path = str(extra.get("oci2gds_bind_stats_path", "")).strip()
            tensor_map_path = str(extra.get("oci2gds_tensor_map_path", "")).strip()
            if tensor_map_path:
                self._tensor_map = json.loads(Path(tensor_map_path).read_text(encoding="utf-8"))
            else:
                self._tensor_map = list(extra.get("oci2gds_tensor_map", OCI2GDS_TENSOR_MAP) or [])
            self._delegate_format = str(extra.get("delegate_load_format", "safetensors")).strip().lower()
            if not self._delegate_format:
                self._delegate_format = "safetensors"
            allowed = {"fastsafetensors", "safetensors", "auto", "hf", "pt"}
            if self._delegate_format not in allowed:
                raise ValueError(
                    f"unsupported delegate_load_format={self._delegate_format}, expected one of {sorted(allowed)}"
                )

            delegate_extra = {}
            for key in ("enable_multithread_load", "num_threads"):
                if key in extra:
                    delegate_extra[key] = extra[key]

            self._delegate_cfg = LoadConfig(
                load_format=self._delegate_format,
                download_dir=load_config.download_dir,
                safetensors_load_strategy=load_config.safetensors_load_strategy,
                model_loader_extra_config=delegate_extra,
                device=load_config.device,
                ignore_patterns=load_config.ignore_patterns,
                use_tqdm_on_load=load_config.use_tqdm_on_load,
                pt_load_map_location=load_config.pt_load_map_location,
            )
            self._delegate = DefaultModelLoader(self._delegate_cfg)

        def _resolve_model_path(self, model_ref: str) -> Path:
            if self._resolved_path:
                return Path(self._resolved_path)

            ref = str(model_ref).strip()
            if ref.startswith("oci2gds://"):
                spec = ref[len("oci2gds://") :]
                if "@" not in spec:
                    raise RuntimeError(f"invalid oci2gds reference (missing @digest): {ref}")
                model_id, digest = spec.split("@", 1)
                model_id = model_id.strip()
                digest = digest.strip()
                if not model_id or not digest:
                    raise RuntimeError(f"invalid oci2gds reference: {ref}")
                root = Path(os.environ.get("OCI2GDSD_ROOT_PATH", "/var/lib/oci2gdsd"))
                return root / "models" / model_id / digest.replace(":", "-")

            return Path(ref)

        def _run_with_resolved_model(self, model_config, fn):
            resolved = self._resolve_model_path(model_config.model)
            if not resolved.exists():
                raise RuntimeError(f"resolved model path does not exist: {resolved}")

            original_model = model_config.model
            original_model_weights = getattr(model_config, "model_weights", None)
            model_config.model = str(resolved)
            if hasattr(model_config, "model_weights"):
                model_config.model_weights = None
            try:
                return fn()
            finally:
                model_config.model = original_model
                if hasattr(model_config, "model_weights"):
                    model_config.model_weights = original_model_weights

        def download_model(self, model_config) -> None:
            self._run_with_resolved_model(model_config, lambda: self._delegate.download_model(model_config))

        def load_weights(self, model, model_config) -> None:
            global OCI2GDS_BIND_STATS
            global OCI2GDS_NATIVE_MODULE

            parity_mode = str(self._parity_mode).strip().lower()
            require_full = parity_mode == "full"
            use_ipc = parity_mode in {"partial", "full"}

            if not use_ipc:
                self._run_with_resolved_model(model_config, lambda: self._delegate.load_weights(model, model_config))
                OCI2GDS_BIND_STATS = {
                    "status": "skipped",
                    "rebound_params": 0,
                    "rebound_bytes": 0,
                    "fused_params": 0,
                    "unresolved": 0,
                }
                return

            if OCI2GDS_NATIVE_MODULE is None:
                OCI2GDS_NATIVE_MODULE = load_native_module()
            if not self._tensor_map:
                raise RuntimeError("parity mode requires non-empty tensor map")

            if not require_full:
                self._run_with_resolved_model(model_config, lambda: self._delegate.load_weights(model, model_config))

            stats = bind_parameters_from_tensor_map(
                model=model,
                tensor_map=self._tensor_map,
                native_module=OCI2GDS_NATIVE_MODULE,
                device_index=int(self._device_index),
                require_full=require_full,
            )
            OCI2GDS_BIND_STATS = stats
            if self._bind_stats_path:
                Path(self._bind_stats_path).write_text(json.dumps(stats), encoding="utf-8")

    register_oci2gds_loader._done = True


def run_vllm_infer(model_id: str, model_digest: str, runtime_dir: Path, device_index: int, parity_mode: str, tensor_map):
    global OCI2GDS_NATIVE_MODULE
    global OCI2GDS_PARITY_MODE
    global OCI2GDS_TENSOR_MAP
    global OCI2GDS_DEVICE_INDEX

    from vllm import LLM, SamplingParams

    delegate_load_format = os.environ.get("VLLM_DELEGATE_LOAD_FORMAT", "").strip().lower()
    if not delegate_load_format:
        delegate_load_format = "fastsafetensors" if find_spec("fastsafetensors") else "safetensors"

    OCI2GDS_PARITY_MODE = str(parity_mode).strip().lower()
    OCI2GDS_TENSOR_MAP = list(tensor_map)
    OCI2GDS_DEVICE_INDEX = int(device_index)

    register_oci2gds_loader()
    print(
        "VLLM_LOADER_REGISTERED "
        f"load_format=oci2gds delegate={delegate_load_format} runtime_dir={runtime_dir} parity_mode={OCI2GDS_PARITY_MODE}"
    )

    prompt = os.environ.get(
        "PROMPT",
        "Say hello from a vLLM loader plugin that consumes daemon-exported IPC tensors.",
    )
    model_ref = f"oci2gds://{model_id}@{model_digest}"
    model_path = str(runtime_dir)
    bind_stats_path = Path(
        os.environ.get("OCI2GDS_VLLM_BIND_STATS_PATH", "/tmp/oci2gdsd-vllm-bind-stats.json")
    )
    tensor_map_path = Path(
        os.environ.get("OCI2GDS_VLLM_TENSOR_MAP_PATH", "/tmp/oci2gdsd-vllm-tensor-map.json")
    )
    try:
        bind_stats_path.unlink(missing_ok=True)
    except Exception:
        pass
    tensor_map_path.write_text(json.dumps(OCI2GDS_TENSOR_MAP), encoding="utf-8")

    sampling = SamplingParams(max_tokens=64, temperature=0.0)
    llm = LLM(
        model=model_path,
        load_format="oci2gds",
        model_loader_extra_config={
            "resolved_model_path": str(runtime_dir),
            "delegate_load_format": delegate_load_format,
            "oci2gds_model_ref": model_ref,
            "oci2gds_parity_mode": OCI2GDS_PARITY_MODE,
            "oci2gds_tensor_map_path": str(tensor_map_path),
            "oci2gds_device_index": OCI2GDS_DEVICE_INDEX,
            "oci2gds_bind_stats_path": str(bind_stats_path),
        },
        trust_remote_code=True,
        tensor_parallel_size=1,
        gpu_memory_utilization=float(os.environ.get("GPU_MEMORY_UTILIZATION", "0.80")),
        max_model_len=int(os.environ.get("MAX_MODEL_LEN", "1024")),
        enforce_eager=True,
    )
    print(f"VLLM_OCI2GDS_LOAD_OK model_ref={model_ref} model_path={model_path}")

    outputs = llm.generate([prompt], sampling)
    if not outputs or not outputs[0].outputs:
        raise RuntimeError("vLLM generate returned empty outputs")
    answer = outputs[0].outputs[0].text
    if not answer.strip():
        raise RuntimeError("vLLM generated empty text")

    answer_sha = hashlib.sha256(answer.encode("utf-8")).hexdigest()
    answer_len = len(answer)

    bind_stats = dict(OCI2GDS_BIND_STATS)
    if bind_stats_path.exists():
        try:
            bind_stats = json.loads(bind_stats_path.read_text(encoding="utf-8"))
        except Exception:
            pass

    del llm
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.synchronize(device_index)
        torch.cuda.empty_cache()

    return answer_sha, answer_len, bind_stats


def main():
    runtime_root = Path(os.environ.get("RUNTIME_BUNDLE_ROOT", "/tmp/oci2gdsd-runtime-bundle"))
    assert_no_runtime_artifact_access()
    model_ref = os.environ["MODEL_REF"]
    model_id = os.environ["MODEL_ID"]
    model_digest = os.environ.get("MODEL_DIGEST", "").strip()
    lease_holder = os.environ.get("LEASE_HOLDER", "vllm-daemon-client")
    socket_path = os.environ.get("OCI2GDS_DAEMON_SOCKET", "/run/oci2gdsd/daemon.sock")
    device_index = int(os.environ.get("DEVICE_INDEX", "0"))
    device_uuid = resolve_device_uuid(device_index)
    strict_load = parse_bool_env("OCI2GDS_STRICT", True)
    require_direct = parse_bool_env("REQUIRE_DIRECT_GDS", True)

    parity_mode = str(os.environ.get("RUNTIME_PARITY_MODE", "full")).strip().lower()
    if parity_mode != "full":
        raise RuntimeError("vLLM daemon-client requires RUNTIME_PARITY_MODE=full; path-backed modes are removed")

    allocation = create_gpu_allocation(
        socket_path=socket_path,
        model_ref=model_ref,
        model_id=model_id,
        lease_holder=lease_holder,
        device_uuid=device_uuid,
        strict=strict_load,
    )
    allocation_id = str(allocation.get("allocation_id", "")).strip()
    if not allocation_id:
        raise RuntimeError(f"gpu/allocate returned empty allocation_id: {allocation}")
    runtime_bundle_token = str(allocation.get("runtime_bundle_token", "")).strip()
    if not runtime_bundle_token:
        raise RuntimeError(f"gpu/allocate returned empty runtime_bundle_token: {allocation}")
    model_digest = str(allocation.get("manifest_digest", model_digest)).strip()
    if not model_digest:
        raise RuntimeError(f"gpu/allocate returned empty manifest digest: {allocation}")
    hydrate_runtime_bundle(socket_path, runtime_root, runtime_bundle_token)

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
    answer_len = 0
    bind_stats = {
        "status": "skipped",
        "rebound_params": 0,
        "rebound_bytes": 0,
        "fused_params": 0,
        "unresolved": 0,
    }
    attach_client_id = f"{lease_holder}-vllm-{os.getpid()}"

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

        tensor_req = {
            "allocation_id": allocation_id,
            "max_shards": 0,
            "max_tensors": int(os.environ.get("MAX_TENSOR_MAP_TENSORS", "0")),
            "include_handles": True,
        }
        tensor_code, tensor_payload = unix_http_json(socket_path, "POST", "/v2/gpu/tensor-map", tensor_req, timeout_seconds=300)
        assert_http_ok(tensor_code, tensor_payload, "gpu/tensor-map")
        tensors = tensor_payload.get("tensors", []) if isinstance(tensor_payload, dict) else []
        if not tensors:
            raise RuntimeError(f"gpu/tensor-map returned no tensors: {tensor_payload}")
        tensor_bytes = sum(int(t.get("byte_length", 0)) for t in tensors)
        print(f"VLLM_IPC_TENSOR_MAP_OK tensors={len(tensors)} tensor_bytes={tensor_bytes}")

        runtime_dir = build_runtime_dir(runtime_root)
        answer_sha, answer_len, bind_stats = run_vllm_infer(
            model_id=model_id,
            model_digest=model_digest,
            runtime_dir=runtime_dir,
            device_index=device_index,
            parity_mode=parity_mode,
            tensor_map=tensors,
        )

        print(
            "VLLM_IPC_BIND_OK "
            f"status={bind_stats.get('status', 'unknown')} "
            f"rebound_params={bind_stats.get('rebound_params', 0)} "
            f"rebound_bytes={bind_stats.get('rebound_bytes', 0)} "
            f"fused_params={bind_stats.get('fused_params', 0)} "
            f"unresolved={bind_stats.get('unresolved', 0)} "
            f"parity_mode={parity_mode}"
        )
        if parity_mode == "full":
            if bind_stats.get("status") != "ok":
                raise RuntimeError(f"full parity mode requires status=ok; got {bind_stats}")
            if int(bind_stats.get("rebound_params", 0)) <= 0:
                raise RuntimeError("full parity mode requires rebound_params > 0")
            if int(bind_stats.get("unresolved", 0)) != 0:
                raise RuntimeError(f"full parity mode requires unresolved=0; got {bind_stats}")

        print(f"VLLM_QWEN_INFER_OK answer_sha256={answer_sha} answer_len={answer_len}")

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

    if not torch.cuda.is_available():
        raise RuntimeError("torch.cuda.is_available() is false")
    cuda_name = torch.cuda.get_device_name(device_index)
    print(
        "VLLM_DAEMON_CLIENT_SUCCESS "
        f"model_id={metadata.get('modelId')} "
        f"manifest={metadata.get('manifestDigest')} "
        f"sample_sha256={sample_sha} "
        f"direct_files={direct_files} "
        f"answer_sha256={answer_sha} "
        f"answer_len={answer_len} "
        f"parity_mode={parity_mode} "
        f"rebound_params={bind_stats.get('rebound_params', 0)} "
        f"rebound_bytes={bind_stats.get('rebound_bytes', 0)} "
        f"fused_params={bind_stats.get('fused_params', 0)} "
        f"cuda_device={cuda_name}"
    )


if __name__ == "__main__":
    main()
