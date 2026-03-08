# Security Hardening Checklist (Implementation-Level)

This checklist tracks hardening controls that are implemented in the current codebase.
It is intentionally implementation-scoped (no backlog-only items).

## 1. Immediate hardening

- [x] `ValidateModelID` enforced on service entrypoints.
  - `ensure`, `status`, `release`, `verify`
  - `gpu load` when model-id + digest path is used
- [x] Canonical root-boundary validation before destructive deletes.
  - `release --cleanup`
  - `gc` delete path
  - stale tmp cleanup in `Recover()`
- [x] Canonical root-boundary validation before publish rename target.
  - final publish destination checked under `model_root`
  - staging source checked under `tmp_root`
- [x] Symlink-aware root enforcement.
  - root and candidate paths are resolved through symlinks
  - missing target paths are resolved via nearest existing parent symlink chain
  - escape outside configured root is rejected

## 2. Medium-term hardening now implemented

- [x] Optional model ID allowlist regex.
  - config: `security.model_id_allowlist_regex`
  - model id must satisfy both structural validation and regex (when configured)
  - invalid regex fails config validation on startup

## 3. Defensive coding improvements now implemented

- [x] Shared path helpers for root-safe operations.
  - `EnsureUnderRoot(root, path)`
  - `SafeJoinUnderRoot(root, components...)`
- [x] Destructive call sites use root-safe checks at execution time.
  - `os.RemoveAll` call paths routed through root-safe helper
- [x] Root-safe join used for computed publish and transaction paths.
  - final model path construction
  - temporary transaction path construction
- [x] Symlink escape tests added.
  - util-level tests for path helpers
  - service-level tests for GC symlink escape rejection

## 4. Notes

- This file tracks only committed implementation behavior.
- Potential future controls (for example audit-event streams and transaction correlation IDs) should be tracked in a separate roadmap/backlog document, not here.
