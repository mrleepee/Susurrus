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
| R28 | Streaming transcription with live interim text displayed in a floating overlay | Must | 8 |
| R29 | Overlay shows confirmed text in primary color and unconfirmed text in secondary color | Should | 8 |
| R30 | Overlay does not steal focus from the active application | Must | 8 |
| R31 | LLM automatically assigns each transcription to the most relevant notebook based on content | Should | 9 |
| R32 | Notebook entries store original ASR text and edited text for Whisper training pairs | Must | 9 |

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
| LLM | llama.cpp server with Gemma 4 E2B (local, offline); MiniMax M2.5 (cloud fallback) |
| Distribution | Direct download (.dmg), notarized |

## Not in Scope (v1)

| Item | Justification |
|---|---|
| Auto-insertion into focused text fields | Requires Accessibility API; violates privacy-first design |
| Windows / Intel Mac support | WhisperKit requires Metal on Apple Silicon |
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

## Phase 8 — Streaming Transcription

> Real-time transcription with live interim text in a floating overlay, replacing batch processing.
> Traces to: R28, R29, R30

### Behaviours

**Streaming overlay appears on hotkey press**
- Given model loaded and mic permission granted
- When the user presses the global hotkey
- Then a floating overlay window appears near the menu bar icon
- And `AudioStreamTranscriber` starts capturing audio
- And `RecordingState` is `.streaming`

**Live text updates in overlay (R28, R29)**
- Given streaming is active
- When `AudioStreamTranscriber` delivers an interim state change
- Then the overlay displays confirmed text in primary color
- And unconfirmed/in-flight text is shown in secondary color
- And the overlay does not steal focus from the active application (R30)

**Streaming stops on hotkey release**
- Given streaming is active with confirmed text
- When the user releases the hotkey
- Then `RecordingState` transitions to `.finalizing`
- And the overlay fades out over 300ms
- And the final text is extracted from confirmed + unconfirmed segments
- And text is written to clipboard, auto-pasted, saved to history, and appended to active notebook
- And `RecordingState` transitions to `.idle`

**Streaming flush catches trailing words**
- Given streaming is active and the user releases the hotkey
- When `stopStreamTranscription()` is called but `finalTextEmitted` is false
- Then a 200ms flush delay allows pending audio chunks to finish processing
- And the trailing words are captured in the final text

**No speech detected during streaming**
- Given streaming is active but no speech is detected
- When streaming stops
- Then a "No speech detected" notification is shown
- And the clipboard is untouched
- And `RecordingState` returns to `.idle`

**VAD parameters tuned for minimal word loss**
- Given streaming is active
- When the user speaks with varying volume
- Then `silenceThreshold` is set to `0.1` (catches quiet speech)
- And `requiredSegmentsForConfirmation` is `1` (first words confirmed immediately)
- And VAD does not cut off trailing words

**60-second cap still enforced during streaming**
- Given streaming is active for 60 seconds
- When the duration timer fires
- Then streaming stops, `wasDurationCapped` is set, final text is processed

### Verification

| # | Test | Method |
|---|---|---|
| 8.1 | Overlay appears on hotkey press with live text | Press hotkey, speak, verify overlay shows text in real-time |
| 8.2 | Confirmed vs unconfirmed text colors differ | Observe overlay during streaming |
| 8.3 | Overlay does not steal focus | Stream text while typing in another app |
| 8.4 | Final text on clipboard after release | Speak, release hotkey, paste into TextEdit |
| 8.5 | Trailing words not lost | Speak a sentence, release hotkey immediately, verify complete text |
| 8.6 | No speech detected shows notification | Record silence, verify notification |
| 8.7 | 60-second cap stops streaming with text | Stream for 60s+, verify auto-stop and text capture |

---

## Phase 9 — LLM-Driven Notebook Assignment & Edit Tracking

> After transcription, the LLM classifies which notebook the text belongs to based on content and existing notebook context. Notebook entries store original ASR text alongside edits for Whisper fine-tuning.
> Traces to: R31, R32

### Behaviours

**LLM classifies transcription into a notebook (R31)**
- Given LLM is enabled and at least one notebook exists
- When transcription completes with non-empty text
- Then the LLM receives the transcription text and a list of all notebooks with their recent context
- And the LLM returns the ID of the most relevant notebook, or `nil` if no match
- And the transcription is appended to the selected notebook
- And the text is also copied to clipboard (dual output preserved)

**LLM notebook assignment prompt is separate from cleanup prompt**
- Given LLM notebook assignment is enabled
- When the classification request is made
- Then a dedicated system prompt instructs the LLM to classify only (not rewrite)
- And the prompt includes each notebook's name and last N entries as context
- And the LLM returns a JSON response with `{"notebook_id": "<uuid>" | null}`

**Manual notebook selection overrides LLM assignment**
- Given a notebook is manually selected as active in the menu bar
- When transcription completes
- Then the text is appended to the manually selected notebook
- And LLM notebook assignment is skipped

**LLM assignment runs when no notebook is active**
- Given no notebook is manually selected (active notebook is "None")
- When transcription completes with non-empty text
- Then the LLM classification runs to determine the best notebook
- And if the LLM returns a notebook ID, the text is appended to that notebook

**Notebook entry stores original ASR text (R32)**
- Given a transcription is appended to a notebook
- When the entry is created
- Then `text` holds the final text (after LLM cleanup if applicable)
- And `originalText` is nil (not yet edited)
- And `date` is the transcription timestamp

**Notebook entry preserves original on edit**
- Given a notebook entry exists with `text` = "Data bid is great" and `originalText` = nil
- When the user edits the text to "DataBid is great"
- Then `text` is updated to "DataBid is great"
- And `originalText` is set to "Data bid is great" (captured on first edit)
- And `editedDate` is set to the current time

**Edited entries show visual diff**
- Given a notebook entry has been edited
- When the entry is displayed in the notebook UI
- Then an orange "edited" badge appears next to the timestamp
- And the diff is shown below the text in monospace: `{Data bid → DataBid} is great`

**Entries sorted newest first**
- Given a notebook has multiple entries
- When the notebook detail view is displayed
- Then entries are listed in descending date order (newest at top)

**LLM notebook assignment failure is non-blocking**
- Given LLM notebook assignment is enabled
- When the LLM classification call fails or times out
- Then the transcription is still copied to clipboard
- And no notebook assignment is made
- And no error notification is shown (graceful degradation)

### Verification

| # | Test | Method |
|---|---|---|
| 9.1 | LLM assigns transcription to correct notebook | Create notebooks "ACS" and "Susurrus", transcribe about ACS topics, verify entry appears in ACS notebook |
| 9.2 | LLM returns null for irrelevant transcription | Transcribe casual conversation, verify no notebook assignment |
| 9.3 | Manual selection overrides LLM | Select "Susurrus" in menu bar, transcribe ACS content, verify entry in Susurrus notebook |
| 9.4 | Original text preserved on edit | Edit notebook entry, verify originalText is set and diff is displayed |
| 9.5 | Entries sorted newest first | Add entries at different times, verify sort order |
| 9.6 | LLM failure doesn't block clipboard | Disable network, transcribe with LLM on, verify text still on clipboard |
| 9.7 | Training pairs extractable | Get all entries where originalText != nil, verify (originalText → text) pairs |

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

- ~~Full streaming transcription (record-while-transcribe via AudioStreamTranscriber)~~ ✅ Shipped in v1.1
- ~~Auto-paste via clipboard + simulated `Cmd+V` (opt-in, requires Accessibility)~~ ✅ Shipped in v1.1
- ~~Hotkey reconfiguration UI with key capture~~ ✅ Shipped in v1.1
- ~~Transcription history panel~~ ✅ Shipped in v1.1
- ~~LLM post-processing~~ ✅ Shipped in v1.1 (cloud-based via MiniMax M2.5)
- ~~Streaming overlay with interim text~~ ✅ Shipped in v1.1
- ~~Ontological vocabulary (F9)~~ ✅ Shipped
- ~~Edit-driven learning (F10)~~ ✅ Shipped
- ~~Project notebooks with dual output (F11)~~ ✅ Shipped

#### Competitive Features (inspired by Wispr Flow)

| # | Feature | Description | Priority | Dependencies |
|---|---------|-------------|----------|--------------|
| F1 | Context-aware spelling | Read surrounding text from the focused app's text field via Accessibility APIs; extract proper nouns and domain terms; inject into Whisper's vocabulary prompt before transcription starts. Makes uncommon names spell correctly without manual vocabulary entry. | High | Accessibility API (already used for auto-paste) |
| F2 | AI cleanup as default | Make LLM post-processing the default experience (not opt-in). Whisper output is inherently messy — filler words, bad punctuation, false starts. AI cleanup should "just work" with a sensible default prompt. User can disable or customise. | High | Local llama.cpp + Gemma 4 E2B (validated: 0.58s for 10s speech, fully offline) |
| F3 | Voice snippets / shortcuts | User-defined voice shortcuts that expand to pre-saved text blocks. E.g. "insert signature" → full email signature, "insert address" → home address. Triggered by a keyword phrase detected in the transcription. | Medium | None (post-processing layer) |
| F4 | Whispering mode | Optimise for quiet/whispered input by adjusting Whisper's silence threshold and energy detection. Allows use in quiet environments without disturbing others. | Medium | AudioProcessor parameter tuning |
| F5 | Per-app prompt templates | Detect the frontmost application and apply context-appropriate LLM prompts automatically. "Formal writing" for email clients, "code comment" for IDEs, "casual" for messaging apps. | Medium | Accessibility API for frontmost app detection, local LLM |
| F6 | On-device LLM via Gemma 4 | Replace cloud LLM with local Gemma 4 E2B via llama.cpp for fully offline, private text post-processing. Eliminates latency, network dependency, and subscription cost. | Medium | llama.cpp server, ~3-4 GB RAM (Q4_K_S quantization) |
| F7 | Multi-language transcription | Support language selection in Whisper DecodingOptions. Gemma 3 supports 140+ languages and could auto-detect language for post-processing. | Low | Whisper language config, UI for language picker |
| F8 | Vocabulary editor with autocomplete | Enhanced vocabulary UI that suggests completions from a built-in dictionary and the user's transcription history. Reduces friction of adding new terms. | Low | None |
| F9 | Ontological vocabulary | Categorise vocabulary entries into typed groups: People, Places, Projects, Technical Terms, Products, Acronyms, etc. Categories enable context-aware injection — ASR bias (promptTokens) gets proper nouns and technical terms, while LLM cleanup prompt gets category context ("DataBid is a product name, always capitalize"). Supports user-defined categories. | High | Vocabulary model refactor, Preferences UI |
| F10 | Edit-driven learning | When users edit transcriptions in the history panel, store correction pairs (raw → edited). Inject the most relevant pairs into the LLM cleanup prompt as few-shot examples. Captures user-specific preferences (capitalisation, filler word tolerance, style) without fine-tuning. Auto-extracts proper noun corrections back into vocabulary. | High | History edit UI, correction pair storage, prompt engineering |
| F11 | Project notebooks | Named notebooks that accumulate transcriptions as project context. Dual output: text always goes to clipboard (primary workflow preserved), and also appends to the active notebook. Notebook content is injected into the LLM cleanup prompt as domain context. User edits notebook entries to refine context. Menu bar has notebook selector. Preferences has notebook management (create, rename, delete, export). | High | Notebook data model, Preferences UI, Menu bar UI, LLM prompt integration |
| F12 | LLM-driven notebook assignment | After transcription completes, the LLM classifies the text against all existing notebooks and assigns it to the most relevant one. Eliminates manual notebook switching. Uses a dedicated classification prompt that receives notebook names and recent context, returns a notebook ID or null. Manual selection overrides. Failed classification falls back gracefully. | High | LLM integration, notebook context extraction |

#### Context-Aware Spelling — Technical Detail

The highest-impact competitive feature. Implementation path:

1. **Before streaming starts**: Use `AXUIElementCopyAttributeValue(AXUIElement.systemWide, kAXFocusedUIElement)` to get the focused text field
2. **Read text content**: `AXUIElementCopyAttributeValue(focusedElement, kAXValueAttribute)` returns the full text
3. **Extract proper nouns**: Simple heuristic — capitalised words not at sentence start, words matching NER patterns (person names, org names, product names)
4. **Inject into vocabulary prompt**: `contextExtracted + " " + vocabularyManager.promptString()` → passed to `DecodingOptions.promptTokens`
5. **Fallback**: If AX read fails (terminal, Electron apps with broken a11y, password fields), use static vocabulary only

**Limitations**: 50-200ms latency for complex documents, not all apps expose text via accessibility, requires Accessibility permission (already granted for auto-paste).

#### On-Device LLM — Architecture Decision: WhisperKit + llama.cpp/Gemma 4 E2B

**Decision**: Hybrid architecture using WhisperKit for ASR + llama.cpp server with Gemma 4 E2B for text cleanup.

**Benchmark results (M2 Pro 32GB, 2026-04-05):**

##### Gemma 4 MLX — Direct Audio Transcription (mlx-vlm)

| Model | 10s audio (hot) | 20s audio (hot) | Memory | Throughput | Audio cap |
|-------|-----------------|-----------------|--------|------------|-----------|
| E2B (2.3B) | 1.09s | 2.09s | ~10.7 GB | 35 tok/s | ~20s hard limit |
| E4B (4.5B) | 1.95s | 3.97s | ~16.4 GB | 18 tok/s | ~20s hard limit |

Key finding: Both models have a hard audio context cap at ~750 audio tokens (~20-25s). Content beyond this is silently truncated. This makes Gemma 4 unsuitable as a primary ASR engine for dictation use cases.

Combined ASR + cleanup in a single prompt works but adds no speed benefit over separate steps, and the cleanup quality from E2B is poor (leaves fillers, false starts).

##### llama.cpp Server — Text Cleanup (E2B Q4_K_S, `--reasoning off`)

| Input length | Gen tokens | Latency (best) | tok/s |
|-------------|-----------|----------------|-------|
| 10s speech (~40 words) | 21 tok | **0.58s** | 34.5 |
| 20s speech (~80 words) | 58 tok | **1.39s** | 41.3 |
| 60s speech (~180 words) | 140 tok | **3.24s** | 43.0 |

Server startup: 3.7s (model cached). Memory: ~3-4 GB (Q4_K_S quantization).

Concurrency scales to ~110 tok/s with 4 workers. Metal GPU cannot run parallel inferences on a single device — concurrency is request-level interleaving.

**Critical**: Gemma 4 IT enables chain-of-thought thinking by default, which generates hundreds of hidden tokens before producing output. Use `--reasoning off` to disable. Without this flag, cleanup takes 8-20s instead of 0.5-3s.

##### Why not Gemma 4 as primary ASR

| | WhisperKit streaming | Gemma 4 E2B |
|---|---|---|
| Perceived latency | ~0s (live text) | 1-2s post-recording |
| Max audio length | Unlimited (VAD chunking) | ~20s hard cap |
| Streaming | Yes (interim results) | No (batch only) |
| Memory | ~2-4 GB | ~10.7 GB |
| Metal parallelism | Yes (concurrent workers) | No (command buffer conflict) |

##### Recommended Architecture

```
User speaks → WhisperKit AudioStreamTranscriber (streaming ASR)
                    ↓
           Raw transcription text
                    ↓
    llama.cpp server (localhost:8321, Gemma 4 E2B Q4_K_S)
           --reasoning off --port 8321 -ngl 99
                    ↓
           Cleaned text → clipboard → auto-paste
```

- **WhisperKit**: streaming ASR with interim results, handles any length, ~2-4 GB
- **llama.cpp/Gemma 4 E2B**: local text cleanup, ~3-4 GB, sub-second for typical utterances
- **Total memory**: ~6-8 GB for the full pipeline
- **Fully offline**: no network, no API key, no subscription
- **Graceful degradation**: if llama.cpp server unavailable, raw WhisperKit text goes to clipboard

**Future path: E4B as unified ASR + LLM**

Gemma 4 E4B/E2B have native audio input via a Conformer-based encoder (128-bin mel spectrogram, 16kHz). If Google releases models with longer audio context (>30s), a future pipeline could be:
- Current: Audio → WhisperKit (ASR) → text → llama.cpp Gemma 4 (cleanup) → clipboard
- Future: Audio → Gemma 4 (ASR + cleanup in one model) → clipboard

This would eliminate WhisperKit dependency entirely. Blocked on the ~750 audio token context limit.

#### Ontological Vocabulary — Technical Detail (F9)

Vocabulary entries are typed, enabling smarter injection into both ASR and LLM pipelines.

**Data model:**

```
VocabularyEntry {
    term: String          // e.g. "DataBid"
    category: VocabCategory
    notes: String?        // optional context, e.g. "client's product"
}

VocabCategory: enum {
    Person        // Names — inject into promptTokens + tell LLM "capitalize exactly as shown"
    Place         // Locations — inject into promptTokens
    Project       // Project codenames — inject into promptTokens + tell LLM context
    Product       // Product/company names — inject + "always capitalize"
    Technical     // Jargon, acronyms — inject into promptTokens
    Acronym       // Short forms — inject + expansion hint for LLM
    Custom        // User-defined category with label
}
```

**Injection behaviour by pipeline stage:**

1. **WhisperKit (ASR)**: All categories contribute to `DecodingOptions.promptTokens` — the model just needs to see the words to bias recognition. No category distinction needed at this stage.

2. **LLM cleanup (llama.cpp/Gemma 4)**: Category context is injected into the cleanup prompt to guide post-processing:
   - `"DataBid" is a product name — always capitalize as shown`
   - `"ACS" is an acronym for "Advanced Client Services" — expand on first use if appropriate`
   - `"Clay" is a project codename — treat as proper noun`

**UI**: Preferences → Vocabulary tab shows a table with columns [Term | Category ▼ | Notes]. Category is a dropdown. Add button with autocomplete from transcription history.

#### Edit-Driven Learning — Technical Detail (F10)

When a user edits a transcription in the history panel, the system captures the correction pair and uses it to improve future LLM cleanup.

**Flow:**

1. User opens history entry, edits text (e.g. changes "so I think we need to get the databid sow signed" → "We need to get the DataBid SOW signed")
2. System computes a lightweight diff (not character-level — sentence or clause level)
3. Stores as a `CorrectionPair(raw, edited, timestamp)`
4. Correction pairs are persisted in Application Support alongside history

**How correction pairs improve cleanup:**

The LLM cleanup prompt includes the most relevant recent corrections as few-shot examples:

```
System: You clean up transcriptions. Follow the user's demonstrated preferences.

Examples of previous corrections by this user:
- Raw: "so I think we need to get the databid sow signed"
  Fixed: "We need to get the DataBid SOW signed."

- Raw: "um ACS had with databid um had ended"
  Fixed: "ACS had with DataBid had ended."

Now clean up this transcription:
{new raw text}
```

**Why this works better than fine-tuning:**
- Instant feedback loop — no retraining, the next transcription immediately benefits
- User can inspect and delete correction pairs they disagree with
- Naturally captures style preferences (terse vs verbose, Oxford comma, capitalisation patterns)
- Proper noun corrections auto-extracted: if a user consistently capitalises "DataBid", the system can suggest adding it to vocabulary as a Product

**Implementation notes:**
- Cap stored correction pairs at ~50 most recent to keep prompt size manageable
- Select the 3-5 most relevant pairs for each cleanup request (similarity matching on shared vocabulary/terms)
- Relevance scoring: number of shared vocabulary terms between correction pair and current transcription
- Auto-prune pairs older than 90 days or when user deletes history entries
- F10 depends on F9 for the auto-extraction of vocabulary from edits

#### Project Notebooks — Technical Detail (F11)

Named notebooks that accumulate transcriptions as project-specific context. The primary clipboard workflow is never disrupted — text always goes to clipboard, and optionally to the active notebook.

**Data model:**

```
Notebook {
    id: UUID
    name: String              // e.g. "ACS", "Susurrus", "Personal"
    createdAt: Date
    entries: [NotebookEntry]
}

NotebookEntry {
    id: UUID
    text: String              // current/latest text (after LLM cleanup + user edits)
    originalText: String?     // original ASR text before first edit (nil if never edited)
    date: Date
    editedDate: Date?         // when last manually edited (nil if never edited)
}
```

Persisted in `~/Library/Application Support/Susurrus/Notebooks/` as JSON files.

**Dual output flow:**

1. User presses hotkey, speaks, releases
2. WhisperKit produces raw text → LLM cleanup (with notebook context injected)
3. Cleaned text → **clipboard** (always, primary workflow)
4. Cleaned text → **assigned notebook** (LLM determines which, or manual selection)
5. Auto-paste fires as usual

The clipboard workflow is identical whether or not a notebook is active. The notebook is purely additive.

**Menu bar integration:**

```
┌─────────────────────────────┐
│ 🔴 Stop Recording           │  (or "Start Recording" when idle)
│ ─────────────────────────── │
│ Notebook: ▸ Auto            │  ← submenu with notebook list
│   ● Auto (LLM assigns)      │  ← default: LLM decides
│   ○ None (clipboard only)   │
│   ○ ACS                     │
│   ○ Susurrus                │
│   ○ Personal                │
│ ─────────────────────────── │
│ Preferences...              │
│ Quit Susurrus               │
└─────────────────────────────┘
```

"Auto" is the default — LLM classifies after each transcription. Manual selection overrides. "None" disables notebook capture entirely.

**Preferences — Notebooks tab:**

Two-pane layout: notebook list on left, entry detail on right.

- Left pane: create/rename/delete notebooks, set active, see entry count and last updated
- Right pane: entries sorted newest first, each showing timestamp, text, and edit controls
- Edited entries show orange "edited" badge and inline diff: `{original → edited}`
- Each entry has pencil icon for editing, trash icon for deletion

**Notebook entry editing and Whisper training data:**

When the user edits a notebook entry:
- `originalText` captures the pre-edit text on first edit (preserved across subsequent edits)
- `text` holds the current/latest version
- `editedDate` records when the edit happened
- The diff is displayed in the UI for transparency

Training pairs for Whisper fine-tuning are extracted from entries where `originalText != nil`:
- Input: `originalText` (raw ASR output)
- Target: `text` (user-corrected version)
- This is the key data structure for Phase 9's training pipeline

**LLM prompt integration:**

When a notebook is active, the cleanup prompt injects recent notebook entries as domain context:

```
System: You clean up transcriptions for a project called "ACS".
Below is recent context from this project's notebook.
Use this context for consistent terminology, style, and domain knowledge.

Project context (recent entries):
- We need to update the DataBid SOW before the end of the month.
- The previous statement of work with ACS had ended or was about to end.
- Clay project timeline: discovery phase complete, moving to implementation.

Now clean up this transcription:
{new raw text}
```

This gives the LLM three advantages over generic cleanup:
1. **Terminology** — "DataBid" and "ACS" are already established, so the model capitalises them correctly
2. **Style consistency** — if previous entries are terse, the model matches that style
3. **Domain knowledge** — the model understands this is about client SOW renewals, not random text

**Relationship to other features:**
- F9 (ontological vocabulary): Notebook context complements vocabulary. Vocabulary provides term definitions, notebooks provide usage context. LLM prompt gets both.
- F10 (edit-driven learning): Notebook editing subsumes correction pairs for project-specific style. F10 remains useful for global style preferences across all projects.
- F12 (LLM notebook assignment): Determines which notebook receives each transcription, replacing manual switching.
- F1 (context-aware spelling): If the focused app is a text editor with an open document matching a notebook name, could auto-select that notebook.

#### LLM-Driven Notebook Assignment — Technical Detail (F12)

After transcription completes (and optional LLM cleanup), a second LLM call classifies the text into the most relevant notebook. This replaces manual notebook switching for users with multiple project notebooks.

**Classification flow:**

1. Transcription completes → text is on clipboard (primary output already delivered)
2. System checks: is manual notebook selected? If yes, append to that notebook. Done.
3. If "Auto" mode: system builds classification prompt with all notebook names + last 3 entries each
4. LLM returns `{"notebook_id": "<uuid>"}` or `{"notebook_id": null}`
5. If a notebook ID is returned, text is appended to that notebook
6. If null or classification fails, text is clipboard-only (no notebook assignment)

**Classification prompt:**

```
You are a notebook classifier. Given a transcription and a list of notebooks with recent entries,
determine which notebook this transcription belongs to.

Notebooks:
1. "ACS" (id: abc-123)
   - We need to update the DataBid SOW before the end of the month.
   - The previous statement of work with ACS had ended.
2. "Susurrus" (id: def-456)
   - Streaming overlay now shows interim text in real-time.
   - Fixed window opening bug caused by early return in Scene body.

Transcription: "We should get the DataBid SOW signed before Friday"

Respond with JSON only: {"notebook_id": "<uuid>" or null}
```

**Key design decisions:**
- Classification runs AFTER clipboard write — the user never waits for notebook assignment
- The classification prompt is separate from the cleanup prompt (different system prompt, different purpose)
- Failed classification is non-blocking — clipboard still works, no error shown
- "Auto" mode is the default for new users with notebooks; manual selection overrides
- Classification can reuse the same LLM endpoint/config as cleanup (one extra API call per transcription)

**Preferences integration:**
- General tab: "Notebook assignment" selector — Auto (LLM) / Manual / None
- When "Auto" is selected, the menu bar shows "Notebook: ▸ Auto" with LLM badge
