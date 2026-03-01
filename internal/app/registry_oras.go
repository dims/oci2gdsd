package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	ocispec "github.com/opencontainers/image-spec/specs-go/v1"
	"oras.land/oras-go/v2/registry/remote"
	"oras.land/oras-go/v2/registry/remote/auth"
	"oras.land/oras-go/v2/registry/remote/credentials"
	"oras.land/oras-go/v2/registry/remote/retry"
)

type RemoteBlob struct {
	Name      string
	Digest    string
	Size      int64
	MediaType string
	Open      func(ctx context.Context) (io.ReadCloser, error)
}

type FetchedModel struct {
	Reference      string
	Repository     string
	ManifestDigest string
	ArtifactType   string
	Profile        *ModelProfile
	Layers         []ManifestLayer
	Blobs          []RemoteBlob
}

type ModelFetcher interface {
	Fetch(ctx context.Context, ref string) (*FetchedModel, error)
}

type ORASModelFetcher struct {
	cfg Config
}

func NewORASModelFetcher(cfg Config) *ORASModelFetcher {
	return &ORASModelFetcher{cfg: cfg}
}

func (f *ORASModelFetcher) Fetch(ctx context.Context, ref string) (*FetchedModel, error) {
	repository, manifestDigest, err := ParseDigestPinnedRef(ref)
	if err != nil {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "invalid --ref", err)
	}

	repo, err := remote.NewRepository(repository)
	if err != nil {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "invalid repository", err)
	}
	repo.PlainHTTP = f.cfg.Registry.PlainHTTP
	client, err := f.buildAuthClient()
	if err != nil {
		return nil, err
	}
	repo.Client = client

	manifestDesc, err := repo.Resolve(ctx, manifestDigest)
	if err != nil {
		return nil, wrapRegistryError("failed to resolve manifest", err)
	}
	manifestRC, err := repo.Fetch(ctx, manifestDesc)
	if err != nil {
		return nil, wrapRegistryError("failed to fetch manifest", err)
	}
	defer manifestRC.Close()
	manifestBytes, err := io.ReadAll(manifestRC)
	if err != nil {
		return nil, wrapRegistryError("failed to read manifest", err)
	}

	manifest := ocispec.Manifest{}
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		return nil, NewAppError(ExitValidation, ReasonValidationFailed, "manifest is not valid JSON", err)
	}

	configRC, err := repo.Fetch(ctx, manifest.Config)
	if err != nil {
		return nil, wrapRegistryError("failed to fetch model config", err)
	}
	defer configRC.Close()
	configBytes, err := io.ReadAll(configRC)
	if err != nil {
		return nil, wrapRegistryError("failed to read model config", err)
	}

	profile := &ModelProfile{}
	if err := json.Unmarshal(configBytes, profile); err != nil {
		return nil, NewAppError(ExitValidation, ReasonProfileLintFailed, "model config is not valid OCI-ModelProfile-v1 JSON", err)
	}

	layerMap := map[string]ocispec.Descriptor{}
	layers := make([]ManifestLayer, 0, len(manifest.Layers))
	for _, layer := range manifest.Layers {
		layerMap[layer.Digest.String()] = layer
		layers = append(layers, ManifestLayer{
			MediaType:   layer.MediaType,
			Digest:      layer.Digest.String(),
			Size:        layer.Size,
			Annotations: layer.Annotations,
		})
	}

	sorted := SortShardsByOrdinal(profile.Shards)
	blobs := make([]RemoteBlob, 0, len(sorted))
	for _, shard := range sorted {
		desc, ok := layerMap[shard.Digest]
		if !ok {
			return nil, NewAppError(ExitIntegrity, ReasonBlobNotFound, fmt.Sprintf("shard digest %s not found in manifest layers", shard.Digest), nil)
		}
		name := strings.TrimSpace(shard.Name)
		if name == "" && desc.Annotations != nil {
			name = desc.Annotations["org.opencontainers.image.title"]
		}
		if name == "" {
			name = fmt.Sprintf("shard-%04d", shard.Ordinal)
		}
		descriptor := desc
		blobs = append(blobs, RemoteBlob{
			Name:      name,
			Digest:    descriptor.Digest.String(),
			Size:      descriptor.Size,
			MediaType: descriptor.MediaType,
			Open: func(ctx context.Context) (io.ReadCloser, error) {
				rc, fetchErr := repo.Fetch(ctx, descriptor)
				if fetchErr != nil {
					return nil, wrapRegistryError("failed to fetch blob", fetchErr)
				}
				return rc, nil
			},
		})
	}

	return &FetchedModel{
		Reference:      ref,
		Repository:     repository,
		ManifestDigest: manifestDigest,
		ArtifactType:   manifest.ArtifactType,
		Profile:        profile,
		Layers:         layers,
		Blobs:          blobs,
	}, nil
}

func (f *ORASModelFetcher) buildAuthClient() (*auth.Client, error) {
	timeout := f.cfg.TimeoutOrDefault(0)
	transport := &http.Transport{
		MaxIdleConns:          f.cfg.Download.MaxIdleConns,
		MaxIdleConnsPerHost:   f.cfg.Download.MaxIdleConnsPerHost,
		MaxConnsPerHost:       f.cfg.Download.MaxConnsPerHost,
		ResponseHeaderTimeout: time.Duration(f.cfg.Download.ResponseHeaderTimeoutSec) * time.Second,
		ForceAttemptHTTP2:     true,
	}
	retryTransport := retry.NewTransport(transport)
	retryTransport.Policy = func() retry.Policy {
		minWait := time.Duration(f.cfg.Download.Retry.MinBackoffMS) * time.Millisecond
		maxWait := time.Duration(f.cfg.Download.Retry.MaxBackoffMS) * time.Millisecond
		if minWait <= 0 {
			minWait = 30 * time.Millisecond
		}
		if maxWait <= 0 {
			maxWait = 300 * time.Second
		}
		return &retry.GenericPolicy{
			Retryable: retry.DefaultPredicate,
			Backoff:   retry.ExponentialBackoff(250*time.Millisecond, 2, 0.1),
			MinWait:   minWait,
			MaxWait:   maxWait,
			MaxRetry:  f.cfg.Download.Retry.MaxRetries,
		}
	}
	httpClient := &http.Client{
		Transport: retryTransport,
		Timeout:   timeout,
	}

	authClient := &auth.Client{
		Client: httpClient,
		Cache:  auth.NewCache(),
	}

	store, err := credentials.NewStoreFromDocker(credentials.StoreOptions{})
	if err != nil {
		path := f.cfg.EffectiveDockerConfig()
		if path != "" {
			fileStore, fileErr := credentials.NewStore(path, credentials.StoreOptions{})
			if fileErr == nil {
				authClient.Credential = credentials.Credential(fileStore)
				return authClient, nil
			}
		}
		return authClient, nil
	}
	authClient.Credential = credentials.Credential(store)
	return authClient, nil
}

func wrapRegistryError(message string, err error) error {
	if err == nil {
		return nil
	}
	lower := strings.ToLower(err.Error())
	switch {
	case strings.Contains(lower, "unauthorized"), strings.Contains(lower, "authentication"), strings.Contains(lower, "denied"):
		return NewAppError(ExitAuth, ReasonRegistryAuthFailed, message, err)
	case strings.Contains(lower, "timeout"), strings.Contains(lower, "deadline exceeded"):
		return NewAppError(ExitRegistry, ReasonRegistryTimeout, message, err)
	case strings.Contains(lower, "not found"), strings.Contains(lower, "manifest unknown"):
		return NewAppError(ExitRegistry, ReasonManifestNotFound, message, err)
	case strings.Contains(lower, "blob unknown"):
		return NewAppError(ExitRegistry, ReasonBlobNotFound, message, err)
	default:
		return NewAppError(ExitRegistry, ReasonRegistryUnreachable, message, err)
	}
}
