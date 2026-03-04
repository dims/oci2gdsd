SHELL := /usr/bin/env bash

.PHONY: help
help:
	@echo "Targets:"
	@echo "  build                  Build oci2gdsd CLI"
	@echo "  install                Install oci2gdsd to \$$GOPATH/bin"
	@echo "  clean                  Remove local build and test harness artifacts"
	@echo "  test                   Run Go tests (no GPU required)"
	@echo "  demo-local             Self-contained local demo (no GPU, no k8s)"
	@echo "  local-e2e-prereq       Stage 0 prereq: local/base tooling + storage"
	@echo "  local-e2e              Run local CLI lifecycle e2e (ensure/status/verify/release/gc)"
	@echo "  local-e2e-negative     Run local CLI negative/failure-path assertions"
	@echo "  host-e2e-prereq        Stage 1 prereq: host direct-GDS (extends local-e2e-prereq)"
	@echo "  k3s-e2e-prereq         Stage 2 prereq: k3s harness (extends host-e2e-prereq)"
	@echo "  k3s-e2e                Run k3s Kubernetes GPU e2e harness"
	@echo "  k3s-e2e-daemonset-manifest Run k3s e2e using raw daemonset manifests"
	@echo "  k3s-e2e-qwen-quick     Fast qwen-hello redeploy/probe loop"
	@echo "  host-e2e-qwen-quick    Run host-only strict direct-GDS qwen probe"
	@echo "  doctor                 Run all prerequisite checks (local/host/k3s)"
	@echo "  k3s-e2e-clean          Delete k3s e2e local harness artifacts"

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

.PHONY: test
test:
	go test ./...

.PHONY: demo-local
demo-local: build
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

.PHONY: local-e2e-prereq
local-e2e-prereq:
	./testharness/local-e2e/scripts/prereq-check.sh

.PHONY: local-e2e
local-e2e: local-e2e-prereq
	./testharness/local-e2e/scripts/run.sh
	./testharness/local-e2e/scripts/negative-tests.sh

.PHONY: local-e2e-negative
local-e2e-negative:
	./testharness/local-e2e/scripts/negative-tests.sh

.PHONY: k3s-e2e-prereq
k3s-e2e-prereq: host-e2e-prereq
	./testharness/k3s-e2e/scripts/prereq-check.sh

.PHONY: k3s-e2e
k3s-e2e: k3s-e2e-prereq
	./testharness/k3s-e2e/scripts/run.sh

.PHONY: k3s-e2e-daemonset-manifest
k3s-e2e-daemonset-manifest: k3s-e2e-prereq
	E2E_DEPLOY_MODE=daemonset-manifest ./testharness/k3s-e2e/scripts/run.sh

.PHONY: k3s-e2e-qwen-quick
k3s-e2e-qwen-quick: k3s-e2e-prereq
	./testharness/k3s-e2e/scripts/quick-qwen.sh

.PHONY: host-e2e-prereq
host-e2e-prereq: local-e2e-prereq
	./testharness/host-e2e/scripts/prereq-check.sh

.PHONY: host-e2e-qwen-quick
host-e2e-qwen-quick: host-e2e-prereq
	./testharness/host-e2e/scripts/quick-qwen.sh

.PHONY: doctor
doctor: local-e2e-prereq host-e2e-prereq k3s-e2e-prereq

.PHONY: k3s-e2e-clean
k3s-e2e-clean:
	./testharness/k3s-e2e/scripts/cleanup.sh
