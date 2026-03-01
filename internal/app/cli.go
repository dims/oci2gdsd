package app

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"strings"
	"time"
)

func Run(ctx context.Context, args []string, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		printUsage(stderr)
		return ExitValidation
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
		return ExitValidation
	}
	remaining := globalFS.Args()
	if len(remaining) == 0 {
		printUsage(stderr)
		return ExitValidation
	}
	command := remaining[0]
	commandArgs := remaining[1:]

	cfg, err := LoadConfig(configPath)
	if err != nil {
		return emitError(err, jsonOut, stderr)
	}
	cfg.ApplyGlobalOverrides(root, targetRoot, logLevel)
	if err := cfg.Validate(); err != nil {
		return emitError(err, jsonOut, stderr)
	}
	svc, err := NewService(cfg, nil)
	if err != nil {
		return emitError(err, jsonOut, stderr)
	}

	var timeout time.Duration
	if timeoutStr != "" {
		timeout, err = time.ParseDuration(timeoutStr)
		if err != nil {
			return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid --timeout value", err), jsonOut, stderr)
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
	default:
		fmt.Fprintf(stderr, "unknown command: %s\n", command)
		printUsage(stderr)
		return ExitValidation
	}
}

func runEnsure(ctx context.Context, svc *Service, args []string, timeout time.Duration, globalJSON bool, stdout, stderr io.Writer) int {
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
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid ensure flags", err), commandJSON, stderr)
	}
	result, err := svc.Ensure(ctx, EnsureRequest{
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
			return AsAppError(err).ExitCode
		}
		return emitError(err, false, stderr)
	}
	return ExitSuccess
}

func runStatus(svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("status", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var modelID string
	var digest string
	var commandJSON bool
	fs.StringVar(&modelID, "model-id", "", "model id")
	fs.StringVar(&digest, "digest", "", "manifest digest")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid status flags", err), commandJSON, stderr)
	}
	if modelID == "" || digest == "" {
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "--model-id and --digest are required", nil), commandJSON, stderr)
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
	return ExitSuccess
}

func runList(svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var commandJSON bool
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid list flags", err), commandJSON, stderr)
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
	return ExitSuccess
}

func runRelease(ctx context.Context, svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
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
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid release flags", err), commandJSON, stderr)
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
	return ExitSuccess
}

func runGC(svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
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
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid gc flags", err), commandJSON, stderr)
	}
	minBytes, err := parseMinFreeBytesOrDefault(minFree, svc.cfg.Retention.MinFreeBytes)
	if err != nil {
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, err.Error(), nil), commandJSON, stderr)
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
	return ExitSuccess
}

func runVerify(svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
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
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid verify flags", err), commandJSON, stderr)
	}
	result, err := svc.Verify(path, modelID, digest)
	if commandJSON {
		_ = emitJSON(stdout, result)
	} else {
		fmt.Fprintf(stdout, "status=%s path=%s model=%s digest=%s reason=%s\n", result.Status, result.Path, result.ModelID, result.ManifestDigest, result.ReasonCode)
	}
	if err != nil {
		if commandJSON {
			return AsAppError(err).ExitCode
		}
		return emitError(err, false, stderr)
	}
	return ExitSuccess
}

func runProfile(ctx context.Context, svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "profile subcommand required: lint|inspect")
		return ExitValidation
	}
	switch args[0] {
	case "lint":
		return runProfileLint(ctx, svc, args[1:], globalJSON, stdout, stderr)
	case "inspect":
		return runProfileInspect(ctx, svc, args[1:], globalJSON, stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown profile subcommand: %s\n", args[0])
		return ExitValidation
	}
}

func runProfileLint(ctx context.Context, svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
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
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid profile lint flags", err), commandJSON, stderr)
	}

	var profile *ModelProfile
	var layers []ManifestLayer
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
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "either --ref or --config is required", nil), commandJSON, stderr)
	}

	result := LintProfile(profile, manifestDigest, layers)
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
		return ExitValidation
	}
	return ExitSuccess
}

func runProfileInspect(ctx context.Context, svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("profile inspect", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var configPath string
	var ref string
	var commandJSON bool
	fs.StringVar(&configPath, "config", "", "local model-config.json path")
	fs.StringVar(&ref, "ref", "", "digest-pinned OCI ref")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid profile inspect flags", err), commandJSON, stderr)
	}

	var profile *ModelProfile
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
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "either --ref or --config is required", nil), commandJSON, stderr)
	}
	if profile.Integrity.ManifestDigest == "" {
		profile.Integrity.ManifestDigest = manifestDigest
	}
	summary := BuildProfileSummary(profile)
	if commandJSON {
		_ = emitJSON(stdout, summary)
	} else {
		fmt.Fprintf(stdout, "model_id=%s revision=%s framework=%s format=%s shards=%d total_bytes=%d manifest=%s\n",
			summary.ModelID, summary.ModelRevision, summary.Framework, summary.Format, summary.ShardCount, summary.TotalShardSize, summary.ManifestDigest)
	}
	return ExitSuccess
}

func runGPU(ctx context.Context, svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "gpu subcommand required: probe|load", nil), globalJSON, stderr)
	}
	switch args[0] {
	case "probe":
		return runGPUProbe(ctx, svc, args[1:], globalJSON, stdout, stderr)
	case "load":
		return runGPULoad(ctx, svc, args[1:], globalJSON, stdout, stderr)
	default:
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, fmt.Sprintf("unknown gpu subcommand: %s", args[0]), nil), globalJSON, stderr)
	}
}

func runGPUProbe(ctx context.Context, svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("gpu probe", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var device int
	var commandJSON bool
	fs.IntVar(&device, "device", 0, "GPU device index")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid gpu probe flags", err), commandJSON, stderr)
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
		return ExitPolicy
	}
	return ExitSuccess
}

func runGPULoad(ctx context.Context, svc *Service, args []string, globalJSON bool, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("gpu load", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var modelID string
	var digest string
	var path string
	var device int
	var chunkBytes string
	var maxShards int
	var strict bool
	var commandJSON bool
	fs.StringVar(&modelID, "model-id", "", "model id")
	fs.StringVar(&digest, "digest", "", "manifest digest")
	fs.StringVar(&path, "path", "", "local published model path")
	fs.IntVar(&device, "device", 0, "GPU device index")
	fs.StringVar(&chunkBytes, "chunk-bytes", "16MiB", "read chunk bytes")
	fs.IntVar(&maxShards, "max-shards", 0, "maximum shards to load (0=all)")
	fs.BoolVar(&strict, "strict", true, "fail if direct GDS read fails instead of fallback")
	fs.BoolVar(&commandJSON, "json", globalJSON, "json output")
	if err := fs.Parse(args); err != nil {
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid gpu load flags", err), commandJSON, stderr)
	}
	chunk, err := ParseByteSize(chunkBytes)
	if err != nil {
		return emitError(NewAppError(ExitValidation, ReasonValidationFailed, "invalid --chunk-bytes", err), commandJSON, stderr)
	}
	res, err := svc.GPULoad(ctx, GPULoadRequest{
		ModelID:    modelID,
		Digest:     digest,
		Path:       path,
		Device:     device,
		ChunkBytes: chunk,
		MaxShards:  maxShards,
		Strict:     strict,
	})
	if commandJSON {
		_ = emitJSON(stdout, res)
	} else {
		fmt.Fprintf(stdout, "status=%s loader=%s device=%d bytes=%d files=%d reason=%s message=%s\n",
			res.Status, res.Loader, res.Device, res.TotalBytes, len(res.Files), res.ReasonCode, res.Message)
	}
	if err != nil {
		if commandJSON {
			return AsAppError(err).ExitCode
		}
		return emitError(err, false, stderr)
	}
	return ExitSuccess
}

func emitJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func emitError(err error, jsonOut bool, stderr io.Writer) int {
	appErr := AsAppError(err)
	if appErr == nil {
		return ExitStateCorrupt
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
