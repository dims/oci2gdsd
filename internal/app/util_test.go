package app

import (
	"os"
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
	root := filepath.Join(t.TempDir(), "models")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatalf("mkdir root: %v", err)
	}
	okPath := filepath.Join(root, "demo", "sha256-abc")
	if err := ensurePathWithinRoot(root, okPath); err != nil {
		t.Fatalf("expected in-root path to pass, got %v", err)
	}
	outside := filepath.Join(t.TempDir(), "outside")
	if err := ensurePathWithinRoot(root, outside); err == nil {
		t.Fatalf("expected out-of-root path to fail")
	}
}

func TestEnsureUnderRootRejectsSymlinkEscape(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "root")
	outside := filepath.Join(base, "outside")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatalf("mkdir root: %v", err)
	}
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatalf("mkdir outside: %v", err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	escaped := filepath.Join(link, "payload")
	if err := EnsureUnderRoot(root, escaped); err == nil {
		t.Fatalf("expected symlink escape to fail")
	}
}

func TestSafeJoinUnderRootRejectsEscape(t *testing.T) {
	root := filepath.Join(t.TempDir(), "models")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatalf("mkdir root: %v", err)
	}
	if _, err := SafeJoinUnderRoot(root, "..", "escape"); err == nil {
		t.Fatalf("expected SafeJoinUnderRoot to reject escaping join")
	}
}
