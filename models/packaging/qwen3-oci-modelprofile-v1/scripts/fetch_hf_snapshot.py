#!/usr/bin/env python3
import argparse
import os
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Download Qwen3 snapshot from Hugging Face")
    p.add_argument("--hf-repo", required=True, help="Hugging Face repo id, example: Qwen/Qwen3-0.6B")
    p.add_argument("--hf-revision", default="main", help="HF revision (branch/tag/commit)")
    p.add_argument("--out-dir", required=True, help="Destination directory")
    p.add_argument("--include-py", action="store_true", help="Include Python files")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    try:
        from huggingface_hub import snapshot_download
    except ModuleNotFoundError as exc:
        raise SystemExit(
            "missing dependency huggingface_hub; run `pip install -r requirements.txt` "
            "or use the provided Docker image"
        ) from exc

    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    token = os.getenv("HF_TOKEN", None)
    allow_patterns = [
        "*.safetensors",
        "*.safetensors.index.json",
        "config.json",
        "generation_config.json",
        "tokenizer.json",
        "tokenizer.model",
        "tokenizer_config.json",
        "special_tokens_map.json",
        "vocab.json",
        "merges.txt",
        "*.tiktoken",
        "README.md",
    ]
    if args.include_py:
        allow_patterns.append("*.py")

    ignore_patterns = [
        "*.bin",
        "*.onnx",
        "*.h5",
        "*.msgpack",
    ]

    snapshot_download(
        repo_id=args.hf_repo,
        revision=args.hf_revision,
        local_dir=str(out_dir),
        local_dir_use_symlinks=False,
        allow_patterns=allow_patterns,
        ignore_patterns=ignore_patterns,
        token=token,
        resume_download=True,
    )
    print(f"snapshot downloaded: repo={args.hf_repo} revision={args.hf_revision} dir={out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
