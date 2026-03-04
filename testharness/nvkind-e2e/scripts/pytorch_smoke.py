import hashlib
import json
import os
from pathlib import Path
import torch

model_root = Path(os.environ["MODEL_ROOT_PATH"])
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

device = torch.device("cuda:0")
a = torch.randn((2048, 2048), device=device)
b = torch.randn((2048, 2048), device=device)
c = torch.matmul(a, b)
torch.cuda.synchronize()
value = float(c.mean().item())

print(
    "PYTORCH_SMOKE_SUCCESS "
    f"model_id={metadata.get('modelId')} "
    f"manifest={metadata.get('manifestDigest')} "
    f"shard={first_shard.name} "
    f"sample_sha256={sample_sha} "
    f"cuda_device={torch.cuda.get_device_name(0)} "
    f"matmul_mean={value}"
)
