package app

import (
	"encoding/binary"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeSafeTensorsTestFile(t *testing.T, path string, header map[string]any, data []byte) {
	t.Helper()
	hb, err := json.Marshal(header)
	if err != nil {
		t.Fatalf("marshal header: %v", err)
	}
	buf := make([]byte, 8+len(hb)+len(data))
	binary.LittleEndian.PutUint64(buf[:8], uint64(len(hb)))
	copy(buf[8:8+len(hb)], hb)
	copy(buf[8+len(hb):], data)
	if err := os.WriteFile(path, buf, 0o644); err != nil {
		t.Fatalf("write safetensors test file: %v", err)
	}
}

func TestParseSafeTensorsShard(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "model-00001-of-00001.safetensors")
	header := map[string]any{
		"weight": map[string]any{
			"dtype":        "F32",
			"shape":        []int{2},
			"data_offsets": []int{0, 8},
		},
		"__metadata__": map[string]any{"format": "pt"},
	}
	writeSafeTensorsTestFile(t, path, header, []byte{1, 2, 3, 4, 5, 6, 7, 8})

	shard := ModelShard{
		Name:    filepath.Base(path),
		Digest:  "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		Size:    8,
		Ordinal: 1,
	}
	got, err := parseSafeTensorsShard(path, shard)
	if err != nil {
		t.Fatalf("parseSafeTensorsShard: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("tensor count=%d want=1", len(got))
	}
	if got[0].Name != "weight" {
		t.Fatalf("tensor name=%q want=weight", got[0].Name)
	}
	if got[0].ByteLength != 8 {
		t.Fatalf("tensor byte length=%d want=8", got[0].ByteLength)
	}
	if got[0].ByteOffset <= 8 {
		t.Fatalf("tensor byte offset=%d want>8", got[0].ByteOffset)
	}
	if got[0].ShardName != shard.Name {
		t.Fatalf("shard name=%q want=%q", got[0].ShardName, shard.Name)
	}
}

func TestParseSafeTensorsShardRejectsInvalidOffsets(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "bad.safetensors")
	header := map[string]any{
		"weight": map[string]any{
			"dtype":        "F16",
			"shape":        []int{2},
			"data_offsets": []int{0, 9000},
		},
	}
	writeSafeTensorsTestFile(t, path, header, []byte{1, 2, 3, 4, 5, 6, 7, 8})

	shard := ModelShard{
		Name:    filepath.Base(path),
		Digest:  "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		Size:    8,
		Ordinal: 1,
	}
	if _, err := parseSafeTensorsShard(path, shard); err == nil {
		t.Fatalf("expected parseSafeTensorsShard to fail on invalid offsets")
	}
}
