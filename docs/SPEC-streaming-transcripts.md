# Streaming Interim Transcripts — Implementation Spec

## Context

Susurrus currently records audio into a buffer, then transcribes the entire buffer after recording stops. This means the user sees nothing until the recording finishes and WhisperKit processes the full audio — typically 2-5 seconds of silence after each recording.

WhisperKit ships an `AudioStreamTranscriber` actor that manages its own microphone input via `AudioProcessor` and produces interim text in real-time through a state-change callback. Switching to this eliminates the post-recording wait and gives the user live feedback as they speak.

**Key constraint**: `AudioStreamTranscriber` owns its own audio pipeline (it calls `AudioProcessor.startRecordingLive()` internally). Our existing `AudioCaptureService` is not compatible and must be replaced in the recording flow.

---

## Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| R1 | Show a floating overlay near the menu bar icon with real-time transcription text while recording | Must |
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
- **Streaming VAD-based chunking for longer utterances** — R25 from SPEC.md, separate feature
- **Speaker diarization** — not part of the streaming flow

---

## Phase 0: Pre-requisites

### Pre-requisite 0.1 — Verify WhisperKit API

Before writing any streaming code, verify the `AudioStreamTranscriber` constructor signature against the exact `WhisperKit` version pinned in `Package.swift`. The API has changed across versions. If the 6-component constructor in this spec no longer matches, update the constructor call in Phase 1 before implementation begins.

**Verification**: Clone WhisperKit at the pinned revision, open its sources, confirm `AudioStreamTranscriber.init` parameters match the code in Behaviour 1.3.

### Pre-requisite 0.2 — Empirical vocabulary bias test

Run a test stream with `DecodingOptions.promptTokens` set and confirm WhisperKit applies the vocabulary bias to per-chunk decoding in streaming mode. If `promptTokens` are ignored in streaming mode (likely — streaming decodes chunks with limited context), remove R6 from streaming scope and note that vocabulary bias falls back to LLM post-processing for streaming sessions.

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

*Note*: If `promptTokens` are confirmed not to work in streaming mode (Pre-requisite 0.2), this behaviour is deferred until a future iteration. Vocabulary bias will only apply via LLM post-processing.

### Behaviour 1.3 — Interim text callback fires

**Given** a streaming session is active
**When** `AudioStreamTranscriber.State` changes with new `currentText` or segment changes
**Then** the callback fires with confirmed text and unconfirmed text as separate fields

### Behaviour 1.4 — Final text extraction

**Given** a streaming session with confirmed segments ["Hello "] and unconfirmed segments ["world"]
**When** `stopStreamTranscription()` is called
**Then** the returned text is "Hello world" (trimmed, noise-stripped)

### Behaviour 1.5 — No speech detected

**Given** a streaming session that produces only noise tokens ("[BLANK_AUDIO]")
**When** `stopStreamTranscription()` is called
**Then** `TranscriptionError.noSpeechDetected` is thrown

### Behaviour 1.6 — Stream interrupted by failure

**Given** `AudioStreamTranscriber` is active
**When** the underlying audio processor fails (mic permission revoked, device disconnected, memory pressure)
**Then** the callback receives an `.error` state with `TranscriptionError.audioCaptureFailed`
**And** the state machine transitions to `.idle`
**And** the overlay is hidden
**And** the clipboard is untouched
**And** a notification is shown describing the failure

### Files

- **Modify**: `Sources/SusurrusKit/Protocols/Transcribing.swift` — add `StreamTranscribing` protocol alongside existing `Transcribing` (do not remove; batch mode may return in future)
- **Modify**: `Sources/SusurrusKit/Services/WhisperKitTranscriptionService.swift` — add `startStreamTranscription(callback:)` and `stopStreamTranscription()` methods; do not remove batch methods until Phase 7

### Key implementation notes

`AudioStreamTranscriber` requires WhisperKit internals. Verify the constructor against the pinned version before writing this code (Pre-requisite 0.1).

The `stateChangeCallback` fires on the actor's executor, not the main thread. Must dispatch to `@MainActor` via `Task { @MainActor in ... }`.

The callback should receive a structured type — not a flat string — so the overlay can distinguish confirmed from unconfirmed text:

```swift
struct InterimTranscript {
    let confirmed: String      // text the model has committed to
    let unconfirmed: String    // text currently in-flight / unconfirmed
    let isFinal: Bool          // true when stream has stopped and this is the final transcript
}
```

---

## Phase 2: State Machine Update

### Behaviour 2.1 — Start streaming

**Given** `AppState` with `modelReady=true`
**When** `startStreaming()` is called
**Then** `recordingState` is `.streaming` and `interimText` is empty

### Behaviour 2.2 — Interim text update

**Given** `AppState` in `.streaming`
**When** `interimText` is set to `InterimTranscript(confirmed: "Hello ", unconfirmed: "wo", isFinal: false)`
**Then** `interimText.confirmed` reads "Hello " and `interimText.unconfirmed` reads "wo"

### Behaviour 2.3 — Stop streaming

**Given** `AppState` in `.streaming`
**When** `stopStreaming()` is called
**Then** `recordingState` is `.finalizing`

### Behaviour 2.4 — Finish processing

**Given** `AppState` in `.finalizing`
**When** `finishProcessing()` is called
**Then** `recordingState` is `.idle` and `interimText` is cleared

### Behaviour 2.5 — Duration cap

**Given** `AppState` in `.streaming`
**When** `enforceDurationCap()` fires
**Then** `recordingState` is `.finalizing` and `wasDurationCapped` is `true`

### Behaviour 2.6 — Duration cap flag consumed and reset

**Given** `wasDurationCapped` is `true` after `finishProcessing()` was called
**When** the cap notification is shown
**Then** `wasDurationCapped` is reset to `false`
**And** the next `startStreaming()` begins with `wasDurationCapped = false`

### Behaviour 2.7 — Hotkey push-to-talk down

**Given** push-to-talk mode with `modelReady=true`
**When** `handleHotkeyDown()` is called
**Then** returns `true` and state is `.streaming`

### Behaviour 2.8 — Hotkey push-to-talk up

**Given** push-to-talk mode, currently `.streaming`
**When** `handleHotkeyUp()` is called
**Then** state is `.finalizing`

### Behaviour 2.9 — Hotkey toggle off

**Given** toggle mode, currently `.streaming`
**When** `handleHotkeyDown()` is called
**Then** returns `false` and state is `.finalizing`

### Files

- **Modify**: `Sources/SusurrusKit/Models/AppState.swift` — add `interimText: InterimTranscript?` property, add `wasDurationCapped: Bool`, add `startStreaming()` / `stopStreaming()` / `finishProcessing()` / `enforceDurationCap()` methods; do NOT remove batch-mode `startRecording()` / `stopRecording()` methods yet (Phase 7 removes them)
- **Modify**: `Sources/SusurrusKit/Models/RecordingState.swift` — add `.streaming` and `.finalizing` enum cases alongside existing cases (do not remove `.recording` / `.processing` until Phase 7)

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
**When** `show(confirmed: "", unconfirmed: "")` is called
**Then** the panel is visible on screen at `.floating` level, anchored to the menu bar icon's screen position (not screen-center)

### Behaviour 4.2 — Update text with confirmed and unconfirmed split

**Given** a visible overlay showing confirmed="Hello " and unconfirmed="wo"
**When** `updateText(confirmed: "Hello ", unconfirmed: "world")` is called
**Then** the overlay displays "Hello world" with "Hello " in primary color and "world" in secondary color

### Behaviour 4.3 — Hide overlay with fade

**Given** a visible overlay
**When** `hide()` is called
**Then** the panel fades out over 300ms and is then not visible

### Behaviour 4.4 — Click-through

**Given** a visible overlay
**When** the user clicks on it
**Then** the click passes through to the application beneath (Susurrus does not activate)

### Behaviour 4.5 — Overlay destroyed on app termination

**Given** a visible overlay
**When** `NSApplication.willTerminateNotification` fires
**Then** the overlay panel is closed immediately

### Design

`StreamingOverlayWindow`: `NSPanel` subclass with:
- Style: `.borderless`, `.nonActivatingPanel`
- Level: `.floating`
- Background: transparent
- Override `canBecomeKey` to return `false` (suppresses key input without ignoring all mouse events — preserves ability to add scroll/hover later)
- Content: SwiftUI `NSHostingView` with frosted-glass rounded card (`ultraThinMaterial`)
- Width: capped at 400pt, height auto-sizes
- Horizontal position: horizontally centered on the menu bar icon's screen x coordinate
- Vertical position: immediately below the menu bar icon's screen frame

**Positioning**: Query the status item's `window.frame` or `NSEvent.mouseLocation` to find the menu bar icon. Do NOT center the overlay on screen — most users have left-aligned menu bars and it will look misaligned.

**Fade-out**: Use `NSAnimationContext` with `.fadeOut` duration of 0.3s. Do not use `NSPanel.animates` alone as it does not handle opacity.

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

**Given** streaming active, callback fires with `InterimTranscript(confirmed: "Hello ", unconfirmed: "world", isFinal: false)`
**When** callback updates `appState.interimText`
**Then** overlay displays confirmed portion in primary color and unconfirmed portion in secondary color

### Behaviour 5.3 — Hotkey stops stream, processes final text

**Given** streaming active with final transcript "Hello world"
**When** hotkey released (push-to-talk up)
**Then** state → `.finalizing`, overlay hides with fade, "Hello world" written to clipboard, auto-paste fires, history updated, state → `.idle`

### Behaviour 5.4 — LLM processing on force-LLM hotkey

**Given** streaming active with final text "Hello world" and `forceLLM=true`
**When** stream stops
**Then** LLM processes text, LLM result written to clipboard (not raw text)

### Behaviour 5.5 — Duration cap stops stream

**Given** streaming active for 60 seconds
**When** duration timer fires
**Then** state → `.finalizing`, `wasDurationCapped` is set to `true`, cap notification shown, final text processed normally

### Behaviour 5.6 — No speech detected

**Given** streaming active but no speech detected
**When** stream stops
**Then** "No speech detected" notification shown, clipboard untouched, state → `.idle`

### Behaviour 5.7 — Stream interrupted

**Given** streaming active
**When** `AudioStreamTranscriber` callback receives `.error`
**Then** overlay hides with fade, error notification shown, clipboard untouched, state → `.idle`

### Files

- **Modify**: `Sources/SusurrusKit/Services/SusurrusApp.swift` — replace `handleStateChange` recording/processing handlers with streaming/finalizing; add overlay window lifecycle management; add `AudioStreamTranscriber` lifecycle management

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

- **Modify**: `Tests/SusurrusTests/TranscriptionTests.swift` — add `StreamTranscribing` mock and tests for interim callback, no-speech, stream-interrupted behaviours
- **Modify**: `Tests/SusurrusTests/AppStateTests.swift` — add streaming state tests, add `interimText` tests, add `wasDurationCapped` lifecycle test
- **Modify**: `Tests/SusurrusTests/MenuStateTests.swift` — update for new state names

### Batch-mode dead code removal (after streaming wiring confirmed working)

After Phase 5 verification steps pass and streaming is confirmed working in the app:

- **Remove**: `Sources/SusurrusKit/Services/AudioCaptureService.swift`
- **Remove**: `Sources/SusurrusKit/Services/RecordingWorkflow.swift`
- **Remove**: `Sources/SusurrusKit/Protocols/AudioCapturing.swift`
- **Remove**: `Tests/SusurrusTests/AudioCaptureServiceTests.swift`
- **Modify**: `Sources/SusurrusKit/Models/RecordingState.swift` — remove `.recording` and `.processing` cases
- **Modify**: `Sources/SusurrusKit/Models/AppState.swift` — remove `startRecording()`, `stopRecording()`, `startProcessing()`, `finishProcessing()` methods

### Final cleanup

- **Modify**: `Sources/SusurrusKit/Protocols/Transcribing.swift` — remove batch `transcribe(buffer:)` method once all callers are updated

---

## Verification

1. `make build` — compiles without errors
2. `make test` — all tests pass
3. `make install && open /Applications/Susurrus.app`
4. Press Option+Space — overlay appears at menu bar icon position, live text streams as you speak
5. Release Option+Space — text is on clipboard and pasted into active app; overlay fades out over 300ms
6. Press Shift+Option+Space — same as above but LLM post-processes the text
7. Record for 60+ seconds — cap fires, notification shown, text still processed, `wasDurationCapped` flag consumed and reset
8. Record silence — "No speech detected" notification, clipboard untouched, overlay fades
9. Click on overlay — click passes through, Susurrus does not activate
10. Menu bar icon pulses during streaming, ellipsis during finalizing
11. Stream while mic is disconnected mid-recording — "Audio capture failed" notification, clipboard untouched, state returns to idle
12. Quit app while streaming — overlay disappears immediately, no orphan panel left on screen

