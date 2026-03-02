package fsutil

import (
	"os"
	"path/filepath"
)

func FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func FsyncFile(path string) error {
	f, err := os.OpenFile(path, os.O_RDONLY, 0)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

func FsyncDir(path string) error {
	d, err := os.Open(path)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}

func WriteAtomicFile(path string, data []byte, perm os.FileMode, fsync bool) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	if fsync {
		if err := FsyncFile(tmp); err != nil {
			return err
		}
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	if fsync {
		return FsyncDir(dir)
	}
	return nil
}
