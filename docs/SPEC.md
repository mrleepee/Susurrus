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
| R12 | Download selected model on first launch; cache locally in Application Support | Must | 3 |
| R13 | User-selectable model (base default, small, medium, large-v3, large-v3_turbo, distil-large-v3) | Should | 5 |
| R14 | Show progress indicator during transcription | Must | 3 |
| R15 | Pre-load model at app launch; ready within 3 seconds | Should | 3 |
| R16 | Write transcribed text to NSPasteboard | Must | 4 |
| R17 | Do not clear existing clipboard until transcription succeeds | Must | 4 |
| R18 | Display brief success notification when text is ready | Must | 4 |
| R19 | Optional append-to-clipboard mode (off by default) | Could | 5 |
| R20 | Global hotkey set to Option+Cmd+R automatically on first launch; configurable in preferences | Must | 2, 5 |
| R21 | Override input device from preferences | Should | 5 |
| R22 | Custom vocabulary list biases transcription toward user-defined words/phrases | Should | 5 |
| R23 | History panel showing last 200 transcriptions with copy-to-clipboard buttons | Should | 5 |
| R24 | Optional LLM post-processing via MiniMax M2.5 (Anthropic-compatible endpoint) with configurable system prompt | Could | 6 |
| R25 | VAD-based audio chunking for parallel transcription of longer utterances | Should | 7 |
| R26 | Use Apple Neural Engine (ANE) for audio encoding and text decoding compute | Should | 7 |
| R27 | Turbo and distil model variants available as speed/accuracy tradeoff options | Should | 7 |

## Constraints

| Constraint | Detail |
|---|---|
| Platform | macOS 14 (Sonoma) or later |
| Architecture | Apple Silicon only (M1+) |
| Network | Not required for core transcription; one-time model download on first launch; LLM feature requires network |
| Cold start | App ready to record within 3 seconds (model pre-loaded) |
| Transcription latency | Under 3 seconds for utterances up to 30 seconds |
| Privacy | No telemetry; mic audio never persisted to disk; LLM text sent to MiniMax only when feature is enabled |
| Language | Swift 6 |
| UI framework | SwiftUI + MenuBarExtra |
| Audio | AVFoundation |
| Transcription engine | WhisperKit (argmaxinc/WhisperKit) |
| Hotkey | NSEvent global/local monitors for system-wide key capture |
| Clipboard | NSPasteboard |
| LLM | MiniMax M2.5 via Anthropic-compatible API endpoint |
| Distribution | Direct download (.dmg), notarized |

## Not in Scope (v1)

| Item | Justification |
|---|---|
| Auto-insertion into focused text fields | Requires Accessibility API; violates privacy-first design |
| Windows / Intel Mac support | WhisperKit requires Metal on Apple Silicon |
| Full streaming transcription (record-while-transcribe) | Requires major pipeline restructure; deferred to v2 |
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

**Hotkey set automatically on first launch (R20)**
- Given no hotkey has been configured (first launch)
- When the app finishes initialising
- Then Option+Cmd+R is saved as the global hotkey
- And recording is available immediately without user setup
- And the hotkey persists across app restarts

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
| 2.3 | Option+Cmd+R hotkey set on first launch | Fresh install, verify hotkey works without setup |
| 2.4 | Hold hotkey starts recording, release stops | Hold and release, verify state transitions |
| 2.5 | Recording stops at 60 seconds with notification | Record for >60s, verify auto-stop and notification |
| 2.6 | Hotkey works from any foreground app | Focus Safari, press hotkey, verify recording |
| 2.7 | Menu "Start Recording" item triggers recording | Click menu item, verify recording starts |

---

## Phase 3 — On-Device Transcription

> WhisperKit integration for local speech-to-text with model management, VAD chunking, and ANE acceleration.
> Traces to: R10, R11, R12, R14, R15, R22, R25, R26, R27

### Behaviours

**Model downloaded on first launch (R12)**
- Given the app is launched for the first time (no cached model)
- When initialisation begins
- Then the app downloads the selected model (default: `base`) from the WhisperKit model hub
- And a progress indicator shows download status
- And the model is cached in `~/Library/Application Support/Susurrus/`
- And no subsequent launches require a download

**Model pre-loaded at launch (R15)**
- Given a cached model exists
- When the app launches
- Then the WhisperKit pipeline is initialised with the cached model
- And the app is ready to record within 3 seconds of launch

**VAD chunking for parallel transcription (R25)**
- Given a recording has completed and an audio buffer is available
- When the audio is longer than the Whisper window (30s)
- Then the audio is split at silence boundaries using VAD
- And chunks are transcribed in parallel (up to 4 concurrent workers)
- And the results are concatenated into a single transcription

**ANE-accelerated inference (R26)**
- Given WhisperKit is initialising with a model
- When the model is loaded
- Then audio encoding uses Apple Neural Engine (`cpuAndNeuralEngine`)
- And text decoding uses Apple Neural Engine (`cpuAndNeuralEngine`)
- And fallback to GPU/CPU occurs automatically on unsupported devices

**Turbo and distil model variants (R27)**
- Given the user selects `large-v3_turbo` or `distil-large-v3` in Preferences
- When the model is downloaded and loaded
- Then subsequent transcriptions use the selected variant
- And `large-v3_turbo` provides near-large accuracy at higher speed
- And `distil-large-v3` provides a balanced speed/accuracy tradeoff

**Custom vocabulary applied as initial prompt (R22)**
- Given the user has configured a vocabulary list in Preferences
- When transcription begins
- Then the vocabulary words are joined into a prompt string
- And passed as the `initialPrompt` in WhisperKit's `DecodingOptions`
- And the decoder is biased toward recognising those words/phrases

**Transcription processes captured audio (R10)**
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

**No audio persisted to disk (R11)**
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
| 3.5 | Transcription error shows notification, no clipboard change | Feed corrupt/empty audio, verify error handling |
| 3.6 | No audio files written to disk | Monitor filesystem during record/transcribe cycle |
| 3.7 | No network calls during transcription | Monitor network during transcription |
| 3.8 | Custom vocabulary improves recognition of domain terms | Add jargon to vocabulary, speak it, verify transcription accuracy vs. without |
| 3.9 | VAD chunking splits long audio and transcribes in parallel | Record 45s speech, verify transcription completes faster than without chunking |
| 3.10 | ANE compute units used on supported hardware | Verify model loads with cpuAndNeuralEngine compute options |
| 3.11 | large-v3_turbo model downloads and transcribes | Select turbo model, verify download and transcription |

---

## Phase 4 — Clipboard & Notification

> Delivers transcription results to the user via clipboard and visual confirmation.
> Traces to: R16, R17, R18

### Behaviours

**Transcribed text written to clipboard (R16)**
- Given transcription has completed successfully
- When the result text is available
- Then the text is written to `NSPasteboard.general`
- And the user can paste it with `Cmd+V` in any application

**Existing clipboard preserved until success (R17)**
- Given the clipboard contains prior content
- When a recording starts and transcription begins
- Then the clipboard is not modified
- And only on successful transcription is the clipboard updated

**Success notification displayed (R18)**
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

> Settings UI for recording mode, model selection, input device, clipboard behaviour, vocabulary, and history.
> Traces to: R8, R13, R19, R20, R21, R22, R23

### Behaviours

**Preferences window opens from menu**
- Given the app is running
- When the user selects "Preferences..." from the menu
- Then a preferences window opens in the foreground
- And it contains tabs: General, Model, LLM

**Recording mode selection (R8)**
- Given the preferences window is open
- When the user selects "Push-to-talk" or "Toggle"
- Then the recording behaviour changes accordingly
- And the selection persists across app restarts

**Whisper model selection (R13)**
- Given the preferences window is open
- When the user selects a different model (base, small, medium, large-v3, large-v3_turbo, distil-large-v3)
- Then the model is downloaded if not already cached
- And subsequent transcriptions use the selected model

**Input device override (R21)**
- Given the preferences window is open
- When the user selects a specific input device from the dropdown
- Then recordings use that device instead of the system default
- And if the selected device is disconnected, recording falls back to system default

**Custom vocabulary list (R22)**
- Given the preferences window is open
- When the user enters words or phrases in the Vocabulary text field (one per line)
- Then the list is saved and used as the initial prompt for all subsequent transcriptions
- And the list persists across app restarts

**Append-to-clipboard toggle (R19)**
- Given the preferences window is open
- When the user enables "Append to clipboard"
- Then subsequent transcriptions append text to existing clipboard content (newline-separated)
- And the toggle is off by default

**Transcription history panel (R23)**
- Given the app is running and at least one transcription has been completed
- When the user selects "History..." from the menu
- Then a panel opens showing the last 200 transcriptions (most recent first)
- And each entry shows the transcription text and a copy button
- When the user clicks a copy button
- Then that transcription text is copied to the clipboard
- And the history persists across app restarts

**Escape key closes windows**
- Given the Preferences or History window is open
- When the user presses Escape
- Then the window closes
- And any unsaved changes are preserved (auto-save via @AppStorage)

### Verification

| # | Test | Method |
|---|---|---|
| 5.1 | Preferences window opens from menu | Click Preferences, verify window |
| 5.2 | Toggle mode changes recording behaviour | Switch to toggle, verify press/press interaction |
| 5.3 | Model switch downloads if needed, transcription uses new model | Switch model, verify download and output |
| 5.4 | Input device override works | Select specific mic, verify recording source |
| 5.5 | Append mode appends text with newline separator | Enable, transcribe twice, verify clipboard |
| 5.6 | Vocabulary list saved and persists across restarts | Add words, restart, verify list retained |
| 5.7 | History panel shows last 10 transcriptions | Transcribe multiple times, open history, verify entries |
| 5.8 | Copy button in history copies text to clipboard | Click copy, verify clipboard content |
| 5.9 | History persists across app restarts | Transcribe, restart, verify history retained |
| 5.10 | Escape closes Preferences window | Open Preferences, press Escape, verify window closes |
| 5.11 | Escape closes History window | Open History, press Escape, verify window closes |

---

## Phase 6 — LLM Post-Processing

> Optional cloud-based LLM cleanup of transcription text via MiniMax M2.5.
> Traces to: R24

### Behaviours

**LLM post-processing disabled by default**
- Given the app has been freshly installed
- When transcription completes
- Then the raw transcription text goes directly to the clipboard
- And no LLM API call is made

**LLM post-processing enabled via Preferences**
- Given the Preferences window is open
- When the user enables "Enable LLM post-processing"
- Then a system prompt text editor appears
- And the user can customise the prompt that instructs the LLM how to process transcriptions
- And the setting persists across app restarts

**LLM processes transcription text**
- Given LLM post-processing is enabled
- When transcription completes with non-empty text
- Then the text is sent to MiniMax M2.5 via Anthropic-compatible API endpoint
- And the LLM system prompt is included in the request
- And the LLM response (text content block only, excluding thinking blocks) replaces the raw transcription
- And the processed text is copied to the clipboard

**LLM failure falls back to raw transcription**
- Given LLM post-processing is enabled
- When the LLM API call fails or times out
- Then the raw transcription text is copied to the clipboard
- And no error notification is shown (graceful degradation)

**LLM prompt instructs error correction only**
- Given the default LLM system prompt is in use
- When transcription text contains questions or instructions
- Then the LLM corrects errors but does NOT answer questions or respond to content
- And the output is the corrected transcription text only

### Verification

| # | Test | Method |
|---|---|---|
| 6.1 | LLM disabled by default — no API call | Fresh install, transcribe, verify no network call |
| 6.2 | LLM toggle persists across restarts | Enable LLM, restart, verify still enabled |
| 6.3 | LLM processes text when enabled | Enable LLM, transcribe, verify clipboard contains LLM-processed text |
| 6.4 | LLM failure falls back to raw text | Disable network, transcribe with LLM on, verify raw text on clipboard |
| 6.5 | Custom system prompt used | Change prompt, transcribe, verify LLM uses custom prompt |
| 6.6 | LLM does not answer questions in transcription | Dictate a question, verify clipboard contains the question text, not an answer |

---

## Phase 7 — Speed Optimization

> Transcription pipeline optimizations using VAD chunking, ANE acceleration, and faster model variants.
> Traces to: R25, R26, R27

### Behaviours

**VAD-based audio chunking (R25)**
- Given a recording has completed with audio longer than 30 seconds
- When transcription begins
- Then WhisperKit splits the audio at silence boundaries using Voice Activity Detection
- And each chunk is transcribed independently
- And chunks are processed concurrently (up to 4 workers)
- And results are concatenated in order

**ANE-accelerated compute (R26)**
- Given WhisperKit is loading a model
- When the CoreML pipeline is initialised
- Then audio encoding is configured to use `cpuAndNeuralEngine`
- And text decoding is configured to use `cpuAndNeuralEngine`
- And on devices without ANE, the system falls back to GPU/CPU automatically

**Turbo model variant (R27)**
- Given the user has selected `large-v3_turbo` in Preferences
- When a transcription is performed
- Then the turbo variant is used, providing near-large-v3 accuracy with improved speed
- And the model is cached locally after first download

**Distil model variant (R27)**
- Given the user has selected `distil-large-v3` in Preferences
- When a transcription is performed
- Then the distilled variant is used, providing a speed/accuracy balance
- And the model is cached locally after first download

### Verification

| # | Test | Method |
|---|---|---|
| 7.1 | VAD chunking reduces transcription time for longer audio | Record 30s+ speech, compare time with/without chunking |
| 7.2 | ANE compute units configured on model load | Verify WhisperKit init uses cpuAndNeuralEngine options |
| 7.3 | large-v3_turbo downloads and transcribes correctly | Select turbo model, transcribe, verify output quality |
| 7.4 | distil-large-v3 downloads and transcribes correctly | Select distil model, transcribe, verify output quality |
| 7.5 | Concurrent workers process chunks in parallel | Verify transcription uses multiple workers for long audio |

---

## Appendix

### A. Technical Stack Rationale

| Choice | Rationale |
|---|---|
| Swift 6 | Latest Swift with strict concurrency; async/await and Sendable compliance |
| SwiftUI + MenuBarExtra | Native menu bar API; avoids AppKit boilerplate |
| AVFoundation | Direct access to input devices and buffer-based capture |
| WhisperKit | Metal-optimised Whisper inference for Apple Silicon; no cloud dependency; VAD chunking and ANE support |
| NSEvent monitors | System-wide hotkey capture via global/local event monitors |
| NSPasteboard | Standard macOS clipboard API |
| MiniMax M2.5 | Anthropic-compatible LLM endpoint for optional text post-processing |
| Direct .dmg | Avoids App Store review delays; notarization provides security |

### B. Future Considerations (v2+)

- Full streaming transcription (record-while-transcribe via AudioStreamTranscriber)
- Auto-paste via clipboard + simulated `Cmd+V` (opt-in, requires Accessibility)
- Per-app prompt templates ("formal writing mode" for email, "code comment mode" for IDE)
- LFM2-Audio as alternative backend to WhisperKit
- Hotkey reconfiguration UI with key capture
- Vocabulary editor with autocomplete
