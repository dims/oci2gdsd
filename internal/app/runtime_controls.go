package app

import (
	"context"
	"strings"
)

func (s *Service) CacheMetricsSnapshot() CacheMetrics {
	s.cacheMetricsMu.Lock()
	defer s.cacheMetricsMu.Unlock()
	return s.cacheMetrics
}

func (s *Service) addRuntimeBundleHit() {
	s.cacheMetricsMu.Lock()
	s.cacheMetrics.RuntimeBundleHits++
	s.cacheMetricsMu.Unlock()
}

func (s *Service) addRuntimeBundleMiss() {
	s.cacheMetricsMu.Lock()
	s.cacheMetrics.RuntimeBundleMisses++
	s.cacheMetricsMu.Unlock()
}

func (s *Service) addRuntimeBundleEvictions(n int) {
	if n <= 0 {
		return
	}
	s.cacheMetricsMu.Lock()
	s.cacheMetrics.RuntimeBundleEvictions += uint64(n)
	s.cacheMetricsMu.Unlock()
}

func (s *Service) addTensorMapHit() {
	s.cacheMetricsMu.Lock()
	s.cacheMetrics.TensorMapHits++
	s.cacheMetricsMu.Unlock()
}

func (s *Service) addTensorMapMiss() {
	s.cacheMetricsMu.Lock()
	s.cacheMetrics.TensorMapMisses++
	s.cacheMetricsMu.Unlock()
}

func (s *Service) addTensorMapEvictions(n int) {
	if n <= 0 {
		return
	}
	s.cacheMetricsMu.Lock()
	s.cacheMetrics.TensorMapEvictions += uint64(n)
	s.cacheMetricsMu.Unlock()
}

func (s *Service) runtimeBundleTokenLimit() int {
	limit := s.cfg.Runtime.MaxRuntimeBundleTokens
	if limit <= 0 {
		return 1024
	}
	return limit
}

func (s *Service) tensorMapCacheLimit() int {
	limit := s.cfg.Runtime.MaxTensorMapCacheEntries
	if limit <= 0 {
		return 128
	}
	return limit
}

func (s *Service) acquireDevicePersistentLoadSlot(ctx context.Context, deviceUUID string) (func(), error) {
	limit := s.cfg.Runtime.MaxConcurrentPersistentLoadsPerDevice
	if limit <= 0 {
		limit = 1
	}
	return s.acquireDeviceSlot(ctx, "load", strings.TrimSpace(deviceUUID), limit)
}

func (s *Service) acquireDeviceAttachSlot(ctx context.Context, deviceUUID string) (func(), error) {
	limit := s.cfg.Runtime.MaxConcurrentAttachmentsPerDevice
	if limit <= 0 {
		limit = 8
	}
	return s.acquireDeviceSlot(ctx, "attach", strings.TrimSpace(deviceUUID), limit)
}

func (s *Service) acquireDeviceSlot(ctx context.Context, class, deviceUUID string, limit int) (func(), error) {
	if strings.TrimSpace(deviceUUID) == "" {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "device uuid is required for concurrency limit", nil)
	}
	if limit <= 0 {
		limit = 1
	}

	s.deviceLimitMu.Lock()
	var sem chan struct{}
	switch class {
	case "load":
		if s.loadSlotsByDevice == nil {
			s.loadSlotsByDevice = map[string]chan struct{}{}
		}
		sem = s.loadSlotsByDevice[deviceUUID]
		if sem == nil {
			sem = make(chan struct{}, limit)
			s.loadSlotsByDevice[deviceUUID] = sem
		}
	case "attach":
		if s.attachSlotsByDevice == nil {
			s.attachSlotsByDevice = map[string]chan struct{}{}
		}
		sem = s.attachSlotsByDevice[deviceUUID]
		if sem == nil {
			sem = make(chan struct{}, limit)
			s.attachSlotsByDevice[deviceUUID] = sem
		}
	default:
		s.deviceLimitMu.Unlock()
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "invalid concurrency limiter class", nil)
	}
	s.deviceLimitMu.Unlock()

	select {
	case sem <- struct{}{}:
		return func() {
			select {
			case <-sem:
			default:
			}
		}, nil
	case <-ctx.Done():
		return nil, NewAppError(ExitRegistry, ReasonRegistryTimeout, "context canceled before acquiring per-device concurrency slot", ctx.Err())
	}
}
