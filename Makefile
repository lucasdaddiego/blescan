# blescan — live terminal BLE scanner & fingerprinter (Swift / CoreBluetooth).
# `make` builds a single self-contained `blescan` binary and installs it on PATH.
#
# Why no .app bundle? Unlike Wi-Fi SSIDs (which macOS reveals only to a real
# LaunchServices app session), BLE scanning just needs the Bluetooth TCC grant.
# A bare CLI gets that prompt as long as it carries an Info.plist with
# NSBluetoothAlwaysUsageDescription — so we embed the plist into the Mach-O at link
# time (-sectcreate __TEXT __info_plist) and code-sign the binary. No bundle needed.

# Optional machine-local overrides (git-ignored) — e.g. SIGN := <your cert>.
-include Makefile.local

BINARY      := blescan
# Core.swift = pure, framework-free logic (also compiled standalone by `make test`
# and held at 100% coverage by `make coverage`); main.swift = CoreBluetooth, the
# TUI, and the entrypoint.
CORE        := Sources/blescan/Core.swift
SRC         := $(CORE) Sources/blescan/main.swift
TEST_SRC    := $(CORE) Tests/CoreTests.swift
COV_DIR     := .build/coverage
PLIST       := Info.plist
INSTALL_DIR := $(HOME)/.bin
BUNDLE_ID   := com.lucasdaddiego.blescan
# Signing identity. Ad-hoc ("-") by default — but ad-hoc has no stable identity, so
# macOS ties the Bluetooth grant to the exact build and forgets it on every rebuild.
# For a grant that survives rebuilds, create a self-signed "Code Signing" certificate
# once (Keychain Access → Certificate Assistant → Create a Certificate, type "Code
# Signing"), then build with:  make SIGN="Your Cert Name"
SIGN        ?= -

FRAMEWORKS  := -framework CoreBluetooth
# Embed Info.plist into the binary so a bundle-less CLI still gets the Bluetooth
# prompt and a TCC identity. -sectcreate is a linker option, so route it via -Xlinker.
EMBED_PLIST := -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(PLIST)
# Release: optimise (-O), strip local symbols (-x), drop dead code (-dead_strip).
# No -g, so zero debug info. Stripping is at link time, before signing.
RELEASE     := -O -Xlinker -x -Xlinker -dead_strip

.DEFAULT_GOAL := install
.PHONY: install clean test coverage

install: ## Build the optimised, signed blescan binary into ~/.bin
	@mkdir -p "$(INSTALL_DIR)"
	swiftc $(RELEASE) $(EMBED_PLIST) $(SRC) -o "$(INSTALL_DIR)/$(BINARY)" $(FRAMEWORKS)
	codesign --force --sign $(SIGN) --identifier $(BUNDLE_ID) "$(INSTALL_DIR)/$(BINARY)"
	@echo "installed $(INSTALL_DIR)/$(BINARY) ($$(du -h "$(INSTALL_DIR)/$(BINARY)" | cut -f1))"
	@echo
	@echo "one-time permission:"
	@echo "  1. run \`$(BINARY)\` once  (triggers the Bluetooth prompt)"
	@echo "  2. System Settings → Privacy & Security → Bluetooth → enable 'blescan'"
	@echo "     (or click Allow on the prompt)"
	@echo "  3. rerun \`$(BINARY)\`; \`$(BINARY) --diag\` should report state poweredOn"

test: ## Build & run the dependency-free core unit tests (no Xcode/XCTest needed)
	@swiftc -parse-as-library $(TEST_SRC) -o /tmp/blescan-tests
	@/tmp/blescan-tests

coverage: ## Run the core tests under coverage; fail unless Core.swift is 100% covered
	@mkdir -p "$(COV_DIR)"
	@swiftc -profile-generate -profile-coverage-mapping -parse-as-library $(TEST_SRC) -o "$(COV_DIR)/tests"
	@LLVM_PROFILE_FILE="$(COV_DIR)/tests.profraw" "$(COV_DIR)/tests"
	@xcrun llvm-profdata merge -sparse "$(COV_DIR)/tests.profraw" -o "$(COV_DIR)/tests.profdata"
	@xcrun llvm-cov report "$(COV_DIR)/tests" -instr-profile="$(COV_DIR)/tests.profdata" $(CORE)
	@bash scripts/check-coverage.sh "$(COV_DIR)/tests" "$(COV_DIR)/tests.profdata" $(CORE)

clean: ## Remove the installed binary and build artifacts
	rm -rf "$(INSTALL_DIR)/$(BINARY)" "$(COV_DIR)" /tmp/blescan-tests
