# blescan — live terminal BLE scanner & fingerprinter (Swift / CoreBluetooth).
# `make` (or `make help`) lists the targets; `make install` builds a single
# self-contained `blescan` binary into bin/ and links it from ~/.bin (on PATH).
#
# Why no .app bundle? Unlike Wi-Fi SSIDs (which macOS reveals only to a real
# LaunchServices app session), BLE scanning just needs the Bluetooth TCC grant.
# A bare CLI gets that prompt as long as it carries an Info.plist with
# NSBluetoothAlwaysUsageDescription — so we embed the plist into the Mach-O at link
# time (-sectcreate __TEXT __info_plist) and code-sign the binary. No bundle needed.

# Optional machine-local overrides (git-ignored) — e.g. SIGN := <your cert>.
-include Makefile.local

BINARY      := blescan
# The built, signed binary. Not the repo root: see the build rule.
OUT         := bin/$(BINARY)
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
INSTALL_DIR ?= $(HOME)/.bin
BUNDLE_ID   := com.lucasdaddiego.blescan
# The version is owned by Info.plist (CFBundleShortVersionString) — `--version` reads it
# from the embedded plist at runtime, `make release` tags from it.
VERSION     := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(PLIST))
DIST_DIR    := $(BUILD_DIR)/dist
DIST_ZIP    := $(DIST_DIR)/blescan-v$(VERSION)-macos-universal.zip

# Swift compiler — override to pin a toolchain, e.g. `make SWIFTC="xcrun swiftc"`.
# Swift 6 language mode (strict concurrency), matching Package.swift's tools-version so
# `make` and `swift build` compile the same dialect.
SWIFTC      ?= swiftc
SWIFTFLAGS  := -swift-version 6

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
# Slices in the universal dist binary. The x86_64 slice needs a toolchain whose Swift
# compatibility libraries carry both architectures — Xcode's does, and that is what the
# release workflow runs on. The Command Line Tools ship them arm64-only, so on a CLT-only
# Mac build a single-slice dist with `make dist ARCHS=arm64`.
ARCHS       ?= arm64 x86_64

.DEFAULT_GOAL := help
.PHONY: help build install run diag test coverage dist release clean uninstall

help: ## List all targets
	@echo "blescan — make targets ('make install' builds + links):"
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[1m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

build: $(OUT) ## Build the optimised, signed bin/blescan (the file ~/.bin/blescan links to)

# File rule = real dependency tracking: relink only when the sources, the embedded
# plist, or the build flags (this Makefile) actually change. Stripping happens at
# link time, so we code-sign the final stripped Mach-O — `build`, `run` and `diag`
# then use this locally-signed binary directly.
#
# Link + sign under .build/, NOT in the repo root: codesign treats a directory that
# holds an Info.plist naming a sibling file as its CFBundleExecutable as a flat
# bundle — exactly what the repo root looks like once ./blescan exists. Signing the
# binary there "signs the bundle" instead: it seals the whole tree into a
# _CodeSignature/CodeResources beside the sources, leaves the embedded plist unbound,
# and fails outright on anything it can't seal (git's fsmonitor socket in .git/).
# Signed as a bare Mach-O the seal lives in the file, so the move keeps it intact.
# The same applies to where the file finally sits: in the repo root, beside
# Info.plist, `codesign --verify ./blescan` fails ("code has no resources but
# signature indicates they must be present"); in bin/ the same bytes verify. That
# matters because ~/.bin/blescan is a symlink, and macOS checks the resolved path.
$(OUT): $(SRC) $(PLIST) Makefile
	@mkdir -p "$(BUILD_DIR)" bin
	$(SWIFTC) $(SWIFTFLAGS) $(RELEASE) $(EMBED_PLIST) $(SRC) -o "$(BUILD_DIR)/$(BINARY)" $(FRAMEWORKS)
	codesign --force --sign $(SIGN) --identifier $(BUNDLE_ID) "$(BUILD_DIR)/$(BINARY)"
	mv -f "$(BUILD_DIR)/$(BINARY)" $@
	@echo "built ./$@ ($$(du -h $@ | cut -f1)), signed as '$(SIGN)'"

# Link, not copy: ~/.bin holds only symlinks. The build rule already signed bin/blescan
# with the bundle id, so the link runs exactly that file. Ad-hoc signing re-keys every
# build, so `make build` and `make install` both reset the Bluetooth grant; a real SIGN
# cert keeps it (see the note above).
install: $(OUT) ## Build, then link ~/.bin/blescan to bin/blescan
	@mkdir -p "$(INSTALL_DIR)"
	ln -sfn "$(CURDIR)/$(OUT)" "$(INSTALL_DIR)/$(BINARY)"
	@echo "linked $(INSTALL_DIR)/$(BINARY) -> $(CURDIR)/$(OUT)"
	@echo
	@echo "one-time permission:"
	@echo "  1. run \`$(BINARY)\` once  (triggers the Bluetooth prompt)"
	@echo "  2. System Settings → Privacy & Security → Bluetooth → enable 'blescan'"
	@echo "     (or click Allow on the prompt)"
	@echo "  3. rerun \`$(BINARY)\`; \`$(BINARY) --diag\` should report state poweredOn"

run: $(OUT) ## Build, then run bin/blescan locally (pass flags via ARGS=…)
	./$(OUT) $(ARGS)

diag: $(OUT) ## Build, then run bin/blescan --diag (report Bluetooth state)
	./$(OUT) --diag

test: ## Build & run the dependency-free core unit tests (no Xcode/XCTest needed)
	@mkdir -p "$(BUILD_DIR)"
	@$(SWIFTC) $(SWIFTFLAGS) -parse-as-library $(TEST_SRC) -o "$(TEST_BIN)"
	@"$(TEST_BIN)"

coverage: ## Run the core tests under coverage; fail unless Core.swift is 100% covered
	@mkdir -p "$(COV_DIR)"
	@$(SWIFTC) $(SWIFTFLAGS) -profile-generate -profile-coverage-mapping -parse-as-library $(TEST_SRC) -o "$(COV_DIR)/tests"
	@LLVM_PROFILE_FILE="$(COV_DIR)/tests.profraw" "$(COV_DIR)/tests"
	@xcrun llvm-profdata merge -sparse "$(COV_DIR)/tests.profraw" -o "$(COV_DIR)/tests.profdata"
	@xcrun llvm-cov report "$(COV_DIR)/tests" -instr-profile="$(COV_DIR)/tests.profdata" $(CORE)
	@bash scripts/check-coverage.sh "$(COV_DIR)/tests" "$(COV_DIR)/tests.profdata" $(CORE)

# Universal binary: each slice is cross-compiled with -target (the macOS SDK carries both),
# the slices are lipo'd together, signed once, zipped with LICENSE + README, and a SHA-256
# manifest is written beside the zip so a download can be checked against what CI built.
# Run by the release workflow on every v* tag.
dist: ## Build a universal (arm64 + x86_64) signed blescan, zip it with LICENSE + README, write SHA256SUMS
	@rm -rf "$(DIST_DIR)"
	@mkdir -p "$(DIST_DIR)"
	@for arch in $(ARCHS); do \
	  echo "$(SWIFTC) $(SWIFTFLAGS) $(RELEASE) $(EMBED_PLIST) -target $$arch-apple-macosx12.0 $(SRC) -o \"$(DIST_DIR)/blescan-$$arch\" $(FRAMEWORKS)"; \
	  $(SWIFTC) $(SWIFTFLAGS) $(RELEASE) $(EMBED_PLIST) -target $$arch-apple-macosx12.0 $(SRC) -o "$(DIST_DIR)/blescan-$$arch" $(FRAMEWORKS) || exit 1; \
	done
	lipo -create $(foreach a,$(ARCHS),"$(DIST_DIR)/blescan-$(a)") -output "$(DIST_DIR)/$(BINARY)"
	codesign --force --sign $(SIGN) --identifier $(BUNDLE_ID) "$(DIST_DIR)/$(BINARY)"
	zip -qj "$(DIST_ZIP)" "$(DIST_DIR)/$(BINARY)" LICENSE README.md
	cd "$(DIST_DIR)" && shasum -a 256 "$(notdir $(DIST_ZIP))" > SHA256SUMS
	@echo "built $(DIST_ZIP) ($$(du -h "$(DIST_ZIP)" | cut -f1)): $$(lipo -archs "$(DIST_DIR)/$(BINARY)")"

# Tagging is the release trigger: .github/workflows/release.yml builds `make dist` on the
# tag and publishes the zip + SHA256SUMS as a GitHub release. Bump CFBundleShortVersionString
# first. HEAD must already be on origin/master: a tag on an unpushed commit would release
# code nobody has reviewed on GitHub.
release: ## Tag v$(VERSION) (from Info.plist) and push the tag — CI builds + publishes the release
	@git diff --quiet && git diff --cached --quiet || { echo "release: commit or stash your changes first"; exit 1; }
	@git fetch -q origin master
	@git merge-base --is-ancestor HEAD origin/master || { echo "release: HEAD is not on origin/master — push it first"; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(VERSION)" >/dev/null || { echo "release: tag v$(VERSION) exists — bump CFBundleShortVersionString in $(PLIST)"; exit 1; }
	git tag -a "v$(VERSION)" -m "blescan v$(VERSION)"
	git push origin "v$(VERSION)"
	@echo "tagged v$(VERSION) — follow the release build with: gh run watch"

# _CodeSignature/ is the stale seal an older Makefile left at the repo root (it signed the
# binary in place, and codesign treated the root as a flat bundle — see the build rule);
# ./blescan is where older Makefiles put the build.
clean: ## Remove local build artifacts, bin/ included (the ~/.bin link dangles until make install)
	rm -rf bin "$(BINARY)" "$(COV_DIR)" "$(DIST_DIR)" "$(TEST_BIN)" _CodeSignature

uninstall: ## Remove the ~/.bin/blescan link (leaves bin/)
	rm -f "$(INSTALL_DIR)/$(BINARY)"
	@echo "removed $(INSTALL_DIR)/$(BINARY)"
	@echo "note: the Bluetooth permission entry remains in System Settings → Privacy & Security."
