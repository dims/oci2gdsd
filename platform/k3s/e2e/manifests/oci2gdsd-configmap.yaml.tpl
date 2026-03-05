apiVersion: v1
kind: ConfigMap
metadata:
  name: oci2gdsd-config
  namespace: __E2E_NAMESPACE__
data:
  config.yaml: |
    root: __OCI2GDSD_ROOT_PATH__
    model_root: __OCI2GDSD_ROOT_PATH__/models
    tmp_root: __OCI2GDSD_ROOT_PATH__/tmp
    locks_root: __OCI2GDSD_ROOT_PATH__/locks
    journal_dir: __OCI2GDSD_ROOT_PATH__/journal
    state_db: __OCI2GDSD_ROOT_PATH__/state.db
    registry:
      plain_http: true
      request_timeout_seconds: 600
      timeout_seconds: 600
      retries: 6
    transfer:
      max_models_concurrent: 2
      max_shards_concurrent_per_model: 8
      max_connections_per_registry: 32
      stream_buffer_bytes: 4194304
      max_resume_attempts: 2
    download:
      max_concurrent_requests_global: 128
      max_concurrent_requests_per_model: 16
      max_concurrent_chunks_per_blob: 8
      chunk_size_bytes: 16777216
      max_idle_conns: 256
      max_idle_conns_per_host: 128
      max_conns_per_host: 128
      request_timeout_sec: 600
      response_header_timeout_sec: 10
      retry:
        max_retries: 8
        min_backoff_ms: 50
        max_backoff_ms: 60000
        jitter: true
    integrity:
      strict_digest: true
      strict_signature: false
      allow_unsigned_in_dev: true
    publish:
      require_ready_marker: true
      fsync_files: false
      fsync_directory: false
      atomic_publish: true
      deny_partial_reads: true
    retention:
      policy: lru_no_lease
      min_free_bytes: 0
      max_models: 64
      ttl_hours: 168
      emergency_low_space_mode: true
    observability:
      metrics_enabled: false
      events_json_log: true
