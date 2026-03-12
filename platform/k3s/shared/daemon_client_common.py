import io
import json
import os
import re
import shutil
import socket
import subprocess
import tarfile
import time
import urllib.parse
from pathlib import Path

import torch


GPU_UUID_PATTERN = re.compile(r"^GPU-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


def parse_bool_env(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def monotonic_ms() -> int:
    return int(time.monotonic() * 1000)


def emit_phase_timing(phase: str, duration_ms: int, **extra_fields):
    phase_name = str(phase).strip().lower()
    if not phase_name:
        raise RuntimeError("phase name must not be empty")
    parts = [
        "DAEMON_PHASE_TIMING",
        f"phase={phase_name}",
        f"duration_ms={int(duration_ms)}",
    ]
    for key, value in extra_fields.items():
        if value is None:
            continue
        key_text = str(key).strip()
        if not key_text:
            continue
        parts.append(f"{key_text}={value}")
    print(" ".join(parts))


def assert_no_runtime_artifact_access():
    forbidden_env = []
    for name in ("MODEL_ROOT_PATH",):
        if os.environ.get(name, "").strip():
            forbidden_env.append(name)
    if forbidden_env:
        raise RuntimeError(f"runtime artifact path envs must be unset: {forbidden_env}")

    forbidden_mount_points = {
        "/var/lib/oci2gdsd",
        "/var/lib/oci2gdsd/models",
    }
    mount_hits = []
    try:
        with open("/proc/self/mountinfo", "r", encoding="utf-8") as f:
            for line in f:
                parts = line.strip().split(" ")
                if len(parts) < 5:
                    continue
                mount_point = parts[4].replace("\\040", " ")
                if mount_point in forbidden_mount_points or mount_point.startswith("/var/lib/oci2gdsd/models/"):
                    mount_hits.append(mount_point)
    except FileNotFoundError:
        pass
    if mount_hits:
        raise RuntimeError(f"runtime container must not mount daemon artifact roots: {sorted(set(mount_hits))}")

    root = Path("/var/lib/oci2gdsd/models")
    if root.exists():
        artifact_markers = [
            p
            for p in (
                list(root.glob("**/*.safetensors"))
                + list(root.glob("**/metadata/model.json"))
                + list(root.glob("**/READY"))
            )
            if p.is_file()
        ]
        if artifact_markers:
            sample = [str(p) for p in artifact_markers[:3]]
            raise RuntimeError(
                f"runtime container has direct model artifacts under {root}; sample={sample}"
            )

    print("DAEMON_NO_RUNTIME_ARTIFACT_ACCESS_OK pathless_runtime=true")


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
        out.extend(body_raw[pos : pos + size])
        pos += size
        if body_raw[pos : pos + 2] != b"\r\n":
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
            text = text[min(start_obj) :]
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
    code, payload = unix_http_json(socket_path, "POST", "/v2/model/ensure", req, timeout_seconds=1800)
    assert_http_ok(code, payload, "model/ensure")
    if str(payload.get("status", "")).upper() != "READY":
        raise RuntimeError(f"model/ensure did not return READY: {payload}")
    print(f"DAEMON_MODEL_ENSURE_READY model_id={payload.get('model_id', model_id)} digest={payload.get('manifest_digest', '')}")
    return payload


def create_gpu_allocation(
    socket_path: str,
    model_ref: str,
    model_id: str,
    model_digest: str,
    lease_holder: str,
    device_uuid: str,
    strict: bool,
    runtime_bundle_include_weights: bool = False,
):
    ref = str(model_ref or "").strip()
    digest = str(model_digest or "").strip()
    req = {}
    if ref:
        req["ref"] = ref
    if str(model_id).strip():
        req["model_id"] = model_id
    if digest:
        req["digest"] = digest
    req["lease_holder"] = lease_holder
    req["device_uuid"] = device_uuid
    req["chunk_bytes"] = 4 * 1024 * 1024
    req["max_shards"] = 0
    req["strict"] = bool(strict)
    req["runtime_bundle_include_weights"] = bool(runtime_bundle_include_weights)
    code, payload = unix_http_json(socket_path, "POST", "/v2/gpu/allocate", req, timeout_seconds=1800)
    assert_http_ok(code, payload, "gpu/allocate")
    if str(payload.get("status", "")).upper() != "READY":
        raise RuntimeError(f"gpu/allocate did not return READY: {payload}")
    allocation_id = str(payload.get("allocation_id", "")).strip()
    if not allocation_id:
        raise RuntimeError(f"gpu/allocate returned empty allocation_id: {payload}")
    model_id_out = str(payload.get("model_id", model_id)).strip()
    digest_out = str(payload.get("manifest_digest", "")).strip()
    print(
        "DAEMON_GPU_ALLOCATE_READY "
        f"allocation_id={allocation_id} model_id={model_id_out} digest={digest_out} "
        f"files={payload.get('files', 0)} direct_files={payload.get('direct_files', 0)} "
        f"runtime_bundle_token={str(payload.get('runtime_bundle_token', '')).strip()}"
    )
    return payload


def hydrate_runtime_bundle(socket_path: str, runtime_root: Path, runtime_bundle_token: str):
    if runtime_root.exists():
        shutil.rmtree(runtime_root)
    runtime_root.mkdir(parents=True, exist_ok=True)
    token = str(runtime_bundle_token).strip()
    if not token:
        raise RuntimeError("runtime bundle token is required")
    token_path = urllib.parse.quote(token, safe="")
    phase_start = monotonic_ms()
    code, headers, payload = unix_http_request(
        socket_path=socket_path,
        method="GET",
        path=f"/v2/runtime-bundles/{token_path}",
        payload=None,
        timeout_seconds=600,
    )
    if code >= 300:
        text = payload.decode("utf-8", errors="replace")
        raise RuntimeError(f"runtime-bundle token fetch failed: code={code} body={text}")
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:") as tf:
        tf.extractall(path=str(runtime_root))
    if not (runtime_root / "metadata" / "model.json").exists():
        raise RuntimeError(f"runtime bundle missing metadata/model.json in {runtime_root}")
    if not (runtime_root / "shards" / "config.json").exists():
        raise RuntimeError(f"runtime bundle missing shards/config.json in {runtime_root}")
    bundle_elapsed_ms = monotonic_ms() - phase_start
    prepare_ms_raw = str(headers.get("x-oci2gdsd-runtime-bundle-prepare-ms", "")).strip()
    prepare_ms = -1
    if prepare_ms_raw:
        try:
            prepare_ms = int(prepare_ms_raw)
        except ValueError:
            prepare_ms = -1
    print(
        "DAEMON_RUNTIME_BUNDLE_TIMING "
        f"prepare_ms={prepare_ms} "
        f"transfer_extract_ms={bundle_elapsed_ms} "
        f"payload_bytes={len(payload)}"
    )
    print(f"DAEMON_RUNTIME_BUNDLE_READY files_root={runtime_root}")


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


def load_native_module(
    *,
    build_dir_default: str,
    module_name_prefix: str,
    required_symbol: str,
):
    if not _native_enabled():
        raise RuntimeError("native backend disabled")
    if not torch.cuda.is_available():
        raise RuntimeError("cuda unavailable")
    try:
        from torch.utils.cpp_extension import load_inline
    except Exception as exc:
        raise RuntimeError(f"torch cpp extension unavailable: {exc}") from exc

    ensure_cuda_linkage_paths()

    build_dir = Path(os.environ.get("OCI2GDS_TORCH_BUILD_DIR", build_dir_default))
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
    name = f"{module_name_prefix}_{os.getpid()}"
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
    if not hasattr(module, required_symbol):
        raise RuntimeError(f"native module missing {required_symbol}")
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
