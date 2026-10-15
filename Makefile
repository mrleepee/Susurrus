FRAMEWORK_DIR := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
APP_NAME := Susurrus
APP_BUNDLE := build/$(APP_NAME).app
INSTALL_DIR := /Applications

# Stable codesigning identity. Ad-hoc signing ("-") produces a new code hash on
# every build, which makes macOS TCC silently revoke Accessibility/Microphone/
# Automation grants after each rebuild. Prefer a real identity from the keychain;
# override with: make bundle SIGN_IDENTITY="My Cert Name"
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -E -o '"(Apple Development|Developer ID Application|Susurrus)[^"]*"' \
	| head -1 | tr -d '"')

.PHONY: test build clean perf release bundle install uninstall launch eval-build eval-golden eval eval-baseline eval-compare

build:
	swift build

# Run debug binary directly — stdout/stderr visible in terminal, no install needed
dev: build
	-killall $(APP_NAME) 2>/dev/null || true
	@echo "Running from .build/debug/$(APP_NAME) — Ctrl+C to quit"
	.build/debug/$(APP_NAME)

release:
	swift build -c release

bundle: release
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp .build/release/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	cp Info.plist $(APP_BUNDLE)/Contents/
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/
	# Never ship .env or any secrets in the bundle — API keys belong in macOS Keychain only
	@if [ -n "$(SIGN_IDENTITY)" ]; then \
		echo "Signing with stable identity: $(SIGN_IDENTITY)"; \
		codesign --force --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE); \
	else \
		echo "WARNING: no codesigning identity found — signing ad-hoc."; \
		echo "         TCC grants (Accessibility/Microphone) will reset on every rebuild."; \
		echo "         Create one in Keychain Access: Certificate Assistant > Create a Certificate,"; \
		echo "         name 'Susurrus Dev', type 'Code Signing', then rebuild."; \
		codesign --force --sign - $(APP_BUNDLE); \
	fi
	@echo "Built $(APP_BUNDLE)"

install: bundle
	@# Kill running instance if any
	-killall $(APP_NAME) 2>/dev/null || true
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -r $(APP_BUNDLE) $(INSTALL_DIR)/
	@# Force Launch Services to re-scan the new copy. Without this it can
	@# keep serving a stale registration (wrong mod date, or a lingering
	@# launch-disabled flag from before code-signing was stabilized),
	@# which is what kept the app from surfacing in Spotlight/Siri search.
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f $(INSTALL_DIR)/$(APP_NAME).app
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

launch:
	open $(INSTALL_DIR)/$(APP_NAME).app

uninstall:
	-killall $(APP_NAME) 2>/dev/null || true
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	@echo "Uninstalled $(APP_NAME)"

test:
	swift build --build-tests \
		-Xswiftc -F -Xswiftc $(FRAMEWORK_DIR) \
		-Xlinker -rpath -Xlinker $(FRAMEWORK_DIR)
	swift test --skip-build

perf:
	swift build --build-tests \
		-Xswiftc -F -Xswiftc $(FRAMEWORK_DIR) \
		-Xlinker -rpath -Xlinker $(FRAMEWORK_DIR)
	swift test --skip-build --filter TranscriptionPerfTests

clean:
	swift package clean
	rm -rf build

# --- Offline accuracy harness (docs/eval-harness.md) ---
GOLDEN := Tests/Fixtures/eval/golden
EVAL := .build/release/susurrus-eval
EVAL_CONFIG ?= $(GOLDEN)/config.production.json
EVAL_OUT ?= eval-runs/$(shell date +%Y%m%d-%H%M%S).json

eval-build:
	swift build -c release --product susurrus-eval

# Render the golden scripts to audio (regenerate after a macOS update changes voices).
eval-golden: eval-build
	$(EVAL) synth --scripts $(GOLDEN)/scripts.jsonl --out $(GOLDEN) --voices "Daniel,Flo" --variants clean,paused,noisy

# Score the golden set and gate against the committed baseline.
eval: eval-build
	@test -f $(GOLDEN)/manifest.jsonl || $(MAKE) eval-golden
	@mkdir -p eval-runs
	$(EVAL) run --corpus $(GOLDEN) --config $(EVAL_CONFIG) --out $(EVAL_OUT)
	$(EVAL) compare $(GOLDEN)/baseline.json $(EVAL_OUT) --gate

# Deliberately replace the committed baseline.
eval-baseline: eval-build
	@test -f $(GOLDEN)/manifest.jsonl || $(MAKE) eval-golden
	$(EVAL) run --corpus $(GOLDEN) --config $(EVAL_CONFIG) --out $(GOLDEN)/baseline.json

eval-compare: eval-build
	$(EVAL) compare $(A) $(B)
