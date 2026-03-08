package app

import (
	"fmt"
	"strings"
	"time"
)

func (s *Service) nextRuntimeBundleToken(allocationID string) string {
	s.bundleSeq++
	return fmt.Sprintf("rb_%s_%d", shortToken(allocationID+":"+time.Now().UTC().Format(time.RFC3339Nano)), s.bundleSeq)
}

func (s *Service) issueRuntimeBundleToken(allocationID string, includeWeights bool) (string, time.Time) {
	s.bundleMu.Lock()
	defer s.bundleMu.Unlock()
	now := time.Now().UTC()
	s.cleanupExpiredRuntimeBundleTokensLocked(now)
	token := s.nextRuntimeBundleToken(allocationID)
	expiresAt := now.Add(s.bundleTTL)
	rec := &runtimeBundleAccessToken{
		Token:          token,
		AllocationID:   allocationID,
		IncludeWeights: includeWeights,
		CreatedAt:      now,
		ExpiresAt:      expiresAt,
	}
	if s.bundleMap == nil {
		s.bundleMap = map[string]*runtimeBundleAccessToken{}
	}
	if s.bundleByAllocation == nil {
		s.bundleByAllocation = map[string]map[string]struct{}{}
	}
	s.bundleMap[token] = rec
	set := s.bundleByAllocation[allocationID]
	if set == nil {
		set = map[string]struct{}{}
		s.bundleByAllocation[allocationID] = set
	}
	set[token] = struct{}{}
	return token, expiresAt
}

func (s *Service) resolveRuntimeBundleToken(token string) (string, bool, error) {
	token = strings.TrimSpace(token)
	if token == "" {
		return "", false, NewAppError(ExitValidation, ReasonValidationFailed, "runtime bundle token is required", nil)
	}
	s.bundleMu.Lock()
	defer s.bundleMu.Unlock()
	now := time.Now().UTC()
	s.cleanupExpiredRuntimeBundleTokensLocked(now)
	rec, ok := s.bundleMap[token]
	if !ok || rec == nil {
		return "", false, NewAppError(ExitValidation, ReasonValidationFailed, "runtime bundle token not found", nil)
	}
	if !rec.ExpiresAt.IsZero() && now.After(rec.ExpiresAt) {
		s.deleteRuntimeBundleTokenLocked(token, rec.AllocationID)
		return "", false, NewAppError(ExitValidation, ReasonValidationFailed, "runtime bundle token expired", nil)
	}
	return rec.AllocationID, rec.IncludeWeights, nil
}

func (s *Service) revokeRuntimeBundleTokensForAllocation(allocationID string) {
	allocationID = strings.TrimSpace(allocationID)
	if allocationID == "" {
		return
	}
	s.bundleMu.Lock()
	defer s.bundleMu.Unlock()
	if s.bundleByAllocation == nil {
		return
	}
	set := s.bundleByAllocation[allocationID]
	if len(set) == 0 {
		delete(s.bundleByAllocation, allocationID)
		return
	}
	for token := range set {
		delete(s.bundleMap, token)
	}
	delete(s.bundleByAllocation, allocationID)
}

func (s *Service) cleanupExpiredRuntimeBundleTokensLocked(now time.Time) {
	if s.bundleMap == nil {
		return
	}
	for token, rec := range s.bundleMap {
		if rec == nil {
			delete(s.bundleMap, token)
			continue
		}
		if !rec.ExpiresAt.IsZero() && now.After(rec.ExpiresAt) {
			s.deleteRuntimeBundleTokenLocked(token, rec.AllocationID)
		}
	}
}

func (s *Service) deleteRuntimeBundleTokenLocked(token, allocationID string) {
	delete(s.bundleMap, token)
	if s.bundleByAllocation == nil {
		return
	}
	set := s.bundleByAllocation[allocationID]
	if set == nil {
		return
	}
	delete(set, token)
	if len(set) == 0 {
		delete(s.bundleByAllocation, allocationID)
	}
}
