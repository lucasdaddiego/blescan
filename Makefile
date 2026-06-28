# blescan — live terminal BLE scanner & fingerprinter (Swift / CoreBluetooth).
# `make` (or `make help`) lists the targets; `make install` builds a single
# self-contained `blescan` binary and installs it on PATH.
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
# Everything we generate lives under .build/ (git-ignored, shared with SwiftPM).
BUILD_DIR   := .build
COV_DIR     := $(BUILD_DIR)/coverage
TEST_BIN    := $(BUILD_DIR)/blescan-tests
PLIST       := Info.plist
INSTALL_DIR := $(HOME)/.bin
BUNDLE_ID   := com.lucasdaddiego.blescan

# Swift compiler — override to pin a toolchain, e.g. `make SWIFTC="xcrun swiftc"`.
SWIFTC      ?= swiftc

# Signing identity. Ad-hoc ("-") by default — but ad-hoc has no stable identity, so
# macOS ties the Bluetooth grant to the exact build and forgets it on every rebuild.
# For a grant that survives rebuilds, create a self-signed "Code Signing" certificate
# once (Keychain Access → Certificate Assistant → Create a Certificate, type "Code
# Signing"), then build with:  make SIGN="Your Cert Name"
SIGN        ?= -

# Extra arguments for `make run` — e.g. `make run ARGS=--diag`.
ARGS        ?=

FRAMEWORKS  := -framework CoreBluetooth
# Embed Info.plist into the binary so a bundle-less CLI still gets the Bluetooth
# prompt and a TCC identity. -sectcreate is a linker option, so route it via -Xlinker.
EMBED_PLIST := -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(PLIST)
# Release: optimise (-O), strip local symbols (-x), drop dead code (-dead_strip).
# No -g, so zero debug info. Stripping is at link time, before signing.
RELEASE     := -O -Xlinker -x -Xlinker -dead_strip

.DEFAULT_GOAL := help
.PHONY: help build install run diag test coverage clean uninstall

help: ## List all targets
	@echo "blescan — make targets ('make install' builds + installs):"
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: $(BINARY) ## Build the optimised, signed ./blescan (no install)

# File rule = real dependency tracking: relink only when the sources, the embedded
# plist, or the build flags (this Makefile) actually change. Stripping happens at
# link time, so we code-sign the final stripped Mach-O — `build`, `run` and `diag`
# then use this locally-signed binary directly.
$(BINARY): $(SRC) $(PLIST) Makefile
	$(SWIFTC) $(RELEASE) $(EMBED_PLIST) $(SRC) -o $@ $(FRAMEWORKS)
	codesign --force --sign $(SIGN) --identifier $(BUNDLE_ID) $@
	@echo "built ./$@ ($$(du -h $@ | cut -f1)), signed as '$(SIGN)'"

# Copy, then re-sign in place. A copied Mach-O fails strict signature verification
# (macOS quirk — cp/ditto/install all trigger it, even byte-identical on the same
# volume), so re-sign at the destination to give the installed binary a clean
# signature and Bluetooth TCC identity. (Stability across rebuilds still needs a
# real SIGN cert, per the note above; ad-hoc re-keys every build.)
install: $(BINARY) ## Build and install blescan into ~/.bin
	@mkdir -p "$(INSTALL_DIR)"
	cp -f "$(BINARY)" "$(INSTALL_DIR)/$(BINARY)"
	codesign --force --sign $(SIGN) --identifier $(BUNDLE_ID) "$(INSTALL_DIR)/$(BINARY)"
	@echo "installed $(INSTALL_DIR)/$(BINARY)"
	@echo
	@echo "one-time permission:"
	@echo "  1. run \`$(BINARY)\` once  (triggers the Bluetooth prompt)"
	@echo "  2. System Settings → Privacy & Security → Bluetooth → enable 'blescan'"
	@echo "     (or click Allow on the prompt)"
	@echo "  3. rerun \`$(BINARY)\`; \`$(BINARY) --diag\` should report state poweredOn"

run: $(BINARY) ## Build, then run ./blescan locally (pass flags via ARGS=…)
	./$(BINARY) $(ARGS)

diag: $(BINARY) ## Build, then run ./blescan --diag (report Bluetooth state)
	./$(BINARY) --diag

test: ## Build & run the dependency-free core unit tests (no Xcode/XCTest needed)
	@mkdir -p "$(BUILD_DIR)"
	@$(SWIFTC) -parse-as-library $(TEST_SRC) -o "$(TEST_BIN)"
	@"$(TEST_BIN)"

coverage: ## Run the core tests under coverage; fail unless Core.swift is 100% covered
	@mkdir -p "$(COV_DIR)"
	@$(SWIFTC) -profile-generate -profile-coverage-mapping -parse-as-library $(TEST_SRC) -o "$(COV_DIR)/tests"
	@LLVM_PROFILE_FILE="$(COV_DIR)/tests.profraw" "$(COV_DIR)/tests"
	@xcrun llvm-profdata merge -sparse "$(COV_DIR)/tests.profraw" -o "$(COV_DIR)/tests.profdata"
	@xcrun llvm-cov report "$(COV_DIR)/tests" -instr-profile="$(COV_DIR)/tests.profdata" $(CORE)
	@bash scripts/check-coverage.sh "$(COV_DIR)/tests" "$(COV_DIR)/tests.profdata" $(CORE)

clean: ## Remove local build artifacts (leaves the installed binary — see uninstall)
	rm -rf "$(BINARY)" "$(COV_DIR)" "$(TEST_BIN)"

uninstall: ## Remove the installed binary from ~/.bin
	rm -f "$(INSTALL_DIR)/$(BINARY)"
	@echo "removed $(INSTALL_DIR)/$(BINARY)"
	@echo "note: the Bluetooth permission entry remains in System Settings → Privacy & Security."
