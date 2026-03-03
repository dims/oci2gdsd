apiVersion: v1
kind: Namespace
metadata:
  name: __QWEN_HELLO_NAMESPACE__
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: oci2gdsd-config
  namespace: __QWEN_HELLO_NAMESPACE__
data:
  config.yaml: |
    root: __OCI2GDSD_ROOT_PATH__
    model_root: __OCI2GDSD_ROOT_PATH__/models
    tmp_root: __OCI2GDSD_ROOT_PATH__/tmp
    locks_root: __OCI2GDSD_ROOT_PATH__/locks
    journal_dir: __OCI2GDSD_ROOT_PATH__/journal
    state_db: __OCI2GDSD_ROOT_PATH__/state.db
    registry:
      plain_http: true
      request_timeout_seconds: 600
      timeout_seconds: 600
      retries: 6
    transfer:
      max_models_concurrent: 2
      max_shards_concurrent_per_model: 8
      max_connections_per_registry: 32
      stream_buffer_bytes: 4194304
      max_resume_attempts: 2
    integrity:
      strict_digest: true
      strict_signature: false
      allow_unsigned_in_dev: true
    publish:
      require_ready_marker: true
      fsync_files: false
      fsync_directory: false
      atomic_publish: true
      deny_partial_reads: true
    retention:
      policy: lru_no_lease
      min_free_bytes: 0
      max_models: 64
      ttl_hours: 168
      emergency_low_space_mode: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: qwen-hello
  namespace: __QWEN_HELLO_NAMESPACE__
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: qwen-hello
  template:
    metadata:
      labels:
        app: qwen-hello
    spec:
      restartPolicy: Always
      tolerations:
      - key: "nvidia.com/gpu"
        operator: "Exists"
        effect: "NoSchedule"
      volumes:
      - name: oci2gdsd-root
        hostPath:
          path: __OCI2GDSD_ROOT_PATH__
          type: DirectoryOrCreate
      - name: oci2gdsd-config
        configMap:
          name: oci2gdsd-config
      - name: oci2gdsd-run
        emptyDir: {}
      - name: oci2gdsd-bin
        emptyDir: {}
      - name: run-udev
        hostPath:
          path: /run/udev
          type: Directory
      initContainers:
      - name: preload-model
        image: __OCI2GDSD_IMAGE__
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh", "-ec"]
        args:
        - |
          set -eu
          cp /usr/local/bin/oci2gdsd /oci2gdsd-bin/oci2gdsd
          chmod 0755 /oci2gdsd-bin/oci2gdsd
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json ensure \
            --ref "__MODEL_REF__" \
            --model-id "__MODEL_ID__" \
            --lease-holder "__LEASE_HOLDER__" \
            --strict-integrity \
            --wait
          oci2gdsd --registry-config /etc/oci2gdsd/config.yaml --json status \
            --model-id "__MODEL_ID__" \
            --digest "__MODEL_DIGEST__"
        volumeMounts:
        - name: oci2gdsd-root
          mountPath: __OCI2GDSD_ROOT_PATH__
        - name: oci2gdsd-config
          mountPath: /etc/oci2gdsd
          readOnly: true
        - name: oci2gdsd-bin
          mountPath: /oci2gdsd-bin
      containers:
      - name: pytorch-api
        image: __PYTORCH_RUNTIME_IMAGE__
        imagePullPolicy: IfNotPresent
        securityContext:
          runAsUser: 0
          runAsGroup: 0
        command: ["/bin/sh", "-ec"]
        args:
        - |
          set -eu
          if [ ! -e /usr/local/cuda/lib64/libcufile.so ] && [ -e /usr/local/cuda/lib64/libcufile.so.0 ]; then
            ln -sf /usr/local/cuda/lib64/libcufile.so.0 /usr/local/cuda/lib64/libcufile.so
          fi
          if [ ! -e /usr/lib/x86_64-linux-gnu/libcufile.so ] && [ -e /usr/local/cuda/lib64/libcufile.so ]; then
            ln -sf /usr/local/cuda/lib64/libcufile.so /usr/lib/x86_64-linux-gnu/libcufile.so
          fi
          if [ ! -e /usr/local/cuda/lib64/libcuda.so.1 ] && [ -e /usr/local/cuda/compat/libcuda.so.1 ]; then
            ln -sf /usr/local/cuda/compat/libcuda.so.1 /usr/local/cuda/lib64/libcuda.so.1
          fi
          python - <<'PY_DEPS'
          import importlib.util
          import subprocess
          import sys

          wanted = {
              "fastapi": "fastapi",
              "pydantic": "pydantic",
              "uvicorn": "uvicorn",
              "transformers": "transformers",
              "safetensors": "safetensors",
          }
          missing = [pkg for pkg, mod in wanted.items() if importlib.util.find_spec(mod) is None]
          if missing:
              subprocess.check_call([
                  sys.executable,
                  "-m",
                  "pip",
                  "install",
                  "--no-cache-dir",
                  "--break-system-packages",
                  *missing,
              ])
          PY_DEPS
          /oci2gdsd-bin/oci2gdsd --registry-config /etc/oci2gdsd/config.yaml serve \
            --unix-socket /run/oci2gdsd/daemon.sock \
            --socket-perms 0660 &
          daemon_pid="$!"
          cleanup() {
            kill "${daemon_pid}" 2>/dev/null || true
            wait "${daemon_pid}" 2>/dev/null || true
          }
          trap cleanup EXIT INT TERM
          python - <<'PY'
          import json
          import os
          import socket
          import shutil
          from pathlib import Path

          from fastapi import FastAPI, HTTPException
          from pydantic import BaseModel
          import torch
          from torch.library import Library
          import uvicorn
          from transformers import AutoModelForCausalLM, AutoTokenizer

          OCI2GDS_NATIVE_CPP = r"""
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

          static py::dict read_into_tensor_native(
              const std::string& path,
              torch::Tensor tensor,
              int64_t file_offset,
              int64_t length,
              bool strict,
              int64_t chunk_bytes) {
            if (!tensor.is_cuda()) {
              throw std::runtime_error("tensor must be CUDA for native cuFile path");
            }
            if (tensor.scalar_type() != at::ScalarType::Byte) {
              throw std::runtime_error("tensor must be uint8");
            }
            if (!tensor.is_contiguous()) {
              throw std::runtime_error("tensor must be contiguous");
            }
            if (file_offset < 0 || length < 0) {
              throw std::runtime_error("offset and length must be non-negative");
            }
            if (length > static_cast<int64_t>(tensor.numel())) {
              throw std::runtime_error("tensor is smaller than requested length");
            }
            if (chunk_bytes < 4096) {
              chunk_bytes = 4096;
            }
            chunk_bytes = (chunk_bytes / 4096) * 4096;
            if (chunk_bytes == 0) {
              chunk_bytes = 4096;
            }

            ensure_gds_ready();
            int device = tensor.get_device();
            cudaError_t crt = cudaSetDevice(device);
            if (crt != cudaSuccess) {
              throw std::runtime_error("cudaSetDevice failed");
            }
            (void)cudaFree(0);

            int fd = -1;
            bool direct_io = true;
            std::string fallback_reason;
            fd = ::open(path.c_str(), O_RDONLY | O_DIRECT);
            if (fd < 0) {
              if (strict) {
                throw std::runtime_error("open(O_DIRECT) failed");
              }
              fd = ::open(path.c_str(), O_RDONLY);
              if (fd < 0) {
                throw std::runtime_error("open failed");
              }
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
              throw std::runtime_error("offset beyond end of file");
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
                  throw std::runtime_error("cuFileHandleRegister failed");
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
                  throw std::runtime_error("cuFileBufRegister failed");
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
                    if (buf_registered) {
                      (void)cuFileBufDeregister(tensor.data_ptr());
                    }
                    (void)cuFileHandleDeregister(cfh);
                    ::close(fd);
                    throw std::runtime_error("cuFileRead failed");
                  }
                  fallback_reason = "cufile_read_failed";
                  break;
                }
                if (n == 0) {
                  break;
                }
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
                  if (buf_registered) {
                    (void)cuFileBufDeregister(tensor.data_ptr());
                  }
                  if (handle_registered) {
                    (void)cuFileHandleDeregister(cfh);
                  }
                  ::close(fd);
                  throw std::runtime_error("pread fallback failed");
                }
                crt = cudaMemcpy(
                    reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(tensor.data_ptr()) + static_cast<uintptr_t>(bytes_done)),
                    host.data(),
                    static_cast<size_t>(n),
                    cudaMemcpyHostToDevice);
                if (crt != cudaSuccess) {
                  if (buf_registered) {
                    (void)cuFileBufDeregister(tensor.data_ptr());
                  }
                  if (handle_registered) {
                    (void)cuFileHandleDeregister(cfh);
                  }
                  ::close(fd);
                  throw std::runtime_error("cudaMemcpy fallback failed");
                }
                bytes_done += static_cast<int64_t>(n);
              }
            }

            if (buf_registered) {
              (void)cuFileBufDeregister(tensor.data_ptr());
            }
            if (handle_registered) {
              (void)cuFileHandleDeregister(cfh);
            }
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
            m.def("read_into_tensor_native", &read_into_tensor_native, "Read file bytes into CUDA tensor via cuFile when possible");
          }
          """

          OCI2GDS_IPC_NATIVE_CPP = r"""
          #include <torch/extension.h>
          #include <pybind11/pybind11.h>
          #include <cuda.h>
          #include <string.h>
          #include <string>
          #include <vector>
          #include <stdexcept>

          namespace py = pybind11;

          static std::vector<unsigned char> decode_b64(const std::string& input) {
            static const signed char kDec[256] = {
              -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
              -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,52,53,54,55,56,57,58,59,60,61,-1,-1,-1, 0,-1,-1,
              -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,63,
              -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1,
              -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
              -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
              -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
              -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1
            };
            std::vector<unsigned char> out;
            out.reserve((input.size() * 3) / 4);
            int val = 0;
            int valb = -8;
            for (unsigned char c : input) {
              if (c == '=') break;
              signed char d = kDec[c];
              if (d < 0) continue;
              val = (val << 6) + d;
              valb += 6;
              if (valb >= 0) {
                out.push_back((unsigned char)((val >> valb) & 0xFF));
                valb -= 8;
              }
            }
            return out;
          }

          static torch::Tensor import_ipc_copy_to_tensor(const std::string& handle_b64, int64_t length, int64_t device) {
            if (length <= 0) {
              throw std::runtime_error("length must be > 0");
            }
            auto bytes = decode_b64(handle_b64);
            if (bytes.size() != sizeof(CUipcMemHandle)) {
              throw std::runtime_error("invalid CUDA IPC handle payload size");
            }

            CUresult cu = cuInit(0);
            if (cu != CUDA_SUCCESS) {
              throw std::runtime_error("cuInit failed");
            }
            CUdevice dev;
            cu = cuDeviceGet(&dev, (int)device);
            if (cu != CUDA_SUCCESS) {
              throw std::runtime_error("cuDeviceGet failed");
            }
            CUcontext retained = nullptr;
            cu = cuDevicePrimaryCtxRetain(&retained, dev);
            if (cu != CUDA_SUCCESS) {
              throw std::runtime_error("cuDevicePrimaryCtxRetain failed");
            }
            CUcontext prev = nullptr;
            cu = cuCtxPushCurrent(retained);
            if (cu != CUDA_SUCCESS) {
              (void)cuDevicePrimaryCtxRelease(dev);
              throw std::runtime_error("cuCtxPushCurrent failed");
            }

            CUipcMemHandle handle{};
            memcpy(&handle, bytes.data(), sizeof(CUipcMemHandle));
            CUdeviceptr imported = 0;
            cu = cuIpcOpenMemHandle(&imported, handle, CU_IPC_MEM_LAZY_ENABLE_PEER_ACCESS);
            if (cu != CUDA_SUCCESS) {
              (void)cuCtxPopCurrent(&prev);
              (void)cuDevicePrimaryCtxRelease(dev);
              throw std::runtime_error("cuIpcOpenMemHandle failed");
            }

            auto out = torch::empty(
                {length},
                torch::TensorOptions().dtype(torch::kUInt8).device(torch::kCUDA, (int)device));
            cu = cuMemcpyDtoD((CUdeviceptr)out.data_ptr(), imported, (size_t)length);
            CUresult close_res = cuIpcCloseMemHandle(imported);
            (void)cuCtxPopCurrent(&prev);
            (void)cuDevicePrimaryCtxRelease(dev);
            if (cu != CUDA_SUCCESS) {
              throw std::runtime_error("cuMemcpyDtoD failed");
            }
            if (close_res != CUDA_SUCCESS) {
              throw std::runtime_error("cuIpcCloseMemHandle failed");
            }
            return out;
          }

          PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
            m.def("import_ipc_copy_to_tensor", &import_ipc_copy_to_tensor, "Import CUDA IPC handle and copy bytes into a CUDA tensor");
          }
          """

          _REGISTERED_LIBRARIES = []
          _NATIVE_MODULE = None
          _NATIVE_ERROR = ""
          _IPC_NATIVE_MODULE = None
          _IPC_NATIVE_ERROR = ""

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
              verbose = os.environ.get("OCI2GDS_TORCH_NATIVE_VERBOSE", "0").strip() == "1"
              name = f"oci2gds_torch_native_{os.getpid()}"
              try:
                  module = load_inline(
                      name=name,
                      cpp_sources=[OCI2GDS_NATIVE_CPP],
                      functions=None,
                      extra_cflags=["-O3", "-std=c++17"],
                      extra_ldflags=ldflags,
                      extra_include_paths=include_paths,
                      with_cuda=False,
                      build_directory=str(build_dir),
                      verbose=verbose,
                  )
                  return module, ""
              except Exception as exc:
                  return None, f"native build/load failed: {exc}"

          def _load_ipc_native_module():
              if not _native_enabled():
                  return None, "ipc native backend disabled"
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
              ldflags.append("-lcuda")
              verbose = os.environ.get("OCI2GDS_TORCH_NATIVE_VERBOSE", "0").strip() == "1"
              name = f"oci2gds_torch_ipc_native_{os.getpid()}"
              try:
                  module = load_inline(
                      name=name,
                      cpp_sources=[OCI2GDS_IPC_NATIVE_CPP],
                      functions=None,
                      extra_cflags=["-O3", "-std=c++17"],
                      extra_ldflags=ldflags,
                      extra_include_paths=include_paths,
                      with_cuda=False,
                      build_directory=str(build_dir),
                      verbose=verbose,
                  )
                  return module, ""
              except Exception as exc:
                  return None, f"ipc native build/load failed: {exc}"

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
                      }
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
                          scratch = torch.empty(read_len, dtype=torch.uint8, device=target)
                          out = torch.ops.oci2gds.read_into_tensor(
                              str(shard_path),
                              scratch,
                              0,
                              read_len,
                              bool(strict),
                              int(chunk_bytes),
                          )
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
                  }

              impl_lib.impl("read_into_tensor", _read_into_tensor)
              impl_lib.impl("load_profile", _load_profile)

          _register_oci2gds_ops()
          oci2gds_backend = {
              "backend": "native-cufile" if _NATIVE_MODULE is not None else "python-fallback",
              "native_error": _NATIVE_ERROR,
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
                  load_req = {
                      "model_id": str(model_id),
                      "digest": str(model_digest),
                      "lease_holder": str(lease_holder),
                      "device": int(device_idx),
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
                      "device": int(device_idx),
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
          oci2gds_strict = os.environ.get("OCI2GDS_STRICT", "false").strip().lower() in {"1", "true", "yes"}
          oci2gds_probe_strict = os.environ.get("OCI2GDS_PROBE_STRICT", "false").strip().lower() in {"1", "true", "yes"}
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
          PY
        env:
        - name: MODEL_ROOT_PATH
          value: "__MODEL_ROOT_PATH__"
        - name: MODEL_ID
          value: "__MODEL_ID__"
        - name: MODEL_DIGEST
          value: "__MODEL_DIGEST__"
        - name: LEASE_HOLDER
          value: "__LEASE_HOLDER__"
        - name: OCI2GDS_DAEMON_SOCKET
          value: "/run/oci2gdsd/daemon.sock"
        - name: OCI2GDS_DAEMON_ENABLE
          value: "1"
        - name: OCI2GDS_DAEMON_PROBE_SHARDS
          value: "1"
        - name: MAX_NEW_TOKENS
          value: "128"
        - name: TEMPERATURE
          value: "0.7"
        - name: TOP_P
          value: "0.95"
        - name: LOCAL_MODEL_DIR
          value: "/tmp/oci2gdsd-local-model"
        - name: OCI2GDS_TORCH_ENABLE_NATIVE
          value: "1"
        - name: OCI2GDS_TORCH_NATIVE_VERBOSE
          value: "0"
        - name: CUDA_INCLUDE_DIR
          value: "/usr/local/cuda/include"
        - name: CUDA_LIB_DIR
          value: "/usr/local/cuda/lib64"
        - name: OCI2GDS_CHUNK_BYTES
          value: "4194304"
        - name: OCI2GDS_SAMPLE_BYTES_PER_SHARD
          value: "8388608"
        - name: OCI2GDS_STRICT
          value: "__OCI2GDS_STRICT__"
        - name: OCI2GDS_PROBE_STRICT
          value: "__OCI2GDS_PROBE_STRICT__"
        - name: HF_HOME
          value: "/tmp/hf-cache"
        - name: XDG_CACHE_HOME
          value: "/tmp/hf-cache"
        - name: HF_HUB_OFFLINE
          value: "1"
        - name: TRANSFORMERS_OFFLINE
          value: "1"
        startupProbe:
          httpGet:
            path: /healthz
            port: 8000
          periodSeconds: 10
          failureThreshold: 120
        readinessProbe:
          httpGet:
            path: /healthz
            port: 8000
          periodSeconds: 10
          failureThreshold: 6
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8000
          periodSeconds: 20
          failureThreshold: 6
        resources:
          limits:
            nvidia.com/gpu: "1"
          requests:
            nvidia.com/gpu: "1"
        volumeMounts:
        - name: oci2gdsd-root
          mountPath: __OCI2GDSD_ROOT_PATH__
          readOnly: false
        - name: oci2gdsd-config
          mountPath: /etc/oci2gdsd
          readOnly: true
        - name: oci2gdsd-run
          mountPath: /run/oci2gdsd
          readOnly: false
        - name: oci2gdsd-bin
          mountPath: /oci2gdsd-bin
          readOnly: true
        - name: run-udev
          mountPath: /run/udev
          readOnly: true
---
apiVersion: v1
kind: Service
metadata:
  name: qwen-hello
  namespace: __QWEN_HELLO_NAMESPACE__
spec:
  selector:
    app: qwen-hello
  ports:
  - name: http
    port: 8000
    targetPort: 8000
