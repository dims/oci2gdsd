import json
import os
import re
import socket
import shutil
import subprocess
import time
from pathlib import Path

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import torch
from torch.library import Library
import uvicorn
from transformers import AutoModelForCausalLM, AutoTokenizer

def _native_cpp_source_path() -> Path:
    raw = os.environ.get("OCI2GDS_NATIVE_CPP_PATH", "").strip()
    if raw:
        return Path(raw)
    return Path(__file__).resolve().parent.parent / "native" / "oci2gds_torch_native.cpp"


def _load_native_cpp_source() -> str:
    source_path = _native_cpp_source_path()
    if not source_path.exists():
        raise RuntimeError(f"native C++ source not found: {source_path}")
    return source_path.read_text(encoding="utf-8")


_REGISTERED_LIBRARIES = []
_NATIVE_MODULE = None
_NATIVE_ERROR = ""
_IPC_NATIVE_MODULE = None
_IPC_NATIVE_ERROR = ""
_CUFILE_ENV_PATH = ""
_GPU_UUID_PATTERN = re.compile(r"^GPU-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")


def _resolve_device_uuid(device_index: int) -> str:
    explicit = os.environ.get("DEVICE_UUID", "").strip()
    if explicit:
        if not _GPU_UUID_PATTERN.match(explicit):
            raise RuntimeError(f"DEVICE_UUID is not a canonical GPU UUID: {explicit}")
        return explicit
    visible = os.environ.get("NVIDIA_VISIBLE_DEVICES", "").strip()
    if visible and visible.lower() not in {"none", "void"}:
        first = visible.split(",")[0].strip()
        if _GPU_UUID_PATTERN.match(first):
            return first
    out = subprocess.check_output(
        ["nvidia-smi", "--query-gpu=uuid", "--format=csv,noheader"],
        text=True,
        stderr=subprocess.STDOUT,
    )
    uuids = [line.strip() for line in out.splitlines() if line.strip()]
    if device_index < 0 or device_index >= len(uuids):
        raise RuntimeError(f"device index {device_index} out of range for discovered GPU UUIDs: {uuids}")
    candidate = uuids[device_index]
    if not _GPU_UUID_PATTERN.match(candidate):
        raise RuntimeError(f"nvidia-smi returned non-canonical GPU UUID: {candidate}")
    return candidate

def _force_no_compat():
    raw = os.environ.get("OCI2GDS_FORCE_NO_COMPAT", "true").strip().lower()
    return raw in {"1", "true", "yes", "on"}

def _configure_cufile_env():
    if not _force_no_compat():
        return ""
    cfg_path = Path("/tmp/cufile-qwen-hello.json")
    cfg = {
        "logging": {"level": "ERROR"},
        "profile": {"cufile_stats": 3},
        "properties": {"allow_compat_mode": False},
    }
    cfg_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    os.environ["CUFILE_ENV_PATH_JSON"] = str(cfg_path)
    return str(cfg_path)

def _native_enabled():
    flag = os.environ.get("OCI2GDS_TORCH_ENABLE_NATIVE", "1").strip().lower()
    return flag not in {"0", "false", "no"}

def _load_native_module():
    if not _native_enabled():
        return None, "native backend disabled"
    if not torch.cuda.is_available():
        return None, "cuda unavailable"
    try:
        from torch.utils.cpp_extension import load_inline
    except Exception as exc:
        return None, f"torch cpp extension unavailable: {exc}"
    build_dir = Path(os.environ.get("OCI2GDS_TORCH_BUILD_DIR", "/tmp/oci2gds_torch_build"))
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
    try:
        native_cpp = _load_native_cpp_source()
    except Exception as exc:
        return None, f"native source load failed: {exc}"
    verbose = os.environ.get("OCI2GDS_TORCH_NATIVE_VERBOSE", "0").strip() == "1"
    name = f"oci2gds_torch_native_{os.getpid()}"
    try:
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
        return module, ""
    except Exception as exc:
        if _force_no_compat():
            return None, (
                f"native build/load failed with OCI2GDS_FORCE_NO_COMPAT=true "
                f"(CUFILE_ENV_PATH_JSON={os.environ.get('CUFILE_ENV_PATH_JSON', '')}): {exc}"
            )
        return None, f"native build/load failed: {exc}"

def _load_ipc_native_module():
    if _NATIVE_MODULE is None:
        return None, "ipc native backend unavailable: native module unavailable"
    if not hasattr(_NATIVE_MODULE, "import_ipc_copy_to_tensor"):
        return None, "ipc native backend unavailable: import symbol missing"
    return _NATIVE_MODULE, ""

def _fallback_read_into_tensor(path, tensor, offset, length):
    if length < 0 or offset < 0:
        raise RuntimeError("offset and length must be non-negative")
    if tensor.dtype != torch.uint8:
        raise RuntimeError("tensor dtype must be torch.uint8")
    flat = tensor.contiguous().view(-1)
    if flat.numel() < length:
        raise RuntimeError("tensor is smaller than requested length")
    fd = os.open(path, os.O_RDONLY)
    try:
        data = os.pread(fd, length, offset)
    finally:
        os.close(fd)
    if len(data) != length:
        raise RuntimeError(f"short read from {path}: expected={length} got={len(data)}")
    cpu = torch.frombuffer(memoryview(data), dtype=torch.uint8).clone()
    if tensor.device.type == "cuda":
        flat[:length].copy_(cpu.to(device=tensor.device), non_blocking=False)
    else:
        flat[:length].copy_(cpu)
    return {
        "backend": "python-fallback",
        "mode": "fallback",
        "bytes": str(length),
        "reason": "",
    }

def _register_oci2gds_ops():
    global _NATIVE_MODULE, _NATIVE_ERROR
    if hasattr(torch.ops, "oci2gds") and hasattr(torch.ops.oci2gds, "read_into_tensor"):
        return
    _NATIVE_MODULE, _NATIVE_ERROR = _load_native_module()
    define_lib = Library("oci2gds", "DEF")
    define_lib.define(
        "read_into_tensor(str path, Tensor tensor, int offset, int length, bool strict, int chunk_bytes) -> Dict(str, str)"
    )
    define_lib.define(
        "load_profile(str profile_json, int device, bool strict, int chunk_bytes, int sample_bytes) -> Dict(str, str)"
    )
    _REGISTERED_LIBRARIES.append(define_lib)
    impl_lib = Library("oci2gds", "IMPL", "CompositeExplicitAutograd")
    _REGISTERED_LIBRARIES.append(impl_lib)

    def _read_into_tensor(path, tensor, offset, length, strict, chunk_bytes):
        if _NATIVE_MODULE is not None:
            try:
                out = _NATIVE_MODULE.read_into_tensor_native(
                    path,
                    tensor,
                    int(offset),
                    int(length),
                    bool(strict),
                    int(chunk_bytes),
                )
                return {str(k): str(v) for k, v in out.items()}
            except Exception as exc:
                if strict:
                    raise
                fallback = _fallback_read_into_tensor(path, tensor, int(offset), int(length))
                fallback["reason"] = f"native_error:{exc}"
                return fallback
        if strict:
            raise RuntimeError(
                f"strict direct path requested but native backend unavailable: {_NATIVE_ERROR}"
            )
        return _fallback_read_into_tensor(path, tensor, int(offset), int(length))

    def _load_profile(profile_json, device, strict, chunk_bytes, sample_bytes):
        payload = json.loads(profile_json)
        root = Path(payload.get("root", ""))
        profile_obj = payload.get("profile", {})
        shards = sorted(
            profile_obj.get("shards", []),
            key=lambda s: int(s.get("ordinal", 0)),
        )
        if int(device) < 0 or not torch.cuda.is_available():
            return {
                "status": "skipped",
                "backend": "none",
                "native_error": _NATIVE_ERROR,
                "reason": "cuda_unavailable",
                "shards_total": str(len(shards)),
                "shards_sampled": "0",
                "bytes_sampled": "0",
                "mode_counts": "{}",
                "reason_counts": "{}",
                "force_no_compat": "true" if _force_no_compat() else "false",
                "cufile_env_path": _CUFILE_ENV_PATH,
                "cufile_init_ok": "true" if _NATIVE_MODULE is not None else "false",
                "duration_ms": "0",
                "throughput_mib_s": "0.00",
            }
        if bool(strict) and _NATIVE_MODULE is None:
            raise RuntimeError(
                f"strict direct path requested but native backend unavailable: {_NATIVE_ERROR}"
            )
        start_ns = time.monotonic_ns()
        mode_counts = {}
        reason_counts = {}
        shards_sampled = 0
        bytes_sampled = 0
        target = torch.device(f"cuda:{int(device)}")
        with torch.cuda.device(target):
            for shard in shards:
                name = str(shard.get("name", "")).strip()
                if not name:
                    continue
                shard_path = root / "shards" / name if root else Path(name)
                if not shard_path.exists():
                    continue
                file_size = shard_path.stat().st_size
                read_len = int(min(file_size, max(int(sample_bytes), 0)))
                if read_len <= 0:
                    continue
                if bool(strict):
                    read_len_aligned = (read_len // 4096) * 4096
                    if read_len_aligned <= 0:
                        reason_counts["strict_skip_unaligned"] = reason_counts.get("strict_skip_unaligned", 0) + 1
                        continue
                    read_len = int(read_len_aligned)
                scratch = torch.empty(read_len, dtype=torch.uint8, device=target)
                try:
                    out = torch.ops.oci2gds.read_into_tensor(
                        str(shard_path),
                        scratch,
                        0,
                        read_len,
                        bool(strict),
                        int(chunk_bytes),
                    )
                except Exception as exc:
                    raise RuntimeError(
                        f"read_into_tensor failed path={shard_path} size={file_size} read_len={read_len}: {exc}"
                    ) from exc
                mode = out.get("mode", "unknown")
                mode_counts[mode] = mode_counts.get(mode, 0) + 1
                reason = out.get("reason", "")
                if reason:
                    reason_counts[reason] = reason_counts.get(reason, 0) + 1
                shards_sampled += 1
                try:
                    bytes_sampled += int(out.get("bytes", "0"))
                except Exception:
                    pass
            torch.cuda.synchronize(target)
        elapsed_ms = max(0, int((time.monotonic_ns() - start_ns) / 1_000_000))
        if elapsed_ms > 0:
            throughput_mib_s = (float(bytes_sampled) / (1024.0 * 1024.0)) / (float(elapsed_ms) / 1000.0)
        else:
            throughput_mib_s = 0.0
        backend_name = "native-cufile" if _NATIVE_MODULE is not None else "python-fallback"
        return {
            "status": "ok",
            "backend": backend_name,
            "native_error": _NATIVE_ERROR,
            "reason": "",
            "shards_total": str(len(shards)),
            "shards_sampled": str(shards_sampled),
            "bytes_sampled": str(bytes_sampled),
            "mode_counts": json.dumps(mode_counts, sort_keys=True),
            "reason_counts": json.dumps(reason_counts, sort_keys=True),
            "force_no_compat": "true" if _force_no_compat() else "false",
            "cufile_env_path": _CUFILE_ENV_PATH,
            "cufile_init_ok": "true" if _NATIVE_MODULE is not None else "false",
            "duration_ms": str(elapsed_ms),
            "throughput_mib_s": f"{throughput_mib_s:.2f}",
        }

    impl_lib.impl("read_into_tensor", _read_into_tensor)
    impl_lib.impl("load_profile", _load_profile)

_CUFILE_ENV_PATH = _configure_cufile_env()
_register_oci2gds_ops()
oci2gds_backend = {
    "backend": "native-cufile" if _NATIVE_MODULE is not None else "python-fallback",
    "native_error": _NATIVE_ERROR,
    "force_no_compat": _force_no_compat(),
    "cufile_env_path": _CUFILE_ENV_PATH,
}
_IPC_NATIVE_MODULE, _IPC_NATIVE_ERROR = _load_ipc_native_module()

def _unix_http_json(socket_path, method, path, payload=None, timeout_seconds=60):
    body = b""
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    request_lines = [
        f"{method} {path} HTTP/1.1",
        "Host: localhost",
        "Connection: close",
    ]
    if body:
        request_lines.append("Content-Type: application/json")
        request_lines.append(f"Content-Length: {len(body)}")
    raw = ("\r\n".join(request_lines) + "\r\n\r\n").encode("utf-8") + body
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
    header_lines = header_raw.decode("utf-8", errors="replace").splitlines()
    if not header_lines:
        raise RuntimeError("empty daemon HTTP response")
    parts = header_lines[0].split(" ")
    if len(parts) < 2:
        raise RuntimeError(f"invalid daemon HTTP status line: {header_lines[0]}")
    status_code = int(parts[1])
    payload_out = {}
    if body_raw.strip():
        payload_out = json.loads(body_raw.decode("utf-8"))
    return status_code, payload_out

def _ipc_import_probe(handle_b64, sample_bytes, device_idx):
    if _IPC_NATIVE_MODULE is None:
        return {
            "status": "skipped",
            "backend": "none",
            "reason": _IPC_NATIVE_ERROR,
            "sample_bytes": "0",
        }
    length = int(sample_bytes)
    if length <= 0:
        return {
            "status": "skipped",
            "backend": "native-cuda-ipc-copy",
            "reason": "sample_bytes<=0",
            "sample_bytes": "0",
        }
    buf = _IPC_NATIVE_MODULE.import_ipc_copy_to_tensor(handle_b64, int(length), int(device_idx))
    checksum_window = min(int(buf.numel()), 1024)
    checksum = int(buf[:checksum_window].to(dtype=torch.int64).sum().item()) if checksum_window > 0 else 0
    return {
        "status": "ok",
        "backend": "native-cuda-ipc-copy",
        "reason": "",
        "sample_bytes": str(int(length)),
        "checksum_1k": str(checksum),
    }

def _daemon_persistent_probe(model_id, model_digest, lease_holder, device_idx, chunk_bytes, sample_bytes, shard_count):
    enabled = os.environ.get("OCI2GDS_DAEMON_ENABLE", "1").strip().lower() not in {"0", "false", "no"}
    socket_path = os.environ.get("OCI2GDS_DAEMON_SOCKET", "/run/oci2gdsd/daemon.sock").strip()
    if not enabled:
        return {
            "status": "skipped",
            "reason": "daemon_probe_disabled",
            "socket": socket_path,
        }
    if device_idx < 0:
        return {
            "status": "skipped",
            "reason": "cuda_unavailable",
            "socket": socket_path,
        }
    if not socket_path:
        return {
            "status": "skipped",
            "reason": "daemon_socket_missing",
            "socket": "",
        }
    if not Path(socket_path).exists():
        return {
            "status": "error",
            "reason": "daemon_socket_not_found",
            "socket": socket_path,
        }
    try:
        device_uuid = _resolve_device_uuid(int(device_idx))
        load_req = {
            "model_id": str(model_id),
            "digest": str(model_digest),
            "lease_holder": str(lease_holder),
            "device_uuid": str(device_uuid),
            "chunk_bytes": int(chunk_bytes),
            "strict": False,
            "mode": "persistent",
        }
        load_code, load_res = _unix_http_json(socket_path, "POST", "/v1/gpu/load", load_req, timeout_seconds=600)
        if load_code >= 300:
            load_reason = str(load_res.get("reason_code", "")).strip().upper() if isinstance(load_res, dict) else ""
            if load_reason in {"DIRECT_PATH_INELIGIBLE", "POLICY_REJECTED"}:
                return {
                    "status": "skipped",
                    "reason": f"daemon_load_{load_reason.lower()}",
                    "socket": socket_path,
                    "load": load_res,
                    "ipc_native_error": _IPC_NATIVE_ERROR,
                }
            return {
                "status": "error",
                "reason": f"daemon_load_failed_http_{load_code}",
                "socket": socket_path,
                "load": load_res,
            }
        export_req = {
            "model_id": str(model_id),
            "digest": str(model_digest),
            "device_uuid": str(device_uuid),
            "max_shards": int(max(shard_count, 1)),
        }
        export_code, export_res = _unix_http_json(socket_path, "POST", "/v1/gpu/export", export_req, timeout_seconds=120)
        if export_code >= 300:
            return {
                "status": "error",
                "reason": f"daemon_export_failed_http_{export_code}",
                "socket": socket_path,
                "export": export_res,
            }
        files = export_res.get("files", []) if isinstance(export_res, dict) else []
        if not files:
            return {
                "status": "error",
                "reason": "daemon_export_empty",
                "socket": socket_path,
                "export": export_res,
            }
        first = files[0]
        handle = str(first.get("ipc_handle", "")).strip()
        shard_bytes = int(first.get("bytes", "0"))
        if not handle:
            return {
                "status": "error",
                "reason": "daemon_export_missing_ipc_handle",
                "socket": socket_path,
                "export": export_res,
            }
        probe_len = int(min(max(int(sample_bytes), 0), max(shard_bytes, 0)))
        ipc_probe = _ipc_import_probe(handle, probe_len, int(device_idx))
        return {
            "status": ipc_probe.get("status", "unknown"),
            "reason": ipc_probe.get("reason", ""),
            "socket": socket_path,
            "load_backend": load_res.get("loader", ""),
            "load_mode": load_res.get("mode", ""),
            "exported_files": str(len(files)),
            "import_backend": ipc_probe.get("backend", ""),
            "sample_bytes": ipc_probe.get("sample_bytes", "0"),
            "checksum_1k": ipc_probe.get("checksum_1k", "0"),
            "ipc_native_error": _IPC_NATIVE_ERROR,
        }
    except Exception as exc:
        return {
            "status": "error",
            "reason": str(exc),
            "socket": socket_path,
            "ipc_native_error": _IPC_NATIVE_ERROR,
        }

model_root = Path(os.environ["MODEL_ROOT_PATH"])
if not (model_root / "READY").exists():
    raise RuntimeError("READY marker missing")
meta = json.loads((model_root / "metadata" / "model.json").read_text(encoding="utf-8"))
profile = meta.get("profile", {})
source = profile.get("source", {})
shard_entries = sorted(
    profile.get("shards", []),
    key=lambda s: int(s.get("ordinal", 0)),
)
if not shard_entries:
    raise RuntimeError("profile.shards is empty; cannot build local runtime model directory")

runtime_dir = Path(
    os.environ.get("LOCAL_MODEL_DIR", os.environ.get("VLLM_LOCAL_MODEL_DIR", "/tmp/oci2gdsd-local-model"))
)
if runtime_dir.exists():
    shutil.rmtree(runtime_dir)
runtime_dir.mkdir(parents=True, exist_ok=True)

weights_found = 0
for shard in shard_entries:
    name = str(shard.get("name", "")).strip()
    if not name:
        raise RuntimeError("profile shard name is empty")
    src = model_root / "shards" / name
    if not src.exists():
        raise RuntimeError(f"expected shard file missing: {src}")
    dst = runtime_dir / name
    os.symlink(src, dst)
    if name.endswith(".safetensors"):
        weights_found += 1

metadata_dir = model_root / "metadata"
if metadata_dir.is_dir():
    for src in sorted(metadata_dir.iterdir(), key=lambda p: p.name):
        if not src.is_file() or src.name == "model.json":
            continue
        dst = runtime_dir / src.name
        if not dst.exists():
            os.symlink(src, dst)

if not (runtime_dir / "config.json").exists():
    raise RuntimeError(f"config.json missing in local runtime dir: {runtime_dir}")
tokenizer_candidates = ["tokenizer.json", "tokenizer.model", "vocab.json"]
if not any((runtime_dir / name).exists() for name in tokenizer_candidates):
    raise RuntimeError(f"tokenizer artifacts missing in local runtime dir: {runtime_dir}")
if weights_found == 0:
    raise RuntimeError(f"no .safetensors files found in local runtime dir: {runtime_dir}")

model_name = str(runtime_dir.resolve())
max_new_tokens = int(os.environ.get("MAX_NEW_TOKENS", "128"))
temperature = float(os.environ.get("TEMPERATURE", "0.7"))
top_p = float(os.environ.get("TOP_P", "0.95"))
oci2gds_chunk_bytes = int(os.environ.get("OCI2GDS_CHUNK_BYTES", str(4 * 1024 * 1024)))
oci2gds_sample_bytes = int(os.environ.get("OCI2GDS_SAMPLE_BYTES_PER_SHARD", str(8 * 1024 * 1024)))
oci2gds_strict = os.environ.get("OCI2GDS_STRICT", "true").strip().lower() in {"1", "true", "yes"}
oci2gds_probe_strict = os.environ.get("OCI2GDS_PROBE_STRICT", "true").strip().lower() in {"1", "true", "yes"}
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
if device.type == "cuda" and hasattr(torch.cuda, "is_bf16_supported") and torch.cuda.is_bf16_supported():
    torch_dtype = torch.bfloat16
elif device.type == "cuda":
    torch_dtype = torch.float16
else:
    torch_dtype = torch.float32
if device.type == "cuda":
    device_index = int(device.index) if device.index is not None else 0
else:
    device_index = -1

profile_payload = json.dumps({"root": str(model_root), "profile": profile})
try:
    oci2gds_profile = torch.ops.oci2gds.load_profile(
        profile_payload,
        int(device_index),
        bool(oci2gds_strict),
        int(oci2gds_chunk_bytes),
        int(oci2gds_sample_bytes),
    )
except Exception as exc:
    if oci2gds_probe_strict:
        raise
    oci2gds_profile = {
        "status": "error",
        "backend": oci2gds_backend.get("backend", "unknown"),
        "native_error": oci2gds_backend.get("native_error", ""),
        "reason": str(exc),
        "shards_total": str(len(shard_entries)),
        "shards_sampled": "0",
        "bytes_sampled": "0",
        "mode_counts": "{}",
        "reason_counts": "{}",
        "force_no_compat": "true" if _force_no_compat() else "false",
        "cufile_env_path": _CUFILE_ENV_PATH,
        "cufile_init_ok": "true" if _NATIVE_MODULE is not None else "false",
        "duration_ms": "0",
        "throughput_mib_s": "0.00",
    }
print("OCI2GDS_PROFILE_PROBE " + json.dumps(oci2gds_profile, sort_keys=True), flush=True)

daemon_probe_shards = int(os.environ.get("OCI2GDS_DAEMON_PROBE_SHARDS", "1"))
daemon_lease_holder = os.environ.get("LEASE_HOLDER", "qwen-hello-daemon")
oci2gds_ipc = _daemon_persistent_probe(
    model_id=meta.get("modelId", os.environ.get("MODEL_ID", "")),
    model_digest=meta.get("manifestDigest", os.environ.get("MODEL_DIGEST", "")),
    lease_holder=daemon_lease_holder,
    device_idx=int(device_index),
    chunk_bytes=int(oci2gds_chunk_bytes),
    sample_bytes=int(oci2gds_sample_bytes),
    shard_count=int(max(daemon_probe_shards, 1)),
)
print("OCI2GDS_IPC_PROBE " + json.dumps(oci2gds_ipc, sort_keys=True), flush=True)

tokenizer = AutoTokenizer.from_pretrained(model_name, local_files_only=True, trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained(
    model_name,
    local_files_only=True,
    trust_remote_code=True,
    torch_dtype=torch_dtype,
)
model.to(device)
model.eval()

app = FastAPI(title="qwen-hello-pytorch-oci2gds")

class ChatRequest(BaseModel):
    prompt: str

@app.get("/healthz")
def healthz():
    return {
        "status": "ok",
        "model_name": model_name,
        "source_repo": source.get("repoId", ""),
        "model_id": meta.get("modelId"),
        "manifest_digest": meta.get("manifestDigest"),
        "device": str(device),
        "torch_dtype": str(torch_dtype),
        "oci2gds_backend": oci2gds_backend,
        "oci2gds_profile": oci2gds_profile,
        "oci2gds_ipc": oci2gds_ipc,
    }

@app.post("/chat")
def chat(req: ChatRequest):
    prompt = (req.prompt or "").strip()
    if not prompt:
        raise HTTPException(status_code=400, detail="prompt must be non-empty")
    encoded = tokenizer(prompt, return_tensors="pt")
    encoded = {k: v.to(device) for k, v in encoded.items()}
    with torch.no_grad():
        generated = model.generate(
            **encoded,
            max_new_tokens=max_new_tokens,
            do_sample=temperature > 0.0,
            temperature=max(temperature, 1e-5),
            top_p=top_p,
            pad_token_id=tokenizer.eos_token_id,
            eos_token_id=tokenizer.eos_token_id,
        )
    completion_tokens = generated[0][encoded["input_ids"].shape[1]:]
    text = tokenizer.decode(completion_tokens, skip_special_tokens=True).strip()
    return {
        "answer": text,
        "model_name": model_name,
        "source_repo": source.get("repoId", ""),
        "model_id": meta.get("modelId"),
        "manifest_digest": meta.get("manifestDigest"),
        "device": str(device),
        "oci2gds_profile_status": oci2gds_profile.get("status", "unknown"),
        "oci2gds_mode_counts": oci2gds_profile.get("mode_counts", "{}"),
        "oci2gds_ipc_status": oci2gds_ipc.get("status", "unknown"),
        "oci2gds_ipc_backend": oci2gds_ipc.get("import_backend", ""),
    }

uvicorn.run(app, host="0.0.0.0", port=8000)
