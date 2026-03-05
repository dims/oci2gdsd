# Contributing

## Dev setup

Requirements:

- Go 1.23+
- `docker` (for local registry in integration tests)
- `oras` CLI (for artifact push in getting-started walkthrough)

No GPU or NVIDIA hardware is needed to build, run unit tests, or try the core CLI.

```bash
git clone https://github.com/dims/oci2gdsd
cd oci2gdsd
go build ./cmd/oci2gdsd
go test ./...
```

All unit tests pass without a GPU or a running registry. The integration harnesses
(`platform/`) require real hardware — see their READMEs.

---

## Build variants

### Standard (no GPU support)

```bash
go build ./cmd/oci2gdsd
```

### With GPU Direct Storage (GDS)

Requires Linux, CUDA 12+, and `libcufile`:

```bash
CGO_ENABLED=1 go build -tags gds ./cmd/oci2gdsd
```

The `internal/gpu/stub.go` file provides a no-op fallback for non-Linux or non-GDS builds.
The `internal/gpu/gds_linux.go` file is only compiled with `-tags gds`.

---

## Run tests

```bash
# All unit tests
go test ./...

# Verbose output
go test -v ./...

# A specific package
go test ./internal/app/...
```

Tests in `internal/app/`, `internal/config/`, `internal/registry/`, and `internal/store/`
are pure unit tests with no external dependencies.

---

## Code structure

```
cmd/oci2gdsd/          # Binary entry point (delegates to internal/cli)
internal/
  cli/                 # Command routing and flag parsing
  app/                 # Core service logic: ensure, status, release, gc, verify
  config/              # YAML config loading and validation
  registry/            # ORAS-based registry client
  store/               # JSON state DB with file locking
  model/               # Model state machine types
  gpu/                 # GPU loader interface (stub + Linux GDS impl)
  daemon/              # Unix socket daemon server
  fsutil/              # Filesystem utilities (symlink-safe path ops)
  apperr/              # Structured error types with exit codes
docs/                          # All user-facing documentation
models/
  qwen3-oci-modelprofile-v1/   # Reproducible model packaging workflow (Qwen3)
  profiles/                    # Example config/profile payloads
charts/                        # Helm charts
  oci2gdsd-daemon/             # Daemonset chart
platform/
  local/                       # Local CLI integration harness (no GPU required)
    scripts/
  host/                        # Host direct-GDS integration harness
    scripts/
  k3s/                         # k3s integration harness + runtime assets
    scripts/
    shared/
    pytorch/
    tensorrt/
    vllm/
```

---

## Key design invariants

Before changing core behavior, understand these constraints:

1. **`ensure` is idempotent** — same `model-id + manifest-digest` must be safe to call
   concurrently from multiple callers. Per-model file locks in `internal/app/lock.go`
   enforce this. Don't bypass them.

2. **READY is the read contract boundary** — consumers may only read shards after READY
   exists. It must be written last, after all shards and metadata are verified.

3. **Digest-pinned refs only** — `ensure` rejects any ref without `@sha256:`. This is
   intentional. Don't add tag-based resolution.

4. **GC only touches zero-lease models** — the `lru_no_lease` policy must never delete
   a model with active leases. Verify this in any GC-adjacent change.

5. **Root boundary enforcement** — all destructive filesystem operations (delete, rename)
   must go through `fsutil.EnsureUnderRoot` or `fsutil.SafeJoinUnderRoot`. This prevents
   path traversal attacks.

---

## Adding a new CLI command

1. Add the flag definition and dispatch in `internal/cli/cli.go`.
2. Implement the logic in the appropriate `internal/app/` file.
3. Add a corresponding entry to `docs/cli-reference.md`.
4. Add at least one test in `internal/app/`.

---

## Adding a new config field

1. Add the field to the struct in `internal/config/config.go`.
2. Set a safe default in `DefaultConfig()`.
3. Add a validation rule in `Validate()` if applicable.
4. Document it in `docs/config-reference.md` with a status label:
   - `active` — read and used
   - `validation-only` — checked but not used at runtime
   - `reserved` — accepted but currently no-op
5. Add a `# RESERVED: not yet implemented` comment in `models/profiles/oci2gdsd.yaml`.

---

## Pull requests

- Keep changes focused: one logical change per PR.
- Run `go test ./...` and `go vet ./...` before opening.
- Update `docs/` for any user-visible behavior change.
- Update `docs/IMPLEMENTATION-NOTES.md` if you implement a previously "not yet" feature.
- No need to update `CHANGELOG` — commit messages serve that purpose.

---

## Where to start

Good first areas:

- `internal/app/*_test.go` — add test coverage for edge cases
- `docs/` — improve examples, fix unclear explanations
- `internal/config/config.go` — wire a `reserved` field to actual runtime behavior
- `internal/registry/oras.go` — improve retry logic or add mirror failover

See `docs/IMPLEMENTATION-NOTES.md` for the current list of "not yet implemented" features.
