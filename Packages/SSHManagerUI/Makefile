SHELL := /bin/bash
.DEFAULT_GOAL := help

SWIFT   ?= swift
NFPM    ?= nfpm
VERSION := $(shell sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' ../../sshconfigmanager.xcodeproj/project.pbxproj | head -1)
ARCH    ?= amd64
ARCHES  ?= amd64 arm64
FORMAT_CONFIG := ../../.swift-format

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: check-deps
check-deps: ## Fail early if the GTK development packages are missing
	@pkg-config --exists gtk4 libadwaita-1 \
		|| { echo "install libgtk-4-dev and libadwaita-1-dev first"; exit 1; }
	@echo "gtk4 $$(pkg-config --modversion gtk4), libadwaita $$(pkg-config --modversion libadwaita-1)"

.PHONY: build
build: check-deps ## Build the GTK app
	$(SWIFT) build

.PHONY: release
release: check-deps ## Build the GTK app with optimisations, on this machine
	$(SWIFT) build -c release -Xswiftc -static-stdlib

.PHONY: run
run: build ## Build and run the GTK app
	.build/debug/sshmanager

.PHONY: test
test: check-deps ## Run the unit tests
	$(SWIFT) test

.PHONY: lint
lint: ## Format check (swift-format, same config as the macOS app)
	swift-format lint --configuration $(FORMAT_CONFIG) --recursive --strict Sources Tests

.PHONY: format
format: ## Reformat the sources in place
	swift-format format --configuration $(FORMAT_CONFIG) --in-place --recursive Sources Tests

.PHONY: version-check
version-check: ## Fail if AppVersion.current and MARKETING_VERSION disagree
	@grep -q '"$(VERSION)"' Sources/SSHManagerUI/Model/AppVersion.swift \
		|| { echo "MARKETING_VERSION ($(VERSION)) does not match AppVersion.swift"; exit 1; }

.PHONY: release-build
release-build: ## Build in a container against the oldest supported GNOME
	./scripts/release-build.sh

.PHONY: floor
floor: ## Report the compatibility floor of the container build
	./scripts/release-build.sh --report

.PHONY: floor-local
floor-local: ## Report the compatibility floor of the local build
	@test -x .build/release/sshmanager || test -x .build/debug/sshmanager \
		|| { echo "run 'make release' first"; exit 1; }
	@bin=$$(test -x .build/release/sshmanager && echo .build/release/sshmanager || echo .build/debug/sshmanager); \
		echo "$$bin needs glibc $$(objdump -T $$bin | grep -oP 'GLIBC_\d+\.\d+' | sort -uV | tail -1 | cut -d_ -f2)"; \
		echo "(a local build inherits this machine's glibc — use 'make release-build' for a shippable one)"

.PHONY: package
package: version-check ## Package the container build as .deb and .rpm
	@test -x .build/release-container/sshmanager \
		|| { echo "run 'make release-build' first"; exit 1; }
	@mkdir -p dist .build/pkg
	cp .build/release-container/sshmanager .build/pkg/sshmanager
	PKG_VERSION=$(VERSION) PKG_ARCH=$(ARCH) $(NFPM) package -f packaging/nfpm.yaml -p deb -t dist/
	PKG_VERSION=$(VERSION) PKG_ARCH=$(ARCH) $(NFPM) package -f packaging/nfpm.yaml -p rpm -t dist/

.PHONY: package-all
package-all: ## Package every architecture in $(ARCHES)
	@for a in $(ARCHES); do $(MAKE) package ARCH=$$a || exit 1; done

.PHONY: flatpak
flatpak: ## Build and install the Flatpak from the container build
	@test -x .build/release-container/sshmanager \
		|| { echo "run 'make release-build' first"; exit 1; }
	flatpak-builder --user --install --force-clean \
		.build/flatpak packaging/flatpak/app.sshmanager.SSHConfigManager.yml

.PHONY: clean
clean: ## Remove build output and packages
	rm -rf .build dist
