package app

import cfg "github.com/dims/oci2gdsd/internal/config"

type Config = cfg.Config
type RegistryConfig = cfg.RegistryConfig
type RegistryAuth = cfg.RegistryAuth
type TransferConfig = cfg.TransferConfig
type DownloadConfig = cfg.DownloadConfig
type DownloadRetryConfig = cfg.DownloadRetryConfig
type IntegrityConfig = cfg.IntegrityConfig
type PublishConfig = cfg.PublishConfig
type RetentionConfig = cfg.RetentionConfig
type ObservabilityConfig = cfg.ObservabilityConfig

func DefaultConfig() Config {
	return cfg.DefaultConfig()
}

func LoadConfig(path string) (Config, error) {
	return cfg.LoadConfig(path)
}

func ParseMinFreeBytesOrDefault(flagValue string, fallback int64) (int64, error) {
	return cfg.ParseMinFreeBytesOrDefault(flagValue, fallback)
}
