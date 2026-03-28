#!/usr/bin/env bash
# Build and run tests with Testing framework path fix for CLI Tools (no Xcode)
set -euo pipefail

FRAMEWORK_DIR="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
TEST_BINARY=".build/arm64-apple-macosx/debug/SusurrusPackageTests.xctest/Contents/MacOS/SusurrusPackageTests"

# Build with Testing framework on the search path
swift build --build-tests \
    -Xswiftc -F -Xswiftc "$FRAMEWORK_DIR"

# Add rpath so the test binary can find Testing.framework at runtime
if [ -f "$TEST_BINARY" ]; then
    install_name_tool -add_rpath "$FRAMEWORK_DIR" "$TEST_BINARY" 2>/dev/null || true
fi

# Run tests
swift test --skip-build
