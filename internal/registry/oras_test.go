package registry

import (
	"bytes"
	"context"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/dims/oci2gdsd/internal/app"
	"oras.land/oras-go/v2/registry/remote/errcode"
)

func TestReadAllWithLimit(t *testing.T) {
	in := []byte("hello-world")
	out, err := readAllWithLimit(bytes.NewReader(in), int64(len(in)))
	if err != nil {
		t.Fatalf("readAllWithLimit error: %v", err)
	}
	if string(out) != string(in) {
		t.Fatalf("unexpected content: got %q want %q", string(out), string(in))
	}
}

func TestReadAllWithLimitExceeded(t *testing.T) {
	_, err := readAllWithLimit(bytes.NewReader([]byte("0123456789")), 4)
	if !errors.Is(err, errReadLimitExceeded) {
		t.Fatalf("expected errReadLimitExceeded, got %v", err)
	}
}

func newORASErrorResponse(status int, codes ...string) *errcode.ErrorResponse {
	resp := &errcode.ErrorResponse{
		Method:     http.MethodGet,
		URL:        &url.URL{Scheme: "https", Host: "registry.example.invalid", Path: "/v2/test"},
		StatusCode: status,
	}
	if len(codes) == 0 {
		return resp
	}
	resp.Errors = make(errcode.Errors, 0, len(codes))
	for _, code := range codes {
		resp.Errors = append(resp.Errors, errcode.Error{
			Code:    code,
			Message: strings.ToLower(strings.ReplaceAll(code, "_", " ")),
		})
	}
	return resp
}

func TestWrapRegistryError(t *testing.T) {
	tests := []struct {
		name       string
		in         error
		wantReason app.ReasonCode
		wantExit   int
	}{
		{
			name:       "oras auth status",
			in:         newORASErrorResponse(401),
			wantReason: app.ReasonRegistryAuthFailed,
			wantExit:   app.ExitAuth,
		},
		{
			name:       "oras manifest unknown code",
			in:         newORASErrorResponse(404, errcode.ErrorCodeManifestUnknown),
			wantReason: app.ReasonManifestNotFound,
			wantExit:   app.ExitRegistry,
		},
		{
			name:       "oras blob unknown code",
			in:         newORASErrorResponse(404, errcode.ErrorCodeBlobUnknown),
			wantReason: app.ReasonBlobNotFound,
			wantExit:   app.ExitRegistry,
		},
		{
			name:       "oras timeout status",
			in:         newORASErrorResponse(504),
			wantReason: app.ReasonRegistryTimeout,
			wantExit:   app.ExitRegistry,
		},
		{
			name:       "context deadline exceeded",
			in:         context.DeadlineExceeded,
			wantReason: app.ReasonRegistryTimeout,
			wantExit:   app.ExitRegistry,
		},
		{
			name: "net timeout",
			in: &net.DNSError{
				Err:         "i/o timeout",
				Name:        "registry.example.com",
				IsTimeout:   true,
				IsTemporary: true,
			},
			wantReason: app.ReasonRegistryTimeout,
			wantExit:   app.ExitRegistry,
		},
		{
			name:       "string auth fallback",
			in:         errors.New("unauthorized: token expired"),
			wantReason: app.ReasonRegistryAuthFailed,
			wantExit:   app.ExitAuth,
		},
		{
			name:       "string manifest fallback",
			in:         errors.New("manifest unknown"),
			wantReason: app.ReasonManifestNotFound,
			wantExit:   app.ExitRegistry,
		},
		{
			name:       "string blob fallback",
			in:         errors.New("blob unknown"),
			wantReason: app.ReasonBlobNotFound,
			wantExit:   app.ExitRegistry,
		},
		{
			name:       "default unreachable",
			in:         errors.New("dial tcp 1.2.3.4:443: connection refused"),
			wantReason: app.ReasonRegistryUnreachable,
			wantExit:   app.ExitRegistry,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			err := wrapRegistryError("fetch failed", tc.in)
			appErr := app.AsAppError(err)
			if appErr.Reason != tc.wantReason {
				t.Fatalf("reason mismatch: got=%s want=%s err=%v", appErr.Reason, tc.wantReason, appErr)
			}
			if appErr.ExitCode != tc.wantExit {
				t.Fatalf("exit mismatch: got=%d want=%d err=%v", appErr.ExitCode, tc.wantExit, appErr)
			}
		})
	}
}
