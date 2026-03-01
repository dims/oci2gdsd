package app

import (
	"github.com/dims/oci2gdsd/internal/apperr"
	"github.com/dims/oci2gdsd/internal/model"
)

type ModelState = model.ModelState

const (
	StateNew         = model.StateNew
	StateResolving   = model.StateResolving
	StateDownloading = model.StateDownloading
	StateVerifying   = model.StateVerifying
	StatePublishing  = model.StatePublishing
	StateReady       = model.StateReady
	StateFailed      = model.StateFailed
	StateReleasing   = model.StateReleasing
	StateReleased    = model.StateReleased
)

type ReasonCode = apperr.ReasonCode

const (
	ReasonNone                    = apperr.ReasonNone
	ReasonRegistryAuthFailed      = apperr.ReasonRegistryAuthFailed
	ReasonRegistryUnreachable     = apperr.ReasonRegistryUnreachable
	ReasonRegistryTimeout         = apperr.ReasonRegistryTimeout
	ReasonManifestNotFound        = apperr.ReasonManifestNotFound
	ReasonBlobNotFound            = apperr.ReasonBlobNotFound
	ReasonBlobSizeMismatch        = apperr.ReasonBlobSizeMismatch
	ReasonBlobDigestMismatch      = apperr.ReasonBlobDigestMismatch
	ReasonSignaturePolicyFailed   = apperr.ReasonSignaturePolicyFailed
	ReasonDiskSpaceInsufficient   = apperr.ReasonDiskSpaceInsufficient
	ReasonPublishRenameFailed     = apperr.ReasonPublishRenameFailed
	ReasonLeaseConflict           = apperr.ReasonLeaseConflict
	ReasonStateDBCorrupt          = apperr.ReasonStateDBCorrupt
	ReasonDirectPathIneligible    = apperr.ReasonDirectPathIneligible
	ReasonValidationFailed        = apperr.ReasonValidationFailed
	ReasonProfileLintFailed       = apperr.ReasonProfileLintFailed
	ReasonFilesystemError         = apperr.ReasonFilesystemError
	ReasonInternalError           = apperr.ReasonInternalError
	ReasonPolicyRejected          = apperr.ReasonPolicyRejected
	ReasonRegistryDownloadFailure = apperr.ReasonRegistryDownloadFailure
)

const (
	ExitSuccess      = apperr.ExitSuccess
	ExitValidation   = apperr.ExitValidation
	ExitAuth         = apperr.ExitAuth
	ExitRegistry     = apperr.ExitRegistry
	ExitIntegrity    = apperr.ExitIntegrity
	ExitFilesystem   = apperr.ExitFilesystem
	ExitPolicy       = apperr.ExitPolicy
	ExitStateCorrupt = apperr.ExitStateCorrupt
)

type AppError = apperr.AppError

func NewAppError(exitCode int, reason ReasonCode, message string, err error) *AppError {
	return apperr.NewAppError(exitCode, reason, message, err)
}

func AsAppError(err error) *AppError {
	return apperr.AsAppError(err)
}

func mapReasonToExitCode(reason ReasonCode) int {
	return apperr.MapReasonToExitCode(reason)
}
