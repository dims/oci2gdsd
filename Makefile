SHELL := /usr/bin/env bash

.PHONY: help
help:
	@echo "Targets:"
	@echo "  build                  Build oci2gdsd CLI"
	@echo "  install                Install oci2gdsd to \$$GOPATH/bin"
	@echo "  clean                  Remove local build and test harness artifacts"
	@echo "  test                   Run Go tests (no GPU required)"
	@echo "  demo-local             Self-contained local demo (no GPU, no k8s)"
	@echo "  nvkind-e2e-prereq      Check/install nvkind e2e prerequisites"
	@echo "  nvkind-e2e             Run nvkind Kubernetes GPU e2e harness"
	@echo "  host-e2e-prereq        Check/install host qwen quick prerequisites"
	@echo "  nvkind-e2e-qwen-quick  Fast qwen-hello redeploy/probe loop"
	@echo "  host-e2e-qwen-quick    Run host-only strict direct-GDS qwen probe"
	@echo "  nvkind-e2e-clean       Delete nvkind cluster and local harness artifacts"

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
	@rm -rf ./testharness/nvkind-e2e/work ./testharness/host-e2e/work
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

.PHONY: nvkind-e2e-prereq
nvkind-e2e-prereq:
	./testharness/nvkind-e2e/scripts/prereq-check.sh

.PHONY: nvkind-e2e
nvkind-e2e: nvkind-e2e-prereq
	./testharness/nvkind-e2e/scripts/run.sh

.PHONY: nvkind-e2e-qwen-quick
nvkind-e2e-qwen-quick: nvkind-e2e-prereq
	./testharness/nvkind-e2e/scripts/quick-qwen.sh

.PHONY: host-e2e-prereq
host-e2e-prereq:
	./testharness/host-e2e/scripts/prereq-check.sh

.PHONY: host-e2e-qwen-quick
host-e2e-qwen-quick: host-e2e-prereq
	./testharness/host-e2e/scripts/quick-qwen.sh

.PHONY: nvkind-e2e-clean
nvkind-e2e-clean:
	./testharness/nvkind-e2e/scripts/cleanup.sh
