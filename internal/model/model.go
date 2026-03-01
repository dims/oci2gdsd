package model

import (
	"time"

	"github.com/dims/oci2gdsd/internal/apperr"
)

type ModelState string

const (
	StateNew         ModelState = "NEW"
	StateResolving   ModelState = "RESOLVING"
	StateDownloading ModelState = "DOWNLOADING"
	StateVerifying   ModelState = "VERIFYING"
	StatePublishing  ModelState = "PUBLISHING"
	StateReady       ModelState = "READY"
	StateFailed      ModelState = "FAILED"
	StateReleasing   ModelState = "RELEASING"
	StateReleased    ModelState = "RELEASED"
)

func (s ModelState) ExternalStatus() string {
	switch s {
	case StateReady:
		return "READY"
	case StateFailed:
		return "FAILED"
	case StateReleasing:
		return "RELEASING"
	case StateReleased:
		return "RELEASED"
	default:
		return "PENDING"
	}
}

type Lease struct {
	Holder     string    `json:"holder"`
	AcquiredAt time.Time `json:"acquired_at"`
}

type ModelRecord struct {
	Key              string            `json:"key"`
	ModelID          string            `json:"model_id"`
	ManifestDigest   string            `json:"manifest_digest"`
	Status           ModelState        `json:"status"`
	Path             string            `json:"path"`
	Bytes            int64             `json:"bytes"`
	Leases           []Lease           `json:"leases"`
	Releasable       bool              `json:"releasable"`
	ReleasableAt     *time.Time        `json:"releasable_at,omitempty"`
	LastError        apperr.ReasonCode `json:"last_error"`
	LastErrorMessage string            `json:"last_error_message"`
	CreatedAt        time.Time         `json:"created_at"`
	UpdatedAt        time.Time         `json:"updated_at"`
	LastAccessedAt   time.Time         `json:"last_accessed_at"`
}
