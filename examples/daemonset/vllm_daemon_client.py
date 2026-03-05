import gc
import hashlib
import json
import os
import socket
from importlib.util import find_spec
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
            raise RuntimeError(f"missing shard file: {src}")
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
            self._run_with_resolved_model(model_config, lambda: self._delegate.load_weights(model, model_config))

    register_oci2gds_loader._done = True


def run_vllm_infer(model_id: str, model_digest: str, runtime_dir: Path, device_index: int) -> tuple[str, int]:
    from vllm import LLM, SamplingParams

    delegate_load_format = os.environ.get("VLLM_DELEGATE_LOAD_FORMAT", "").strip().lower()
    if not delegate_load_format:
        # Prefer fastsafetensors only when available in the runtime image.
        delegate_load_format = "fastsafetensors" if find_spec("fastsafetensors") else "safetensors"

    register_oci2gds_loader()
    print(
        "VLLM_LOADER_REGISTERED "
        f"load_format=oci2gds delegate={delegate_load_format} runtime_dir={runtime_dir}"
    )

    prompt = os.environ.get(
        "PROMPT",
        "Say hello from a vLLM loader plugin that resolves a preloaded OCI model path.",
    )
    model_ref = f"oci2gds://{model_id}@{model_digest}"
    model_path = str(runtime_dir)

    sampling = SamplingParams(max_tokens=64, temperature=0.0)
    llm = LLM(
        # Keep model as a local directory so Transformers config discovery does not
        # reject a custom URI scheme before vLLM invokes our loader.
        model=model_path,
        load_format="oci2gds",
        model_loader_extra_config={
            "resolved_model_path": str(runtime_dir),
            "delegate_load_format": delegate_load_format,
            "oci2gds_model_ref": model_ref,
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
    del llm
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.synchronize(device_index)
        torch.cuda.empty_cache()

    return answer_sha, answer_len


def main():
    model_root = Path(os.environ["MODEL_ROOT_PATH"])
    model_id = os.environ["MODEL_ID"]
    model_digest = os.environ["MODEL_DIGEST"]
    lease_holder = os.environ.get("LEASE_HOLDER", "vllm-daemon-client")
    socket_path = os.environ.get("OCI2GDS_DAEMON_SOCKET", "/run/oci2gdsd/daemon.sock")
    device_index = int(os.environ.get("DEVICE_INDEX", "0"))
    strict_load = parse_bool_env("OCI2GDS_STRICT", True)
    require_direct = parse_bool_env("REQUIRE_DIRECT_GDS", True)

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

    load_ready = False
    direct_files = 0
    answer_sha = ""
    answer_len = 0

    try:
        load_req = {
            "model_id": model_id,
            "digest": model_digest,
            "lease_holder": lease_holder,
            "device": device_index,
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
            f"/v1/gpu/status?device={device_index}",
            payload=None,
            timeout_seconds=60,
        )
        assert_http_ok(status_code, status_payload, "gpu/status")
        status_files = status_payload.get("files", []) if isinstance(status_payload, dict) else []
        if not status_files:
            raise RuntimeError(f"gpu/status returned no files after load: {status_payload}")
        print(f"DAEMON_GPU_STATUS_OK files={len(status_files)}")

        runtime_dir = build_runtime_dir(model_root)
        answer_sha, answer_len = run_vllm_infer(model_id, model_digest, runtime_dir, device_index)
        print(f"VLLM_QWEN_INFER_OK answer_sha256={answer_sha} answer_len={answer_len}")

        unload_req = {
            "model_id": model_id,
            "digest": model_digest,
            "lease_holder": lease_holder,
            "device": device_index,
        }
        unload_code, unload_payload = unix_http_json(socket_path, "POST", "/v1/gpu/unload", unload_req, timeout_seconds=300)
        assert_http_ok(unload_code, unload_payload, "gpu/unload")
        load_ready = False
        print("DAEMON_GPU_UNLOAD_OK")

        post_code, post_payload = unix_http_json(
            socket_path,
            "GET",
            f"/v1/gpu/status?device={device_index}",
            payload=None,
            timeout_seconds=60,
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
    finally:
        if load_ready:
            unload_req = {
                "model_id": model_id,
                "digest": model_digest,
                "lease_holder": lease_holder,
                "device": device_index,
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
        f"cuda_device={cuda_name}"
    )


if __name__ == "__main__":
    main()
