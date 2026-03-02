package app

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	digest "github.com/opencontainers/go-digest"
)

func modelKey(modelID, manifestDigest string) string {
	return modelID + "@" + manifestDigest
}

func digestToPathComponent(d string) string {
	return strings.ReplaceAll(d, ":", "-")
}

func modelRootPath(base, modelID, manifestDigest string) string {
	return filepath.Join(base, modelID, digestToPathComponent(manifestDigest))
}

func readyMarkerPath(path string) string {
	return filepath.Join(path, "READY")
}

func metadataPath(path string) string {
	return filepath.Join(path, "metadata", "model.json")
}

func shardPath(path, name string) string {
	return filepath.Join(path, "shards", name)
}

func ValidateShardName(name string) error {
	n := strings.TrimSpace(name)
	if n == "" {
		return errors.New("shard name is empty")
	}
	if n == "." || n == ".." {
		return fmt.Errorf("shard name %q is not allowed", name)
	}
	if filepath.IsAbs(n) {
		return fmt.Errorf("shard name %q must not be absolute", name)
	}
	if filepath.Base(n) != n {
		return fmt.Errorf("shard name %q must be a single path component", name)
	}
	if strings.ContainsAny(n, `/\`) {
		return fmt.Errorf("shard name %q contains path separators", name)
	}
	return nil
}

func tmpTxnPath(tmpRoot, modelID, manifestDigest string) string {
	token := shortToken(modelID + ":" + manifestDigest + ":" + time.Now().UTC().Format(time.RFC3339Nano))
	return filepath.Join(tmpRoot, modelID, digestToPathComponent(manifestDigest), token)
}

func shortToken(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:8])
}

func ParseDigestPinnedRef(ref string) (repository string, manifestDigest string, err error) {
	parts := strings.Split(ref, "@")
	if len(parts) != 2 {
		return "", "", fmt.Errorf("reference must be digest pinned (repo@sha256:...), got %q", ref)
	}
	repository = strings.TrimSpace(parts[0])
	manifestDigest = strings.TrimSpace(parts[1])
	if repository == "" {
		return "", "", errors.New("empty repository in ref")
	}
	d, err := digest.Parse(manifestDigest)
	if err != nil {
		return "", "", err
	}
	if d.Algorithm() != digest.SHA256 {
		return "", "", fmt.Errorf("unsupported digest algorithm %s", d.Algorithm())
	}
	return repository, manifestDigest, nil
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

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func diskFreeBytes(path string) (int64, error) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err != nil {
		return 0, err
	}
	return int64(stat.Bavail) * int64(stat.Bsize), nil
}

func fsyncFile(path string) error {
	f, err := os.OpenFile(path, os.O_RDONLY, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

func fsyncDir(path string) error {
	d, err := os.Open(path)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func writeAtomicFile(path string, data []byte, perm os.FileMode, fsync bool) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	if fsync {
		if err := fsyncFile(tmp); err != nil {
			return err
		}
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	if fsync {
		return fsyncDir(dir)
	}
	return nil
}
