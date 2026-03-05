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
#include <limits>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
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

struct ImportedIPCAllocation {
  CUdeviceptr ptr{0};
  int device{-1};
  int refs{0};
};

static std::mutex g_ipc_mu;
static std::unordered_map<std::string, ImportedIPCAllocation> g_ipc_allocs;

static std::string ipc_key(int device, const std::string& handle_b64) {
  return std::to_string(device) + ":" + handle_b64;
}

static ImportedIPCAllocation open_imported_allocation(int device, const std::string& handle_b64) {
  auto bytes = decode_b64(handle_b64);
  if (bytes.size() != sizeof(CUipcMemHandle)) {
    throw std::runtime_error("invalid CUDA IPC handle payload size");
  }
  CUipcMemHandle handle{};
  memcpy(&handle, bytes.data(), sizeof(CUipcMemHandle));

  CUresult cu = cuInit(0);
  if (cu != CUDA_SUCCESS) {
    throw std::runtime_error("cuInit failed");
  }
  CUdevice dev;
  cu = cuDeviceGet(&dev, device);
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

  CUdeviceptr imported = 0;
  cu = cuIpcOpenMemHandle(&imported, handle, CU_IPC_MEM_LAZY_ENABLE_PEER_ACCESS);
  (void)cuCtxPopCurrent(&prev);
  (void)cuDevicePrimaryCtxRelease(dev);
  if (cu != CUDA_SUCCESS) {
    throw std::runtime_error("cuIpcOpenMemHandle failed");
  }

  ImportedIPCAllocation alloc;
  alloc.ptr = imported;
  alloc.device = device;
  alloc.refs = 1;
  return alloc;
}

static void close_imported_allocation(const ImportedIPCAllocation& alloc) {
  if (alloc.ptr == 0 || alloc.device < 0) return;
  CUresult cu = cuInit(0);
  if (cu != CUDA_SUCCESS) return;
  CUdevice dev;
  cu = cuDeviceGet(&dev, alloc.device);
  if (cu != CUDA_SUCCESS) return;
  CUcontext retained = nullptr;
  cu = cuDevicePrimaryCtxRetain(&retained, dev);
  if (cu != CUDA_SUCCESS) return;
  CUcontext prev = nullptr;
  cu = cuCtxPushCurrent(retained);
  if (cu != CUDA_SUCCESS) {
    (void)cuDevicePrimaryCtxRelease(dev);
    return;
  }
  (void)cuIpcCloseMemHandle(alloc.ptr);
  (void)cuCtxPopCurrent(&prev);
  (void)cuDevicePrimaryCtxRelease(dev);
}

static ImportedIPCAllocation acquire_imported_allocation(int device, const std::string& handle_b64) {
  const std::string key = ipc_key(device, handle_b64);
  {
    std::lock_guard<std::mutex> lock(g_ipc_mu);
    auto it = g_ipc_allocs.find(key);
    if (it != g_ipc_allocs.end()) {
      it->second.refs += 1;
      return it->second;
    }
  }

  ImportedIPCAllocation opened = open_imported_allocation(device, handle_b64);
  {
    std::lock_guard<std::mutex> lock(g_ipc_mu);
    auto it = g_ipc_allocs.find(key);
    if (it != g_ipc_allocs.end()) {
      it->second.refs += 1;
      close_imported_allocation(opened);
      return it->second;
    }
    g_ipc_allocs.emplace(key, opened);
  }
  return opened;
}

static void release_imported_allocation(int device, const std::string& handle_b64) {
  const std::string key = ipc_key(device, handle_b64);
  ImportedIPCAllocation to_close;
  bool should_close = false;
  {
    std::lock_guard<std::mutex> lock(g_ipc_mu);
    auto it = g_ipc_allocs.find(key);
    if (it == g_ipc_allocs.end()) {
      return;
    }
    it->second.refs -= 1;
    if (it->second.refs <= 0) {
      to_close = it->second;
      g_ipc_allocs.erase(it);
      should_close = true;
    }
  }
  if (should_close) {
    close_imported_allocation(to_close);
  }
}

struct DTypeInfo {
  at::ScalarType scalar_type;
  int element_bytes;
};

static DTypeInfo safetensors_dtype(const std::string& code) {
  if (code == "BF16") return {at::ScalarType::BFloat16, 2};
  if (code == "F16") return {at::ScalarType::Half, 2};
  if (code == "F32") return {at::ScalarType::Float, 4};
  if (code == "F64") return {at::ScalarType::Double, 8};
  if (code == "I64") return {at::ScalarType::Long, 8};
  if (code == "I32") return {at::ScalarType::Int, 4};
  if (code == "I16") return {at::ScalarType::Short, 2};
  if (code == "I8") return {at::ScalarType::Char, 1};
  if (code == "U8") return {at::ScalarType::Byte, 1};
  if (code == "BOOL") return {at::ScalarType::Bool, 1};
  throw std::runtime_error("unsupported safetensors dtype: " + code);
}

static int64_t checked_numel(const std::vector<int64_t>& shape) {
  int64_t n = 1;
  for (int64_t dim : shape) {
    if (dim < 0) throw std::runtime_error("shape contains negative dimension");
    if (dim == 0) return 0;
    if (n > (std::numeric_limits<int64_t>::max() / dim)) {
      throw std::runtime_error("shape size overflow");
    }
    n *= dim;
  }
  return n;
}

static torch::Tensor import_ipc_tensor_view(
    const std::string& handle_b64,
    int64_t byte_offset,
    const std::vector<int64_t>& shape,
    const std::string& dtype_code,
    int64_t device) {
  if (device < 0) {
    throw std::runtime_error("device must be >= 0");
  }
  if (byte_offset < 0) {
    throw std::runtime_error("byte_offset must be >= 0");
  }
  if (shape.empty()) {
    throw std::runtime_error("shape must not be empty");
  }

  DTypeInfo info = safetensors_dtype(dtype_code);
  int64_t numel = checked_numel(shape);
  if (numel < 0) {
    throw std::runtime_error("invalid tensor shape");
  }
  if ((byte_offset % info.element_bytes) != 0) {
    throw std::runtime_error("byte_offset is not aligned to tensor element size");
  }
  if (numel > 0 && numel > (std::numeric_limits<int64_t>::max() / info.element_bytes)) {
    throw std::runtime_error("tensor byte size overflow");
  }

  ImportedIPCAllocation alloc = acquire_imported_allocation((int)device, handle_b64);
  uintptr_t base = static_cast<uintptr_t>(alloc.ptr);
  uintptr_t ptr_value = base + static_cast<uintptr_t>(byte_offset);
  const std::string handle_key = handle_b64;
  const int alloc_device = alloc.device;

  auto options = torch::TensorOptions()
      .dtype(info.scalar_type)
      .device(torch::kCUDA, (int)device)
      .requires_grad(false);

  auto tensor = torch::from_blob(
      reinterpret_cast<void*>(ptr_value),
      shape,
      [handle_key, alloc_device](void* /*unused*/) {
        release_imported_allocation(alloc_device, handle_key);
      },
      options);
  return tensor;
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
  m.def("init_native", &init_native, "initialize native cufile path");
  m.def("read_into_tensor_native", &read_into_tensor_native, "read path into CUDA tensor via cuFile");
  m.def("import_ipc_copy_to_tensor", &import_ipc_copy_to_tensor, "import CUDA IPC handle and copy bytes into a CUDA tensor");
  m.def("import_ipc_tensor_view", &import_ipc_tensor_view, "import CUDA IPC handle and create a tensor view without copying");
}
