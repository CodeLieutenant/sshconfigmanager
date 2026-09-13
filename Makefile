# SSH Config Manager — one entry point for both platforms. Run `make` for help.
#
# The macOS targets need Xcode; the Linux targets delegate to
# Packages/SSHManagerUI/Makefile, and linux-check builds the shared packages
# inside the Swift container so a Mac can prove the Linux port still compiles.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT := sshconfigmanager.xcodeproj
SCHEME  := sshconfigmanager
DEST    := platform=macOS
UNSIGNED := CODE_SIGNING_ALLOWED=NO
DIRECT := SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) UNSANDBOXED' \
	CODE_SIGN_ENTITLEMENTS=sshconfigmanager/sshconfigmanager-direct.entitlements \
	ENABLE_APP_SANDBOX=NO ENABLE_USER_SELECTED_FILES=none
VERSION := $(shell sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' $(PROJECT)/project.pbxproj | head -1)

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: version
version: ## Print the product version (MARKETING_VERSION)
	@echo $(VERSION)

# ── macOS ───────────────────────────────────────────────────────────────────

.PHONY: build
build: ## Type-check build of the Mac app, unsigned
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build \
		-destination '$(DEST)' $(UNSIGNED)

.PHONY: build-signed
build-signed: ## Build the Mac app signed (needs Config/Local.xcconfig)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build \
		-destination '$(DEST)' -allowProvisioningUpdates

.PHONY: build-direct
build-direct: ## Build the Mac app unsandboxed, so ProxyCommand runs (see docs/building.md)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build \
		-destination '$(DEST)' -allowProvisioningUpdates $(DIRECT)

.PHONY: test
test: test-app test-macui ## Run every macOS test suite

.PHONY: test-app
test-app: ## Run the app target's unit tests
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-only-testing:sshconfigmanagerTests $(UNSIGNED)

.PHONY: test-macui
test-macui: ## Run the SSHConfigMacUI package tests
	cd Packages/SSHConfigMacUI && swift test --no-parallel

.PHONY: install
install: ## Build and install the Mac app into ~/Applications
	./scripts/install-local.sh

# ── Shared core ─────────────────────────────────────────────────────────────

.PHONY: test-kit
test-kit: ## Run the SSHConfigKit tests on the host
	cd Packages/SSHConfigKit && swift test

.PHONY: linux-check
linux-check: ## Build the shared packages on Linux, in the Swift container
	./scripts/linux-build.sh --test

# ── Linux ───────────────────────────────────────────────────────────────────

.PHONY: gui
gui: ## Build the GTK app (needs libgtk-4-dev and libadwaita-1-dev)
	@$(MAKE) -C Packages/SSHManagerUI build

.PHONY: test-gui
test-gui: ## Run the GTK app's tests
	@$(MAKE) -C Packages/SSHManagerUI test

.PHONY: packages
packages: ## Build the .deb and .rpm for every architecture
	@$(MAKE) -C Packages/SSHManagerUI package-all

# ── Quality ─────────────────────────────────────────────────────────────────

.PHONY: lint
lint: ## Format check every first-party Swift source
	./scripts/lint.sh

.PHONY: format
format: ## Reformat every first-party Swift source in place
	./scripts/lint.sh --fix

.PHONY: changelog-check
changelog-check: ## Validate CHANGELOG.md
	python3 scripts/changelog.py check

.PHONY: version-check
version-check: ## Fail if the Linux app version disagrees with MARKETING_VERSION
	@$(MAKE) -C Packages/SSHManagerUI version-check

.PHONY: leak-check
leak-check:
	./scripts/leak-check.sh

.PHONY: check
check: lint changelog-check version-check test ## Everything CI gates on

# ── Release ─────────────────────────────────────────────────────────────────

.PHONY: release-notes
release-notes: ## Rewrite the App Store notes from CHANGELOG.md
	python3 scripts/changelog.py notes --project --write

.PHONY: testflight
testflight: ## Bump the build number and upload to TestFlight
	./scripts/release.sh testflight

.PHONY: dmg
dmg: ## Build a notarized Developer ID .dmg
	./scripts/release.sh dmg

.PHONY: clean
clean: ## Remove build output from every package
	rm -rf build DerivedData dist
	@$(MAKE) -C Packages/SSHManagerUI clean
