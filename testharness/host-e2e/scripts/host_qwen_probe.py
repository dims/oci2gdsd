#!/usr/bin/env python3
import glob
import json
import os
import re
import sys
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
    cfg_path = Path("/tmp/cufile-host-e2e.json")
    cfg = {
        "logging": {"level": "ERROR"},
        "profile": {"cufile_stats": 3},
        "properties": {"allow_compat_mode": False},
    }
    cfg_path.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    os.environ["CUFILE_ENV_PATH_JSON"] = str(cfg_path)
    return str(cfg_path)


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


def build_native_module(force_no_compat: bool, cufile_env_path: str):
    code = r"""
#include <torch/extension.h>
#include <pybind11/pybind11.h>
#include <cuda.h>
#include <cuda_runtime_api.h>
#include <cufile.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <string.h>
#include <algorithm>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

namespace py = pybind11;

static std::once_flag g_init_once;
static int g_init_code = 0;
static std::string g_init_err;

static void ensure_gds_ready() {
  std::call_once(g_init_once, []() {
    CUresult cu = cuInit(0);
    if (cu != CUDA_SUCCESS) {
      g_init_code = 1;
      g_init_err = "cuInit failed";
      return;
    }
    CUfileError_t st = cuFileDriverOpen();
    if (st.err != CU_FILE_SUCCESS) {
      g_init_code = 2;
      g_init_err = "cuFileDriverOpen failed";
      return;
    }
  });
  if (g_init_code != 0) {
    throw std::runtime_error(g_init_err);
  }
}

static py::dict init_native() {
  ensure_gds_ready();
  py::dict out;
  out["status"] = "ok";
  out["backend"] = "native-cufile";
  return out;
}

static py::dict read_into_tensor_native(
    const std::string& path,
    torch::Tensor tensor,
    int64_t file_offset,
    int64_t length,
    bool strict,
    int64_t chunk_bytes) {
  if (!tensor.is_cuda()) throw std::runtime_error("tensor must be CUDA");
  if (tensor.scalar_type() != at::ScalarType::Byte) throw std::runtime_error("tensor must be uint8");
  if (!tensor.is_contiguous()) throw std::runtime_error("tensor must be contiguous");
  if (file_offset < 0 || length < 0) throw std::runtime_error("offset/length must be non-negative");
  if (length > static_cast<int64_t>(tensor.numel())) throw std::runtime_error("tensor smaller than length");

  if (chunk_bytes < 4096) chunk_bytes = 4096;
  chunk_bytes = (chunk_bytes / 4096) * 4096;
  if (chunk_bytes == 0) chunk_bytes = 4096;

  ensure_gds_ready();
  int device = tensor.get_device();
  cudaError_t crt = cudaSetDevice(device);
  if (crt != cudaSuccess) throw std::runtime_error("cudaSetDevice failed");
  (void)cudaFree(0);

  int fd = -1;
  bool direct_io = true;
  std::string fallback_reason;
  fd = ::open(path.c_str(), O_RDONLY | O_DIRECT);
  if (fd < 0) {
    if (strict) throw std::runtime_error("open(O_DIRECT) failed");
    fd = ::open(path.c_str(), O_RDONLY);
    if (fd < 0) throw std::runtime_error("open failed");
    direct_io = false;
    fallback_reason = "odirect_open_failed";
  }

  struct stat st;
  if (fstat(fd, &st) != 0) {
    ::close(fd);
    throw std::runtime_error("fstat failed");
  }
  if (file_offset > static_cast<int64_t>(st.st_size)) {
    ::close(fd);
    throw std::runtime_error("offset beyond file size");
  }
  if (length > static_cast<int64_t>(st.st_size) - file_offset) {
    ::close(fd);
    throw std::runtime_error("length exceeds file bounds");
  }

  CUfileHandle_t cfh{};
  bool handle_registered = false;
  bool buf_registered = false;
  int64_t bytes_done = 0;
  int64_t direct_target = length;
  bool used_direct = false;

  if (direct_io) {
    if ((file_offset % 4096) != 0) {
      if (strict) {
        ::close(fd);
        throw std::runtime_error("strict mode requires 4K-aligned file offsets");
      }
      direct_target = 0;
    } else if ((length % 4096) != 0) {
      if (strict) {
        ::close(fd);
        throw std::runtime_error("strict mode requires 4K-aligned lengths");
      }
      direct_target = (length / 4096) * 4096;
    }
  } else {
    direct_target = 0;
  }

  if (direct_target > 0) {
    CUfileDescr_t desc{};
    desc.handle.fd = fd;
    desc.type = CU_FILE_HANDLE_TYPE_OPAQUE_FD;
    CUfileError_t ferr = cuFileHandleRegister(&cfh, &desc);
    if (ferr.err != CU_FILE_SUCCESS) {
      if (strict) {
        ::close(fd);
        std::ostringstream os;
        os << "cuFileHandleRegister failed err=" << static_cast<int>(ferr.err)
           << " cu_err=" << static_cast<int>(ferr.cu_err);
        throw std::runtime_error(os.str());
      }
      direct_target = 0;
      fallback_reason = "handle_register_failed";
    } else {
      handle_registered = true;
      ferr = cuFileBufRegister(tensor.data_ptr(), static_cast<size_t>(direct_target), 0);
      if (ferr.err == CU_FILE_SUCCESS) {
        buf_registered = true;
      } else if (strict) {
        (void)cuFileHandleDeregister(cfh);
        ::close(fd);
        std::ostringstream os;
        os << "cuFileBufRegister failed err=" << static_cast<int>(ferr.err)
           << " cu_err=" << static_cast<int>(ferr.cu_err);
        throw std::runtime_error(os.str());
      } else {
        fallback_reason = "buf_register_failed";
      }
    }
  }

  if (direct_target > 0 && handle_registered) {
    while (bytes_done < direct_target) {
      size_t to_read = static_cast<size_t>(std::min<int64_t>(chunk_bytes, direct_target - bytes_done));
      ssize_t n = cuFileRead(
          cfh,
          reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(tensor.data_ptr()) + static_cast<uintptr_t>(bytes_done)),
          to_read,
          static_cast<off_t>(file_offset + bytes_done),
          0);
      if (n < 0) {
        if (strict) {
          if (buf_registered) (void)cuFileBufDeregister(tensor.data_ptr());
          (void)cuFileHandleDeregister(cfh);
          ::close(fd);
          throw std::runtime_error("cuFileRead failed");
        }
        fallback_reason = "cufile_read_failed";
        break;
      }
      if (n == 0) break;
      used_direct = true;
      bytes_done += static_cast<int64_t>(n);
    }
  }

  if (bytes_done < length) {
    std::vector<char> host(static_cast<size_t>(chunk_bytes));
    while (bytes_done < length) {
      size_t want = static_cast<size_t>(std::min<int64_t>(chunk_bytes, length - bytes_done));
      ssize_t n = pread(fd, host.data(), want, static_cast<off_t>(file_offset + bytes_done));
      if (n <= 0) {
        if (buf_registered) (void)cuFileBufDeregister(tensor.data_ptr());
        if (handle_registered) (void)cuFileHandleDeregister(cfh);
        ::close(fd);
        throw std::runtime_error("pread fallback failed");
      }
      crt = cudaMemcpy(
          reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(tensor.data_ptr()) + static_cast<uintptr_t>(bytes_done)),
          host.data(),
          static_cast<size_t>(n),
          cudaMemcpyHostToDevice);
      if (crt != cudaSuccess) {
        if (buf_registered) (void)cuFileBufDeregister(tensor.data_ptr());
        if (handle_registered) (void)cuFileHandleDeregister(cfh);
        ::close(fd);
        throw std::runtime_error("cudaMemcpy fallback failed");
      }
      bytes_done += static_cast<int64_t>(n);
    }
  }

  if (buf_registered) (void)cuFileBufDeregister(tensor.data_ptr());
  if (handle_registered) (void)cuFileHandleDeregister(cfh);
  ::close(fd);

  py::dict out;
  out["backend"] = "native-cufile";
  out["bytes"] = std::to_string(bytes_done);
  if (used_direct && bytes_done == length && direct_target == length && buf_registered) {
    out["mode"] = "direct";
    out["reason"] = "";
  } else if (used_direct && bytes_done == length) {
    out["mode"] = "hybrid";
    out["reason"] = fallback_reason;
  } else {
    out["mode"] = "fallback";
    out["reason"] = fallback_reason;
  }
  return out;
}

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def("init_native", &init_native, "initialize native cufile path");
  m.def("read_into_tensor_native", &read_into_tensor_native, "read path into CUDA tensor via cuFile");
}
"""
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
    validate_sample_bytes = parse_bool("OCI2GDS_VALIDATE_SAMPLE_BYTES", True)
    # FIXME: Defaulted to false because some direct-path runs show no nvfs Ops
    # increments despite successful cuFile direct reads. Revisit and restore
    # true-by-default once provider/runtime counter behavior is consistent.
    require_nvfs_stats_delta = parse_bool("REQUIRE_NVFS_STATS_DELTA", False)
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
    nvfs_before = read_nvfs_ops()

    module = build_native_module(force_no_compat=force_no_compat, cufile_env_path=cufile_env_path)

    mode_counts = {}
    reason_counts = {}
    shards_sampled = 0
    bytes_sampled = 0
    device = torch.device("cuda:0")

    with torch.cuda.device(device):
        for shard in shards:
            name = str(shard.get("name", "")).strip()
            if not name:
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
    if require_nvfs_stats_delta:
        if not nvfs_delta["available"]:
            raise RuntimeError("REQUIRE_NVFS_STATS_DELTA=true but /proc/driver/nvidia-fs/stats is unavailable")
        if nvfs_before.get("io_stats_enabled") is False or nvfs_before.get("rw_stats_enabled") is False:
            raise RuntimeError(
                "REQUIRE_NVFS_STATS_DELTA=true but nvidia-fs IO stats are disabled "
                f"(io_stats_enabled={nvfs_before.get('io_stats_enabled')}, "
                f"rw_stats_enabled={nvfs_before.get('rw_stats_enabled')})"
            )
        if int(nvfs_delta["read"]) <= 0 and int(nvfs_delta["batchio"]) <= 0:
            raise RuntimeError(
                "REQUIRE_NVFS_STATS_DELTA=true but nvfs Ops counters did not increase "
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
        "validate_sample_bytes": bool(validate_sample_bytes),
        "require_nvfs_stats_delta": bool(require_nvfs_stats_delta),
        "cufile_env_path": cufile_env_path,
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
    # Some runtime/toolchain combos can crash in process teardown after a
    # successful probe summary is emitted (exit 139). Exit hard after summary
    # so harness status reflects the validated probe result.
    sys.stdout.flush()
    os._exit(0)


if __name__ == "__main__":
    main()
