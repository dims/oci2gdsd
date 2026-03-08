package app

import (
	"context"
	"fmt"
	"strings"
)

func (s *Service) fetchModelByRefDigest(ctx context.Context, ref, manifestDigest string) (*FetchedModel, error) {
	ref = strings.TrimSpace(ref)
	digestValue := strings.TrimSpace(manifestDigest)
	if ref == "" || digestValue == "" {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "ref and digest are required for ensure fetch dedupe", nil)
	}
	sfKey := fmt.Sprintf("%s|%s", ref, digestValue)
	ch := s.ensureFetchGroup.DoChan(sfKey, func() (any, error) {
		timeout := s.cfg.TimeoutOrDefault(0)
		fetchCtx := context.Background()
		if timeout > 0 {
			var cancel context.CancelFunc
			fetchCtx, cancel = context.WithTimeout(fetchCtx, timeout)
			defer cancel()
		}
		return s.fetcher.Fetch(fetchCtx, ref)
	})
	select {
	case <-ctx.Done():
		return nil, NewAppError(ExitRegistry, ReasonRegistryTimeout, "context canceled while waiting for ensure singleflight fetch", ctx.Err())
	case res := <-ch:
		if res.Err != nil {
			return nil, res.Err
		}
		model, ok := res.Val.(*FetchedModel)
		if !ok || model == nil {
			return nil, NewAppError(ExitStateCorrupt, ReasonStateDBCorrupt, "ensure singleflight fetch returned invalid model payload", nil)
		}
		return model, nil
	}
}
