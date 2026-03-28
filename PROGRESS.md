# Susurrus — Progress Tracker

## Phase 1 — Menu Bar Shell
- [x] R1: App lives in macOS menu bar with no Dock icon
- [x] R2: Menu bar icon reflects state: idle, recording, processing
- [x] R3: Menu provides: Start/Stop Recording, Preferences, Quit

## Phase 2 — Audio Capture & Hotkey
- [x] R4: Capture audio from system default input device
- [x] R5: Request microphone permission on first launch
- [x] R6: Global hotkey triggers start/stop recording system-wide
- [x] R7: Push-to-talk (hold hotkey) is the default recording mode
- [x] R9: 60-second maximum recording duration cap
- [x] R20: User-configurable hotkey

## Phase 3 — On-Device Transcription
- [x] R10: Transcribe audio on-device using WhisperKit
- [x] R11: No audio data leaves the device
- [x] R12: Download whisper-large-v3 model on first launch
- [x] R14: Show progress indicator during transcription
- [ ] R15: Pre-load model at app launch
- [ ] R22: Custom vocabulary list

## Phase 4 — Clipboard & Notification
- [ ] R16: Write transcribed text to NSPasteboard
- [ ] R17: Do not clear existing clipboard until transcription succeeds
- [ ] R18: Display brief success notification when text is ready

## Phase 5 — Preferences
- [ ] R8: Toggle mode available as preference
- [ ] R13: User-selectable model
- [ ] R19: Optional append-to-clipboard mode
- [ ] R21: Override input device from preferences
