{
  "schemaVersion": 1,
  "modelId": "demo",
  "manifestDigest": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
  "profile": {
    "schemaVersion": 1,
    "modelId": "demo",
    "modelRevision": "r1",
    "framework": "pytorch",
    "format": "safetensors",
    "shards": [
      {"name": "weights-00001.safetensors", "digest": "sha256:__W_DIGEST__", "size": __W_SIZE__, "ordinal": 1, "kind": "weight"},
      {"name": "config.json", "digest": "sha256:__R_DIGEST__", "size": __R_SIZE__, "ordinal": 2, "kind": "runtime"}
    ],
    "integrity": {"manifestDigest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}
  }
}
