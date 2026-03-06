SHELL := /usr/bin/env bash

.PHONY: help
help:
	@echo "Targets:"
	@echo "  build                  Build oci2gdsd CLI"
	@echo "  install                Install oci2gdsd to \$$GOPATH/bin"
	@echo "  clean                  Remove local build and test harness artifacts"
	@echo ""
	@echo "  prereq                 Full prereq chain (local -> host -> k3s)"
	@echo "  verify-core            verify-unit + verify-local"
	@echo "  verify-smoke           verify-core + host/k3s qwen smoke"
	@echo "  verify-k3s             Full k3s qwen e2e (inline mode)"
	@echo "  verify-k3s-daemonset   Full k3s qwen e2e (daemonset mode)"
	@echo "  verify-k3s-daemonset-all Daemonset mode for qwen + tensorrt + vllm"
	@echo "  verify-k3s-daemonset-parity-all Full parity-focused daemonset mode for tensorrt + vllm"
	@echo "  clean-k3s              Delete k3s e2e local harness artifacts"
	@echo "  demo-local-registry    Self-contained local demo (no GPU, no k8s)"
	@echo ""
	@echo "Advanced targets: prereq-local prereq-host-gds prereq-k3s prereq-all"
	@echo "                  verify-unit verify-local verify-host-qwen-smoke verify-k3s-qwen-smoke"
	@echo "                  verify-k3s-qwen-e2e-inline verify-k3s-qwen-e2e-daemonset"
	@echo "                  verify-k3s-tensor-e2e-daemonset verify-k3s-vllm-e2e-daemonset"
	@echo "                  verify-k3s-tensor-e2e-daemonset-parity verify-k3s-vllm-e2e-daemonset-parity"

.PHONY: build
build:
	go build -buildvcs=false ./cmd/oci2gdsd

.PHONY: install
install:
	go install ./cmd/oci2gdsd

.PHONY: clean
clean:
	@echo "==> Removing local artifacts..."
	@rm -f ./oci2gdsd
	@rm -rf ./platform/local/work ./platform/k3s/work ./platform/host/work
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
	./platform/local/scripts/prereq-check.sh

.PHONY: verify-local
verify-local: prereq-local
	./platform/local/scripts/run.sh
	./platform/local/scripts/negative-tests.sh

.PHONY: prereq-host-gds
prereq-host-gds: prereq-local
	./platform/host/scripts/prereq-check.sh

.PHONY: prereq-k3s
prereq-k3s: prereq-host-gds
	./platform/k3s/scripts/prereq-check.sh

.PHONY: prereq-all
prereq-all: prereq-local prereq-host-gds prereq-k3s

.PHONY: prereq
prereq: prereq-all

.PHONY: verify-host-qwen-smoke
verify-host-qwen-smoke: prereq-host-gds
	./platform/host/scripts/quick-qwen.sh

.PHONY: verify-k3s-qwen-smoke
verify-k3s-qwen-smoke: prereq-k3s
	./platform/k3s/scripts/quick-qwen.sh

.PHONY: verify-k3s-qwen-e2e-inline
verify-k3s-qwen-e2e-inline: prereq-k3s
	./platform/k3s/scripts/run.sh

.PHONY: verify-k3s-qwen-e2e-daemonset
verify-k3s-qwen-e2e-daemonset: prereq-k3s
	E2E_DEPLOY_MODE=daemonset-manifest ./platform/k3s/scripts/run.sh

.PHONY: verify-k3s-tensor-e2e-daemonset
verify-k3s-tensor-e2e-daemonset: prereq-k3s
	E2E_DEPLOY_MODE=daemonset-manifest WORKLOAD_RUNTIME=tensorrt ./platform/k3s/scripts/run.sh

.PHONY: verify-k3s-vllm-e2e-daemonset
verify-k3s-vllm-e2e-daemonset: prereq-k3s
	E2E_DEPLOY_MODE=daemonset-manifest WORKLOAD_RUNTIME=vllm ./platform/k3s/scripts/run.sh

.PHONY: verify-k3s-tensor-e2e-daemonset-parity
verify-k3s-tensor-e2e-daemonset-parity: prereq-k3s
	E2E_DEPLOY_MODE=daemonset-manifest WORKLOAD_RUNTIME=tensorrt RUNTIME_PARITY_MODE=full ./platform/k3s/scripts/run.sh

.PHONY: verify-k3s-vllm-e2e-daemonset-parity
verify-k3s-vllm-e2e-daemonset-parity: prereq-k3s
	E2E_DEPLOY_MODE=daemonset-manifest WORKLOAD_RUNTIME=vllm RUNTIME_PARITY_MODE=full REQUIRE_FULL_IPC_BIND=true ./platform/k3s/scripts/run.sh

.PHONY: verify-core
verify-core: verify-unit verify-local

.PHONY: verify-smoke
verify-smoke: verify-core verify-host-qwen-smoke verify-k3s-qwen-smoke

.PHONY: verify-k3s
verify-k3s: verify-k3s-qwen-e2e-inline

.PHONY: verify-k3s-daemonset
verify-k3s-daemonset: verify-k3s-qwen-e2e-daemonset

.PHONY: verify-k3s-daemonset-all
verify-k3s-daemonset-all: verify-k3s-qwen-e2e-daemonset verify-k3s-tensor-e2e-daemonset verify-k3s-vllm-e2e-daemonset

.PHONY: verify-k3s-daemonset-parity-all
verify-k3s-daemonset-parity-all: verify-k3s-tensor-e2e-daemonset-parity verify-k3s-vllm-e2e-daemonset-parity

.PHONY: clean-k3s
clean-k3s:
	./platform/k3s/scripts/cleanup.sh
