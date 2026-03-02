package app

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type LockManager struct {
	root string
}

func NewLockManager(root string) *LockManager {
	return &LockManager{root: root}
}

func (m *LockManager) Acquire(ctx context.Context, key string, wait bool) (unlock func(), pending bool, err error) {
	if err := os.MkdirAll(m.root, 0o755); err != nil {
		return nil, false, NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to create lock directory", err)
	}
	safeName := strings.NewReplacer("/", "_", "@", "_", ":", "_").Replace(key) + ".lock"
	path := filepath.Join(m.root, safeName)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, false, NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to open model lock", err)
	}

	tryLock := func() error {
		return syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	}

	if !wait {
		if err := tryLock(); err != nil {
			_ = f.Close()
			if isLockBusy(err) {
				return nil, true, nil
			}
			return nil, false, NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to acquire lock", err)
		}
		return func() {
			_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
			_ = f.Close()
		}, false, nil
	}

	for {
		if err := tryLock(); err == nil {
			return func() {
				_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
				_ = f.Close()
			}, false, nil
		} else if !isLockBusy(err) {
			_ = f.Close()
			return nil, false, NewAppError(ExitFilesystem, ReasonFilesystemError, "failed to acquire lock", err)
		}
		select {
		case <-ctx.Done():
			_ = f.Close()
			waitErr := ctx.Err()
			message := "model lock wait canceled"
			if errors.Is(waitErr, context.DeadlineExceeded) {
				message = "timed out waiting for model lock"
			}
			return nil, false, NewAppError(ExitPolicy, ReasonLeaseConflict, message, waitErr)
		case <-time.After(200 * time.Millisecond):
		}
	}
}

func isLockBusy(err error) bool {
	return errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN)
}

func transitionState(current, next ModelState) error {
	valid := map[ModelState][]ModelState{
		StateNew:         {StateResolving},
		StateResolving:   {StateDownloading, StateFailed},
		StateDownloading: {StateVerifying, StateFailed},
		StateVerifying:   {StatePublishing, StateFailed},
		StatePublishing:  {StateReady, StateFailed},
		StateReady:       {StateReleasing},
		StateReleasing:   {StateReady, StateReleased},
		StateFailed:      {StateResolving, StateReleased},
	}
	allowed, ok := valid[current]
	if !ok {
		return fmt.Errorf("invalid current state %s", current)
	}
	for _, candidate := range allowed {
		if candidate == next {
			return nil
		}
	}
	return fmt.Errorf("invalid transition %s -> %s", current, next)
}
