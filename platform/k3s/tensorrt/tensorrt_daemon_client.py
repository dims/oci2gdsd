import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
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


def build_runtime_dir(model_root: Path) -> Path:
    profile = json.loads((model_root / "metadata" / "model.json").read_text(encoding="utf-8")).get("profile", {})
    shard_entries = sorted(profile.get("shards", []), key=lambda s: int(s.get("ordinal", 0)))
    if not shard_entries:
        raise RuntimeError("profile.shards is empty")

    runtime_dir = Path(os.environ.get("LOCAL_MODEL_DIR", "/tmp/oci2gdsd-trt-model"))
    if runtime_dir.exists():
        shutil.rmtree(runtime_dir)
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


def build_engine(runtime_dir: Path, model_root: Path) -> Path:
    cache_root = model_root / ".trt-cache"
    checkpoint_dir = Path(os.environ.get("TRT_CHECKPOINT_DIR", str(cache_root / "checkpoint")))
    engine_dir = Path(os.environ.get("TRT_ENGINE_DIR", str(cache_root / "engine")))
    force_rebuild = parse_bool_env("TRT_FORCE_REBUILD", False)

    if force_rebuild:
        shutil.rmtree(checkpoint_dir, ignore_errors=True)
        shutil.rmtree(engine_dir, ignore_errors=True)

    if engine_ready(engine_dir):
        print(f"TENSORRT_ENGINE_BUILD_OK reused=true engine_dir={engine_dir}")
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
    print(f"TENSORRT_ENGINE_BUILD_OK reused=false engine_dir={engine_dir}")
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

    runner = ModelRunnerCpp.from_dir(
        engine_dir=str(engine_dir),
        rank=0,
        max_batch_size=1,
        max_input_len=max_input_len,
        max_output_len=max_output_len,
        max_beam_width=1,
        use_gpu_direct_storage=require_direct,
        gpu_weights_percent=1.0,
    )
    print(
        "TENSORRT_GDS_RUNNER_READY "
        f"use_gpu_direct_storage={require_direct} "
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


def main():
    model_root = Path(os.environ["MODEL_ROOT_PATH"])
    model_id = os.environ["MODEL_ID"]
    model_digest = os.environ["MODEL_DIGEST"]
    lease_holder = os.environ["LEASE_HOLDER"]
    socket_path = os.environ.get("OCI2GDS_DAEMON_SOCKET", "/run/oci2gdsd/daemon.sock")
    device_index = int(os.environ.get("DEVICE_INDEX", "0"))
    device_uuid = resolve_device_uuid(device_index)
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

    load_ready = False
    direct_files = 0
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

        runtime_dir = build_runtime_dir(model_root)
        engine_dir = build_engine(runtime_dir, model_root=model_root)
        answer_sha = run_tensorrt_infer(engine_dir, runtime_dir, require_direct=require_direct, device_index=device_index)

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
        f"cuda_device={cuda_name}"
    )


if __name__ == "__main__":
    main()
