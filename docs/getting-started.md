# Getting Started

This guide walks you through `oci2gdsd` end-to-end on any machine — no GPU, no
Kubernetes, no NVIDIA hardware needed. You'll build the binary, push a tiny test
artifact to a local registry, and exercise the full `ensure → status → verify →
release → gc` lifecycle.

Time: about 10 minutes.

---

## What you need

- Go 1.23+
- Docker (for the local OCI registry)
- `oras` CLI v1.2+ — install from [oras.land/docs/installation](https://oras.land/docs/installation)

---

## Step 1: Build

```bash
git clone https://github.com/dims/oci2gdsd
cd oci2gdsd
go build ./cmd/oci2gdsd
./oci2gdsd --help
```

You should see the help output listing all subcommands.

---

## Step 2: Start a local OCI registry

```bash
docker run -d --rm -p 5000:5000 --name local-registry registry:2
```

Verify it's running:

```bash
curl -s http://localhost:5000/v2/ | cat
# Expected: {}
```

---

## Step 3: Create a tiny test model artifact

We'll push a minimal OCI artifact that `oci2gdsd` can consume. An artifact needs:
1. A shard file (the "model weights" — we'll use a dummy file)
2. A `model.json` config blob (OCI-ModelProfile-v1 metadata)

### 3a. Create the payload files

```bash
mkdir -p /tmp/test-model/shards /tmp/test-model/metadata

# Create a dummy "shard" (real models use .safetensors or .gguf files)
dd if=/dev/urandom of=/tmp/test-model/shards/model-00001-of-00001.bin bs=1M count=1 2>/dev/null

# Compute its sha256 digest
SHARD_DIGEST=$(sha256sum /tmp/test-model/shards/model-00001-of-00001.bin | awk '{print "sha256:"$1}')
SHARD_SIZE=$(stat -c%s /tmp/test-model/shards/model-00001-of-00001.bin)

echo "Shard digest: $SHARD_DIGEST"
echo "Shard size:   $SHARD_SIZE bytes"
```

### 3b. Write the OCI-ModelProfile-v1 config

```bash
cat > /tmp/test-model/metadata/model.json <<EOF
{
  "schemaVersion": 1,
  "modelId": "test-model",
  "modelRevision": "v1",
  "framework": "pytorch",
  "format": "safetensors",
  "shards": [
    {
      "name": "model-00001-of-00001.bin",
      "digest": "${SHARD_DIGEST}",
      "size": ${SHARD_SIZE},
      "ordinal": 1,
      "kind": "weights"
    }
  ]
}
EOF
```

### 3c. Push to the local registry with oras

```bash
cd /tmp/test-model

oras push localhost:5000/models/test-model:v1 \
  --config metadata/model.json:application/vnd.oci.model-profile.v1+json \
  shards/model-00001-of-00001.bin:application/vnd.oci.model.shard.v1
```

Get the immutable digest of what was pushed:

```bash
MODEL_DIGEST=$(oras resolve localhost:5000/models/test-model:v1)
echo "Model digest: $MODEL_DIGEST"
# e.g. sha256:a3f8c1d2...
```

Hold onto that digest — you'll use it in every subsequent command.

---

## Step 4: Create a working directory for oci2gdsd

```bash
sudo mkdir -p /var/lib/oci2gdsd
sudo chown $USER /var/lib/oci2gdsd
```

Or use a temp dir if you prefer not to write to `/var/lib`:

```bash
export OCI2GDSD_ROOT=/tmp/oci2gdsd-test
mkdir -p $OCI2GDSD_ROOT
```

---

## Step 5: ensure — download and cache the model

```bash
cd /path/to/oci2gdsd  # back to repo root where you built the binary

./oci2gdsd \
  --root /var/lib/oci2gdsd \
  ensure \
  --ref localhost:5000/models/test-model@${MODEL_DIGEST} \
  --model-id test-model \
  --lease-holder getting-started-1 \
  --wait \
  --json
```

Expected output (success):

```json
{"status":"READY","model_id":"test-model","digest":"sha256:a3f8c1d2...","path":"/var/lib/oci2gdsd/models/test-model/sha256-a3f8c1d2..."}
```

What happened:
- The manifest was fetched and validated against the digest
- `model.json` was parsed and linted (OCI-ModelProfile-v1 check)
- The shard file was downloaded and its digest/size verified
- Everything was written atomically; `READY` was created last
- A lease for `getting-started-1` was recorded in state.db

> **Idempotent**: running `ensure` again with the same ref + lease-holder is safe — it will
> detect the existing READY model and just refresh the lease.

---

## Step 6: status — check the record

```bash
./oci2gdsd \
  --root /var/lib/oci2gdsd \
  status \
  --model-id test-model \
  --digest ${MODEL_DIGEST} \
  --json
```

```json
{"model_id":"test-model","status":"READY","leases":["getting-started-1"],...}
```

---

## Step 7: list — see all cached models

```bash
./oci2gdsd --root /var/lib/oci2gdsd list --json
```

---

## Step 8: verify — re-check integrity

```bash
./oci2gdsd \
  --root /var/lib/oci2gdsd \
  verify \
  --model-id test-model \
  --digest ${MODEL_DIGEST} \
  --json
```

`verify` re-reads every shard on disk and compares digests against the profile.
Exit code `0` means the cached copy is intact.

---

## Step 9: profile inspect — read the metadata

```bash
./oci2gdsd \
  profile inspect \
  --ref localhost:5000/models/test-model@${MODEL_DIGEST} \
  --json
```

---

## Step 10: release and gc — clean up

First release the lease you acquired during `ensure`:

```bash
./oci2gdsd \
  --root /var/lib/oci2gdsd \
  release \
  --model-id test-model \
  --digest ${MODEL_DIGEST} \
  --lease-holder getting-started-1 \
  --json
```

Now run garbage collection. Because no leases remain, the model is eligible:

```bash
./oci2gdsd \
  --root /var/lib/oci2gdsd \
  gc \
  --policy lru_no_lease \
  --min-free-bytes 1G \
  --json
```

The cached model directory is deleted. Confirm with:

```bash
./oci2gdsd --root /var/lib/oci2gdsd list --json
# Should return an empty array []
```

---

## What to try next

| Next step | Guide |
|-----------|-------|
| Use a real YAML config instead of `--root` flags | [docs/config-reference.md](config-reference.md) |
| See all CLI flags | [docs/cli-reference.md](cli-reference.md) |
| Package a real model from Hugging Face | [packaging/qwen3-oci-modelprofile-v1/README.md](../packaging/qwen3-oci-modelprofile-v1/README.md) |
| Deploy on Kubernetes with GPU | [testharness/nvkind-e2e/README.md](../testharness/nvkind-e2e/README.md) |
| Understand the profile format | [docs/OCI-ModelProfile-v1.md](OCI-ModelProfile-v1.md) |
| Something not working? | [docs/troubleshooting.md](troubleshooting.md) |

---

## Troubleshooting this walkthrough

**`plain_http` needed for localhost registry**

If `ensure` fails with a TLS error against `localhost:5000`, add `--registry-config` pointing
to a config with `registry.plain_http: true`, or set the flag inline:

```bash
# Create a minimal config override
cat > /tmp/oci2gdsd-local.yaml <<'EOF'
root: /var/lib/oci2gdsd
model_root: /var/lib/oci2gdsd/models
tmp_root: /var/lib/oci2gdsd/tmp
locks_root: /var/lib/oci2gdsd/locks
journal_dir: /var/lib/oci2gdsd/journal
state_db: /var/lib/oci2gdsd/state.db
registry:
  plain_http: true
EOF

./oci2gdsd \
  --registry-config /tmp/oci2gdsd-local.yaml \
  ensure \
  --ref localhost:5000/models/test-model@${MODEL_DIGEST} \
  --model-id test-model \
  --lease-holder getting-started-1 \
  --wait --json
```

**`permission denied` writing to `/var/lib/oci2gdsd`**

Use a temp directory instead:

```bash
mkdir -p /tmp/oci2gdsd-test
./oci2gdsd --root /tmp/oci2gdsd-test ensure ...
```

**`oras` not found**

Install oras from [oras.land/docs/installation](https://oras.land/docs/installation):

```bash
# macOS
brew install oras

# Linux (amd64)
VERSION=1.2.2
curl -LO "https://github.com/oras-project/oras/releases/download/v${VERSION}/oras_${VERSION}_linux_amd64.tar.gz"
mkdir -p /tmp/oras && tar -zxf oras_${VERSION}_linux_amd64.tar.gz -C /tmp/oras
sudo mv /tmp/oras/oras /usr/local/bin/
```
