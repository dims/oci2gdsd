# Qwen3 OCI Packaging (ModelProfile v1)

This directory provides a reproducible workflow to package a Qwen3 model from
Hugging Face into an OCI artifact that matches `oci2gdsd` expectations:

- `artifactType`: `application/vnd.oci2gdsd.model.v1`
- config media type: `application/vnd.oci2gdsd.model.config.v1+json`
- one layer per payload file under `shards/`:
  - model weight shards (`*.safetensors`)
  - runtime model files (`config.json`, tokenizer files, and related metadata)
- original Hugging Face shard filenames are preserved for index compatibility

The resulting artifact is digest-pinnable and consumable by:

```bash
oci2gdsd ensure --ref <registry>/<repo>@sha256:<digest> --model-id <id> --wait --json
```

## Files

- `Dockerfile`: containerized packaging environment (Python + ORAS).
- `requirements.txt`: Python dependencies for HF snapshot download.
- `scripts/fetch_hf_snapshot.py`: downloads model files from Hugging Face.
- `scripts/prepare_payload.py`: normalizes shards and writes `model-config.json`.
- `scripts/push_with_oras.sh`: pushes artifact to registry with required media types.
- `scripts/package_and_push.sh`: orchestrates full flow end-to-end.

## Quick Start (Containerized)

1. Build packager image:

```bash
cd /path/to/oci2gdsd/models/qwen3-oci-modelprofile-v1
docker build -t oci2gdsd-qwen3-packager:local .
```

2. Run full package + push:

```bash
mkdir -p ./work
docker run --rm \
  -e HF_TOKEN="${HF_TOKEN:-}" \
  -v "$PWD/work:/work" \
  -v "$HOME/.docker/config.json:/root/.docker/config.json:ro" \
  oci2gdsd-qwen3-packager:local \
  /workspace/scripts/package_and_push.sh \
  --hf-repo Qwen/Qwen3-0.6B \
  --hf-revision main \
  --model-id qwen3-0.6b \
  --oci-ref registry.example.com/models/qwen3-0.6b:v1
```

3. Capture immutable digest:

```bash
cat ./work/output/manifest-descriptor.json
```

Then use the descriptor digest in `oci2gdsd ensure`.

For command semantics and config behavior, use:

- [../../docs/cli-reference.md](../../docs/cli-reference.md)
- [../../docs/config-reference.md](../../docs/config-reference.md)

## Notes

- Some Qwen3 repositories require HF authentication. Set `HF_TOKEN`.
- `integrity.manifestDigest` in `model-config.json` uses a placeholder
  (`resolved-manifest-digest`) to avoid impossible self-referential digest loops.
  The actual manifest digest remains the runtime immutable key.
- This workflow intentionally ignores legacy `.bin` checkpoints and uses
  safetensors shards as the primary payload, with required runtime metadata
  included so engines can load from the OCI-preloaded local directory.
