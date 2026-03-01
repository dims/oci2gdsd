package app

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const (
	JournalTxnStarted      = "TXN_STARTED"
	JournalBlobsWritten    = "TXN_BLOBS_WRITTEN"
	JournalBlobsVerified   = "TXN_BLOBS_VERIFIED"
	JournalMetadataWritten = "TXN_METADATA_WRITTEN"
	JournalReadyWritten    = "TXN_READY_WRITTEN"
	JournalCommitted       = "TXN_COMMITTED"
)

type Journal struct {
	path string
}

func NewJournal(baseDir, modelID, manifestDigest string) *Journal {
	name := strings.NewReplacer("/", "_", "@", "_", ":", "_").Replace(modelKey(modelID, manifestDigest))
	return &Journal{
		path: filepath.Join(baseDir, name+".journal"),
	}
}

func (j *Journal) Append(marker string) error {
	if err := os.MkdirAll(filepath.Dir(j.path), 0o755); err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to create journal directory", err)
	}
	f, err := os.OpenFile(j.path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to open journal", err)
	}
	defer f.Close()
	if _, err := fmt.Fprintf(f, "%s %s\n", time.Now().UTC().Format(time.RFC3339Nano), marker); err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to write journal", err)
	}
	if err := f.Sync(); err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to fsync journal", err)
	}
	return nil
}

func (j *Journal) Markers() (map[string]bool, error) {
	markers := map[string]bool{}
	if !fileExists(j.path) {
		return markers, nil
	}
	f, err := os.Open(j.path)
	if err != nil {
		return nil, NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to read journal", err)
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.Fields(line)
		if len(parts) < 2 {
			continue
		}
		markers[parts[1]] = true
	}
	if err := scanner.Err(); err != nil {
		return nil, NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to scan journal", err)
	}
	return markers, nil
}

func (j *Journal) Path() string {
	return j.path
}
