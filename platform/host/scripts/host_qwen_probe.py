#!/usr/bin/env python3
import glob
import json
import os
import re
import sys
import time
from pathlib import Path

import torch
from torch.utils.cpp_extension import load_inline


def parse_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def ensure_runtime_links() -> None:
    for nvfs in glob.glob("/host-dev/nvidia-fs*"):
        target = Path("/dev") / Path(nvfs).name
        try:
            if target.exists() or target.is_symlink():
                target.unlink()
            target.symlink_to(nvfs)
        except Exception:
            continue

    cuda_lib = Path("/usr/local/cuda/lib64/libcufile.so")
    cuda_lib0 = Path("/usr/local/cuda/lib64/libcufile.so.0")
    if not cuda_lib.exists() and cuda_lib0.exists():
        cuda_lib.symlink_to(cuda_lib0)

    sys_lib = Path("/usr/lib/x86_64-linux-gnu/libcufile.so")
    if not sys_lib.exists() and cuda_lib.exists():
        sys_lib.symlink_to(cuda_lib)


def configure_cufile_env(force_no_compat: bool) -> str:
    if not force_no_compat:
        return ""
    cfg = {}
    base_cfg_path = Path("/etc/cufile.json")
    if base_cfg_path.exists():
        try:
            cfg = json.loads(base_cfg_path.read_text(encoding="utf-8"))
            if not isinstance(cfg, dict):
                cfg = {}
        except Exception:
            cfg = {}
    cfg_path = Path("/tmp/cufile-host-e2e.json")
    logging_cfg = cfg.get("logging")
    if not isinstance(logging_cfg, dict):
        logging_cfg = {}
    logging_cfg["level"] = "ERROR"
    cfg["logging"] = logging_cfg

    profile_cfg = cfg.get("profile")
    if not isinstance(profile_cfg, dict):
        profile_cfg = {}
    profile_cfg["cufile_stats"] = 3
    cfg["profile"] = profile_cfg

    properties_cfg = cfg.get("properties")
    if not isinstance(properties_cfg, dict):
        properties_cfg = {}
    properties_cfg["allow_compat_mode"] = False
    cfg["properties"] = properties_cfg

    cfg_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    os.environ["CUFILE_ENV_PATH_JSON"] = str(cfg_path)
    return str(cfg_path)


def parse_nvfs_mode() -> str:
    legacy = os.environ.get("REQUIRE_NVFS_STATS_DELTA")
    if legacy is not None:
        return "required" if parse_bool("REQUIRE_NVFS_STATS_DELTA", False) else "off"
    mode = os.environ.get("REQUIRE_NVFS_STATS_DELTA_MODE", "auto").strip().lower()
    if mode not in {"auto", "required", "off"}:
        raise RuntimeError(
            "REQUIRE_NVFS_STATS_DELTA_MODE must be one of: auto|required|off "
            f"(got {mode!r})"
        )
    return mode


def read_nvfs_ops() -> dict:
    out = {
        "available": False,
        "read": 0,
        "write": 0,
        "batchio": 0,
        "io_stats_enabled": None,
        "rw_stats_enabled": None,
    }
    rw_param = Path("/sys/module/nvidia_fs/parameters/rw_stats_enabled")
    if rw_param.exists():
        try:
            out["rw_stats_enabled"] = rw_param.read_text(encoding="utf-8", errors="ignore").strip() == "1"
        except Exception:
            pass
    p = Path("/proc/driver/nvidia-fs/stats")
    if not p.exists():
        return out
    text = p.read_text(encoding="utf-8", errors="ignore")
    m_state = re.search(r"IO stats:\s*(Enabled|Disabled)", text)
    if m_state:
        out["io_stats_enabled"] = m_state.group(1).strip().lower() == "enabled"
    m = re.search(r"Ops\s*:\s*Read=(\d+)\s+Write=(\d+)\s+BatchIO=(\d+)", text)
    if not m:
        return out
    out["available"] = True
    out["read"] = int(m.group(1))
    out["write"] = int(m.group(2))
    out["batchio"] = int(m.group(3))
    return out


def load_native_cpp_source() -> str:
    raw = os.environ.get("OCI2GDS_NATIVE_CPP_PATH", "").strip()
    if raw:
        source_path = Path(raw)
    else:
        source_path = Path("/opt/oci2gdsd/native/oci2gds_torch_native.cpp")
    if not source_path.exists():
        raise RuntimeError(f"native C++ source not found: {source_path}")
    return source_path.read_text(encoding="utf-8")


def build_native_module(force_no_compat: bool, cufile_env_path: str):
    code = load_native_cpp_source()
    build_dir = Path("/tmp/oci2gds_host_probe_build")
    build_dir.mkdir(parents=True, exist_ok=True)
    module = load_inline(
        name=f"oci2gds_host_probe_{os.getpid()}",
        cpp_sources=[code],
        functions=None,
        extra_cflags=["-O3", "-std=c++17"],
        extra_ldflags=["-L/usr/local/cuda/lib64", "-lcuda", "-lcufile"],
        with_cuda=False,
        build_directory=str(build_dir),
        verbose=parse_bool("OCI2GDS_TORCH_NATIVE_VERBOSE", False),
    )
    try:
        module.init_native()
    except Exception as exc:
        if force_no_compat:
            raise RuntimeError(
                "native cuFile init failed with OCI2GDS_FORCE_NO_COMPAT=true "
                f"(CUFILE_ENV_PATH_JSON={cufile_env_path}); "
                "if this platform/runtime cannot run with compat disabled, "
                "keep fail-fast defaults and fix platform, or temporarily set "
                "OCI2GDS_FORCE_NO_COMPAT=false only for debugging"
            ) from exc
        raise
    return module


def main() -> None:
    ensure_runtime_links()

    strict = parse_bool("OCI2GDS_STRICT", True)
    require_direct = parse_bool("REQUIRE_DIRECT_GDS", True)
    force_no_compat = parse_bool("OCI2GDS_FORCE_NO_COMPAT", True)
    force_exit_after_summary = parse_bool("OCI2GDS_FORCE_EXIT_AFTER_SUMMARY", False)
    validate_sample_bytes = parse_bool("OCI2GDS_VALIDATE_SAMPLE_BYTES", True)
    nvfs_stats_mode = parse_nvfs_mode()
    chunk_bytes = int(os.environ.get("OCI2GDS_CHUNK_BYTES", str(4 * 1024 * 1024)))
    sample_bytes = int(os.environ.get("OCI2GDS_SAMPLE_BYTES_PER_SHARD", str(8 * 1024 * 1024)))
    model_id = os.environ.get("MODEL_ID", "")
    model_digest = os.environ.get("MODEL_DIGEST", "")
    model_root = Path(os.environ["MODEL_ROOT_PATH"])

    if not torch.cuda.is_available():
        raise RuntimeError("CUDA unavailable in runtime image")

    meta = json.loads((model_root / "metadata" / "model.json").read_text(encoding="utf-8"))
    profile = meta.get("profile", {})
    shards = sorted(profile.get("shards", []), key=lambda s: int(s.get("ordinal", 0)))
    if not shards:
        raise RuntimeError("profile.shards is empty")

    cufile_env_path = configure_cufile_env(force_no_compat)
    if force_no_compat and not cufile_env_path:
        raise RuntimeError("OCI2GDS_FORCE_NO_COMPAT=true but CUFILE_ENV_PATH_JSON was not configured")
    nvfs_before = read_nvfs_ops()

    module = build_native_module(force_no_compat=force_no_compat, cufile_env_path=cufile_env_path)
    cufile_init_ok = True

    mode_counts = {}
    reason_counts = {}
    shards_sampled = 0
    bytes_sampled = 0
    device = torch.device("cuda:0")
    start_ns = time.monotonic_ns()

    with torch.cuda.device(device):
        for shard in shards:
            name = str(shard.get("name", "")).strip()
            if not name:
                continue
            shard_kind = str(shard.get("kind", "")).strip().lower()
            # Probe only weight-bearing shard files; runtime metadata/config files are
            # not part of the direct-GDS data path this check is asserting.
            is_weight_shard = shard_kind == "weight" or name.endswith(".safetensors") or name.endswith(".bin")
            if not is_weight_shard:
                reason_counts["skip_non_weight"] = reason_counts.get("skip_non_weight", 0) + 1
                continue
            path = model_root / "shards" / name
            if not path.exists():
                reason_counts["missing_shard"] = reason_counts.get("missing_shard", 0) + 1
                continue
            file_size = path.stat().st_size
            read_len = int(min(file_size, max(sample_bytes, 0)))
            if read_len <= 0:
                continue
            if strict:
                read_len_aligned = (read_len // 4096) * 4096
                if read_len_aligned <= 0:
                    reason_counts["strict_skip_unaligned"] = reason_counts.get("strict_skip_unaligned", 0) + 1
                    continue
                read_len = int(read_len_aligned)
            scratch = torch.empty(read_len, dtype=torch.uint8, device=device)
            try:
                out = module.read_into_tensor_native(
                    str(path),
                    scratch,
                    0,
                    int(read_len),
                    bool(strict),
                    int(chunk_bytes),
                )
            except Exception as exc:
                raise RuntimeError(
                    f"read_into_tensor failed path={path} size={file_size} read_len={read_len}: {exc}"
                ) from exc

            if validate_sample_bytes:
                check_len = min(read_len, 4096)
                fd = os.open(str(path), os.O_RDONLY)
                try:
                    host_prefix = os.pread(fd, check_len, 0)
                finally:
                    os.close(fd)
                gpu_prefix = scratch[:check_len].to(device="cpu", dtype=torch.uint8, non_blocking=False).contiguous().numpy().tobytes()
                if gpu_prefix != host_prefix:
                    raise RuntimeError(f"byte validation failed for {path}: first {check_len} bytes mismatch")

            out_dict = {str(k): str(v) for k, v in out.items()}
            mode = out_dict.get("mode", "unknown")
            reason = out_dict.get("reason", "")
            mode_counts[mode] = mode_counts.get(mode, 0) + 1
            if reason:
                reason_counts[reason] = reason_counts.get(reason, 0) + 1
            shards_sampled += 1
            try:
                bytes_sampled += int(out_dict.get("bytes", "0"))
            except Exception:
                pass
        torch.cuda.synchronize(device)

    duration_ms = max(0, int((time.monotonic_ns() - start_ns) / 1_000_000))
    throughput_mib_s = 0.0
    if duration_ms > 0:
        throughput_mib_s = (float(bytes_sampled) / (1024.0 * 1024.0)) / (float(duration_ms) / 1000.0)

    nvfs_after = read_nvfs_ops()
    nvfs_delta = {
        "available": bool(nvfs_before.get("available")) and bool(nvfs_after.get("available")),
        "read": int(nvfs_after.get("read", 0)) - int(nvfs_before.get("read", 0)),
        "write": int(nvfs_after.get("write", 0)) - int(nvfs_before.get("write", 0)),
        "batchio": int(nvfs_after.get("batchio", 0)) - int(nvfs_before.get("batchio", 0)),
    }

    direct_count = int(mode_counts.get("direct", 0))
    if require_direct and direct_count <= 0:
        raise RuntimeError(f"direct path required but direct_count={direct_count}; mode_counts={mode_counts}")
    if strict:
        non_direct = sum(v for k, v in mode_counts.items() if k != "direct")
        if non_direct > 0:
            raise RuntimeError(f"strict mode expected only direct reads; mode_counts={mode_counts}")
    if nvfs_stats_mode == "required":
        if not nvfs_delta["available"]:
            raise RuntimeError("REQUIRE_NVFS_STATS_DELTA_MODE=required but /proc/driver/nvidia-fs/stats is unavailable")
        if nvfs_before.get("io_stats_enabled") is False or nvfs_before.get("rw_stats_enabled") is False:
            raise RuntimeError(
                "REQUIRE_NVFS_STATS_DELTA_MODE=required but nvidia-fs IO stats are disabled "
                f"(io_stats_enabled={nvfs_before.get('io_stats_enabled')}, "
                f"rw_stats_enabled={nvfs_before.get('rw_stats_enabled')})"
            )
        if int(nvfs_delta["read"]) <= 0 and int(nvfs_delta["batchio"]) <= 0:
            raise RuntimeError(
                "REQUIRE_NVFS_STATS_DELTA_MODE=required but nvfs Ops counters did not increase "
                f"(delta={nvfs_delta})"
            )
    elif nvfs_stats_mode == "auto":
        if (
            nvfs_delta["available"]
            and nvfs_before.get("io_stats_enabled") is True
            and nvfs_before.get("rw_stats_enabled") is True
            and int(nvfs_delta["read"]) <= 0
            and int(nvfs_delta["batchio"]) <= 0
        ):
            raise RuntimeError(
                "REQUIRE_NVFS_STATS_DELTA_MODE=auto detected enabled nvfs IO stats but Ops counters did not increase "
                f"(delta={nvfs_delta})"
            )

    summary = {
        "status": "ok",
        "backend": "native-cufile",
        "model_id": model_id or meta.get("modelId", ""),
        "manifest_digest": model_digest or meta.get("manifestDigest", ""),
        "model_root": str(model_root),
        "strict": bool(strict),
        "require_direct_gds": bool(require_direct),
        "force_no_compat": bool(force_no_compat),
        "compat_mode_disabled_evidence": bool(force_no_compat and bool(cufile_env_path)),
        "cufile_init_ok": bool(cufile_init_ok),
        "force_exit_after_summary": bool(force_exit_after_summary),
        "validate_sample_bytes": bool(validate_sample_bytes),
        "require_nvfs_stats_delta": bool(nvfs_stats_mode == "required"),
        "require_nvfs_stats_delta_mode": nvfs_stats_mode,
        "cufile_env_path": cufile_env_path,
        "duration_ms": duration_ms,
        "throughput_mib_s": round(throughput_mib_s, 2),
        "shards_total": len(shards),
        "shards_sampled": shards_sampled,
        "bytes_sampled": bytes_sampled,
        "mode_counts": mode_counts,
        "reason_counts": reason_counts,
        "nvfs_ops_before": nvfs_before,
        "nvfs_ops_after": nvfs_after,
        "nvfs_ops_delta": nvfs_delta,
    }
    print("HOST_QWEN_GDS_PROBE " + json.dumps(summary, sort_keys=True), flush=True)
    if force_exit_after_summary:
        # Some runtime/toolchain combos can crash in process teardown after a
        # successful probe summary is emitted (exit 139). Keep this opt-in so
        # normal runs still surface teardown faults.
        sys.stdout.flush()
        os._exit(0)


if __name__ == "__main__":
    main()
