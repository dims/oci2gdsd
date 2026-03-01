package app

import (
	"context"
	"io"
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
