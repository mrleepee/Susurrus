# SPEC: Test Coverage Expansion to 95%

## 1. Summary

Expand SusurrusKit test coverage from ~50% (162 tests) to 95% by adding tests for untested models, service managers, and core transcription services. This spec covers 4 phases progressing from easy model tests through to complex service mocking. Parent initiative: ongoing quality improvement for Susurrus. Status: **draft**.

## 2. Requirements Table

| # | Gap | Current | Expected | Verified |
|---|-----|---------|----------|----------|
| R1 | VocabularyCategory properties untested | No direct tests | All 8 cases return correct displayName, systemImage, llmInstruction | Unit test |
| R2 | VocabularyEntry Codable roundtrip untested | No direct tests | Entry encodes/decodes with id, term, category preserved | Unit test |
| R3 | CorrectionPair struct untested | No tests | Init stores properties, Codable roundtrip, Equatable works | Unit test |
| R4 | InterimTranscript.fullText untested | No direct tests | fullText combines confirmed + unconfirmed with space | Unit test |
| R5 | RecordingMode enum untested | No direct tests | All cases present, rawValue correct, CaseIterable count = 2 | Unit test |
| R6 | RecordingState enum untested | No direct tests | All cases present, CaseIterable count = 5 | Unit test |
| R7 | TranscriptionHistoryItem.withText untested | No tests | Returns new item with updated text, preserves id/rawText/date | Unit test |
| R8 | PasteboardClipboardService untested | No tests | writeText/readText roundtrip, appendText adds with newline | Unit test with mock NSPasteboard |
| R9 | UserDefaultsPreferencesManager untested | No tests | All 10 preference getters/setters roundtrip correctly | Unit test with isolated defaults |
| R10 | TranscriptionHistoryManager CRUD untested | No tests | add, updateText, items, clear, maxItems cap work correctly | Unit test |
| R11 | LLMService untested | No tests | process() sends correct JSON body, handles HTTP errors, resolves config from multiple sources | Unit test with mock URLSession |
| R12 | MediaService untested | No tests | pausePlayingApps/resumeApps run correct AppleScripts, skips when preference disabled | Unit test with mock scripts |
| R13 | MicPermissionManager untested | No tests | checkPermission/requestPermission return correct MicPermission values | Unit test |
| R14 | UserNotificationService untested | No tests | showNotification delivers notification with correct title/body | Unit test |
| R15 | StreamingTranscriptionService state handling untested | No tests | handleStateChange extracts confirmed/unconfirmed text, stripNoiseTokens removes tokens | Unit test with mock state |
| R16 | StreamingTranscriptionService extractFinalText untested | No tests | Combines confirmed + unconfirmed segments, trims whitespace | Unit test |
| R17 | KeychainService CRUD untested | No tests | get/set/delete roundtrip, get returns nil for missing key | Unit test |
| R18 | GlobalHotkeyService untested | No tests | register/unregister lifecycle, callback invocation | Unit test |

## 3. Phases

### Phase 1 — Model Tests [not started]

**Status:** not started
**Fixes:** R1, R2, R3, R4, R5, R6, R7

#### Behaviour

- Given `VocabularyCategory.person`, when `displayName` queried, then returns `"Person"`
- Given `VocabularyCategory.company`, when `systemImage` queried, then returns `"building.2"`
- Given `VocabularyCategory.technical`, when `llmInstruction` queried, then returns `"is a technical term — preserve exact spelling and capitalization"`
- Given all 8 category cases, when iterating `VocabularyCategory.allCases`, then count is 8 and each returns non-empty displayName, systemImage, llmInstruction
- Given `VocabularyEntry(term: "Test", category: .acronym)`, when encoded then decoded, then term == "Test" and category == .acronym
- Given `CorrectionPair(rawText: "hello", editedText: "Hello")`, when encoded then decoded, then rawText and editedText preserved
- Given `InterimTranscript(confirmed: "Hello ", unconfirmed: "world", isFinal: false)`, when `fullText` queried, then returns `"Hello  world"`
- Given `InterimTranscript(confirmed: "", unconfirmed: "", isFinal: true)`, when `fullText` queried, then returns `" "`
- Given `RecordingMode.allCases`, when counted, then count is 2 and contains `.pushToTalk` and `.toggle`
- Given `RecordingMode.pushToTalk.rawValue`, when queried, then equals `"push-to-talk"`
- Given `RecordingState.allCases`, when counted, then count is 5
- Given `TranscriptionHistoryItem(text: "hello", rawText: "helo")`, when `withText("hello world")` called, then returned item has text "hello world", same id, same rawText "helo", same date

#### Verification

| Input | Expected output | Verified |
|-------|----------------|----------|
| `VocabularyCategory.allCases.count` | 8 | Unit test |
| `VocabularyCategory.person.displayName` | `"Person"` | Unit test |
| `VocabularyCategory.company.systemImage` | `"building.2"` | Unit test |
| `VocabularyEntry` encode/decode roundtrip | All fields preserved | Unit test |
| `CorrectionPair` encode/decode roundtrip | All fields preserved | Unit test |
| `InterimTranscript(confirmed: "a", unconfirmed: "b").fullText` | `"a b"` | Unit test |
| `RecordingMode.allCases.count` | 2 | Unit test |
| `RecordingState.allCases.count` | 5 | Unit test |
| `item.withText("new").id == item.id` | true | Unit test |

#### Not in scope

- UI display of categories (view layer)
- LLM integration using category instructions

---

### Phase 2 — Service Manager Tests [not started]

**Status:** not started
**Fixes:** R8, R9, R10

#### Behaviour

- Given `PasteboardClipboardService` with mock pasteboard, when `writeText("hello")` then `readText()` called, then returns `"hello"`
- Given pasteboard with existing content "hello", when `appendText("world")` called, then readText returns "hello\nworld"
- Given `UserDefaultsPreferencesManager` with isolated defaults, when `setRecordingMode(.toggle)` then `recordingMode()`, then returns `.toggle`
- Given `UserDefaultsPreferencesManager`, when `setSelectedModel("large")` then `selectedModel()`, then returns `"large"`
- Given `UserDefaultsPreferencesManager`, when `setLLMEnabled(true)` then `llmEnabled()`, then returns `true`
- Given `UserDefaultsPreferencesManager`, when `setLLMSystemPrompt("custom")` then `llmSystemPrompt()`, then returns `"custom"`
- Given `UserDefaultsPreferencesManager`, when `setAutoPasteEnabled(false)` then `autoPasteEnabled()`, then returns `false`
- Given `UserDefaultsPreferencesManager`, when `setAppendToClipboard(true)` then `appendToClipboard()`, then returns `true`
- Given `TranscriptionHistoryManager`, when `add("hello")` then `items()`, then returns 1 item with text "hello" and nil rawText
- Given `TranscriptionHistoryManager`, when `add("clean", rawText: "clene")`, then item has text "clean" and rawText "clene"
- Given history with 1 item, when `updateText(id, newText: "updated")`, then item text is "updated" and correction pair recorded
- Given history with 3 items, when `clear()` called, then `items()` returns empty
- Given history with 200 items, when `add("overflow")` called, then items count stays at 200 and newest item is "overflow"

#### Verification

| Input | Expected output | Verified |
|-------|----------------|----------|
| `writeText("a")` then `readText()` | `"a"` | Unit test |
| `writeText("a")` then `appendText("b")` then `readText()` | `"a\nb"` | Unit test |
| `setRecordingMode(.toggle)` then `recordingMode()` | `.toggle` | Unit test |
| `add("hello")` then `items().first?.text` | `"hello"` | Unit test |
| `add("a", rawText: "b")` then `items().first?.rawText` | `"b"` | Unit test |
| 201 items added | `items().count == 200` | Unit test |

#### Not in scope

- `simulatePaste()` (requires Accessibility framework, tested manually)
- `isAccessibilityTrusted()` / `promptAccessibility()` (system dialogs)
- LLM API key storage in Keychain (tested in Phase 4)

---

### Phase 3 — External Service Mock Tests [not started]

**Status:** not started
**Fixes:** R11, R12, R13, R14

#### Behaviour

- Given `LLMService` with mock URLSession returning `{"content":[{"type":"text","text":"corrected"}]}`, when `process(text: "hello", systemPrompt: "fix")` called, then returns `"corrected"`
- Given `LLMService` with mock URLSession returning HTTP 401, when `process()` called, then throws `LLMError.requestFailed` containing "401"
- Given `LLMService` with empty API key, when `process()` called, then throws `LLMError.requestFailed` containing "API key not configured"
- Given `LLMService` with mock returning empty content blocks, when `process()` called, then throws `LLMError.emptyResult`
- Given `LLMService` with apiKeyOverride, when config resolved, then uses override key
- Given `LLMService` without apiKeyOverride, when config resolved, then reads from Keychain
- Given `LLMService`, when model/endpoint set via UserDefaults, then `resolveConfig()` returns those values
- Given `LLMService`, when no UserDefaults set, then `resolveConfig()` returns defaults ("MiniMax-M2.5", "https://api.minimax.io/anthropic/v1/messages")
- Given `MediaService`, when `pausePlayingApps()` called and "Spotify" is running and playing, then returns `["Spotify"]`
- Given `MediaService`, when `pausePlayingApps()` called and no media apps playing, then returns empty array
- Given `MediaService`, when `resumeApps(["Spotify"])` called, then runs resume AppleScript for Spotify
- Given `MicPermissionManager`, when `checkPermission()` called, then returns current `MicPermission` value
- Given `UserNotificationService`, when `showNotification(title: "Test", body: "Body")` called, then notification is delivered (or printed in debug mode)

#### Verification

| Input | Expected output | Verified |
|-------|----------------|----------|
| Mock 200 response with valid JSON | Returns extracted text | Unit test |
| Mock 401 response | Throws with "401" | Unit test |
| Empty API key | Throws "API key not configured" | Unit test |
| Empty content blocks | Throws `emptyResult` | Unit test |
| UserDefaults model = "test-model" | Config model is "test-model" | Unit test |
| Spotify running + playing | `pausePlayingApps()` returns ["Spotify"] | Unit test |
| No apps playing | `pausePlayingApps()` returns [] | Unit test |

#### Not in scope

- Real HTTP requests to LLM API
- Real AppleScript execution against running apps
- Real permission dialogs (AVAuthorizationStatus requires system interaction)

---

### Phase 4 — Core Transcription Mock Tests [not started]

**Status:** not started
**Fixes:** R15, R16, R17, R18

#### Behaviour

- Given `StreamingTranscriptionService.handleStateChange` with state containing confirmedSegments `["Hello ", "world"]`, when processed, then confirmed text is `"Hello world"`
- Given `StreamingTranscriptionService.handleStateChange` with state containing unconfirmedSegments `[" there"]`, when processed, then unconfirmed text is `" there"`
- Given `StreamingTranscriptionService.handleStateChange` with `isRecording=false` and non-empty text, when processed, then `isFinal=true`
- Given `StreamingTranscriptionService.handleStateChange` with `isRecording=true`, when processed, then `isFinal=false`
- Given `extractFinalText` with confirmedSegments `["Hello "]` and unconfirmedSegments `["world"]`, when called, then returns `"Hello world"` trimmed
- Given `extractFinalText` with empty confirmed and unconfirmed, when called, then returns empty string
- Given `stripNoiseTokens` with `"<|startoftranscript|> Hello <|en|>"`, when called, then returns `"Hello"`
- Given `stripNoiseTokens` with `"Hello..."`, when called, then returns `"Hello"` (strips ellipsis)
- Given `stripNoiseTokens` with `"Thank you. Bye."`, when called, then returns `""` (strips noise tokens)
- Given `KeychainService`, when `set("secret", for: "key")` then `get("key")`, then returns `"secret"`
- Given `KeychainService`, when `get("nonexistent")`, then returns nil
- Given `KeychainService`, when `set("a", for: "k")` then `delete("k")` then `get("k")`, then returns nil
- Given `GlobalHotkeyService`, when `register(combo:onKeyDown:onKeyUp:)` called, then `isRegistered()` returns true
- Given `GlobalHotkeyService`, when `unregister()` called after register, then `isRegistered()` returns false
- Given `GlobalHotkeyService` registered, when simulated key event fires, then onKeyDown callback is invoked

#### Verification

| Input | Expected output | Verified |
|-------|----------------|----------|
| Confirmed segments ["Hello ", "world"] | confirmed == "Hello world" | Unit test |
| State with isRecording=false, text present | isFinal == true | Unit test |
| `extractFinalText` with ["Hello "] and ["world"] | "Hello world" | Unit test |
| `stripNoiseTokens("<\|en\|> test")` | "test" | Unit test |
| `stripNoiseTokens("test...")` | "test" | Unit test |
| Keychain set/get roundtrip | "secret" | Unit test |
| Keychain get missing key | nil | Unit test |
| Hotkey register then isRegistered | true | Unit test |

#### Not in scope

- Real WhisperKit model loading (requires downloaded models)
- Real audio capture and transcription
- Real Carbon hotkey registration (requires GUI session)

## 4. Constraints

- All tests use Swift Testing framework (`import Testing`, `@Test`, `#expect`)
- Services requiring external dependencies must use mock/protocol-based injection
- Test files follow naming convention: `<ModuleName>Tests.swift`
- Each test file uses `VocabularyManager.createForTesting()` or equivalent isolated factories
- No test should depend on real UserDefaults, Keychain, network, or audio hardware
- Tests must pass in CI without Xcode GUI session

## 5. Not In Scope

| Item | Reason |
|------|--------|
| SwiftUI View tests (MenuBarView, PreferencesView, HistoryView, NotebooksWindowView, StreamingOverlayView) | SwiftUI views tested via manual/visual verification; unit testing views provides low ROI |
| SusurrusApp.swift | App entry point, integration-level only |
| WhisperKitTranscriptionService batch transcription | Requires real WhisperKit model download; covered by existing TranscriptionPerfTests |
| StreamingTranscriptionService real audio pipeline | Requires hardware audio input and WhisperKit model; covered by performance benchmarks |
| PasteboardClipboardService.simulatePaste | Requires Accessibility permissions and GUI session |

## 6. Appendix: Investigation Notes

### A1: Current Test Suite
162 tests across 21 suites, all passing as of commit `e8471e0`. Existing test files cover:
- AppState (19 tests), AudioCapture (4), Clipboard (2), CorrectionLearning (12),
- EndToEnd (4), Hotkey (7), HotkeyStorage (5), LLM (5), MenuBarIcon (7),
- MenuState (8), MicPermission (5), ModelLoad (3), ModelManager (5),
- Notebook (10), Notification (3), Preferences (8), PromptComposer (7),
- Transcription (3), TranscriptionPerf (24 benchmarks), Vocabulary (12)

### A2: Coverage Calculation
48 source files in SusurrusKit. 20 test files. Estimated ~50% method coverage based on:
- 7/14 services fully tested, 5/12 models fully tested
- All protocols are interfaces (no testable logic)
- Views in Sources/Susurrus/ excluded from coverage target

### A3: Mock Strategy
- **URLSession**: Use protocol-based injection or `URLProtocol` subclass for LLMService
- **NSPasteboard**: Inject via init parameter (PasteboardClipboardService already accepts it)
- **AppleScript**: Mock `runAppleScript` by extracting to protocol or subclassing
- **Keychain**: Use test-specific service name to avoid conflicts
- **Carbon APIs**: Wrap in protocol (HotkeyManaging already exists)
- **WhisperKit**: Mock AudioStreamTranscriber.State structs directly for state handler tests
