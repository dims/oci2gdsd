package config

import (
	"strings"
	"testing"
)

func TestReservedFieldWarnings(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Registry.Retries++
	cfg.Observability.MetricsEnabled = !cfg.Observability.MetricsEnabled

	warnings := cfg.ReservedFieldWarnings()
	if len(warnings) == 0 {
		t.Fatalf("expected reserved-field warnings")
	}
	joined := strings.Join(warnings, "\n")
	if !strings.Contains(joined, "registry.retries") {
		t.Fatalf("expected registry.retries warning, got: %s", joined)
	}
	if !strings.Contains(joined, "observability.metrics_enabled") {
		t.Fatalf("expected observability.metrics_enabled warning, got: %s", joined)
	}
}

func TestValidateRejectsInvalidModelIDAllowlistRegex(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Security.ModelIDAllowlistRegex = "["
	if err := cfg.Validate(); err == nil {
		t.Fatalf("expected invalid regex validation error")
	}
}
