package app

import "testing"

func TestParseByteSize(t *testing.T) {
	tests := []struct {
		in   string
		want int64
	}{
		{"200G", 200 * 1024 * 1024 * 1024},
		{"16MiB", 16 * 1024 * 1024},
		{"1024", 1024},
		{"1tb", 1024 * 1024 * 1024 * 1024},
		{"1.5GB", int64(1.5 * 1024 * 1024 * 1024)},
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
