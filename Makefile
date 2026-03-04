SHELL := /usr/bin/env bash

.PHONY: help
help:
	@echo "Targets:"
	@echo "  build                  Build oci2gdsd CLI"
	@echo "  install                Install oci2gdsd to \$$GOPATH/bin"
	@echo "  clean                  Remove local build and test harness artifacts"
	@echo "  prereq-local           Stage 0 prereq: local/base tooling + storage"
	@echo "  prereq-host-gds        Stage 1 prereq: host strict direct-GDS (extends prereq-local)"
	@echo "  prereq-k3s             Stage 2 prereq: k3s harness checks (extends prereq-host-gds)"
	@echo "  prereq-all             Run full prereq chain (local -> host -> k3s)"
	@echo "  verify-unit            Run Go tests (no GPU required)"
	@echo "  verify-local           Local CLI lifecycle e2e (positive + negative checks)"
	@echo "  verify-host-qwen-smoke Host-only strict direct-GDS qwen probe"
	@echo "  verify-k3s-qwen-smoke  Fast qwen-hello redeploy/probe loop on k3s"
	@echo "  verify-k3s-qwen-e2e-inline Full k3s e2e in inline mode"
	@echo "  verify-k3s-qwen-e2e-daemonset Full k3s e2e in daemonset mode"
	@echo "  verify-k3s-tensor-e2e-daemonset Full k3s e2e in daemonset mode with TensorRT-LLM workload"
	@echo "  clean-k3s              Delete k3s e2e local harness artifacts"
	@echo "  demo-local-registry    Self-contained local demo (no GPU, no k8s)"

.PHONY: build
build:
	go build ./cmd/oci2gdsd

.PHONY: install
install:
	go install ./cmd/oci2gdsd

.PHONY: clean
clean:
	@echo "==> Removing local artifacts..."
	@rm -f ./oci2gdsd
	@rm -rf ./testharness/local-e2e/work ./testharness/k3s-e2e/work ./testharness/host-e2e/work
	@find . -type d \( -name '__pycache__' -o -name '.pytest_cache' -o -name '.mypy_cache' \) -prune -exec rm -rf {} +
	@find . -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
	@echo "==> Done"

.PHONY: verify-unit
verify-unit:
	go test ./...

.PHONY: demo-local-registry
demo-local-registry: build
	@echo "==> Starting local OCI registry (requires Docker)..."
	@docker inspect local-registry >/dev/null 2>&1 && echo "(registry already running)" || \
	  docker run -d --rm -p 5000:5000 --name local-registry registry:2
	@echo ""
	@echo "==> Registry running at localhost:5000"
	@echo ""
	@echo "==> Follow docs/getting-started.md to push a test artifact and run"
	@echo "    ensure / status / verify / release / gc against it."
	@echo ""
	@echo "    Binary: ./oci2gdsd"
	@echo "    Docs:   docs/getting-started.md"
	@echo ""
	@echo "==> To stop the registry when done:"
	@echo "    docker stop local-registry"

.PHONY: prereq-local
prereq-local:
	./testharness/local-e2e/scripts/prereq-check.sh

.PHONY: verify-local
verify-local: prereq-local
	./testharness/local-e2e/scripts/run.sh
	./testharness/local-e2e/scripts/negative-tests.sh

.PHONY: prereq-host-gds
prereq-host-gds: prereq-local
	./testharness/host-e2e/scripts/prereq-check.sh

.PHONY: prereq-k3s
prereq-k3s: prereq-host-gds
	./testharness/k3s-e2e/scripts/prereq-check.sh

.PHONY: prereq-all
prereq-all: prereq-local prereq-host-gds prereq-k3s

.PHONY: verify-host-qwen-smoke
verify-host-qwen-smoke: prereq-host-gds
	./testharness/host-e2e/scripts/quick-qwen.sh

.PHONY: verify-k3s-qwen-smoke
verify-k3s-qwen-smoke: prereq-k3s
	./testharness/k3s-e2e/scripts/quick-qwen.sh

.PHONY: verify-k3s-qwen-e2e-inline
verify-k3s-qwen-e2e-inline: prereq-k3s
	./testharness/k3s-e2e/scripts/run.sh

.PHONY: verify-k3s-qwen-e2e-daemonset
verify-k3s-qwen-e2e-daemonset: prereq-k3s
	E2E_DEPLOY_MODE=daemonset-manifest ./testharness/k3s-e2e/scripts/run.sh

.PHONY: verify-k3s-tensor-e2e-daemonset
verify-k3s-tensor-e2e-daemonset: prereq-k3s
	E2E_DEPLOY_MODE=daemonset-manifest WORKLOAD_RUNTIME=tensorrt ./testharness/k3s-e2e/scripts/run.sh

.PHONY: clean-k3s
clean-k3s:
	./testharness/k3s-e2e/scripts/cleanup.sh
