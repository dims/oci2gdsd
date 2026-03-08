package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/dims/oci2gdsd/internal/apperr"
	"gopkg.in/yaml.v3"
)

type Config struct {
	Root       string `yaml:"root" json:"root"`
	ModelRoot  string `yaml:"model_root" json:"model_root"`
	TmpRoot    string `yaml:"tmp_root" json:"tmp_root"`
	LocksRoot  string `yaml:"locks_root" json:"locks_root"`
	JournalDir string `yaml:"journal_dir" json:"journal_dir"`
	StateDB    string `yaml:"state_db" json:"state_db"`
	LogLevel   string `yaml:"log_level" json:"log_level"`

	Registry      RegistryConfig      `yaml:"registry" json:"registry"`
	Transfer      TransferConfig      `yaml:"transfer" json:"transfer"`
	Download      DownloadConfig      `yaml:"download" json:"download"`
	Integrity     IntegrityConfig     `yaml:"integrity" json:"integrity"`
	Publish       PublishConfig       `yaml:"publish" json:"publish"`
	Retention     RetentionConfig     `yaml:"retention" json:"retention"`
	Runtime       RuntimeConfig       `yaml:"runtime" json:"runtime"`
	Observability ObservabilityConfig `yaml:"observability" json:"observability"`
	Security      SecurityConfig      `yaml:"security" json:"security"`
}

type RegistryConfig struct {
	TimeoutSeconds        int               `yaml:"timeout_seconds" json:"timeout_seconds"`
	RequestTimeoutSeconds int               `yaml:"request_timeout_seconds" json:"request_timeout_seconds"`
	Retries               int               `yaml:"retries" json:"retries"`
	BackoffInitialMS      int               `yaml:"backoff_initial_ms" json:"backoff_initial_ms"`
	BackoffMaxMS          int               `yaml:"backoff_max_ms" json:"backoff_max_ms"`
	Mirrors               []string          `yaml:"mirrors" json:"mirrors"`
	Auth                  RegistryAuth      `yaml:"auth" json:"auth"`
	PlainHTTP             bool              `yaml:"plain_http" json:"plain_http"`
	Headers               map[string]string `yaml:"headers" json:"headers"`
}

type RegistryAuth struct {
	Mode             string `yaml:"mode" json:"mode"`
	DockerConfigPath string `yaml:"docker_config_path" json:"docker_config_path"`
}

type TransferConfig struct {
	MaxModelsConcurrent         int `yaml:"max_models_concurrent" json:"max_models_concurrent"`
	MaxShardsConcurrentPerModel int `yaml:"max_shards_concurrent_per_model" json:"max_shards_concurrent_per_model"`
	MaxConnectionsPerRegistry   int `yaml:"max_connections_per_registry" json:"max_connections_per_registry"`
	StreamBufferBytes           int `yaml:"stream_buffer_bytes" json:"stream_buffer_bytes"`
	MaxResumeAttempts           int `yaml:"max_resume_attempts" json:"max_resume_attempts"`
}

type DownloadConfig struct {
	MaxConcurrentRequestsGlobal   int                 `yaml:"max_concurrent_requests_global" json:"max_concurrent_requests_global"`
	MaxConcurrentRequestsPerModel int                 `yaml:"max_concurrent_requests_per_model" json:"max_concurrent_requests_per_model"`
	MaxConcurrentChunksPerBlob    int                 `yaml:"max_concurrent_chunks_per_blob" json:"max_concurrent_chunks_per_blob"`
	ChunkSizeBytes                int64               `yaml:"chunk_size_bytes" json:"chunk_size_bytes"`
	MaxIdleConns                  int                 `yaml:"max_idle_conns" json:"max_idle_conns"`
	MaxIdleConnsPerHost           int                 `yaml:"max_idle_conns_per_host" json:"max_idle_conns_per_host"`
	MaxConnsPerHost               int                 `yaml:"max_conns_per_host" json:"max_conns_per_host"`
	RequestTimeoutSec             int                 `yaml:"request_timeout_sec" json:"request_timeout_sec"`
	ResponseHeaderTimeoutSec      int                 `yaml:"response_header_timeout_sec" json:"response_header_timeout_sec"`
	Retry                         DownloadRetryConfig `yaml:"retry" json:"retry"`
}

type DownloadRetryConfig struct {
	MaxRetries   int  `yaml:"max_retries" json:"max_retries"`
	MinBackoffMS int  `yaml:"min_backoff_ms" json:"min_backoff_ms"`
	MaxBackoffMS int  `yaml:"max_backoff_ms" json:"max_backoff_ms"`
	Jitter       bool `yaml:"jitter" json:"jitter"`
}

type IntegrityConfig struct {
	StrictDigest       bool `yaml:"strict_digest" json:"strict_digest"`
	StrictSignature    bool `yaml:"strict_signature" json:"strict_signature"`
	AllowUnsignedInDev bool `yaml:"allow_unsigned_in_dev" json:"allow_unsigned_in_dev"`
}

type PublishConfig struct {
	RequireReadyMarker bool `yaml:"require_ready_marker" json:"require_ready_marker"`
	FsyncFiles         bool `yaml:"fsync_files" json:"fsync_files"`
	FsyncDirectory     bool `yaml:"fsync_directory" json:"fsync_directory"`
	AtomicPublish      bool `yaml:"atomic_publish" json:"atomic_publish"`
	DenyPartialReads   bool `yaml:"deny_partial_reads" json:"deny_partial_reads"`
}

type RetentionConfig struct {
	Policy                string `yaml:"policy" json:"policy"`
	MinFreeBytes          int64  `yaml:"min_free_bytes" json:"min_free_bytes"`
	MaxModels             int    `yaml:"max_models" json:"max_models"`
	TTLHours              int    `yaml:"ttl_hours" json:"ttl_hours"`
	EmergencyLowSpaceMode bool   `yaml:"emergency_low_space_mode" json:"emergency_low_space_mode"`
}

type RuntimeConfig struct {
	MaxConcurrentPersistentLoadsPerDevice int `yaml:"max_concurrent_persistent_loads_per_device" json:"max_concurrent_persistent_loads_per_device"`
	MaxConcurrentAttachmentsPerDevice     int `yaml:"max_concurrent_attachments_per_device" json:"max_concurrent_attachments_per_device"`
	MaxRuntimeBundleTokens                int `yaml:"max_runtime_bundle_tokens" json:"max_runtime_bundle_tokens"`
	MaxTensorMapCacheEntries              int `yaml:"max_tensor_map_cache_entries" json:"max_tensor_map_cache_entries"`
}

type ObservabilityConfig struct {
	MetricsEnabled bool   `yaml:"metrics_enabled" json:"metrics_enabled"`
	MetricsListen  string `yaml:"metrics_listen" json:"metrics_listen"`
	EventsJSONLog  bool   `yaml:"events_json_log" json:"events_json_log"`
}

type SecurityConfig struct {
	ModelIDAllowlistRegex string `yaml:"model_id_allowlist_regex" json:"model_id_allowlist_regex"`
}

func DefaultConfig() Config {
	root := "/var/lib/oci2gdsd"
	return Config{
		Root:       root,
		ModelRoot:  filepath.Join(root, "models"),
		TmpRoot:    filepath.Join(root, "tmp"),
		LocksRoot:  filepath.Join(root, "locks"),
		JournalDir: filepath.Join(root, "journal"),
		StateDB:    filepath.Join(root, "state.db"),
		LogLevel:   "info",
		Registry: RegistryConfig{
			TimeoutSeconds:        30,
			RequestTimeoutSeconds: 30,
			Retries:               5,
			BackoffInitialMS:      250,
			BackoffMaxMS:          8000,
			Auth: RegistryAuth{
				Mode: "docker-config",
			},
		},
		Transfer: TransferConfig{
			MaxModelsConcurrent:         2,
			MaxShardsConcurrentPerModel: 4,
			MaxConnectionsPerRegistry:   16,
			StreamBufferBytes:           4 * 1024 * 1024,
			MaxResumeAttempts:           2,
		},
		Download: DownloadConfig{
			MaxConcurrentRequestsGlobal:   64,
			MaxConcurrentRequestsPerModel: 12,
			MaxConcurrentChunksPerBlob:    6,
			ChunkSizeBytes:                16 * 1024 * 1024,
			MaxIdleConns:                  256,
			MaxIdleConnsPerHost:           128,
			MaxConnsPerHost:               128,
			RequestTimeoutSec:             300,
			ResponseHeaderTimeoutSec:      5,
			Retry: DownloadRetryConfig{
				MaxRetries:   8,
				MinBackoffMS: 30,
				MaxBackoffMS: 300000,
				Jitter:       true,
			},
		},
		Integrity: IntegrityConfig{
			StrictDigest:       true,
			StrictSignature:    true,
			AllowUnsignedInDev: false,
		},
		Publish: PublishConfig{
			RequireReadyMarker: true,
			FsyncFiles:         true,
			FsyncDirectory:     true,
			AtomicPublish:      true,
			DenyPartialReads:   true,
		},
		Retention: RetentionConfig{
			Policy:                "lru_no_lease",
			MinFreeBytes:          200 * 1024 * 1024 * 1024,
			MaxModels:             16,
			TTLHours:              168,
			EmergencyLowSpaceMode: true,
		},
		Runtime: RuntimeConfig{
			MaxConcurrentPersistentLoadsPerDevice: 1,
			MaxConcurrentAttachmentsPerDevice:     8,
			MaxRuntimeBundleTokens:                1024,
			MaxTensorMapCacheEntries:              128,
		},
		Observability: ObservabilityConfig{
			MetricsEnabled: true,
			MetricsListen:  "127.0.0.1:9098",
			EventsJSONLog:  true,
		},
		Security: SecurityConfig{
			ModelIDAllowlistRegex: "",
		},
	}
}

func LoadConfig(path string) (Config, error) {
	cfg := DefaultConfig()
	if path == "" {
		return cfg, cfg.Validate()
	}

	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "failed to read config", err)
	}
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		return Config{}, apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "failed to parse config", err)
	}
	if err := cfg.Validate(); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func (c *Config) ApplyGlobalOverrides(root string, targetRoot string, logLevel string) {
	if root != "" {
		c.Root = root
		if c.ModelRoot == "" || c.ModelRoot == filepath.Join("/var/lib/oci2gdsd", "models") {
			c.ModelRoot = filepath.Join(root, "models")
		}
		if c.TmpRoot == "" || c.TmpRoot == filepath.Join("/var/lib/oci2gdsd", "tmp") {
			c.TmpRoot = filepath.Join(root, "tmp")
		}
		if c.LocksRoot == "" || c.LocksRoot == filepath.Join("/var/lib/oci2gdsd", "locks") {
			c.LocksRoot = filepath.Join(root, "locks")
		}
		if c.JournalDir == "" || c.JournalDir == filepath.Join("/var/lib/oci2gdsd", "journal") {
			c.JournalDir = filepath.Join(root, "journal")
		}
		if c.StateDB == "" || c.StateDB == filepath.Join("/var/lib/oci2gdsd", "state.db") {
			c.StateDB = filepath.Join(root, "state.db")
		}
	}
	if targetRoot != "" {
		c.ModelRoot = targetRoot
	}
	if logLevel != "" {
		c.LogLevel = logLevel
	}
}

func (c Config) Validate() error {
	if c.Root == "" {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "root must not be empty", nil)
	}
	if !filepath.IsAbs(c.Root) {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "root must be an absolute path", nil)
	}
	if c.ModelRoot == "" {
		c.ModelRoot = filepath.Join(c.Root, "models")
	}
	if !filepath.IsAbs(c.ModelRoot) {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "model_root must be an absolute path", nil)
	}
	if c.TmpRoot == "" {
		c.TmpRoot = filepath.Join(c.Root, "tmp")
	}
	if !filepath.IsAbs(c.TmpRoot) {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "tmp_root must be an absolute path", nil)
	}
	if c.LocksRoot == "" {
		c.LocksRoot = filepath.Join(c.Root, "locks")
	}
	if !filepath.IsAbs(c.LocksRoot) {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "locks_root must be an absolute path", nil)
	}
	if c.JournalDir == "" {
		c.JournalDir = filepath.Join(c.Root, "journal")
	}
	if !filepath.IsAbs(c.JournalDir) {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "journal_dir must be an absolute path", nil)
	}
	if c.StateDB == "" {
		c.StateDB = filepath.Join(c.Root, "state.db")
	}
	if !filepath.IsAbs(c.StateDB) {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "state_db must be an absolute path", nil)
	}
	if c.Transfer.MaxShardsConcurrentPerModel <= 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "transfer.max_shards_concurrent_per_model must be > 0", nil)
	}
	if c.Transfer.StreamBufferBytes <= 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "transfer.stream_buffer_bytes must be > 0", nil)
	}
	if c.Download.MaxConcurrentRequestsGlobal <= 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "download.max_concurrent_requests_global must be > 0", nil)
	}
	if c.Download.MaxConcurrentRequestsPerModel <= 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "download.max_concurrent_requests_per_model must be > 0", nil)
	}
	if c.Download.MaxConcurrentChunksPerBlob <= 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "download.max_concurrent_chunks_per_blob must be > 0", nil)
	}
	if c.Download.ChunkSizeBytes <= 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "download.chunk_size_bytes must be > 0", nil)
	}
	if c.Retention.MinFreeBytes < 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "retention.min_free_bytes must be >= 0", nil)
	}
	if c.Runtime.MaxConcurrentPersistentLoadsPerDevice <= 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "runtime.max_concurrent_persistent_loads_per_device must be > 0", nil)
	}
	if c.Runtime.MaxConcurrentAttachmentsPerDevice <= 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "runtime.max_concurrent_attachments_per_device must be > 0", nil)
	}
	if c.Runtime.MaxRuntimeBundleTokens <= 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "runtime.max_runtime_bundle_tokens must be > 0", nil)
	}
	if c.Runtime.MaxTensorMapCacheEntries <= 0 {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "runtime.max_tensor_map_cache_entries must be > 0", nil)
	}
	if c.Integrity.StrictSignature && c.Integrity.AllowUnsignedInDev {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "integrity.strict_signature and allow_unsigned_in_dev cannot both be true", nil)
	}
	if c.Registry.Auth.DockerConfigPath != "" && !filepath.IsAbs(c.Registry.Auth.DockerConfigPath) {
		return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "registry.auth.docker_config_path must be absolute", nil)
	}
	if c.Security.ModelIDAllowlistRegex != "" {
		if _, err := regexp.Compile(c.Security.ModelIDAllowlistRegex); err != nil {
			return apperr.NewAppError(apperr.ExitValidation, apperr.ReasonValidationFailed, "security.model_id_allowlist_regex is not a valid regex", err)
		}
	}
	return nil
}

func (c Config) EnsureDirectories() error {
	dirs := []string{
		c.Root,
		c.ModelRoot,
		c.TmpRoot,
		c.LocksRoot,
		c.JournalDir,
	}
	for _, d := range dirs {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return apperr.NewAppError(apperr.ExitFilesystem, apperr.ReasonFilesystemError, fmt.Sprintf("failed to create directory %s", d), err)
		}
	}
	return nil
}

func (c Config) TimeoutOrDefault(d time.Duration) time.Duration {
	if d > 0 {
		return d
	}
	timeoutSeconds := c.Registry.RequestTimeoutSeconds
	if timeoutSeconds <= 0 {
		timeoutSeconds = c.Registry.TimeoutSeconds
	}
	if timeoutSeconds <= 0 {
		timeoutSeconds = 30
	}
	return time.Duration(timeoutSeconds) * time.Second
}

func (c Config) EffectiveDockerConfig() string {
	if c.Registry.Auth.DockerConfigPath != "" {
		return c.Registry.Auth.DockerConfigPath
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, ".docker", "config.json")
	}
	return ""
}

func (c Config) ReservedFieldWarnings() []string {
	def := DefaultConfig()
	warnings := make([]string, 0)
	add := func(ok bool, msg string) {
		if ok {
			warnings = append(warnings, msg)
		}
	}

	add(c.LogLevel != def.LogLevel, "log_level is reserved and does not currently change runtime logging behavior")
	add(c.Registry.Retries != def.Registry.Retries, "registry.retries is reserved and not used by current retry policy")
	add(c.Registry.BackoffInitialMS != def.Registry.BackoffInitialMS, "registry.backoff_initial_ms is reserved and not used by current retry policy")
	add(c.Registry.BackoffMaxMS != def.Registry.BackoffMaxMS, "registry.backoff_max_ms is reserved and not used by current retry policy")
	add(len(c.Registry.Mirrors) > 0, "registry.mirrors is reserved and not implemented")
	add(len(c.Registry.Headers) > 0, "registry.headers is reserved and not implemented")
	add(c.Registry.Auth.Mode != "" && c.Registry.Auth.Mode != def.Registry.Auth.Mode, "registry.auth.mode is reserved and not implemented")

	add(c.Transfer.MaxModelsConcurrent != def.Transfer.MaxModelsConcurrent, "transfer.max_models_concurrent is reserved and not used")
	add(c.Transfer.MaxShardsConcurrentPerModel != def.Transfer.MaxShardsConcurrentPerModel, "transfer.max_shards_concurrent_per_model is validation-only in current implementation")
	add(c.Transfer.MaxConnectionsPerRegistry != def.Transfer.MaxConnectionsPerRegistry, "transfer.max_connections_per_registry is reserved and not used")
	add(c.Transfer.MaxResumeAttempts != def.Transfer.MaxResumeAttempts, "transfer.max_resume_attempts is reserved and not used")

	add(c.Download.RequestTimeoutSec != def.Download.RequestTimeoutSec, "download.request_timeout_sec is reserved and not used")
	add(c.Download.Retry.Jitter != def.Download.Retry.Jitter, "download.retry.jitter is reserved and not used")

	add(c.Integrity.StrictDigest != def.Integrity.StrictDigest, "integrity.strict_digest is reserved and not used as a runtime toggle")
	add(c.Integrity.StrictSignature != def.Integrity.StrictSignature, "integrity.strict_signature is validation-only in current implementation")
	add(c.Integrity.AllowUnsignedInDev != def.Integrity.AllowUnsignedInDev, "integrity.allow_unsigned_in_dev is validation-only in current implementation")

	add(c.Publish.RequireReadyMarker != def.Publish.RequireReadyMarker, "publish.require_ready_marker is reserved (READY marker is always enforced)")
	add(c.Publish.AtomicPublish != def.Publish.AtomicPublish, "publish.atomic_publish is reserved (atomic publish is always enforced)")
	add(c.Publish.DenyPartialReads != def.Publish.DenyPartialReads, "publish.deny_partial_reads is reserved and not used")

	add(c.Retention.MaxModels != def.Retention.MaxModels, "retention.max_models is reserved and not used")
	add(c.Retention.TTLHours != def.Retention.TTLHours, "retention.ttl_hours is reserved and not used")
	add(c.Retention.EmergencyLowSpaceMode != def.Retention.EmergencyLowSpaceMode, "retention.emergency_low_space_mode is reserved and not used")

	add(c.Observability.MetricsEnabled != def.Observability.MetricsEnabled, "observability.metrics_enabled is reserved and not used")
	add(c.Observability.MetricsListen != def.Observability.MetricsListen, "observability.metrics_listen is reserved and not used")
	add(c.Observability.EventsJSONLog != def.Observability.EventsJSONLog, "observability.events_json_log is reserved and not used")

	return warnings
}

func ParseByteSize(input string) (int64, error) {
	s := strings.TrimSpace(strings.ToUpper(input))
	if s == "" {
		return 0, errors.New("empty size")
	}
	type unit struct {
		suffix string
		mul    int64
	}
	units := []unit{
		{"TIB", 1024 * 1024 * 1024 * 1024},
		{"GIB", 1024 * 1024 * 1024},
		{"MIB", 1024 * 1024},
		{"KIB", 1024},
		{"TB", 1000 * 1000 * 1000 * 1000},
		{"GB", 1000 * 1000 * 1000},
		{"MB", 1000 * 1000},
		{"KB", 1000},
		{"TI", 1024 * 1024 * 1024 * 1024},
		{"GI", 1024 * 1024 * 1024},
		{"MI", 1024 * 1024},
		{"KI", 1024},
		{"T", 1000 * 1000 * 1000 * 1000},
		{"G", 1000 * 1000 * 1000},
		{"M", 1000 * 1000},
		{"K", 1000},
		{"B", 1},
	}
	for _, u := range units {
		suffix := u.suffix
		if strings.HasSuffix(s, suffix) {
			num := strings.TrimSpace(strings.TrimSuffix(s, suffix))
			v, err := strconv.ParseFloat(num, 64)
			if err != nil {
				return 0, err
			}
			return int64(v * float64(u.mul)), nil
		}
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, err
	}
	return v, nil
}

func parseMinFreeBytesOrDefault(flagValue string, fallback int64) (int64, error) {
	if flagValue == "" {
		return fallback, nil
	}
	n, err := ParseByteSize(flagValue)
	if err != nil {
		return 0, errors.New("invalid --min-free-bytes")
	}
	return n, nil
}

func ParseMinFreeBytesOrDefault(flagValue string, fallback int64) (int64, error) {
	return parseMinFreeBytesOrDefault(flagValue, fallback)
}
