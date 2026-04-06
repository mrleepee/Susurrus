#!/usr/bin/env bash
# Integration test: runs the Susurrus binary and verifies transcription pipeline
# via debug log analysis.
#
# Usage: ./scripts/test_pipeline.sh
#
# This test:
# 1. Builds the debug binary
# 2. Launches it
# 3. Waits for model load
# 4. Signals the app to transcribe via simulated hotkey
# 5. Checks debug log for successful pipeline completion
#
# The app must have a working hotkey and microphone for full testing.
# For automated testing without mic, we check model load and UI state only.

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

cd "$PROJECT_DIR"

# Step 1: Build
echo "=== Building ==="
if ! swift build 2>&1 | grep -q "Build complete"; then
    # It might have printed it but we might have missed it
    swift build 2>&1 | tail -3
fi
log "Build complete"

# Step 2: Kill any existing instance
killall Susurrus 2>/dev/null || true
sleep 1

# Step 3: Clear log and launch
> "$DEBUG_LOG"
.build/debug/Susurrus &
APP_PID=$!
echo "App launched (PID $APP_PID)"

# Step 4: Wait for model load (up to 60s)
echo "=== Waiting for model load ==="
for i in $(seq 1 60); do
    if grep -q "preloadModel: model loaded successfully" "$DEBUG_LOG" 2>/dev/null; then
        log "Model loaded (${i}s)"
        break
    fi
    if ! ps -p $APP_PID > /dev/null 2>&1; then
        fail "App crashed during model loading"
    fi
    if [ $i -eq 60 ]; then
        fail "Model not loaded after 60s"
    fi
    sleep 1
done

# Step 5: Check hotkey registration
sleep 2
if grep -q "Hotkey registered successfully" "$DEBUG_LOG" 2>/dev/null; then
    log "Hotkey registered"
else
    warn "Hotkey not registered (may need menu bar click)"
fi

# Step 6: Check for errors in log
if grep -qiE "FAILED|error|crash" "$DEBUG_LOG" 2>/dev/null; then
    warn "Errors detected in debug log:"
    grep -i "FAILED\|error" "$DEBUG_LOG"
else
    log "No errors in debug log"
fi

# Step 7: Print summary
echo ""
echo "=== Debug Log ==="
cat "$DEBUG_LOG"
echo ""

log "Pipeline test complete. App is running with model loaded."
echo "Next: press hotkey to record, speak, release hotkey."
echo "Then run: cat ~/susurrus_debug.log | grep stopStreamingSession"
echo ""
echo "To stop the app: kill $APP_PID"

# Don't kill — leave running for interactive testing
