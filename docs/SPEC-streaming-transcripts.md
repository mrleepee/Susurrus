# Streaming Interim Transcripts — Implementation Spec

## Context

Susurrus currently records audio into a buffer, then transcribes the entire buffer after recording stops. This means the user sees nothing until the recording finishes and WhisperKit processes the full audio — typically 2-5 seconds of silence after each recording.

WhisperKit ships an `AudioStreamTranscriber` actor that manages its own microphone input via `AudioProcessor` and produces interim text in real-time through a state-change callback. Switching to this eliminates the post-recording wait and gives the user live feedback as they speak.

**Key constraint**: `AudioStreamTranscriber` owns its own audio pipeline (it calls `AudioProcessor.startRecordingLive()` internally). Our existing `AudioCaptureService` is not compatible and must be replaced in the recording flow.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| R1 | Show a floating overlay near the menu bar with real-time transcription text while recording | Must |
| R2 | Replace batch transcription with streaming — no post-recording processing wait | Must |
| R3 | Option+Space and Shift+Option+Space hotkeys continue to work identically | Must |
| R4 | Final text is still written to clipboard, auto-pasted, and saved to history | Must |
| R5 | LLM post-processing still applies when triggered (Shift+Option+Space or preference enabled) | Must |
| R6 | Vocabulary bias (promptTokens) is still injected into DecodingOptions | Must |
| R7 | 60-second recording cap still enforced | Must |
| R8 | Overlay does not steal focus from the active application | Must |
| R9 | Overlay shows confirmed text in primary color and current/unconfirmed text in secondary color | Should |
| R10 | Overlay fades out after recording stops (not an abrupt disappear) | Should |

---

## Not In Scope

- **Configurable streaming vs batch toggle** — streaming replaces batch entirely (per user decision)
- **Multi-language selection UI** — DecodingOptions defaults to English, language config is a separate feature
- **Speaker diarization** — not part of the streaming flow
- **AudioStreamTranscriber customisation** (silence threshold, confirmation window size) — use defaults, expose later if needed

---

## Phase 1: Streaming Protocol and Service Rewrite

### Behaviour 1.1 — Model not ready

**Given** `WhisperKitTranscriptionService` with no model loaded
**When** `startStreamTranscription(callback:)` is called
**Then** it throws `TranscriptionError.modelNotReady`

### Behaviour 1.2 — Vocabulary bias applied to stream

**Given** a loaded WhisperKit model with vocabulary prompt "Kubernetes, Docker, MarkLogic"
**When** `startStreamTranscription(callback:)` is called
**Then** the `AudioStreamTranscriber` is created with `DecodingOptions.promptTokens` containing the tokenized vocabulary

### Behaviour 1.3 — Interim text callback fires

**Given** a streaming session is active
**When** `AudioStreamTranscriber.State` changes with new `currentText` or segment changes
**Then** the callback fires with the concatenated confirmed + unconfirmed text

### Behaviour 1.4 — Final text extraction

**Given** a streaming session with confirmed segments ["Hello "] and unconfirmed segments ["world"]
**When** `stopStreamTranscription()` is called
**Then** the returned text is "Hello world" (trimmed, noise-stripped)

### Behaviour 1.5 — No speech detected

**Given** a streaming session that produces only noise tokens ("[BLANK_AUDIO]")
**When** `stopStreamTranscription()` is called
**Then** `TranscriptionError.noSpeechDetected` is thrown

### Files

- **Modify**: `Sources/SusurrusKit/Protocols/Transcribing.swift` — replace with `StreamTranscribing` protocol
- **Modify**: `Sources/SusurrusKit/Services/WhisperKitTranscriptionService.swift` — complete rewrite: create `AudioStreamTranscriber` from WhisperKit internals, manage stream lifecycle

### Key implementation notes

`AudioStreamTranscriber` requires 6 components from the `WhisperKit` instance:
```swift
AudioStreamTranscriber(
    audioEncoder: whisperKit.audioEncoder,
    featureExtractor: whisperKit.featureExtractor,
    segmentSeeker: whisperKit.segmentSeeker,
    textDecoder: whisperKit.textDecoder,
    tokenizer: whisperKit.tokenizer!,
    audioProcessor: whisperKit.audioProcessor,
    decodingOptions: decodingOptions,
    stateChangeCallback: { oldState, newState in ... }
)
```

The `stateChangeCallback` fires on the actor's executor, not the main thread. Must dispatch to `@MainActor` via `Task { @MainActor in ... }`.

---

## Phase 2: State Machine Update

### Behaviour 2.1 — Start streaming

**Given** `AppState` with `modelReady=true`
**When** `startStreaming()` is called
**Then** `recordingState` is `.streaming` and `interimText` is empty

### Behaviour 2.2 — Interim text update

**Given** `AppState` in `.streaming`
**When** `interimText` is set to "Hello wo"
**Then** `interimText` reads "Hello wo"

### Behaviour 2.3 — Stop streaming

**Given** `AppState` in `.streaming`
**When** `stopStreaming()` is called
**Then** `recordingState` is `.finalizing`

### Behaviour 2.4 — Finish processing

**Given** `AppState` in `.finalizing`
**When** `finishProcessing()` is called
**Then** `recordingState` is `.idle` and `interimText` is empty

### Behaviour 2.5 — Duration cap

**Given** `AppState` in `.streaming`
**When** `enforceDurationCap()` fires
**Then** `recordingState` is `.finalizing`, `wasDurationCapped` is true

### Behaviour 2.6 — Hotkey push-to-talk down

**Given** push-to-talk mode with `modelReady=true`
**When** `handleHotkeyDown()` is called
**Then** returns `true` and state is `.streaming`

### Behaviour 2.7 — Hotkey push-to-talk up

**Given** push-to-talk mode, currently `.streaming`
**When** `handleHotkeyUp()` is called
**Then** state is `.finalizing`

### Behaviour 2.8 — Hotkey toggle off

**Given** toggle mode, currently `.streaming`
**When** `handleHotkeyDown()` is called
**Then** returns `false` and state is `.finalizing`

### Files

- **Modify**: `Sources/SusurrusKit/Models/AppState.swift` — rename `.recording` → `.streaming`, `.processing` → `.finalizing`, add `interimText` property, rename methods
- **Modify**: `Sources/SusurrusKit/Models/RecordingState.swift` — update enum cases

---

## Phase 3: Downstream Model Updates

### Behaviour 3.1 — Streaming icon

**Given** `RecordingState.streaming`
**When** `MenuBarIcon.symbolName` is queried
**Then** returns waveform pulse animation

### Behaviour 3.2 — Finalizing icon

**Given** `RecordingState.finalizing`
**When** `MenuBarIcon.symbolName` is queried
**Then** returns ellipsis pulse animation

### Behaviour 3.3 — Streaming menu action

**Given** `RecordingState.streaming`
**When** `MenuState.recordingAction` is queried
**Then** returns `.stopRecording`

### Behaviour 3.4 — Finalizing menu disabled

**Given** `RecordingState.finalizing`
**When** `MenuState.isRecordingEnabled` is queried
**Then** returns `false`

### Files

- **Modify**: `Sources/SusurrusKit/Models/MenuBarIcon.swift`
- **Modify**: `Sources/SusurrusKit/Models/MenuState.swift`

---

## Phase 4: Streaming Overlay Window

### Behaviour 4.1 — Show overlay

**Given** a `StreamingOverlayWindow`
**When** `show(interimText: "Hello")` is called
**Then** the panel is visible on screen at `.floating` level, positioned below the menu bar

### Behaviour 4.2 — Update text

**Given** a visible overlay showing "Hello"
**When** `updateText("Hello world")` is called
**Then** the displayed text changes to "Hello world"

### Behaviour 4.3 — Hide overlay

**Given** a visible overlay
**When** `hide()` is called
**Then** the panel is not visible

### Behaviour 4.4 — Click-through

**Given** a visible overlay
**When** the user clicks on it
**Then** the click passes through to the application beneath (Susurrus does not activate)

### Design

`StreamingOverlayWindow`: `NSPanel` subclass with:
- Style: `.borderless`, `.nonActivatingPanel`
- Level: `.floating`
- Background: transparent
- `ignoresMouseEvents = true`
- Content: SwiftUI `NSHostingView` with frosted-glass rounded card (`ultraThinMaterial`)
- Width: capped at 400pt, height auto-sizes
- Position: below menu bar icon, horizontally centered

### Files

- **New**: `Sources/Susurrus/StreamingOverlayView.swift`
- **New**: `Sources/Susurrus/StreamingOverlayWindow.swift`

---

## Phase 5: App Wiring — SusurrusApp Rewrite

### Behaviour 5.1 — Hotkey starts stream and overlay

**Given** model loaded, mic permission granted
**When** hotkey pressed (push-to-talk down)
**Then** state → `.streaming`, `AudioStreamTranscriber` starts, overlay appears empty

### Behaviour 5.2 — Interim text updates overlay

**Given** streaming active, callback fires with "Hello world"
**When** callback updates `appState.interimText`
**Then** overlay displays "Hello world"

### Behaviour 5.3 — Hotkey stops stream, processes final text

**Given** streaming active with final text "Hello world"
**When** hotkey released (push-to-talk up)
**Then** state → `.finalizing`, overlay hides, "Hello world" written to clipboard, auto-paste fires, history updated, state → `.idle`

### Behaviour 5.4 — LLM processing on force-LLM hotkey

**Given** streaming active with final text "Hello world" and `forceLLM=true`
**When** stream stops
**Then** LLM processes text, LLM result written to clipboard (not raw text)

### Behaviour 5.5 — Duration cap stops stream

**Given** streaming active for 60 seconds
**When** duration timer fires
**Then** state → `.finalizing`, cap notification shown, final text processed normally

### Behaviour 5.6 — No speech detected

**Given** streaming active but no speech detected
**When** stream stops
**Then** "No speech detected" notification shown, clipboard untouched, state → `.idle`

### Files

- **Modify**: `Sources/Susurrus/SusurrusApp.swift` — replace `handleStateChange` recording/processing handlers with streaming/finalizing; remove `AudioCaptureService` and `RecordingWorkflow` usage; add overlay window management

---

## Phase 6: MenuBarView Update

### Behaviour 6.1 — Streaming menu

**Given** state is `.streaming`
**When** menu bar is opened
**Then** "Stop Recording" button is shown and enabled

### Behaviour 6.2 — Finalizing menu

**Given** state is `.finalizing`
**When** menu bar is opened
**Then** "Start Recording" button is shown but disabled

### Files

- **Modify**: `Sources/Susurrus/MenuBarView.swift`

---

## Phase 7: Cleanup and Tests

### Test updates

- **Modify**: `Tests/SusurrusTests/TranscriptionTests.swift` — mock conforms to `StreamTranscribing`
- **Modify**: `Tests/SusurrusTests/AppStateTests.swift` — rename states, add `interimText` tests
- **Modify**: `Tests/SusurrusTests/MenuStateTests.swift` — update for new state names

### Dead code removal

- `Sources/SusurrusKit/Services/RecordingWorkflow.swift` — remove
- `Sources/SusurrusKit/Services/AudioCaptureService.swift` — remove
- `Sources/SusurrusKit/Protocols/AudioCapturing.swift` — remove
- `Tests/SusurrusTests/AudioCaptureServiceTests.swift` — remove

---

## Verification

1. `make build` — compiles without errors
2. `make test` — all tests pass
3. `make install && open /Applications/Susurrus.app`
4. Press Option+Space — overlay appears, live text streams as you speak
5. Release Option+Space — text is on clipboard and pasted into active app
6. Press Shift+Option+Space — same as above but LLM post-processes the text
7. Record for 60+ seconds — cap fires, notification shown, text still processed
8. Record silence — "No speech detected" notification, clipboard untouched
9. Click on overlay — click passes through, Susurrus does not activate
10. Menu bar icon pulses during streaming, ellipsis during finalizing
