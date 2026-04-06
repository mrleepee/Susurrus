# Susurrus — Claude Code Instructions

## Project Overview

Susurrus is a macOS menu bar app for streaming voice transcription using WhisperKit. Written in Swift, built with Swift Package Manager.

## Common Commands

```bash
swift build          # Build debug binary
make dev             # Build and run debug binary directly (shows stdout/stderr in terminal)
make build           # Build release .app bundle
make install         # Install to /Applications
swift test           # Run tests (currently blocked — test files use Swift Testing which isn't in toolchain)
```

## Development Workflow

**After making any code fix, always:**
1. Build: `swift build`
2. Kill existing process: `killall Susurrus`
3. Run in dev mode: `make dev`
4. Check debug log: `cat ~/susurrus_debug.log`
5. Test the fix interactively before moving on

The `make dev` target runs the debug binary directly from `.build/debug/` with stdout visible — much faster than building an .app bundle and essential for catching runtime errors.

## Architecture

- **App entry**: `Sources/Susurrus/SusurrusApp.swift` — SwiftUI `MenuBarExtra` with `@NSApplicationDelegateAdaptor` for eager setup
- **Transcription**: `Sources/SusurrusKit/Services/StreamingTranscriptionService.swift` — WhisperKit `AudioStreamTranscriber` with VAD
- **Services**: All in `Sources/SusurrusKit/Services/` — follow the protocol in `Sources/SusurrusKit/Protocols/`
- **Models**: `Sources/SusurrusKit/Models/`
- **Views**: `Sources/Susurrus/` — `MenuBarView.swift`, `PreferencesView.swift`, `HistoryView.swift`

## Key Patterns

- **Struct self capture**: `SusurrusApp` is a struct — never capture `self` in escaping closures (causes use-after-free). Instead capture reference-type locals: `let state = appState`, `let streaming = streamingService`, etc.
- **Logging**: `traceApp()` writes to `~/susurrus_debug.log` — the only reliable way to see output from a menu bar app. Use it liberally.
- **Activation policy**: App uses `.accessory` (menu bar only, no dock). Temporarily switches to `.regular` when opening windows (History, Preferences), reverts on window close.

## Platform Requirements

- macOS 14+ (Sonoma)
- Swift Tools Version 6.2
- Dependencies: WhisperKit 0.9.4+
