# SGLang Runtime Harness

SGLang daemon-client verification target:

- `make verify-k3s-sglang`

This runtime validates the same strict pathless runtime contract as the other
k3s runtime jobs:

- no runtime host model-root mount
- no `MODEL_ROOT_PATH` env
- daemon allocation + runtime bundle + tensor-map lifecycle

Implementation notes:

- Uses `load_format=private` with a private loader module installed into the
  runtime image at job start.
- The private loader imports CUDA IPC tensor views from daemon tensor-map
  descriptors and feeds them into SGLang model loading.
- The SGLang job intentionally uses the image's own CUDA headers. Mounting host
  `/usr/local/cuda/include` can mask required toolkit headers such as
  `fatbinary_section.h` and break SGLang JIT kernel compilation during startup.
- Runtime marker coverage includes:
  - `DAEMON_NO_RUNTIME_ARTIFACT_ACCESS_OK`
  - `SGLANG_IPC_TENSOR_MAP_OK`
  - `SGLANG_PRIVATE_LOADER_OK`
  - `SGLANG_QWEN_INFER_OK`
  - `SGLANG_DAEMON_CLIENT_SUCCESS`
