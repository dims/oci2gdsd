SHELL := /usr/bin/env bash

.PHONY: help
help:
	@echo "Targets:"
	@echo "  build               Build oci2gdsd CLI"
	@echo "  test                Run Go tests"
	@echo "  nvkind-e2e          Run nvkind Kubernetes GPU e2e harness"
	@echo "  nvkind-e2e-clean    Delete nvkind cluster and local harness artifacts"

.PHONY: build
build:
	go build ./cmd/oci2gdsd

.PHONY: test
test:
	go test ./...

.PHONY: nvkind-e2e
nvkind-e2e:
	./testharness/nvkind-e2e/scripts/run.sh

.PHONY: nvkind-e2e-clean
nvkind-e2e-clean:
	./testharness/nvkind-e2e/scripts/cleanup.sh
