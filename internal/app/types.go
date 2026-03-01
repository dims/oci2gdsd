package app

import (
	"errors"
	"fmt"
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

type ReasonCode string

const (
	ReasonNone                    ReasonCode = ""
	ReasonRegistryAuthFailed      ReasonCode = "REGISTRY_AUTH_FAILED"
	ReasonRegistryUnreachable     ReasonCode = "REGISTRY_UNREACHABLE"
	ReasonRegistryTimeout         ReasonCode = "REGISTRY_TIMEOUT"
	ReasonManifestNotFound        ReasonCode = "MANIFEST_NOT_FOUND"
	ReasonBlobNotFound            ReasonCode = "BLOB_NOT_FOUND"
	ReasonBlobSizeMismatch        ReasonCode = "BLOB_SIZE_MISMATCH"
	ReasonBlobDigestMismatch      ReasonCode = "BLOB_DIGEST_MISMATCH"
	ReasonSignaturePolicyFailed   ReasonCode = "SIGNATURE_POLICY_FAILED"
	ReasonDiskSpaceInsufficient   ReasonCode = "DISK_SPACE_INSUFFICIENT"
	ReasonPublishRenameFailed     ReasonCode = "PUBLISH_ATOMIC_RENAME_FAILED"
	ReasonLeaseConflict           ReasonCode = "LEASE_CONFLICT"
	ReasonStateDBCorrupt          ReasonCode = "STATE_DB_CORRUPT"
	ReasonDirectPathIneligible    ReasonCode = "DIRECT_PATH_INELIGIBLE"
	ReasonValidationFailed        ReasonCode = "VALIDATION_FAILED"
	ReasonProfileLintFailed       ReasonCode = "PROFILE_LINT_FAILED"
	ReasonFilesystemError         ReasonCode = "FILESYSTEM_ERROR"
	ReasonInternalError           ReasonCode = "INTERNAL_ERROR"
	ReasonPolicyRejected          ReasonCode = "POLICY_REJECTED"
	ReasonRegistryDownloadFailure ReasonCode = "REGISTRY_DOWNLOAD_FAILURE"
)

const (
	ExitSuccess      = 0
	ExitValidation   = 2
	ExitAuth         = 3
	ExitRegistry     = 4
	ExitIntegrity    = 5
	ExitFilesystem   = 6
	ExitPolicy       = 7
	ExitStateCorrupt = 8
)

type AppError struct {
	ExitCode int
	Reason   ReasonCode
	Message  string
	Err      error
}

func (e *AppError) Error() string {
	if e.Err == nil {
		return e.Message
	}
	if e.Message == "" {
		return e.Err.Error()
	}
	return fmt.Sprintf("%s: %v", e.Message, e.Err)
}

func (e *AppError) Unwrap() error {
	return e.Err
}

func NewAppError(exitCode int, reason ReasonCode, message string, err error) *AppError {
	return &AppError{
		ExitCode: exitCode,
		Reason:   reason,
		Message:  message,
		Err:      err,
	}
}

func AsAppError(err error) *AppError {
	if err == nil {
		return nil
	}
	var appErr *AppError
	if errors.As(err, &appErr) {
		return appErr
	}
	return &AppError{
		ExitCode: ExitStateCorrupt,
		Reason:   ReasonInternalError,
		Message:  err.Error(),
		Err:      err,
	}
}

func mapReasonToExitCode(reason ReasonCode) int {
	switch reason {
	case ReasonRegistryAuthFailed:
		return ExitAuth
	case ReasonRegistryUnreachable, ReasonRegistryTimeout, ReasonManifestNotFound, ReasonBlobNotFound, ReasonRegistryDownloadFailure:
		return ExitRegistry
	case ReasonBlobDigestMismatch, ReasonBlobSizeMismatch, ReasonSignaturePolicyFailed:
		return ExitIntegrity
	case ReasonDiskSpaceInsufficient, ReasonPublishRenameFailed, ReasonFilesystemError:
		return ExitFilesystem
	case ReasonPolicyRejected, ReasonDirectPathIneligible:
		return ExitPolicy
	case ReasonStateDBCorrupt:
		return ExitStateCorrupt
	case ReasonValidationFailed, ReasonProfileLintFailed:
		return ExitValidation
	default:
		return ExitStateCorrupt
	}
}
