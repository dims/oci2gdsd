package app

import (
	"context"
	"testing"
	"time"
)

func TestAcquireWaitTimeoutReturnsTypedAppError(t *testing.T) {
	locks := NewLockManager(t.TempDir())
	key := "demo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

	unlock, pending, err := locks.Acquire(context.Background(), key, false)
	if err != nil {
		t.Fatalf("failed to acquire initial lock: %v", err)
	}
	if pending {
		t.Fatalf("expected initial lock acquisition, got pending")
	}
	defer unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	_, pending, err = locks.Acquire(ctx, key, true)
	if err == nil {
		t.Fatalf("expected timeout lock error")
	}
	if pending {
		t.Fatalf("pending must be false on wait=true timeout path")
	}
	appErr := AsAppError(err)
	if appErr.Reason != ReasonLeaseConflict {
		t.Fatalf("expected reason %s, got %s", ReasonLeaseConflict, appErr.Reason)
	}
	if appErr.ExitCode != ExitPolicy {
		t.Fatalf("expected exit code %d, got %d", ExitPolicy, appErr.ExitCode)
	}
}
