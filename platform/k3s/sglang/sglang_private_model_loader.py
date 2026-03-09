from __future__ import annotations

import json
import os
from pathlib import Path

import torch

from daemon_client_common import load_native_module, torch_dtype_from_safetensors
from sglang.srt.configs.load_config import LoadConfig, LoadFormat
from sglang.srt.model_loader.loader import BaseModelLoader, DummyModelLoader


class PrivateModelLoader(BaseModelLoader):
    def __init__(self, load_config: LoadConfig):
        super().__init__(load_config)
        extra = dict(load_config.model_loader_extra_config or {})
        self._tensor_map_path = str(
            extra.get("oci2gds_tensor_map_path", os.environ.get("OCI2GDS_SGLANG_TENSOR_MAP_PATH", ""))
        ).strip()
        self._device_index = int(
            extra.get("oci2gds_device_index", os.environ.get("OCI2GDS_SGLANG_DEVICE_INDEX", "0"))
        )
        self._parity_mode = str(
            extra.get("oci2gds_parity_mode", os.environ.get("OCI2GDS_SGLANG_PARITY_MODE", "full"))
        ).strip().lower()

        dummy_cfg = LoadConfig(
            load_format=LoadFormat.DUMMY,
            download_dir=load_config.download_dir,
            model_loader_extra_config={},
            ignore_patterns=load_config.ignore_patterns,
            decryption_key_file=load_config.decryption_key_file,
            decrypt_max_concurrency=load_config.decrypt_max_concurrency,
            tp_rank=load_config.tp_rank,
            draft_model_idx=load_config.draft_model_idx,
        )
        self._dummy_loader = DummyModelLoader(dummy_cfg)

    def download_model(self, model_config) -> None:
        self._dummy_loader.download_model(model_config)

    def _read_tensor_map(self):
        if not self._tensor_map_path:
            raise RuntimeError("oci2gds tensor-map path is required for SGLang private loader")
        path = Path(self._tensor_map_path)
        if not path.exists():
            raise RuntimeError(f"tensor-map path does not exist: {path}")
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, list) or not payload:
            raise RuntimeError(f"tensor-map payload must be a non-empty list: {path}")
        return payload

    def load_model(self, *, model_config, device_config):
        model = self._dummy_loader.load_model(
            model_config=model_config,
            device_config=device_config,
        )

        tensor_map = self._read_tensor_map()
        native = load_native_module(
            build_dir_default="/tmp/oci2gds_sglang_build",
            module_name_prefix="oci2gds_sglang_native",
            required_symbol="import_ipc_tensor_view",
        )

        named_tensors = []
        loaded_tensors = 0
        loaded_bytes = 0

        for entry in tensor_map:
            name = str(entry.get("name", "")).strip()
            if not name:
                continue
            handle = str(entry.get("ipc_handle", "")).strip()
            if not handle:
                continue

            shape = [int(x) for x in entry.get("shape", [])]
            if not shape:
                continue

            dtype_code = str(entry.get("dtype", "")).strip()
            if not dtype_code:
                continue
            expected_dtype = torch_dtype_from_safetensors(dtype_code)

            byte_offset = int(entry.get("byte_offset", 0))
            byte_length = int(entry.get("byte_length", 0))
            if byte_offset < 0 or byte_length <= 0:
                continue

            view = native.import_ipc_tensor_view(
                handle,
                int(byte_offset),
                shape,
                dtype_code,
                int(self._device_index),
            )
            if not isinstance(view, torch.Tensor):
                raise RuntimeError(f"IPC import returned non-tensor for {name}")
            if view.dtype != expected_dtype:
                raise RuntimeError(
                    f"IPC import dtype mismatch for {name}: imported={view.dtype} expected={expected_dtype}"
                )

            named_tensors.append((name, view))
            loaded_tensors += 1
            loaded_bytes += byte_length

        if loaded_tensors == 0:
            raise RuntimeError("SGLang private loader imported zero tensors from IPC tensor-map")

        model.load_weights(named_tensors)

        param_count = sum(1 for _ in model.named_parameters())
        map_names = {str(entry.get("name", "")).strip() for entry in tensor_map if str(entry.get("name", "")).strip()}
        exact_param_matches = 0
        for name, _ in model.named_parameters():
            if name in map_names:
                exact_param_matches += 1

        status = "ok"
        if self._parity_mode == "full" and exact_param_matches == 0:
            raise RuntimeError("SGLang private loader could not match any model parameters to tensor-map names")

        unresolved = max(0, param_count - exact_param_matches)
        print(
            "SGLANG_PRIVATE_LOADER_OK "
            f"status={status} "
            f"parity_mode={self._parity_mode} "
            f"loaded_tensors={loaded_tensors} "
            f"loaded_bytes={loaded_bytes} "
            f"rebound_params={exact_param_matches} "
            f"unresolved={unresolved}",
            flush=True,
        )

        return model.eval()
