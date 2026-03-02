.PHONY: help lint test image-build profiles-install remoteapp-install install

SHELL := /bin/bash
PREFIX ?= /usr/local

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: ## Run shellcheck on all scripts
	find . -name '*.sh' -exec shellcheck -x {} +

test: ## Run integration tests (requires incus)
	@echo "Running smoke tests..."
	cli/iwt.sh doctor

image-build: ## Build a Windows image for Incus
	image-pipeline/scripts/build-image.sh

profiles-install: ## Install Incus VM profiles
	cli/iwt.sh profiles install

remoteapp-install: ## Install RemoteApp desktop integration
	cli/iwt.sh remoteapp install

install: ## Install iwt CLI to PREFIX
	install -Dm755 cli/iwt.sh $(PREFIX)/bin/iwt
	install -Dm644 profiles/x86_64/*.yaml -t $(PREFIX)/share/iwt/profiles/x86_64/
	install -Dm644 profiles/arm64/*.yaml -t $(PREFIX)/share/iwt/profiles/arm64/
	cp -r image-pipeline $(PREFIX)/share/iwt/image-pipeline
	cp -r remoteapp $(PREFIX)/share/iwt/remoteapp
