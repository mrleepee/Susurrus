# Susurrus — Claude Code Instructions

## Project Overview

Susurrus is a macOS menu bar app for streaming voice transcription using WhisperKit. Written in Swift, built with Swift Package Manager.

## Common Commands

```bash
swift build          # Build debug binary (run `make deps` once first in a fresh checkout or worktree — see below)
make deps            # Resolve packages and apply patches/*.patch to them (every make build target runs it)
make dev             # Build and run debug binary directly (shows stdout/stderr in terminal)
make build           # Build release .app bundle
make install         # Install to /Applications
swift test           # Run tests (currently blocked — test files use Swift Testing which isn't in toolchain)
make eval            # Score the golden audio set against the committed baseline (accuracy gate; see docs/eval-harness.md)
```

## Development Workflow

**After making any code fix, always:**
1. Build: `swift build`
2. Kill existing process: `killall Susurrus`
3. Run in dev mode: `make dev`
4. Check debug log: `cat ~/susurrus_debug.log`
5. Test the fix interactively before moving on
6. For any change that can affect transcription accuracy (decoding, prompt, chunking, corrector), run `make eval` — it needs no microphone and gates WER, vocabulary hits, dropped/invented phrases and silence hallucinations

The `make dev` target runs the debug binary directly from `.build/debug/` with stdout visible — much faster than building an .app bundle and essential for catching runtime errors.

**TCC permissions caveat:** the bare debug binary is ad-hoc signed, so its code hash changes on every rebuild and macOS silently revokes Accessibility/Microphone/Automation grants each time. To test anything permission-dependent (auto-paste, mic capture, media pause), use `make install` + `make launch` — the bundle is signed with a stable identity (see `SIGN_IDENTITY` in the Makefile) so grants persist across rebuilds.

**Patched dependency:** `patches/whisperkit-record-permission.patch` fixes a WhisperKit crash on macOS 26 (SIGBUS resuming the async mic-permission continuation on every dictation start). `swift package resolve` checks WhisperKit out unpatched, so build through `make` (or run `make deps` after any resolve). `Package.resolved` is committed so every checkout gets the WhisperKit version the patch and the eval baseline were made against.

## Architecture

- **App entry**: `Sources/Susurrus/SusurrusApp.swift` — SwiftUI `MenuBarExtra` with `@NSApplicationDelegateAdaptor` for eager setup
- **Transcription**: `Sources/SusurrusKit/Services/StreamingTranscriptionService.swift` — WhisperKit `AudioStreamTranscriber` with VAD for capture and live preview; the stop-time decode uses Parakeet (`ParakeetTranscriber.swift`, FluidAudio, Silero VAD pause squeeze) when the model is `parakeet-v2`, else Whisper
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
