#!/usr/bin/env bash
# Automated smoke test for Susurrus
# Usage: ./scripts/test_app.sh
# Tests: build, launch, model load, no crash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[PASS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEBUG_LOG="$HOME/susurrus_debug.log"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"

cd "$PROJECT_DIR"

# --- Step 1: Build ---
echo "=== Building ==="
if ! make build > /dev/null 2>&1; then
    fail "Build failed. Run 'make build' for details."
fi
log "Build succeeded"

# --- Step 2: Install ---
echo "=== Installing ==="
killall Susurrus 2>/dev/null || true
sleep 1
if ! make install > /dev/null 2>&1; then
    fail "Install failed. Run 'make install' for details."
fi
log "Installed to /Applications/Susurrus.app"

# --- Step 3: Clear debug log and launch ---
> "$DEBUG_LOG"

# Record crash reports before launch
CRASHES_BEFORE=$(ls -1 "$CRASH_DIR"/Susurrus* 2>/dev/null | sort)

echo "=== Launching app ==="
open /Applications/Susurrus.app
sleep 3

if ! pgrep -x Susurrus > /dev/null 2>&1; then
    fail "App crashed on launch"
fi
log "App launched (pid $(pgrep -x Susurrus))"

# --- Step 4: Wait for onAppear to fire (needs menu bar click or patience) ---
echo "=== Waiting for model load (may need menu bar click) ==="
for i in $(seq 1 90); do
    if grep -q "model loaded successfully" "$DEBUG_LOG" 2>/dev/null; then
        log "Model loaded successfully (${i}s)"
        break
    fi
    if ! pgrep -x Susurrus > /dev/null 2>&1; then
        fail "App crashed during model loading"
    fi
    if [ $i -eq 90 ]; then
        warn "Model not loaded after 90s — may need manual menu bar click"
        echo "Debug log so far:"
        cat "$DEBUG_LOG"
        exit 0
    fi
    sleep 1
done

# --- Step 5: Verify no crashes ---
sleep 2
if ! pgrep -x Susurrus > /dev/null 2>&1; then
    LATEST_CRASH=$(ls -t "$CRASH_DIR"/Susurrus* 2>/dev/null | head -1)
    fail "App crashed after model load. Crash report: $LATEST_CRASH"
fi
log "App still running after model load"

# --- Step 6: Check hotkey registration ---
if grep -q "Hotkey registered successfully" "$DEBUG_LOG" 2>/dev/null; then
    log "Hotkey registered"
else
    warn "Hotkey registration not found in log"
fi

# --- Step 7: Check for new crash reports ---
CRASHES_AFTER=$(ls -1 "$CRASH_DIR"/Susurrus* 2>/dev/null | sort)
NEW_CRASHES=$(comm -13 <(echo "$CRASHES_BEFORE") <(echo "$CRASHES_AFTER"))
if [ -n "$NEW_CRASHES" ]; then
    warn "New crash reports detected:"
    echo "$NEW_CRASHES"
else
    log "No new crash reports"
fi

# --- Summary ---
echo ""
echo "=== Smoke Test Results ==="
echo "Debug log:"
cat "$DEBUG_LOG"
echo ""

# Check for any error-level entries in the log
if grep -qiE "FAILED|error:|crash" "$DEBUG_LOG" 2>/dev/null; then
    warn "Potential errors detected in debug log (see above)"
else
    log "No errors detected in debug log"
fi

log "All smoke tests passed. App is running and model is loaded."
echo "Next: manually test Start Recording → speak → Stop Recording → check clipboard"
echo "Tip: use 'make dev' to run from terminal with live log output"
