#!/usr/bin/env python3
import argparse
import hashlib
import json
import shutil
from pathlib import Path
from typing import Dict, List

MANIFEST_DIGEST_PLACEHOLDER = "resolved-manifest-digest"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Prepare OCI payload directory from HF snapshot")
    p.add_argument("--source-dir", required=True, help="HF snapshot directory")
    p.add_argument("--payload-dir", required=True, help="output payload directory")
    p.add_argument("--model-id", required=True, help="model id used by oci2gdsd")
    p.add_argument("--model-revision", default="main", help="model revision")
    p.add_argument("--hf-repo", default="", help="source Hugging Face repo id")
    p.add_argument("--framework", default="transformers", help="framework field")
    p.add_argument("--format", default="safetensors", help="format field")
    return p.parse_args()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            b = f.read(8 * 1024 * 1024)
            if not b:
                break
            h.update(b)
    return "sha256:" + h.hexdigest()


def find_safetensor_shards(source_dir: Path) -> List[Path]:
    shards = sorted(
        [p for p in source_dir.rglob("*.safetensors") if p.is_file()],
        key=lambda p: p.name,
    )
    return shards


def find_runtime_files(source_dir: Path) -> List[Path]:
    patterns = [
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer.model",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "vocab.json",
        "merges.txt",
        "*.tiktoken",
        "*.safetensors.index.json",
        "README.md",
    ]
    files: List[Path] = []
    seen = set()
    for pattern in patterns:
        for src in sorted(source_dir.glob(pattern), key=lambda p: p.name):
            if not src.is_file():
                continue
            key = src.name
            if key in seen:
                continue
            files.append(src)
            seen.add(key)
    return files


def copy_metadata(source_dir: Path, metadata_dir: Path) -> None:
    metadata_dir.mkdir(parents=True, exist_ok=True)
    patterns = [
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer.model",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "vocab.json",
        "merges.txt",
        "*.tiktoken",
        "*.safetensors.index.json",
        "README.md",
    ]
    copied = set()
    for pattern in patterns:
        for src in source_dir.glob(pattern):
            if not src.is_file():
                continue
            if src.name in copied:
                continue
            dst = metadata_dir / src.name
            shutil.copy2(src, dst)
            copied.add(src.name)


def build_model_config(args: argparse.Namespace, shard_entries: List[Dict]) -> Dict:
    return {
        "schemaVersion": 1,
        "modelId": args.model_id,
        "modelRevision": args.model_revision,
        "framework": args.framework,
        "format": args.format,
        "shards": shard_entries,
        "integrity": {
            "manifestDigest": MANIFEST_DIGEST_PLACEHOLDER
        },
        "source": {
            "type": "huggingface",
            "repoId": args.hf_repo or args.model_id,
            "revision": args.model_revision
        }
    }


def main() -> int:
    args = parse_args()
    source_dir = Path(args.source_dir).resolve()
    payload_dir = Path(args.payload_dir).resolve()
    metadata_dir = payload_dir / "metadata"
    shards_dir = payload_dir / "shards"
    metadata_dir.mkdir(parents=True, exist_ok=True)
    shards_dir.mkdir(parents=True, exist_ok=True)

    shards = find_safetensor_shards(source_dir)
    if not shards:
        raise RuntimeError(f"no .safetensors shards found in {source_dir}")

    shard_entries: List[Dict] = []
    total = len(shards)
    for idx, src in enumerate(shards, start=1):
        normalized_name = src.name
        dst = shards_dir / normalized_name
        if dst.exists():
            raise RuntimeError(f"duplicate shard filename in source snapshot: {normalized_name}")
        shutil.copy2(src, dst)
        digest = sha256_file(dst)
        size = dst.stat().st_size
        shard_entries.append(
            {
                "name": normalized_name,
                "sourceName": src.name,
                "digest": digest,
                "size": size,
                "ordinal": idx,
                "kind": "weight",
            }
        )

    ordinal = total + 1
    for src in find_runtime_files(source_dir):
        if (shards_dir / src.name).exists():
            continue
        dst = shards_dir / src.name
        shutil.copy2(src, dst)
        digest = sha256_file(dst)
        size = dst.stat().st_size
        shard_entries.append(
            {
                "name": src.name,
                "sourceName": src.name,
                "digest": digest,
                "size": size,
                "ordinal": ordinal,
                "kind": "runtime",
            }
        )
        ordinal += 1

    copy_metadata(source_dir, metadata_dir)
    model_config = build_model_config(args, shard_entries)
    with (metadata_dir / "model-config.json").open("w", encoding="utf-8") as f:
        json.dump(model_config, f, indent=2)
        f.write("\n")

    manifest = {
        "modelId": args.model_id,
        "modelRevision": args.model_revision,
        "sourceDir": str(source_dir),
        "payloadDir": str(payload_dir),
        "shardCount": len(shard_entries),
        "weightShardCount": total,
        "runtimeFileCount": len(shard_entries) - total,
        "totalBytes": sum(int(s["size"]) for s in shard_entries),
    }
    with (payload_dir / "payload-manifest.json").open("w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")

    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
