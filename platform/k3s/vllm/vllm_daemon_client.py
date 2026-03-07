import gc
import hashlib
import io
import json
import os
import re
import shutil
import socket
import subprocess
import tarfile
from importlib.util import find_spec
from pathlib import Path

import torch


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

    build_dir = Path(os.environ.get("OCI2GDS_TORCH_BUILD_DIR", "/tmp/oci2gds_vllm_build"))
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
    name = f"oci2gds_vllm_native_{os.getpid()}"
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
    if not hasattr(module, "import_ipc_tensor_view"):
        raise RuntimeError("native module missing import_ipc_tensor_view")
    return module


def torch_dtype_from_safetensors(code: str) -> torch.dtype:
    code = str(code).strip().upper()
    if code == "BF16":
        return torch.bfloat16
    if code == "F16":
        return torch.float16
    if code == "F32":
        return torch.float32
    if code == "F64":
        return torch.float64
    if code == "I64":
        return torch.int64
    if code == "I32":
        return torch.int32
    if code == "I16":
        return torch.int16
    if code == "I8":
        return torch.int8
    if code == "U8":
        return torch.uint8
    if code == "BOOL":
        return torch.bool
    raise RuntimeError(f"unsupported safetensors dtype: {code}")


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
    model_root = Path(os.environ.get("MODEL_ROOT_PATH", "/tmp/oci2gdsd-model-root"))
    model_ref = os.environ["MODEL_REF"]
    model_id = os.environ["MODEL_ID"]
    model_digest = os.environ["MODEL_DIGEST"]
    lease_holder = os.environ.get("LEASE_HOLDER", "vllm-daemon-client")
    socket_path = os.environ.get("OCI2GDS_DAEMON_SOCKET", "/run/oci2gdsd/daemon.sock")
    device_index = int(os.environ.get("DEVICE_INDEX", "0"))
    device_uuid = resolve_device_uuid(device_index)
    strict_load = parse_bool_env("OCI2GDS_STRICT", True)
    require_direct = parse_bool_env("REQUIRE_DIRECT_GDS", True)

    parity_mode = str(os.environ.get("RUNTIME_PARITY_MODE", "full")).strip().lower()
    if parity_mode != "full":
        raise RuntimeError("vLLM daemon-client requires RUNTIME_PARITY_MODE=full; path-backed modes are removed")

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
        print(f"VLLM_IPC_TENSOR_MAP_OK tensors={len(tensors)} tensor_bytes={tensor_bytes}")

        runtime_dir = build_runtime_dir(model_root)
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
