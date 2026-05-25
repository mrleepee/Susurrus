# Audio Device Control — Implementation Spec

Susurrus currently records from the system default audio input and provides no visibility into which device is active, no way to choose an explicit device, and no voice isolation processing. Users with multiple input devices (e.g. a Mac Studio with headphones and a paired laptop) cannot tell which mic is listening, sometimes get empty recordings when the wrong device is default, and lack the background-noise suppression that competing tools (SuperWhisper) enable via macOS's system voice isolation.

This spec adds explicit input-device selection, a visible "active device" indicator, and an optional voice isolation toggle — bringing Susurrus to parity with SuperWhisper's audio handling.

**Status:** draft
**Branch:** `feat/audio-device-control`

---

## Requirements

| # | User input | Current behaviour | Expected behaviour | Verified |
|---|---|---|---|---|
| R1 | User opens the Susurrus menu bar with Mac Studio + paired laptop + headphones connected | No indication of which input device Susurrus will record from | Menu bar popover displays the name of the currently-selected input device (e.g. "MacBook Pro Microphone") | User report 2026-04-23 |
| R2 | User triggers Option+Space to record, but the wrong device is system default | Recording produces empty audio or audio from the unexpected device — user doesn't discover until pasting the result | User can select a specific input device in Preferences; selection persists across app launches and is used for all recordings | User report 2026-04-23 |
| R3 | User starts a recording in a noisy environment | Background noise bleeds into the transcription; no system-level voice processing is applied | When "Voice Isolation" preference is enabled, macOS's voice isolation is active during recording (orange mic indicator appears in system menu bar) | Comparison with SuperWhisper — user report 2026-04-23 |
| R4 | User unplugs or disconnects the currently-selected device mid-session (e.g. pulls out USB mic) | Undefined — likely silent failure or crash on next record attempt | App falls back to system default, stored preference marked "unavailable", user sees warning on next record | Predicted edge case |
| R5 | User plugs in new input device (e.g. AirPods) while Susurrus is running | New device does not appear in the picker until app restart | Device list refreshes when macOS emits `kAudioHardwarePropertyDevices` change notifications | Standard macOS behaviour |

---

## Phases

### Phase 1 — Device enumeration and routing

**Status:** not started
**Branch:** `feat/audio-device-control-phase-1`
**Fixes:** R2 (selection plumbing, no UI yet)

#### Behaviour

- **Given** Susurrus is launched, **when** the audio device service is queried for available inputs, **then** it returns a list containing every input device macOS reports via Core Audio, each with a stable `DeviceID` and human-readable name.
- **Given** the user has no saved device preference, **when** a recording starts, **then** the system default input is used (identical to current behaviour).
- **Given** the user has saved a specific device preference (e.g. `DeviceID=73` for "Studio Display Microphone"), **when** a recording starts, **then** that device's `DeviceID` is passed into `AudioStreamTranscriber.startStreamTranscription` and WhisperKit records from that device.
- **Given** the user has a saved device preference but the device is currently disconnected, **when** a recording starts, **then** the service falls back to the system default and emits a `deviceUnavailable` event with the missing device's name.
- **Given** the user selects a new device, **when** the preference is written, **then** the next recording uses the new device without restart.

#### Verification

| Input | Expected output | Verified result |
|---|---|---|
| Query available devices on a Mac with 3 inputs (built-in, USB mic, AirPods) | Array of 3 `AudioDevice` entries with distinct IDs and names | |
| Set preference to `DeviceID=42`, start recording | `AudioStreamTranscriber` receives `inputDeviceID: 42` in its `startRecordingLive` call | |
| Set preference to `DeviceID=999` (disconnected), start recording | Fallback to default; `deviceUnavailable(name: "...")` event emitted | |
| No preference set, start recording | `AudioStreamTranscriber` receives `inputDeviceID: nil` | |
| Change preference mid-session (no restart), start new recording | New recording uses new device | |

#### Not in scope

- UI for selecting a device — Phase 2.
- Live refresh of the device list on hot-plug — Phase 4.
- Voice isolation — Phase 3.

---

### Phase 2 — Preferences picker and menu bar indicator

**Status:** not started
**Branch:** `feat/audio-device-control-phase-2`
**Fixes:** R1, R2 (UI surface)

#### Behaviour

- **Given** the user opens Preferences, **when** the "Audio" section renders, **then** an input-device picker shows all available devices, with "System Default" as the first entry and the currently-selected device highlighted.
- **Given** the user selects a device from the picker, **when** the selection changes, **then** the preference is saved and subsequent recordings use the new device.
- **Given** a recording is in progress, **when** the user opens the menu bar popover, **then** the popover displays the name of the device being recorded (e.g. "Recording from: MacBook Pro Microphone").
- **Given** no recording is in progress, **when** the user opens the menu bar popover, **then** the popover shows the name of the device that *would* be used (e.g. "Input: Studio Display Microphone").
- **Given** the saved device is disconnected, **when** the picker renders, **then** the disconnected device is shown as "Studio Display Microphone (unavailable)" and the effective device shown is the system default.

#### Verification

| Input | Expected output | Verified result |
|---|---|---|
| Open Preferences with 3 input devices connected | Picker shows "System Default", "Built-in Microphone", "USB Mic", "AirPods" | |
| Change picker selection from System Default to USB Mic | Preference saved; menu bar popover updates to "Input: USB Mic" | |
| Start recording with USB Mic selected | Menu bar popover shows "Recording from: USB Mic" while recording | |
| Disconnect USB Mic, reopen Preferences | Picker shows "USB Mic (unavailable)"; effective input reverts to System Default | |

#### Not in scope

- Voice isolation toggle — Phase 3.
- Live device-list refresh without reopening Preferences — Phase 4.

---

### Phase 3 — Voice isolation

**Status:** not started
**Branch:** `feat/audio-device-control-phase-3`
**Fixes:** R3

#### Behaviour

- **Given** the user enables "Voice Isolation" in Preferences, **when** a recording starts, **then** macOS's voice isolation mode is activated (`AVCaptureDevice.preferredMicrophoneMode = .voiceIsolation`) and the orange mic indicator appears in the system menu bar.
- **Given** the user disables "Voice Isolation" in Preferences, **when** a recording starts, **then** the preferred microphone mode is set to `.standard` and no orange indicator appears.
- **Given** a recording ends, **when** the stop flow completes, **then** the preferred microphone mode is restored to whatever it was before the recording started (respects system-wide setting if user hadn't overridden).
- **Given** macOS version is below the minimum that supports voice isolation on a given Mac (some Macs require Apple Silicon), **when** Preferences renders, **then** the Voice Isolation toggle is disabled with an explanatory tooltip.
- **Given** the Voice Isolation preference has never been set, **when** a recording starts, **then** the default value is `enabled` (matches SuperWhisper behaviour — this is the expected tool behaviour for a voice dictation app).

#### Verification

| Input | Expected output | Verified result |
|---|---|---|
| Voice Isolation enabled, start recording | Orange mic indicator appears in system menu bar within 500ms of record start | |
| Voice Isolation enabled, stop recording | Orange mic indicator disappears within 500ms of stop | |
| Voice Isolation disabled, start recording | No orange indicator; standard mic mode active | |
| System was in `.wideSpectrum` mode before recording, Voice Isolation enabled, stop recording | Mode restored to `.wideSpectrum` after stop (not left at `.voiceIsolation`) | |
| Intel Mac or pre-Sonoma macOS | Toggle disabled in Preferences with tooltip "Requires Apple Silicon on macOS 14 or later" | |

#### Not in scope

- Custom voice processing pipelines beyond macOS's built-in modes.
- Per-device voice isolation preferences — one global toggle.
- Voice isolation for non-recording flows (e.g. the model-loading pipeline).

---

### Phase 4 — Hot-plug device monitoring (deferred)

**Status:** deferred
**Fixes:** R4, R5

#### Behaviour

- **Given** a user plugs in a new input device while Susurrus is running, **when** Core Audio emits a device-list change notification, **then** the AudioDeviceService refreshes its cached list and any open Preferences picker reflects the new device.
- **Given** the currently-selected device is disconnected mid-session, **when** Core Audio emits the removal notification, **then** the user is notified (menu bar indicator shows warning badge) and the next recording falls back to system default.

#### Verification

| Input | Expected output | Verified result |
|---|---|---|
| With Preferences open, connect AirPods | AirPods appear in picker within 1 second | |
| With recording in progress, unplug USB mic | Recording stops gracefully; notification emitted | |

#### Not in scope

- Auto-resume recording on a different device.
- Device-hotswap during an active streaming session (requires WhisperKit restart).

---

## Constraints

- **One phase per branch.** Each phase merges independently via its own PR. Branch names follow `feat/audio-device-control-phase-N`.
- **No breaking changes to public API.** `StreamingTranscriptionService.startStreamTranscription(callback:)` remains the default path (uses system default device). New device-aware entry points are additive.
- **Test-first for Phase 1.** Device enumeration and routing is pure logic — tests must exist before the UI is built. Phase 2 UI may follow with manual verification.
- **Each phase ≤ ~200 lines of production code.** Exclude tests, fixtures, and SwiftUI layout boilerplate.
- **Voice isolation restoration is mandatory.** Phase 3 must never leave the system in `.voiceIsolation` mode after Susurrus stops recording — user's system-wide preference must be preserved.
- **Platform guard:** Phase 3 voice isolation code paths must be gated on macOS availability checks (`if #available(macOS 14, *)`) with graceful degradation for older versions.

---

## Not In Scope

- **Audio input levels / gain control:** Not part of this spec. macOS handles input gain at the OS level; Susurrus records what the system provides.
- **Output device selection:** Susurrus has no audio playback; no output device control needed.
- **Multi-device simultaneous recording:** Out of scope — WhisperKit's `AudioStreamTranscriber` records from a single device.
- **Per-recording-mode device preferences:** One device preference applies to all recording modes (push-to-talk, toggle). Per-mode config deferred until user demand materialises.
- **Automatic "best mic" detection:** No heuristic for picking the best available mic — user selects explicitly. Automatic selection is hard to get right and surprises users when it changes.
- **Custom noise suppression beyond macOS built-ins:** Third-party DSP libraries not considered.

---

## Appendix: Investigation Notes

### A1. WhisperKit's audio device API

WhisperKit's `AudioProcessor` already exposes full device control — this spec is mostly wiring existing APIs through to the UI, not building new Core Audio plumbing.

- `AudioProcessor.getAudioDevices() -> [AudioDevice]` (static, `AudioProcessor.swift:816`) enumerates input devices via Core Audio. Returns an array of `AudioDevice` structs, each with `id: DeviceID` (which is `AudioDeviceID` / `UInt32` on macOS) and `name: String`.
- `AudioProcessing.startRecordingLive(inputDeviceID: DeviceID?, callback:)` (protocol method, `AudioProcessor.swift:97`) accepts an optional device ID — `nil` means system default. Currently Susurrus passes `nil`.
- The streaming path routes through `AudioStreamTranscriber.startStreamTranscription()` (internal to WhisperKit), which calls `audioProcessor.startRecordingLive(inputDeviceID: nil, callback: ...)` with the device ID baked in from the transcriber's state. To pass a custom device, we need to call `audioProcessor.assignAudioInput(inputNode:inputDeviceID:)` before the transcriber starts recording — OR extend `StreamingTranscriptionService` to set a device ID on the processor it creates.

Implication: Phase 1 does not require modifying WhisperKit. The device ID flows through via the existing `AudioProcessing` protocol.

### A2. macOS voice isolation API

On macOS 14+, the system exposes `AVCaptureDevice.preferredMicrophoneMode` as a class-level setting:

```swift
AVCaptureDevice.preferredMicrophoneMode = .voiceIsolation
```

This is **system-wide** — it changes the microphone mode for *all* apps that use AVFoundation or Core Audio input. The orange mic indicator in the menu bar is macOS's visual confirmation that voice isolation is active.

Modes available: `.standard`, `.wideSpectrum`, `.voiceIsolation` (and `.videoChatHighlight` on supported hardware).

To avoid clobbering the user's system-wide preference permanently, Phase 3 must:
1. Read `AVCaptureDevice.preferredMicrophoneMode` before recording starts (save as `previousMode`).
2. Set to `.voiceIsolation` (or `.standard` per user preference).
3. On recording stop, restore to `previousMode`.

SuperWhisper uses this exact pattern — verified by observing the orange indicator appear/disappear around their record sessions.

**Availability caveats:**
- `.voiceIsolation` requires Apple Silicon on most Macs; Intel Macs may return an error or silently ignore.
- First invocation may prompt the user with a system dialog — not tested yet.

### A3. Device ID stability

`AudioDeviceID` is a Core Audio `UInt32` that is *not* stable across device reconnections. If a USB mic is unplugged and replugged, it may receive a different ID. Storing `DeviceID` in preferences is therefore unreliable.

**Strategy:** store the device **name** (not ID) in preferences. At recording time, resolve the name back to a current `DeviceID` via `AudioProcessor.getAudioDevices()`. If no device with that name is present, fall back to system default and emit the `deviceUnavailable` event (R4).

Device names can collide if two identical mics are plugged in simultaneously (rare in practice). A future enhancement could store `(name, transportType, vendorID)` tuples for disambiguation, but this is deferred.

### A4. Existing code that passes `nil` device ID

Two call sites currently hardcode `nil` / default device:
- `StreamingTranscriptionService.startStreamTranscription` → builds `AudioStreamTranscriber` with `whisperKit.audioProcessor`, which internally calls `startRecordingLive(inputDeviceID: nil, ...)`.
- `AudioCaptureService.startCapture` → uses `AVAudioEngine`'s default input node without calling `assignAudioInput`.

Both must be updated in Phase 1 to accept and forward a device ID. The buffered (`AudioCaptureService`) path is less critical (the app has moved to streaming) but should be kept consistent to avoid surprise if anyone switches back.

### A5. Why voice isolation default is "on"

SuperWhisper enables voice isolation by default. User's report identifies this as the expected tool behaviour for a voice dictation app. The default could be inverted later if power users complain about artifacts — but for the target use case (dictation in a typical working environment), voice isolation improves transcription quality noticeably.
