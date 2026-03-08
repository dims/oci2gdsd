import gc
import hashlib
import io
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import tarfile
from pathlib import Path

import torch
from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer


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


def ensure_cuda_linkage_paths():
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

    ensure_cuda_linkage_paths()

    build_dir = Path(os.environ.get("OCI2GDS_TORCH_BUILD_DIR", "/tmp/oci2gds_daemon_build"))
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
    name = f"oci2gds_torch_native_daemon_{os.getpid()}"
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
        raise RuntimeError("native module is missing import_ipc_tensor_view")
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


def dtype_size_bytes(code: str) -> int:
    code = str(code).strip().upper()
    if code in {"BF16", "F16", "I16"}:
        return 2
    if code in {"F32", "I32"}:
        return 4
    if code in {"F64", "I64"}:
        return 8
    if code in {"I8", "U8", "BOOL"}:
        return 1
    raise RuntimeError(f"unsupported safetensors dtype: {code}")


def parse_safetensors_index(path: Path):
    with path.open("rb") as f:
        header_len_raw = f.read(8)
        if len(header_len_raw) != 8:
            raise RuntimeError(f"failed reading safetensors header length: {path}")
        header_len = struct.unpack("<Q", header_len_raw)[0]
        header_payload = f.read(header_len)
        if len(header_payload) != header_len:
            raise RuntimeError(f"failed reading safetensors header payload: {path}")
    try:
        header = json.loads(header_payload.decode("utf-8"))
    except Exception as exc:
        raise RuntimeError(f"invalid safetensors header JSON in {path}: {exc}") from exc
    data_start = 8 + int(header_len)
    file_size = path.stat().st_size
    index = {}
    for name, spec in header.items():
        if name == "__metadata__":
            continue
        dtype = str(spec.get("dtype", "")).strip()
        shape = [int(x) for x in spec.get("shape", [])]
        offsets = spec.get("data_offsets", [])
        if len(offsets) != 2:
            raise RuntimeError(f"invalid data_offsets for tensor {name}")
        start = int(offsets[0])
        end = int(offsets[1])
        if start < 0 or end < start:
            raise RuntimeError(f"invalid data_offsets range for tensor {name}: {offsets}")
        abs_start = data_start + start
        abs_end = data_start + end
        if abs_end > file_size:
            raise RuntimeError(f"tensor {name} offsets exceed file size")
        index[str(name)] = {
            "dtype": dtype,
            "shape": shape,
            "byte_offset": abs_start,
            "byte_length": abs_end - abs_start,
        }
    if not index:
        raise RuntimeError(f"no tensors found in safetensors index: {path}")
    return index


def build_runtime_dir(model_root: Path) -> Path:
    profile = json.loads((model_root / "metadata" / "model.json").read_text(encoding="utf-8")).get("profile", {})
    shard_entries = sorted(profile.get("shards", []), key=lambda s: int(s.get("ordinal", 0)))
    if not shard_entries:
        raise RuntimeError("profile.shards is empty")
    runtime_dir = Path(os.environ.get("LOCAL_MODEL_DIR", "/tmp/oci2gdsd-daemon-client-model"))
    if runtime_dir.exists():
        shutil.rmtree(runtime_dir)
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
        dst = runtime_dir / name
        os.symlink(src, dst)
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


def build_tensor_binding_index(tensors):
    global_index = {}
    shard_names = set()
    for entry in tensors:
        name = str(entry.get("name", "")).strip()
        if not name:
            continue
        if name in global_index:
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
        shard_name = str(entry.get("shard_name", "")).strip()
        if shard_name:
            shard_names.add(shard_name)
        global_index[name] = {
            "dtype": str(entry.get("dtype", "")).strip(),
            "shape": [int(x) for x in entry.get("shape", [])],
            "byte_offset": byte_offset,
            "byte_length": byte_length,
            "handle": handle,
            "shard_bytes": shard_size,
            "shard_path": shard_name,
        }
    if not global_index:
        raise RuntimeError("gpu/tensor-map returned no tensor descriptors")
    return global_index, len(shard_names)


def bind_parameters_from_ipc(model, native_module, tensor_index, device_index: int):
    imported = {}
    rebound_params = 0
    rebound_bytes = 0
    for name, param in model.named_parameters():
        spec = tensor_index.get(name)
        if spec is None:
            continue
        expected_shape = tuple(int(x) for x in spec["shape"])
        if tuple(param.shape) != expected_shape:
            raise RuntimeError(
                f"shape mismatch for {name}: model={tuple(param.shape)} safetensors={expected_shape}"
            )
        expected_dtype = torch_dtype_from_safetensors(spec["dtype"])
        byte_offset = int(spec["byte_offset"])
        byte_length = int(spec["byte_length"])
        shard_bytes = int(spec["shard_bytes"])
        if byte_offset < 0 or byte_length <= 0:
            raise RuntimeError(f"invalid byte range for {name}")
        if byte_offset + byte_length > shard_bytes:
            raise RuntimeError(
                f"tensor byte range exceeds shard size for {name}: offset={byte_offset} length={byte_length} shard_bytes={shard_bytes}"
            )
        tensor = native_module.import_ipc_tensor_view(
            str(spec["handle"]),
            int(byte_offset),
            list(expected_shape),
            str(spec["dtype"]),
            int(device_index),
        )
        if tensor.dtype != param.dtype:
            raise RuntimeError(f"imported tensor dtype mismatch for {name}: {tensor.dtype} vs {param.dtype}")
        if tuple(tensor.shape) != tuple(param.shape):
            raise RuntimeError(f"imported tensor shape mismatch for {name}: {tuple(tensor.shape)} vs {tuple(param.shape)}")
        param.data = tensor
        param.requires_grad_(False)
        imported[name] = tensor
        rebound_params += 1
        rebound_bytes += byte_length

    if hasattr(model, "tie_weights"):
        model.tie_weights()

    imported_ptrs = {int(t.data_ptr()) for t in imported.values()}
    unresolved = []
    for name, param in model.named_parameters():
        if name in imported:
            continue
        if int(param.data_ptr()) in imported_ptrs:
            continue
        unresolved.append(name)
    if unresolved:
        raise RuntimeError(f"unresolved parameters not rebound from IPC: {unresolved[:10]}")
    if rebound_params == 0:
        raise RuntimeError("no parameters were rebound from daemon IPC tensors")
    if rebound_bytes < 1_000_000_000:
        raise RuntimeError(f"rebound bytes too small for qwen3-0.6b: {rebound_bytes}")
    return imported, rebound_params, rebound_bytes


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
        raise RuntimeError("PyTorch daemon-client requires RUNTIME_PARITY_MODE=full; path-backed modes are removed")

    ensure_model_ready(socket_path, model_ref, model_id, lease_holder)
    hydrate_model_root(socket_path, model_root, model_id, model_digest)

    metadata_path = model_root / "metadata" / "model.json"
    if not metadata_path.exists():
        raise RuntimeError(f"metadata missing at {metadata_path}")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    sample_sha = ""

    if not torch.cuda.is_available():
        raise RuntimeError("torch.cuda.is_available() is false")
    native_module = load_native_module()

    attach_client_id = f"{lease_holder}-client-{os.getpid()}"
    load_ready = False
    attached = False
    detached = False
    direct_files = 0
    rebound_params = 0
    rebound_bytes = 0
    shard_count = 0
    tensor_count = 0
    answer_sha = ""
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
        load_code, load_payload = unix_http_json(socket_path, "POST", "/v1/gpu/load", load_req, timeout_seconds=600)
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

        status_code, status_payload = unix_http_json(
            socket_path, "GET", f"/v1/gpu/status?device_uuid={device_uuid}", payload=None, timeout_seconds=60
        )
        assert_http_ok(status_code, status_payload, "gpu/status")
        status_files = status_payload.get("files", []) if isinstance(status_payload, dict) else []
        if not status_files:
            raise RuntimeError(f"gpu/status returned no files after load: {status_payload}")
        print(f"DAEMON_GPU_STATUS_OK files={len(status_files)}")

        tensor_req = {
            "model_id": model_id,
            "digest": model_digest,
            "device_uuid": device_uuid,
            "max_shards": 0,
            "max_tensors": 0,
            "include_handles": True,
        }
        tensor_code, tensor_payload = unix_http_json(socket_path, "POST", "/v1/gpu/tensor-map", tensor_req, timeout_seconds=300)
        assert_http_ok(tensor_code, tensor_payload, "gpu/tensor-map")
        tensors = tensor_payload.get("tensors", []) if isinstance(tensor_payload, dict) else []
        if not tensors:
            raise RuntimeError(f"gpu/tensor-map returned no tensors: {tensor_payload}")
        tensor_count = len(tensors)
        print(f"DAEMON_GPU_TENSOR_MAP_OK tensors={len(tensors)}")

        tensor_index, shard_count = build_tensor_binding_index(tensors)
        runtime_dir = build_runtime_dir(model_root)
        dtypes = {spec["dtype"] for spec in tensor_index.values()}
        if len(dtypes) != 1:
            raise RuntimeError(f"expected a single dtype for qwen3-0.6b, got: {sorted(dtypes)}")
        model_dtype = torch_dtype_from_safetensors(next(iter(dtypes)))

        config = AutoConfig.from_pretrained(str(runtime_dir), local_files_only=True, trust_remote_code=True)
        with torch.device("meta"):
            model = AutoModelForCausalLM.from_config(config, trust_remote_code=True)
        target_device = torch.device(f"cuda:{device_index}")
        model.to_empty(device=target_device)
        model.eval()
        tokenizer = AutoTokenizer.from_pretrained(str(runtime_dir), local_files_only=True, trust_remote_code=True)

        heartbeat_req = {
            "model_id": model_id,
            "digest": model_digest,
            "device_uuid": device_uuid,
            "client_id": attach_client_id,
            "ttl_seconds": 300,
        }
        hb_code, hb_payload = unix_http_json(socket_path, "POST", "/v1/gpu/heartbeat", heartbeat_req, timeout_seconds=60)
        assert_http_ok(hb_code, hb_payload, "gpu/heartbeat")
        print(f"DAEMON_GPU_HEARTBEAT_OK expires_at={hb_payload.get('expires_at', '')}")

        imported_tensors, rebound_params, rebound_bytes = bind_parameters_from_ipc(
            model=model,
            native_module=native_module,
            tensor_index=tensor_index,
            device_index=device_index,
        )
        first_param_name = next(iter(imported_tensors.keys()))
        first_param_ptr = int(imported_tensors[first_param_name].data_ptr())
        print(
            "DAEMON_QWEN_IPC_BIND_OK "
            f"rebound_params={rebound_params} "
            f"rebound_bytes={rebound_bytes} "
            f"shards={shard_count} "
            f"first_param={first_param_name} "
            f"first_param_ptr={first_param_ptr}"
        )
        print(
            "PYTORCH_FULL_PARITY_OK "
            f"status=ok "
            f"rebound_params={rebound_params} "
            f"rebound_bytes={rebound_bytes} "
            f"parity_mode={parity_mode}"
        )

        prompt = os.environ.get(
            "PROMPT",
            "Explain in one sentence why loading model weights directly into GPU memory is useful.",
        )
        inputs = tokenizer(prompt, return_tensors="pt")
        inputs = {k: v.to(target_device) for k, v in inputs.items()}
        with torch.no_grad():
            generated = model.generate(
                **inputs,
                max_new_tokens=48,
                do_sample=False,
                pad_token_id=tokenizer.eos_token_id,
            )
        answer = tokenizer.decode(generated[0], skip_special_tokens=True)
        if not answer.strip():
            raise RuntimeError("model inference returned empty answer")
        answer_sha = hashlib.sha256(answer.encode("utf-8")).hexdigest()

        del generated
        del inputs
        del model
        imported_tensors.clear()
        del imported_tensors
        gc.collect()
        torch.cuda.synchronize(device_index)
        torch.cuda.empty_cache()

        detach_req = {
            "model_id": model_id,
            "digest": model_digest,
            "device_uuid": device_uuid,
            "client_id": attach_client_id,
        }
        detach_code, detach_payload = unix_http_json(socket_path, "POST", "/v1/gpu/detach", detach_req, timeout_seconds=120)
        assert_http_ok(detach_code, detach_payload, "gpu/detach")
        attached = False
        detached = True
        print(f"DAEMON_GPU_DETACH_OK detached_files={detach_payload.get('detached_files', 0)}")

        unload_req = {
            "model_id": model_id,
            "digest": model_digest,
            "lease_holder": lease_holder,
            "device_uuid": device_uuid,
        }
        unload_code, unload_payload = unix_http_json(socket_path, "POST", "/v1/gpu/unload", unload_req, timeout_seconds=180)
        assert_http_ok(unload_code, unload_payload, "gpu/unload")
        load_ready = False
        print("DAEMON_GPU_UNLOAD_OK")

        post_code, post_payload = unix_http_json(
            socket_path, "GET", f"/v1/gpu/status?device_uuid={device_uuid}", payload=None, timeout_seconds=60
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
                    socket_path, "POST", "/v1/gpu/detach", detach_req, timeout_seconds=120
                )
                assert_http_ok(detach_code, detach_payload, "gpu/detach(finalizer)")
                detached = True
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
                    socket_path, "POST", "/v1/gpu/unload", unload_req, timeout_seconds=180
                )
                assert_http_ok(unload_code, unload_payload, "gpu/unload(finalizer)")
                print("DAEMON_GPU_UNLOAD_OK finalizer=true")
            except Exception as exc:
                print(f"DAEMON_GPU_UNLOAD_WARN error={exc}")

    cuda_name = torch.cuda.get_device_name(device_index)
    print(
        "PYTORCH_DAEMON_CLIENT_SUCCESS "
        f"model_id={metadata.get('modelId')} "
        f"manifest={metadata.get('manifestDigest')} "
        f"sample_sha256={sample_sha} "
        f"direct_files={direct_files} "
        f"tensor_map_tensors={tensor_count} "
        f"shards={shard_count} "
        f"detached={detached} "
        f"rebound_params={rebound_params} "
        f"rebound_bytes={rebound_bytes} "
        f"answer_sha256={answer_sha} "
        f"cuda_device={cuda_name}"
    )


if __name__ == "__main__":
    main()
