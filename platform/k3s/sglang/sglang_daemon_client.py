import gc
import hashlib
import importlib
import importlib.util
import json
import os
import shutil
from pathlib import Path

import torch

from daemon_client_common import (
    assert_http_ok,
    assert_no_runtime_artifact_access,
    create_gpu_allocation,
    emit_phase_timing,
    ensure_model_ready,
    hydrate_runtime_bundle,
    monotonic_ms,
    parse_bool_env,
    resolve_device_uuid,
    unix_http_json,
)


def build_runtime_dir(model_root: Path) -> Path:
    profile = json.loads((model_root / "metadata" / "model.json").read_text(encoding="utf-8")).get("profile", {})
    shard_entries = sorted(profile.get("shards", []), key=lambda s: int(s.get("ordinal", 0)))
    if not shard_entries:
        raise RuntimeError("profile.shards is empty")

    runtime_dir = Path(os.environ.get("LOCAL_MODEL_DIR", "/tmp/oci2gdsd-sglang-model"))
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


def write_tensor_map_file(tensors) -> Path:
    out_path = Path(os.environ.get("OCI2GDS_SGLANG_TENSOR_MAP_PATH", "/tmp/oci2gdsd-sglang-tensor-map.json"))
    out_path.write_text(json.dumps(tensors), encoding="utf-8")
    return out_path


def install_private_loader_module() -> Path:
    source_path = Path(os.environ.get("SGLANG_PRIVATE_LOADER_SCRIPT_PATH", "/scripts/sglang_private_model_loader.py"))
    if not source_path.exists():
        raise RuntimeError(f"SGLang private loader source missing: {source_path}")

    sglang_spec = importlib.util.find_spec("sglang")
    if sglang_spec is None or not sglang_spec.origin:
        raise RuntimeError("failed to resolve installed sglang package path")
    package_root = Path(sglang_spec.origin).resolve().parent

    private_dir = package_root / "private"
    private_dir.mkdir(parents=True, exist_ok=True)

    init_file = private_dir / "__init__.py"
    if not init_file.exists():
        init_file.write_text("", encoding="utf-8")

    target = private_dir / "private_model_loader.py"
    shutil.copyfile(source_path, target)
    importlib.invalidate_caches()

    print(
        "SGLANG_PRIVATE_LOADER_INSTALLED "
        f"source={source_path} target={target}",
        flush=True,
    )
    return target


def run_sglang_infer(runtime_dir: Path, tensor_map_path: Path, device_index: int, parity_mode: str):
    from sglang.srt.entrypoints.engine import Engine

    os.environ["OCI2GDS_SGLANG_TENSOR_MAP_PATH"] = str(tensor_map_path)
    os.environ["OCI2GDS_SGLANG_DEVICE_INDEX"] = str(int(device_index))
    os.environ["OCI2GDS_SGLANG_PARITY_MODE"] = parity_mode

    prompt = os.environ.get(
        "PROMPT",
        "Say hello from SGLang using private-loader IPC tensor imports from oci2gdsd.",
    )

    sampling_params = {
        "temperature": float(os.environ.get("SGLANG_TEMPERATURE", "0.0")),
        "max_new_tokens": int(os.environ.get("SGLANG_MAX_NEW_TOKENS", "64")),
    }

    bind_start_ms = monotonic_ms()
    engine = Engine(
        model_path=str(runtime_dir),
        tokenizer_path=str(runtime_dir),
        load_format="private",
        model_loader_extra_config=json.dumps(
            {
                "oci2gds_tensor_map_path": str(tensor_map_path),
                "oci2gds_device_index": int(device_index),
                "oci2gds_parity_mode": parity_mode,
            }
        ),
        trust_remote_code=True,
        tp_size=1,
        mem_fraction_static=float(os.environ.get("SGLANG_MEM_FRACTION_STATIC", "0.80")),
        log_level=os.environ.get("SGLANG_LOG_LEVEL", "error"),
        random_seed=int(os.environ.get("SGLANG_RANDOM_SEED", "7")),
    )
    bind_duration_ms = monotonic_ms() - bind_start_ms

    first_token_start_ms = monotonic_ms()
    output = engine.generate(prompt=prompt, sampling_params=sampling_params)
    first_token_duration_ms = monotonic_ms() - first_token_start_ms

    if isinstance(output, list):
        if not output:
            raise RuntimeError("SGLang returned empty output list")
        output = output[0]

    if not isinstance(output, dict):
        raise RuntimeError(f"unexpected SGLang output type: {type(output)}")

    answer = str(output.get("text", ""))
    if not answer.strip():
        raise RuntimeError(f"SGLang generated empty text: {output}")

    answer_sha = hashlib.sha256(answer.encode("utf-8")).hexdigest()
    answer_len = len(answer)

    engine.shutdown()
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.synchronize(device_index)
        torch.cuda.empty_cache()

    return answer_sha, answer_len, bind_duration_ms, first_token_duration_ms


def main():
    runtime_root = Path(os.environ.get("RUNTIME_BUNDLE_ROOT", "/tmp/oci2gdsd-runtime-bundle"))
    perf_mode = str(os.environ.get("PERF_MODE", "unspecified")).strip().lower() or "unspecified"
    assert_no_runtime_artifact_access()

    model_ref = os.environ["MODEL_REF"]
    model_id = os.environ["MODEL_ID"]
    model_digest = os.environ.get("MODEL_DIGEST", "").strip()
    lease_holder = os.environ.get("LEASE_HOLDER", "sglang-daemon-client")
    socket_path = os.environ.get("OCI2GDS_DAEMON_SOCKET", "/run/oci2gdsd/daemon.sock")
    device_index = int(os.environ.get("DEVICE_INDEX", "0"))
    device_uuid = resolve_device_uuid(device_index)
    strict_load = parse_bool_env("OCI2GDS_STRICT", True)
    require_direct = parse_bool_env("REQUIRE_DIRECT_GDS", True)

    parity_mode = str(os.environ.get("RUNTIME_PARITY_MODE", "full")).strip().lower()
    if parity_mode != "full":
        raise RuntimeError("SGLang daemon-client requires RUNTIME_PARITY_MODE=full; path-backed modes are removed")

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
    runtime_bundle_token = str(allocation.get("runtime_bundle_token", "")).strip()
    if not runtime_bundle_token:
        raise RuntimeError(f"gpu/allocate returned empty runtime_bundle_token: {allocation}")
    model_digest = str(allocation.get("manifest_digest", model_digest)).strip()
    if not model_digest:
        raise RuntimeError(f"gpu/allocate returned empty manifest digest: {allocation}")

    bundle_phase_start = monotonic_ms()
    hydrate_runtime_bundle(socket_path, runtime_root, runtime_bundle_token)
    emit_phase_timing("bundle", monotonic_ms() - bundle_phase_start, mode=perf_mode)

    metadata_path = runtime_root / "metadata" / "model.json"
    if not metadata_path.exists():
        raise RuntimeError(f"metadata missing at {metadata_path}")
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))

    load_ready = False
    attached = False
    direct_files = 0
    answer_sha = ""
    answer_len = 0
    attach_client_id = f"{lease_holder}-sglang-{os.getpid()}"

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
            f"strict={strict_load}",
            flush=True,
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
        print(f"DAEMON_GPU_STATUS_OK files={len(status_files)}", flush=True)

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
            f"expires_at={attach_payload.get('expires_at', '')}",
            flush=True,
        )

        hb_req = {
            "allocation_id": allocation_id,
            "client_id": attach_client_id,
            "ttl_seconds": 300,
        }
        hb_code, hb_payload = unix_http_json(socket_path, "POST", "/v2/gpu/heartbeat", hb_req, timeout_seconds=60)
        assert_http_ok(hb_code, hb_payload, "gpu/heartbeat")
        print(f"DAEMON_GPU_HEARTBEAT_OK expires_at={hb_payload.get('expires_at', '')}", flush=True)

        tensor_phase_start = monotonic_ms()
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
        print(f"SGLANG_IPC_TENSOR_MAP_OK tensors={len(tensors)} tensor_bytes={tensor_bytes}", flush=True)
        emit_phase_timing("tensor-map", monotonic_ms() - tensor_phase_start, mode=perf_mode)

        runtime_dir = build_runtime_dir(runtime_root)
        tensor_map_path = write_tensor_map_file(tensors)
        install_private_loader_module()

        answer_sha, answer_len, bind_ms, first_token_ms = run_sglang_infer(
            runtime_dir=runtime_dir,
            tensor_map_path=tensor_map_path,
            device_index=device_index,
            parity_mode=parity_mode,
        )
        emit_phase_timing("bind", bind_ms, mode=perf_mode)
        emit_phase_timing("first-token", first_token_ms, mode=perf_mode)

        print(f"SGLANG_QWEN_INFER_OK answer_sha256={answer_sha} answer_len={answer_len}", flush=True)

        detach_req = {
            "allocation_id": allocation_id,
            "client_id": attach_client_id,
        }
        detach_code, detach_payload = unix_http_json(socket_path, "POST", "/v2/gpu/detach", detach_req, timeout_seconds=120)
        assert_http_ok(detach_code, detach_payload, "gpu/detach")
        attached = False
        print(f"DAEMON_GPU_DETACH_OK detached_files={detach_payload.get('detached_files', 0)}", flush=True)

        unload_req = {"allocation_id": allocation_id}
        unload_code, unload_payload = unix_http_json(socket_path, "POST", "/v2/gpu/unload", unload_req, timeout_seconds=300)
        assert_http_ok(unload_code, unload_payload, "gpu/unload")
        load_ready = False
        print("DAEMON_GPU_UNLOAD_OK", flush=True)

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
                print(f"DAEMON_GPU_DETACH_OK detached_files={detach_payload.get('detached_files', 0)} finalizer=true", flush=True)
            except Exception as exc:
                print(f"DAEMON_GPU_DETACH_WARN error={exc}", flush=True)

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
                print("DAEMON_GPU_UNLOAD_OK finalizer=true", flush=True)
            except Exception as exc:
                print(f"DAEMON_GPU_UNLOAD_WARN error={exc}", flush=True)

    if not torch.cuda.is_available():
        raise RuntimeError("torch.cuda.is_available() is false")
    cuda_name = torch.cuda.get_device_name(device_index)
    print(
        "SGLANG_DAEMON_CLIENT_SUCCESS "
        f"model_id={metadata.get('modelId')} "
        f"manifest={metadata.get('manifestDigest')} "
        f"direct_files={direct_files} "
        f"answer_sha256={answer_sha} "
        f"answer_len={answer_len} "
        f"parity_mode={parity_mode} "
        f"cuda_device={cuda_name}",
        flush=True,
    )


if __name__ == "__main__":
    main()
