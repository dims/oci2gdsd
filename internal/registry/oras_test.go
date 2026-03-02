package registry

import (
	"bytes"
	"errors"
	"testing"
)

func TestReadAllWithLimit(t *testing.T) {
	in := []byte("hello-world")
	out, err := readAllWithLimit(bytes.NewReader(in), int64(len(in)))
	if err != nil {
		t.Fatalf("readAllWithLimit error: %v", err)
	}
	if string(out) != string(in) {
		t.Fatalf("unexpected content: got %q want %q", string(out), string(in))
	}
}

func TestReadAllWithLimitExceeded(t *testing.T) {
	_, err := readAllWithLimit(bytes.NewReader([]byte("0123456789")), 4)
	if !errors.Is(err, errReadLimitExceeded) {
		t.Fatalf("expected errReadLimitExceeded, got %v", err)
	}
}
