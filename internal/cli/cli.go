package cli

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/dims/oci2gdsd/internal/app"
	configpkg "github.com/dims/oci2gdsd/internal/config"
	"github.com/dims/oci2gdsd/internal/daemon"
	"github.com/dims/oci2gdsd/internal/gpu"
	"github.com/dims/oci2gdsd/internal/registry"
)

func Run(ctx context.Context, args []string, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stderr)
		return app.ExitValidation
	}

	globalFS := flag.NewFlagSet("oci2gdsd", flag.ContinueOnError)
	globalFS.SetOutput(io.Discard)
	var root string
	var targetRoot string
	var configPath string
	var logLevel string
	var jsonOut bool
	var timeoutStr string
	globalFS.StringVar(&root, "root", "", "state root")
	globalFS.StringVar(&targetRoot, "target-root", "", "published model path root")
	globalFS.StringVar(&configPath, "registry-config", "", "config path (standalone full config)")
	globalFS.StringVar(&logLevel, "log-level", "", "log level")
	globalFS.BoolVar(&jsonOut, "json", false, "json output")
	globalFS.StringVar(&timeoutStr, "timeout", "", "timeout duration")
	if err := globalFS.Parse(args); err != nil {
		fmt.Fprintf(stderr, "global flag parse error: %v\n", err)
		return app.ExitValidation
	}
	remaining := globalFS.Args()
	if len(remaining) == 0 {
		printUsage(stderr)
		return app.ExitValidation
	}
	command := remaining[0]
	commandArgs := remaining[1:]

	cfg, err := configpkg.LoadConfig(configPath)
	if err != nil {
		return emitError(err, jsonOut, stderr)
	}
	cfg.ApplyGlobalOverrides(root, targetRoot, logLevel)
	if err := cfg.Validate(); err != nil {
		return emitError(err, jsonOut, stderr)
	}
	for _, w := range cfg.ReservedFieldWarnings() {
		fmt.Fprintf(stderr, "warning: %s\n", w)
	}
	svc, err := app.NewService(cfg, registry.NewORASModelFetcher(cfg), gpu.NewDefaultGPULoader())
	if err != nil {
		return emitError(err, jsonOut, stderr)
	}

	var timeout time.Duration
	if timeoutStr != "" {
		timeout, err = time.ParseDuration(timeoutStr)
		if err != nil {
			return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid --timeout value", err), jsonOut, stderr)
		}
	}

	switch command {
	case "ensure":
		return runEnsure(ctx, svc, commandArgs, timeout, jsonOut, stdout, stderr)
	case "status":
		return runStatus(svc, commandArgs, jsonOut, stdout, stderr)
	case "list":
		return runList(svc, commandArgs, jsonOut, stdout, stderr)
	case "release":
		return runRelease(ctx, svc, commandArgs, jsonOut, stdout, stderr)
	case "gc":
		return runGC(svc, commandArgs, jsonOut, stdout, stderr)
	case "verify":
		return runVerify(svc, commandArgs, jsonOut, stdout, stderr)
	case "profile":
		return runProfile(ctx, svc, commandArgs, jsonOut, stdout, stderr)
	case "gpu":
		return runGPU(ctx, svc, commandArgs, jsonOut, stdout, stderr)
	case "serve":
		return runServe(ctx, svc, commandArgs, jsonOut, stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown command: %s\n", command)
		printUsage(stderr)
		return app.ExitValidation
	}
}

func runEnsure(ctx context.Context, svc *app.Service, args []string, timeout time.Duration, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("ensure", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var ref string
	var modelID string
	var strictIntegrity bool
	var strictDirectPath bool
	var leaseHolder string
	var wait bool
	var commandJSON bool
	fs.StringVar(&ref, "ref", "", "digest-pinned OCI ref")
	fs.StringVar(&modelID, "model-id", "", "model id")
	fs.BoolVar(&strictIntegrity, "strict-integrity", false, "strict integrity")
	fs.BoolVar(&strictDirectPath, "strict-direct-path", false, "strict direct path")
	fs.StringVar(&leaseHolder, "lease-holder", "", "lease holder")
	fs.BoolVar(&wait, "wait", false, "wait for lock")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid ensure flags", err), commandJSON, stderr)
	}
	result, err := svc.Ensure(ctx, app.EnsureRequest{
		Ref:              ref,
		ModelID:          modelID,
		LeaseHolder:      leaseHolder,
		StrictIntegrity:  strictIntegrity,
		StrictDirectPath: strictDirectPath,
		Wait:             wait,
		Timeout:          timeout,
	})
	if commandJSON {
		_ = emitJSON(stdout, result)
	} else {
		fmt.Fprintf(stdout, "status=%s model=%s digest=%s path=%s downloaded=%d reused=%d reason=%s\n",
			result.Status, result.ModelID, result.ManifestDigest, result.ModelRootPath, result.BytesDownloaded, result.BytesReused, result.ReasonCode)
	}
	if err != nil {
		if commandJSON {
			return app.AsAppError(err).ExitCode
		}
		return emitError(err, false, stderr)
	}
	return app.ExitSuccess
}

func runStatus(svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var modelID string
	var digest string
	var commandJSON bool
	fs.StringVar(&modelID, "model-id", "", "model id")
	fs.StringVar(&digest, "digest", "", "manifest digest")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid status flags", err), commandJSON, stderr)
	}
	if modelID == "" || digest == "" {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "--model-id and --digest are required", nil), commandJSON, stderr)
	}
	result, err := svc.Status(modelID, digest)
	if err != nil {
		return emitError(err, commandJSON, stderr)
	}
	if commandJSON {
		_ = emitJSON(stdout, result)
	} else {
		fmt.Fprintf(stdout, "status=%s model=%s digest=%s path=%s bytes=%d leases=%d reason=%s\n",
			result.Status, result.ModelID, result.ManifestDigest, result.Path, result.Bytes, len(result.ActiveLeases), result.ReasonCode)
	}
	return app.ExitSuccess
}

func runList(svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var commandJSON bool
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid list flags", err), commandJSON, stderr)
	}
	results, err := svc.List()
	if err != nil {
		return emitError(err, commandJSON, stderr)
	}
	if commandJSON {
		_ = emitJSON(stdout, results)
	} else {
		for _, r := range results {
			fmt.Fprintf(stdout, "%s %s %s %s leases=%d bytes=%d\n", r.Status, r.ModelID, r.ManifestDigest, r.Path, len(r.ActiveLeases), r.Bytes)
		}
	}
	return app.ExitSuccess
}

func runRelease(ctx context.Context, svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("release", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var modelID string
	var digest string
	var leaseHolder string
	var cleanup bool
	var commandJSON bool
	fs.StringVar(&modelID, "model-id", "", "model id")
	fs.StringVar(&digest, "digest", "", "manifest digest")
	fs.StringVar(&leaseHolder, "lease-holder", "", "lease holder")
	fs.BoolVar(&cleanup, "cleanup", false, "delete immediately when lease count hits zero")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid release flags", err), commandJSON, stderr)
	}
	result, err := svc.Release(ctx, modelID, digest, leaseHolder, cleanup)
	if err != nil {
		return emitError(err, commandJSON, stderr)
	}
	if commandJSON {
		_ = emitJSON(stdout, result)
	} else {
		fmt.Fprintf(stdout, "status=%s model=%s digest=%s remaining_leases=%d\n", result.Status, result.ModelID, result.ManifestDigest, result.RemainingLeases)
	}
	return app.ExitSuccess
}

func runGC(svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("gc", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var policy string
	var minFree string
	var dryRun bool
	var commandJSON bool
	fs.StringVar(&policy, "policy", "", "gc policy")
	fs.StringVar(&minFree, "min-free-bytes", "", "minimum free bytes target")
	fs.BoolVar(&dryRun, "dry-run", false, "dry run")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gc flags", err), commandJSON, stderr)
	}
	minBytes, err := configpkg.ParseMinFreeBytesOrDefault(minFree, svc.MinFreeBytesDefault())
	if err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, err.Error(), nil), commandJSON, stderr)
	}
	result, err := svc.GC(policy, minBytes, dryRun)
	if err != nil {
		return emitError(err, commandJSON, stderr)
	}
	if commandJSON {
		_ = emitJSON(stdout, result)
	} else {
		fmt.Fprintf(stdout, "policy=%s deleted=%d bytes_freed=%d remaining_models=%d\n",
			result.Policy, len(result.DeletedModels), result.BytesFreed, result.RemainingModels)
	}
	return app.ExitSuccess
}

func runVerify(svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("verify", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var path string
	var modelID string
	var digest string
	var commandJSON bool
	fs.StringVar(&path, "path", "", "published model path")
	fs.StringVar(&modelID, "model-id", "", "model id")
	fs.StringVar(&digest, "digest", "", "manifest digest")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid verify flags", err), commandJSON, stderr)
	}
	result, err := svc.Verify(path, modelID, digest)
	if commandJSON {
		_ = emitJSON(stdout, result)
	} else {
		fmt.Fprintf(stdout, "status=%s path=%s model=%s digest=%s reason=%s\n", result.Status, result.Path, result.ModelID, result.ManifestDigest, result.ReasonCode)
	}
	if err != nil {
		if commandJSON {
			return app.AsAppError(err).ExitCode
		}
		return emitError(err, false, stderr)
	}
	return app.ExitSuccess
}

func runProfile(ctx context.Context, svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "profile subcommand required: lint|inspect")
		return app.ExitValidation
	}
	switch args[0] {
	case "lint":
		return runProfileLint(ctx, svc, args[1:], globalJSON, stdout, stderr)
	case "inspect":
		return runProfileInspect(ctx, svc, args[1:], globalJSON, stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown profile subcommand: %s\n", args[0])
		return app.ExitValidation
	}
}

func runProfileLint(ctx context.Context, svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("profile lint", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var configPath string
	var ref string
	var digest string
	var commandJSON bool
	fs.StringVar(&configPath, "config", "", "local model-config.json path")
	fs.StringVar(&ref, "ref", "", "digest-pinned OCI ref")
	fs.StringVar(&digest, "digest", "", "expected manifest digest when using --config")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid profile lint flags", err), commandJSON, stderr)
	}

	var profile *app.ModelProfile
	var layers []app.ManifestLayer
	var manifestDigest string
	var err error

	switch {
	case ref != "":
		profile, layers, manifestDigest, err = svc.ProfileFromRef(ctx, ref)
		if err != nil {
			return emitError(err, commandJSON, stderr)
		}
	case configPath != "":
		profile, err = svc.ProfileFromFile(configPath)
		if err != nil {
			return emitError(err, commandJSON, stderr)
		}
		manifestDigest = digest
	default:
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "either --ref or --config is required", nil), commandJSON, stderr)
	}

	result := app.LintProfile(profile, manifestDigest, layers)
	if commandJSON {
		_ = emitJSON(stdout, result)
	} else {
		if result.Valid {
			fmt.Fprintln(stdout, "profile lint: OK")
		} else {
			fmt.Fprintln(stdout, "profile lint: FAILED")
			for _, e := range result.Errors {
				fmt.Fprintf(stdout, "- %s\n", e)
			}
		}
		for _, w := range result.Warnings {
			fmt.Fprintf(stdout, "warning: %s\n", w)
		}
	}
	if !result.Valid {
		return app.ExitValidation
	}
	return app.ExitSuccess
}

func runProfileInspect(ctx context.Context, svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("profile inspect", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var configPath string
	var ref string
	var commandJSON bool
	fs.StringVar(&configPath, "config", "", "local model-config.json path")
	fs.StringVar(&ref, "ref", "", "digest-pinned OCI ref")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid profile inspect flags", err), commandJSON, stderr)
	}

	var profile *app.ModelProfile
	var manifestDigest string
	var err error

	switch {
	case ref != "":
		profile, _, manifestDigest, err = svc.ProfileFromRef(ctx, ref)
		if err != nil {
			return emitError(err, commandJSON, stderr)
		}
	case configPath != "":
		profile, err = svc.ProfileFromFile(configPath)
		if err != nil {
			return emitError(err, commandJSON, stderr)
		}
		manifestDigest = profile.Integrity.ManifestDigest
	default:
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "either --ref or --config is required", nil), commandJSON, stderr)
	}
	if profile.Integrity.ManifestDigest == "" {
		profile.Integrity.ManifestDigest = manifestDigest
	}
	summary := app.BuildProfileSummary(profile)
	if commandJSON {
		_ = emitJSON(stdout, summary)
	} else {
		fmt.Fprintf(stdout, "model_id=%s revision=%s framework=%s format=%s shards=%d total_bytes=%d manifest=%s\n",
			summary.ModelID, summary.ModelRevision, summary.Framework, summary.Format, summary.ShardCount, summary.TotalShardSize, summary.ManifestDigest)
	}
	return app.ExitSuccess
}

func runGPU(ctx context.Context, svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "gpu subcommand required: probe|load|unload|status", nil), globalJSON, stderr)
	}
	switch args[0] {
	case "probe":
		return runGPUProbe(ctx, svc, args[1:], globalJSON, stdout, stderr)
	case "load":
		return runGPULoad(ctx, svc, args[1:], globalJSON, stdout, stderr)
	case "unload":
		return runGPUUnload(ctx, svc, args[1:], globalJSON, stdout, stderr)
	case "status":
		return runGPUStatus(ctx, svc, args[1:], globalJSON, stdout, stderr)
	default:
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, fmt.Sprintf("unknown gpu subcommand: %s", args[0]), nil), globalJSON, stderr)
	}
}

func runGPUProbe(ctx context.Context, svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("gpu probe", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var device int
	var commandJSON bool
	fs.IntVar(&device, "device", 0, "GPU device index")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu probe flags", err), commandJSON, stderr)
	}
	res, err := svc.GPUProbe(ctx, device)
	if err != nil {
		return emitError(err, commandJSON, stderr)
	}
	if commandJSON {
		_ = emitJSON(stdout, res)
	} else {
		fmt.Fprintf(stdout, "available=%t loader=%s device=%d device_count=%d gds_driver=%t message=%s\n",
			res.Available, res.Loader, res.Device, res.DeviceCount, res.GDSDriver, res.Message)
	}
	if !res.Available {
		return app.ExitPolicy
	}
	return app.ExitSuccess
}

func runGPULoad(ctx context.Context, svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("gpu load", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var modelID string
	var digest string
	var path string
	var leaseHolder string
	var device int
	var chunkBytes string
	var maxShards int
	var strict bool
	var mode string
	var commandJSON bool
	fs.StringVar(&modelID, "model-id", "", "model id")
	fs.StringVar(&digest, "digest", "", "manifest digest")
	fs.StringVar(&path, "path", "", "local published model path")
	fs.StringVar(&leaseHolder, "lease-holder", "", "lease holder (required for --mode persistent)")
	fs.IntVar(&device, "device", 0, "GPU device index")
	fs.StringVar(&chunkBytes, "chunk-bytes", "16MiB", "read chunk bytes")
	fs.IntVar(&maxShards, "max-shards", 0, "maximum shards to load (0=all)")
	fs.BoolVar(&strict, "strict", true, "fail if direct GDS read fails instead of fallback")
	fs.StringVar(&mode, "mode", "benchmark", "gpu load mode: benchmark|persistent")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu load flags", err), commandJSON, stderr)
	}
	mode = strings.ToLower(strings.TrimSpace(mode))
	if mode == "persistent" {
		return emitError(
			app.NewAppError(
				app.ExitPolicy,
				app.ReasonPolicyRejected,
				"gpu load --mode persistent is not available in standalone one-shot CLI mode; use --mode benchmark",
				nil,
			),
			commandJSON,
			stderr,
		)
	}
	if !strict {
		return emitError(
			app.NewAppError(
				app.ExitPolicy,
				app.ReasonPolicyRejected,
				"standalone gpu load enforces strict direct GDS; --strict=false is not allowed",
				nil,
			),
			commandJSON,
			stderr,
		)
	}
	chunk, err := app.ParseByteSize(chunkBytes)
	if err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid --chunk-bytes", err), commandJSON, stderr)
	}
	res, err := svc.GPULoad(ctx, app.GPULoadRequest{
		ModelID:     modelID,
		Digest:      digest,
		Path:        path,
		LeaseHolder: leaseHolder,
		Device:      device,
		ChunkBytes:  chunk,
		MaxShards:   maxShards,
		Strict:      strict,
		Mode:        mode,
	})
	if commandJSON {
		_ = emitJSON(stdout, res)
	} else {
		fmt.Fprintf(stdout, "status=%s loader=%s mode=%s persistent=%t device=%d bytes=%d files=%d reason=%s message=%s\n",
			res.Status, res.Loader, res.Mode, res.Persistent, res.Device, res.TotalBytes, len(res.Files), res.ReasonCode, res.Message)
	}
	if err != nil {
		if commandJSON {
			return app.AsAppError(err).ExitCode
		}
		return emitError(err, false, stderr)
	}
	return app.ExitSuccess
}

func runGPUUnload(ctx context.Context, svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("gpu unload", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var modelID string
	var digest string
	var path string
	var leaseHolder string
	var device int
	var commandJSON bool
	fs.StringVar(&modelID, "model-id", "", "model id")
	fs.StringVar(&digest, "digest", "", "manifest digest")
	fs.StringVar(&path, "path", "", "local published model path")
	fs.StringVar(&leaseHolder, "lease-holder", "", "lease holder")
	fs.IntVar(&device, "device", 0, "GPU device index")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu unload flags", err), commandJSON, stderr)
	}
	res, err := svc.GPUUnload(ctx, app.GPUUnloadRequest{
		ModelID:     modelID,
		Digest:      digest,
		Path:        path,
		LeaseHolder: leaseHolder,
		Device:      device,
	})
	if commandJSON {
		_ = emitJSON(stdout, res)
	} else {
		fmt.Fprintf(stdout, "status=%s loader=%s device=%d released_bytes=%d remaining_leases=%d reason=%s message=%s\n",
			res.Status, res.Loader, res.Device, res.ReleasedBytes, res.RemainingLeases, res.ReasonCode, res.Message)
	}
	if err != nil {
		if commandJSON {
			return app.AsAppError(err).ExitCode
		}
		return emitError(err, false, stderr)
	}
	return app.ExitSuccess
}

func runGPUStatus(ctx context.Context, svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("gpu status", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var device int
	var commandJSON bool
	fs.IntVar(&device, "device", 0, "GPU device index")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid gpu status flags", err), commandJSON, stderr)
	}
	res, err := svc.GPUListPersistent(ctx, device)
	if err != nil {
		return emitError(err, commandJSON, stderr)
	}
	if commandJSON {
		_ = emitJSON(stdout, res)
	} else {
		var total int64
		for _, f := range res {
			total += f.Bytes
			fmt.Fprintf(stdout, "path=%s bytes=%d refs=%d ptr=%s direct=%t\n", f.Path, f.Bytes, f.RefCount, f.DevicePtr, f.Direct)
		}
		fmt.Fprintf(stdout, "device=%d persistent_files=%d total_bytes=%d\n", device, len(res), total)
	}
	return app.ExitSuccess
}

func runServe(ctx context.Context, svc *app.Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var socketPath string
	var socketPerms string
	var removeStale bool
	var shutdownTimeout string
	var commandJSON bool
	fs.StringVar(&socketPath, "unix-socket", "/tmp/oci2gdsd/daemon.sock", "unix socket path for daemon API")
	fs.StringVar(&socketPerms, "socket-perms", "0600", "octal permissions for unix socket")
	fs.BoolVar(&removeStale, "remove-stale-socket", true, "remove existing socket path before bind")
	fs.StringVar(&shutdownTimeout, "shutdown-timeout", "5s", "graceful shutdown timeout")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid serve flags", err), commandJSON, stderr)
	}

	permValue, err := strconv.ParseUint(socketPerms, 8, 32)
	if err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid --socket-perms value", err), commandJSON, stderr)
	}
	timeout, err := time.ParseDuration(shutdownTimeout)
	if err != nil {
		return emitError(app.NewAppError(app.ExitValidation, app.ReasonValidationFailed, "invalid --shutdown-timeout value", err), commandJSON, stderr)
	}

	sigCtx, stop := signal.NotifyContext(ctx, syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	if commandJSON {
		_ = emitJSON(stdout, map[string]any{
			"status":      "STARTING",
			"unix_socket": socketPath,
		})
	} else {
		fmt.Fprintf(stdout, "status=STARTING unix_socket=%s\n", socketPath)
	}

	if err := daemon.Serve(sigCtx, svc, daemon.ServerConfig{
		UnixSocket:      socketPath,
		SocketFileMode:  os.FileMode(permValue),
		RemoveStaleSock: removeStale,
		ShutdownTimeout: timeout,
	}); err != nil {
		return emitError(err, commandJSON, stderr)
	}
	if commandJSON {
		_ = emitJSON(stdout, map[string]any{
			"status":      "STOPPED",
			"unix_socket": socketPath,
		})
	} else {
		fmt.Fprintf(stdout, "status=STOPPED unix_socket=%s\n", socketPath)
	}
	return app.ExitSuccess
}

func emitJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func emitError(err error, jsonOut bool, stderr io.Writer) int {
	appErr := app.AsAppError(err)
	if appErr == nil {
		return app.ExitStateCorrupt
	}
	if jsonOut {
		_ = emitJSON(stderr, map[string]any{
			"status":      "FAILED",
			"reason_code": appErr.Reason,
			"message":     appErr.Error(),
			"exit_code":   appErr.ExitCode,
		})
		return appErr.ExitCode
	}
	fmt.Fprintf(stderr, "error: %s\n", appErr.Error())
	return appErr.ExitCode
}

func printUsage(w io.Writer) {
	lines := []string{
		"usage: oci2gdsd [global flags] <command> [command flags]",
		"commands:",
		"  ensure",
		"  status",
		"  list",
		"  release",
		"  gc",
		"  verify",
		"  profile lint",
		"  profile inspect",
		"  gpu probe",
		"  gpu load",
		"  gpu unload",
		"  gpu status",
		"  serve",
		"global flags:",
		"  --root <path>",
		"  --target-root <path>",
		"  --registry-config <path>",
		"  --log-level <debug|info|warn|error>",
		"  --json",
		"  --timeout <duration>",
	}
	_, _ = io.WriteString(w, strings.Join(lines, "\n")+"\n")
}
