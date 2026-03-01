package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"syscall"
	"time"
)

type Lease struct {
	Holder     string    `json:"holder"`
	AcquiredAt time.Time `json:"acquired_at"`
}

type ModelRecord struct {
	Key              string     `json:"key"`
	ModelID          string     `json:"model_id"`
	ManifestDigest   string     `json:"manifest_digest"`
	Status           ModelState `json:"status"`
	Path             string     `json:"path"`
	Bytes            int64      `json:"bytes"`
	Leases           []Lease    `json:"leases"`
	Releasable       bool       `json:"releasable"`
	ReleasableAt     *time.Time `json:"releasable_at,omitempty"`
	LastError        ReasonCode `json:"last_error"`
	LastErrorMessage string     `json:"last_error_message"`
	CreatedAt        time.Time  `json:"created_at"`
	UpdatedAt        time.Time  `json:"updated_at"`
	LastAccessedAt   time.Time  `json:"last_accessed_at"`
}

type stateDB struct {
	Version int                     `json:"version"`
	Models  map[string]*ModelRecord `json:"models"`
}

type StateStore struct {
	path     string
	lockPath string
}

func NewStateStore(path string) *StateStore {
	return &StateStore{
		path:     path,
		lockPath: path + ".lock",
	}
}

func (s *StateStore) Init() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to create state db directory", err)
	}
	if !fileExists(s.path) {
		seed := stateDB{
			Version: 1,
			Models:  map[string]*ModelRecord{},
		}
		b, err := json.MarshalIndent(seed, "", "  ")
		if err != nil {
			return NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "failed to initialize state db", err)
		}
		if err := writeAtomicFile(s.path, b, 0o644, true); err != nil {
			return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to write state db", err)
		}
	}
	lockFile, err := os.OpenFile(s.lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to initialize state lock", err)
	}
	return lockFile.Close()
}

func (s *StateStore) WithLockedDB(fn func(db *stateDB) error) error {
	lockFile, err := os.OpenFile(s.lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to open state lock", err)
	}
	defer lockFile.Close()

	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to lock state db", err)
	}
	defer syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)

	db, err := s.load()
	if err != nil {
		return err
	}
	if err := fn(db); err != nil {
		return err
	}
	if err := s.save(db); err != nil {
		return err
	}
	return nil
}

func (s *StateStore) load() (*stateDB, error) {
	b, err := os.ReadFile(s.path)
	if err != nil {
		return nil, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "failed to read state db", err)
	}
	db := &stateDB{}
	if len(b) == 0 {
		db.Version = 1
		db.Models = map[string]*ModelRecord{}
		return db, nil
	}
	if err := json.Unmarshal(b, db); err != nil {
		return nil, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "failed to parse state db", err)
	}
	if db.Models == nil {
		db.Models = map[string]*ModelRecord{}
	}
	if db.Version == 0 {
		db.Version = 1
	}
	return db, nil
}

func (s *StateStore) save(db *stateDB) error {
	b, err := json.MarshalIndent(db, "", "  ")
	if err != nil {
		return NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "failed to marshal state db", err)
	}
	if err := writeAtomicFile(s.path, b, 0o644, true); err != nil {
		return NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to write state db", err)
	}
	return nil
}

func (s *StateStore) Get(key string) (*ModelRecord, bool, error) {
	var out *ModelRecord
	err := s.WithLockedDB(func(db *stateDB) error {
		rec, ok := db.Models[key]
		if !ok {
			return nil
		}
		cp := *rec
		cp.Leases = append([]Lease(nil), rec.Leases...)
		out = &cp
		return nil
	})
	if err != nil {
		return nil, false, err
	}
	if out == nil {
		return nil, false, nil
	}
	return out, true, nil
}

func (s *StateStore) Put(rec *ModelRecord) error {
	if rec == nil {
		return errors.New("nil model record")
	}
	return s.WithLockedDB(func(db *stateDB) error {
		now := time.Now().UTC()
		if rec.CreatedAt.IsZero() {
			rec.CreatedAt = now
		}
		rec.UpdatedAt = now
		if rec.LastAccessedAt.IsZero() {
			rec.LastAccessedAt = now
		}
		cp := *rec
		cp.Leases = append([]Lease(nil), rec.Leases...)
		db.Models[rec.Key] = &cp
		return nil
	})
}

func (s *StateStore) Delete(key string) error {
	return s.WithLockedDB(func(db *stateDB) error {
		delete(db.Models, key)
		return nil
	})
}

func (s *StateStore) List() ([]ModelRecord, error) {
	records := make([]ModelRecord, 0)
	err := s.WithLockedDB(func(db *stateDB) error {
		for _, rec := range db.Models {
			cp := *rec
			cp.Leases = append([]Lease(nil), rec.Leases...)
			records = append(records, cp)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	sort.Slice(records, func(i, j int) bool {
		if records[i].ModelID == records[j].ModelID {
			return records[i].ManifestDigest < records[j].ManifestDigest
		}
		return records[i].ModelID < records[j].ModelID
	})
	return records, nil
}

func (s *StateStore) UpsertWithLock(key string, fn func(rec *ModelRecord) error) error {
	return s.WithLockedDB(func(db *stateDB) error {
		rec, ok := db.Models[key]
		if !ok {
			return fmt.Errorf("record %s not found", key)
		}
		if err := fn(rec); err != nil {
			return err
		}
		rec.UpdatedAt = time.Now().UTC()
		return nil
	})
}

func (r *ModelRecord) AcquireLease(holder string) {
	if holder == "" {
		return
	}
	for _, l := range r.Leases {
		if l.Holder == holder {
			r.LastAccessedAt = time.Now().UTC()
			return
		}
	}
	r.Leases = append(r.Leases, Lease{
		Holder:     holder,
		AcquiredAt: time.Now().UTC(),
	})
	r.Releasable = false
	r.ReleasableAt = nil
	r.LastAccessedAt = time.Now().UTC()
}

func (r *ModelRecord) ReleaseLease(holder string) int {
	if holder == "" {
		return len(r.Leases)
	}
	next := make([]Lease, 0, len(r.Leases))
	for _, l := range r.Leases {
		if l.Holder == holder {
			continue
		}
		next = append(next, l)
	}
	r.Leases = next
	r.LastAccessedAt = time.Now().UTC()
	return len(r.Leases)
}
