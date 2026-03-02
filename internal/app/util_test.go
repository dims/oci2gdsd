package app

import (
	"path/filepath"
	"testing"
)

func TestParseByteSize(t *testing.T) {
	tests := []struct {
		in   string
		want int64
	}{
		{"200G", 200 * 1000 * 1000 * 1000},
		{"16MiB", 16 * 1024 * 1024},
		{"1024", 1024},
		{"1tb", 1000 * 1000 * 1000 * 1000},
		{"1.5GB", int64(1.5 * 1000 * 1000 * 1000)},
		{"2GiB", 2 * 1024 * 1024 * 1024},
	}
	for _, tt := range tests {
		got, err := ParseByteSize(tt.in)
		if err != nil {
			t.Fatalf("ParseByteSize(%q) error: %v", tt.in, err)
		}
		if got != tt.want {
			t.Fatalf("ParseByteSize(%q)=%d want=%d", tt.in, got, tt.want)
		}
	}
}

func TestParseByteSizeError(t *testing.T) {
	if _, err := ParseByteSize("nope"); err == nil {
		t.Fatalf("expected parse error")
	}
}

func TestValidateShardName(t *testing.T) {
	valid := []string{
		"model-00001-of-00002.safetensors",
		"weights.bin",
		"part_01",
	}
	for _, name := range valid {
		if err := ValidateShardName(name); err != nil {
			t.Fatalf("expected valid shard name %q, got error: %v", name, err)
		}
	}

	invalid := []string{
		"",
		".",
		"..",
		"../escape",
		"dir/file",
		`dir\file`,
		"/abs/path",
	}
	for _, name := range invalid {
		if err := ValidateShardName(name); err == nil {
			t.Fatalf("expected invalid shard name %q", name)
		}
	}
}

func TestValidateModelID(t *testing.T) {
	valid := []string{
		"demo-model",
		"qwen3-0.6b",
		"model_01",
	}
	for _, id := range valid {
		if err := ValidateModelID(id); err != nil {
			t.Fatalf("expected valid model id %q, got error: %v", id, err)
		}
	}

	invalid := []string{
		"",
		".",
		"..",
		"../escape",
		"dir/file",
		`dir\file`,
		"/abs/path",
	}
	for _, id := range invalid {
		if err := ValidateModelID(id); err == nil {
			t.Fatalf("expected invalid model id %q", id)
		}
	}
}

func TestEnsurePathWithinRoot(t *testing.T) {
	root := filepath.Join("/tmp", "oci2gdsd", "models")
	okPath := filepath.Join(root, "demo", "sha256-abc")
	if err := ensurePathWithinRoot(root, okPath); err != nil {
		t.Fatalf("expected in-root path to pass, got %v", err)
	}
	outside := filepath.Join("/tmp", "oci2gdsd", "other")
	if err := ensurePathWithinRoot(root, outside); err == nil {
		t.Fatalf("expected out-of-root path to fail")
	}
}
