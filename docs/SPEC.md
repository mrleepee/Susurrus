# Susurrus — Implementation Spec

## Summary

Susurrus is a macOS menu bar application that captures microphone audio, transcribes it on-device using WhisperKit, and places the result on the clipboard. No cloud, no Accessibility API, no subscription.

Core flow: hold hotkey to talk, release to transcribe, `Cmd+V` to paste.

---

## Requirements

| ID | Requirement | Priority | Phase |
|---|---|---|---|
| R1 | App lives in macOS menu bar with no Dock icon | Must | 1 |
| R2 | Menu bar icon reflects state: idle, recording, processing | Must | 1 |
| R3 | Menu provides: Start/Stop Recording, Preferences, Quit | Must | 1 |
| R4 | Capture audio from system default input device | Must | 2 |
| R5 | Request microphone permission on first launch | Must | 2 |
| R6 | Global hotkey triggers start/stop recording system-wide | Must | 2 |
| R7 | Push-to-talk (hold hotkey) is the default recording mode | Must | 2 |
| R8 | Toggle mode (press to start, press to stop) available as preference | Should | 5 |
| R9 | 60-second maximum recording duration cap | Must | 2 |
| R10 | Transcribe audio on-device using WhisperKit (Metal, Apple Silicon) | Must | 3 |
| R11 | No audio data leaves the device | Must | 3 |
| R12 | Download whisper-large-v3 model on first launch; cache locally | Must | 3 |
| R13 | User-selectable model (large-v3 default, base for speed) | Should | 5 |
| R14 | Show progress indicator during transcription | Must | 3 |
| R15 | Pre-load model at app launch; ready within 3 seconds | Should | 3 |
| R16 | Write transcribed text to NSPasteboard | Must | 4 |
| R17 | Do not clear existing clipboard until transcription succeeds | Must | 4 |
| R18 | Display brief success notification when text is ready | Must | 4 |
| R19 | Optional append-to-clipboard mode (off by default) | Could | 5 |
| R20 | User-configurable hotkey (set at first launch, changeable in preferences) | Must | 2, 5 |
| R21 | Override input device from preferences | Should | 5 |
| R22 | Custom vocabulary list biases transcription toward user-defined words/phrases | Should | 5 |

## Constraints

| Constraint | Detail |
|---|---|
| Platform | macOS 14 (Sonoma) or later |
| Architecture | Apple Silicon only (M1+) |
| Network | Not required for core functionality; one-time model download on first launch |
| Cold start | App ready to record within 3 seconds (model pre-loaded) |
| Transcription latency | Under 3 seconds for utterances up to 30 seconds |
| Privacy | No telemetry, no cloud calls, mic audio never persisted to disk |
| Language | Swift 6 |
| UI framework | SwiftUI + MenuBarExtra |
| Audio | AVFoundation |
| Transcription engine | WhisperKit (argmaxinc/WhisperKit) |
| Hotkey | Carbon `RegisterEventHotKey` or KeyboardShortcuts SPM package |
| Clipboard | NSPasteboard |
| Distribution | Direct download (.dmg), notarized |

## Not in Scope (v1)

| Item | Justification |
|---|---|
| Auto-insertion into focused text fields | Requires Accessibility API; violates privacy-first design |
| LLM cleanup / post-processing | Adds cloud dependency or heavy local compute; deferred to v2 |
| Windows / Intel Mac support | WhisperKit requires Metal on Apple Silicon |
| Real-time streaming transcription | WhisperKit processes complete audio buffers; marginal gain for short utterances |
| Speaker diarization | Not needed for single-user dictation |
| Translation mode | Transcription-only for v1; translation is additive |

---

## Phase 1 — Menu Bar Shell

> App skeleton running as a menu bar-only application with state-driven UI.
> Traces to: R1, R2, R3

### Behaviours

**App appears in menu bar on launch**
- Given the app is launched
- When the system finishes initialising
- Then a static microphone icon appears in the macOS menu bar
- And no Dock icon is shown (`LSUIElement = true`)

**Menu bar icon reflects idle state**
- Given the app is running and not recording or processing
- When the user views the menu bar
- Then the icon is a static microphone glyph

**Menu provides core actions**
- Given the app is running
- When the user clicks the menu bar icon
- Then a menu appears with items: "Start Recording", "Preferences...", "Quit Susurrus"

**Menu reflects recording state**
- Given the user has started recording
- When the user clicks the menu bar icon
- Then "Start Recording" reads "Stop Recording"
- And the menu bar icon is animating (pulsing)

**Menu reflects processing state**
- Given a recording has stopped and transcription is in progress
- When the user views the menu bar
- Then the icon shows a spinner or distinct processing glyph
- And menu interaction is not blocked

### Verification

| # | Test | Method |
|---|---|---|
| 1.1 | App launches with menu bar icon, no Dock icon | Launch app, verify menu bar presence and Dock absence |
| 1.2 | Icon is static in idle state | Visual inspection |
| 1.3 | Clicking icon shows menu with correct items | Click icon, verify menu contents |
| 1.4 | Icon animates during recording | Trigger recording state, verify animation |
| 1.5 | Icon shows processing state during transcription | Trigger processing state, verify indicator |

---

## Phase 2 — Audio Capture & Hotkey

> Microphone access, global hotkey, push-to-talk recording.
> Traces to: R4, R5, R6, R7, R9, R20

### Behaviours

**Microphone permission requested on first launch**
- Given the app has never been launched before
- When the app starts
- Then macOS presents the microphone permission dialog
- And recording is unavailable until permission is granted

**Microphone permission denied gracefully**
- Given the user denies microphone permission
- When the user attempts to record
- Then the app displays a message directing to System Settings > Privacy > Microphone
- And no crash or silent failure occurs

**Hotkey set at first launch**
- Given no hotkey has been configured (first launch)
- When the app finishes initialising
- Then a setup prompt asks the user to record a global hotkey
- And recording is unavailable until a hotkey is set

**Push-to-talk recording (default)**
- Given the app is idle, microphone permission is granted, and a hotkey is configured
- When the user presses and holds the global hotkey
- Then audio recording begins from the system default input device
- And the menu bar icon transitions to the recording state

**Push-to-talk stops on release**
- Given the app is recording in push-to-talk mode
- When the user releases the global hotkey
- Then audio recording stops
- And the captured audio buffer is passed to transcription

**60-second recording cap**
- Given the app is recording
- When 60 seconds of continuous recording elapses
- Then recording stops automatically
- And the captured audio is passed to transcription
- And a notification informs the user that recording was capped

**Hotkey works system-wide**
- Given any application is in the foreground
- When the user presses the configured global hotkey
- Then Susurrus responds (starts/stops recording)
- And the foreground application does not lose focus

**Start Recording menu item works**
- Given the app is idle
- When the user selects "Start Recording" from the menu
- Then recording begins (and must be stopped via hotkey release or menu)

### Verification

| # | Test | Method |
|---|---|---|
| 2.1 | Permission dialog appears on first launch | Fresh install, verify dialog |
| 2.2 | Denied permission shows guidance, no crash | Deny permission, attempt record |
| 2.3 | First launch prompts for hotkey setup | Fresh install, verify setup prompt |
| 2.4 | Hold hotkey starts recording, release stops | Hold and release, verify state transitions |
| 2.5 | Recording stops at 60 seconds with notification | Record for >60s, verify auto-stop and notification |
| 2.6 | Hotkey works from any foreground app | Focus Safari, press hotkey, verify recording |
| 2.7 | Menu "Start Recording" item triggers recording | Click menu item, verify recording starts |

---

## Phase 3 — On-Device Transcription

> WhisperKit integration for local speech-to-text with model management.
> Traces to: R10, R11, R12, R14, R15, R22

### Behaviours

**Model downloaded on first launch**
- Given the app is launched for the first time (no cached model)
- When initialisation begins
- Then the app downloads `whisper-large-v3` from the WhisperKit model hub
- And a progress indicator shows download status
- And the model is cached in `~/Library/Application Support/Susurrus/`
- And no subsequent launches require a download

**Model pre-loaded at launch**
- Given a cached model exists
- When the app launches
- Then the WhisperKit pipeline is initialised with the cached model
- And the app is ready to record within 3 seconds of launch

**Custom vocabulary applied as initial prompt**
- Given the user has configured a vocabulary list in Preferences
- When transcription begins
- Then the vocabulary words are joined into a prompt string
- And passed as the `initialPrompt` in WhisperKit's `DecodingOptions`
- And the decoder is biased toward recognising those words/phrases

**Transcription processes captured audio**
- Given a recording has completed and an audio buffer is available
- When transcription begins
- Then the menu bar icon transitions to the processing state
- And WhisperKit processes the audio buffer locally via Metal
- And no network requests are made during transcription

**Transcription completes with result**
- Given transcription is in progress
- When WhisperKit returns a result
- Then the transcribed text is passed to the clipboard stage
- And the menu bar icon transitions back to idle

**Transcription fails gracefully**
- Given transcription is in progress
- When WhisperKit encounters an error
- Then an error notification is shown to the user
- And the menu bar icon transitions back to idle
- And the existing clipboard is not modified

**No audio persisted to disk**
- Given a recording has been captured
- When transcription completes (success or failure)
- Then the audio buffer is released from memory
- And no audio file is written to disk at any point

### Verification

| # | Test | Method |
|---|---|---|
| 3.1 | First launch downloads model with progress | Delete cached model, launch, verify download + progress |
| 3.2 | Subsequent launches skip download, ready in <3s | Time launch-to-ready with cached model |
| 3.3 | Processing icon shown during transcription | Record and verify icon state change |
| 3.4 | Transcription returns text for clear speech | Speak a known phrase, verify text output |
| 3.8 | Custom vocabulary improves recognition of domain terms | Add jargon to vocabulary, speak it, verify transcription accuracy vs. without |
| 3.5 | Transcription error shows notification, no clipboard change | Feed corrupt/empty audio, verify error handling |
| 3.6 | No audio files written to disk | Monitor filesystem during record/transcribe cycle |
| 3.7 | No network calls during transcription | Monitor network during transcription |

---

## Phase 4 — Clipboard & Notification

> Delivers transcription results to the user via clipboard and visual confirmation.
> Traces to: R16, R17, R18

### Behaviours

**Transcribed text written to clipboard**
- Given transcription has completed successfully
- When the result text is available
- Then the text is written to `NSPasteboard.general`
- And the user can paste it with `Cmd+V` in any application

**Existing clipboard preserved until success**
- Given the clipboard contains prior content
- When a recording starts and transcription begins
- Then the clipboard is not modified
- And only on successful transcription is the clipboard updated

**Success notification displayed**
- Given transcription has completed and the clipboard is updated
- When the result is ready
- Then a brief notification confirms "Copied to clipboard"
- And the notification auto-dismisses within 3 seconds

**Empty transcription handled**
- Given transcription completes but produces empty or whitespace-only text
- When the result is evaluated
- Then the clipboard is not modified
- And a notification informs the user: "No speech detected"

### Verification

| # | Test | Method |
|---|---|---|
| 4.1 | Transcribed text appears on clipboard | Record speech, paste into TextEdit, verify |
| 4.2 | Prior clipboard survives failed/empty transcription | Copy text, trigger failure, verify clipboard unchanged |
| 4.3 | Success notification appears and auto-dismisses | Complete transcription, observe notification timing |
| 4.4 | Empty transcription shows "No speech detected" | Record silence, verify notification and clipboard |

---

## Phase 5 — Preferences

> Settings UI for hotkey, model, input device, recording mode, clipboard behaviour, and vocabulary.
> Traces to: R8, R13, R19, R20, R21, R22

### Behaviours

**Preferences window opens from menu**
- Given the app is running
- When the user selects "Preferences..." from the menu
- Then a preferences window opens
- And it contains sections: Hotkey, Recording Mode, Whisper Model, Input Device, Vocabulary, Clipboard

**Hotkey reconfiguration**
- Given the preferences window is open
- When the user clicks the hotkey field and presses a new key combination
- Then the global hotkey is updated immediately
- And the setting persists across app restarts

**Recording mode selection**
- Given the preferences window is open
- When the user selects "Push-to-talk" or "Toggle"
- Then the recording behaviour changes accordingly
- And the selection persists across app restarts

**Whisper model selection**
- Given the preferences window is open
- When the user selects a different model (e.g., whisper-base)
- Then the model is downloaded if not already cached
- And subsequent transcriptions use the selected model

**Input device override**
- Given the preferences window is open
- When the user selects a specific input device from the dropdown
- Then recordings use that device instead of the system default
- And if the selected device is disconnected, recording falls back to system default

**Custom vocabulary list**
- Given the preferences window is open
- When the user enters words or phrases in the Vocabulary text field (one per line)
- Then the list is saved and used as the initial prompt for all subsequent transcriptions
- And the list persists across app restarts

**Append-to-clipboard toggle**
- Given the preferences window is open
- When the user enables "Append to clipboard"
- Then subsequent transcriptions append text to existing clipboard content (newline-separated)
- And the toggle is off by default

### Verification

| # | Test | Method |
|---|---|---|
| 5.1 | Preferences window opens from menu | Click Preferences, verify window |
| 5.2 | Hotkey change takes effect immediately and persists | Change hotkey, verify, restart, verify |
| 5.3 | Toggle mode changes recording behaviour | Switch to toggle, verify press/press interaction |
| 5.4 | Model switch downloads if needed, transcription uses new model | Switch model, verify download and output |
| 5.5 | Input device override works | Select specific mic, verify recording source |
| 5.6 | Append mode appends text with newline separator | Enable, transcribe twice, verify clipboard |
| 5.7 | Vocabulary list saved and persists across restarts | Add words, restart, verify list retained |

---

## Appendix

### A. Technical Stack Rationale

| Choice | Rationale |
|---|---|
| Swift 6 | Latest Swift with strict concurrency; async/await and Sendable compliance |
| SwiftUI + MenuBarExtra | Native menu bar API; avoids AppKit boilerplate |
| AVFoundation | Direct access to input devices and buffer-based capture |
| WhisperKit | Metal-optimised Whisper inference for Apple Silicon; no cloud dependency |
| Carbon RegisterEventHotKey | Only reliable mechanism for system-wide hotkeys on macOS |
| NSPasteboard | Standard macOS clipboard API |
| Direct .dmg | Avoids App Store review delays; notarization provides security |

### B. Future Considerations (v2+)

- Optional LLM cleanup pass via configured API (Claude, local Ollama, etc.)
- Auto-paste via clipboard + simulated `Cmd+V` (opt-in, requires Accessibility)
- Per-app prompt templates ("formal writing mode" for email, "code comment mode" for IDE)
- LFM2-Audio as alternative backend to WhisperKit
- Menu bar transcript history (last N clips)
