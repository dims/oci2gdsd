import hashlib
import json
import os
import socket
from pathlib import Path

import torch


def parse_bool_env(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def unix_http_json(socket_path: str, method: str, path: str, payload=None, timeout_seconds: int = 120):
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
    payload_out = {}
    if body_raw.strip():
        payload_out = json.loads(body_raw.decode("utf-8"))
    return status_code, payload_out


def assert_http_ok(code: int, payload, action: str):
    if code >= 300:
        raise RuntimeError(f"{action} failed: code={code} payload={payload}")
    if isinstance(payload, dict) and str(payload.get("status", "")).upper() == "FAILED":
        raise RuntimeError(f"{action} returned FAILED payload={payload}")


def main():
    model_root = Path(os.environ["MODEL_ROOT_PATH"])
    model_id = os.environ["MODEL_ID"]
    model_digest = os.environ["MODEL_DIGEST"]
    lease_holder = os.environ["LEASE_HOLDER"]
    socket_path = os.environ.get("OCI2GDS_DAEMON_SOCKET", "/run/oci2gdsd/daemon.sock")
    device_index = int(os.environ.get("DEVICE_INDEX", "0"))
    require_direct = parse_bool_env("REQUIRE_DIRECT_GDS", True)
    strict_load = parse_bool_env("OCI2GDS_STRICT", True)

    ready = model_root / "READY"
    metadata_path = model_root / "metadata" / "model.json"
    if not ready.exists():
        raise RuntimeError(f"READY marker missing at {ready}")
    if not metadata_path.exists():
        raise RuntimeError(f"metadata missing at {metadata_path}")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    shards = metadata.get("profile", {}).get("shards", [])
    if not shards:
        raise RuntimeError("no shards listed in metadata profile")
    first_shard = model_root / "shards" / shards[0]["name"]
    if not first_shard.exists():
        raise RuntimeError(f"first shard missing at {first_shard}")
    with first_shard.open("rb") as f:
        sample = f.read(8 * 1024 * 1024)
    sample_sha = hashlib.sha256(sample).hexdigest()

    if not torch.cuda.is_available():
        raise RuntimeError("torch.cuda.is_available() is false")

    load_req = {
        "model_id": model_id,
        "digest": model_digest,
        "lease_holder": lease_holder,
        "device": device_index,
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
    print(
        "DAEMON_GPU_LOAD_READY "
        f"files={len(files)} direct_files={direct_files} "
        f"mode={load_payload.get('mode', '')} persistent={load_payload.get('persistent', False)} "
        f"strict={strict_load}"
    )

    export_req = {
        "model_id": model_id,
        "digest": model_digest,
        "device": device_index,
        "max_shards": 1,
    }
    export_code, export_payload = unix_http_json(socket_path, "POST", "/v1/gpu/export", export_req, timeout_seconds=120)
    assert_http_ok(export_code, export_payload, "gpu/export")
    exported = export_payload.get("files", []) if isinstance(export_payload, dict) else []
    if not exported:
        raise RuntimeError(f"gpu/export returned no files: {export_payload}")
    first_ipc = str(exported[0].get("ipc_handle", "")).strip()
    if not first_ipc:
        raise RuntimeError(f"gpu/export missing ipc_handle: {export_payload}")
    print(f"DAEMON_GPU_EXPORT_OK files={len(exported)}")

    status_code, status_payload = unix_http_json(
        socket_path, "GET", f"/v1/gpu/status?device={device_index}", payload=None, timeout_seconds=60
    )
    assert_http_ok(status_code, status_payload, "gpu/status")
    status_files = status_payload.get("files", []) if isinstance(status_payload, dict) else []
    if not status_files:
        raise RuntimeError(f"gpu/status returned no files after load: {status_payload}")
    print(f"DAEMON_GPU_STATUS_OK files={len(status_files)}")

    device = torch.device(f"cuda:{device_index}")
    a = torch.randn((2048, 2048), device=device)
    b = torch.randn((2048, 2048), device=device)
    c = torch.matmul(a, b)
    torch.cuda.synchronize(device)
    value = float(c.mean().item())

    unload_req = {
        "model_id": model_id,
        "digest": model_digest,
        "lease_holder": lease_holder,
        "device": device_index,
    }
    unload_code, unload_payload = unix_http_json(socket_path, "POST", "/v1/gpu/unload", unload_req, timeout_seconds=180)
    assert_http_ok(unload_code, unload_payload, "gpu/unload")
    print("DAEMON_GPU_UNLOAD_OK")

    post_code, post_payload = unix_http_json(
        socket_path, "GET", f"/v1/gpu/status?device={device_index}", payload=None, timeout_seconds=60
    )
    assert_http_ok(post_code, post_payload, "post-unload gpu/status")
    post_files = post_payload.get("files", []) if isinstance(post_payload, dict) else []
    still_loaded = []
    for entry in post_files:
        p = str(entry.get("path", "")).strip()
        if p and p.startswith(str(model_root)):
            still_loaded.append(p)
    if still_loaded:
        raise RuntimeError(f"model paths still loaded after unload: {still_loaded}")

    cuda_name = torch.cuda.get_device_name(device_index)
    print(
        "PYTORCH_DAEMON_CLIENT_SUCCESS "
        f"model_id={metadata.get('modelId')} "
        f"manifest={metadata.get('manifestDigest')} "
        f"shard={first_shard.name} "
        f"sample_sha256={sample_sha} "
        f"direct_files={direct_files} "
        f"exported_files={len(exported)} "
        f"cuda_device={cuda_name} "
        f"matmul_mean={value}"
    )


if __name__ == "__main__":
    main()
