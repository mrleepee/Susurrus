import Foundation
import Testing
@testable import SusurrusKit

// MARK: - MicPermission
// (MicPermissionTests already exists in MicPermissionTests.swift)

// MARK: - LLMError

@Suite("LLMError Tests")
struct LLMErrorTests {

    @Test("requestFailed is equatable")
    func requestFailedEquatable() {
        #expect(LLMError.requestFailed("a") == LLMError.requestFailed("a"))
        #expect(LLMError.requestFailed("a") != LLMError.requestFailed("b"))
    }

    @Test("invalidResponse equals itself")
    func invalidResponse() {
        #expect(LLMError.invalidResponse == LLMError.invalidResponse)
        #expect(LLMError.invalidResponse != LLMError.emptyResult)
    }

    @Test("emptyResult equals itself")
    func emptyResult() {
        #expect(LLMError.emptyResult == LLMError.emptyResult)
    }
}

// MARK: - ClipboardError

@Suite("ClipboardError Tests")
struct ClipboardErrorTests {

    @Test("writeFailed is equatable")
    func writeFailed() {
        #expect(ClipboardError.writeFailed("a") == ClipboardError.writeFailed("a"))
        #expect(ClipboardError.writeFailed("a") != ClipboardError.writeFailed("b"))
    }

    @Test("readFailed is equatable")
    func readFailed() {
        #expect(ClipboardError.readFailed("a") == ClipboardError.readFailed("a"))
    }

    @Test("Different cases not equal")
    func differentCases() {
        #expect(ClipboardError.writeFailed("x") != ClipboardError.readFailed("x"))
    }
}

// MARK: - TranscriptionError

@Suite("TranscriptionError Tests")
struct TranscriptionErrorTests {

    @Test("modelNotReady equals itself")
    func modelNotReady() {
        #expect(TranscriptionError.modelNotReady == TranscriptionError.modelNotReady)
    }

    @Test("emptyAudio equals itself")
    func emptyAudio() {
        #expect(TranscriptionError.emptyAudio == TranscriptionError.emptyAudio)
    }

    @Test("transcriptionFailed is equatable by message")
    func transcriptionFailed() {
        #expect(TranscriptionError.transcriptionFailed("x") == TranscriptionError.transcriptionFailed("x"))
        #expect(TranscriptionError.transcriptionFailed("x") != TranscriptionError.transcriptionFailed("y"))
    }

    @Test("noSpeechDetected equals itself")
    func noSpeechDetected() {
        #expect(TranscriptionError.noSpeechDetected == TranscriptionError.noSpeechDetected)
    }

    @Test("Different cases not equal")
    func differentCases() {
        #expect(TranscriptionError.modelNotReady != TranscriptionError.emptyAudio)
        #expect(TranscriptionError.noSpeechDetected != TranscriptionError.audioCaptureFailed)
    }
}

// MARK: - AudioCaptureError

@Suite("AudioCaptureError Tests")
struct AudioCaptureErrorTests {

    @Test("All cases are distinct")
    func distinctCases() {
        let cases: [AudioCaptureError] = [
            .alreadyCapturing, .notCapturing, .noInputDevice,
            .permissionDenied, .engineFailure("x"),
        ]
        #expect(Set(cases.map { String(describing: $0) }).count == cases.count)
    }

    @Test("engineFailure is equatable")
    func engineFailure() {
        #expect(AudioCaptureError.engineFailure("a") == AudioCaptureError.engineFailure("a"))
        #expect(AudioCaptureError.engineFailure("a") != AudioCaptureError.engineFailure("b"))
    }
}

// MARK: - ModelManagerError

@Suite("ModelManagerError Tests")
struct ModelManagerErrorTests {

    @Test("downloadFailed is equatable")
    func downloadFailed() {
        #expect(ModelManagerError.downloadFailed("a") == ModelManagerError.downloadFailed("a"))
        #expect(ModelManagerError.downloadFailed("a") != ModelManagerError.downloadFailed("b"))
    }

    @Test("modelNotFound is equatable")
    func modelNotFound() {
        #expect(ModelManagerError.modelNotFound("x") == ModelManagerError.modelNotFound("x"))
    }

    @Test("cacheDirectoryUnavailable equals itself")
    func cacheUnavailable() {
        #expect(ModelManagerError.cacheDirectoryUnavailable == ModelManagerError.cacheDirectoryUnavailable)
    }
}

// MARK: - HotkeyError

@Suite("HotkeyError Tests")
struct HotkeyErrorTests {

    @Test("registrationFailed is equatable")
    func registrationFailed() {
        #expect(HotkeyError.registrationFailed("a") == HotkeyError.registrationFailed("a"))
        #expect(HotkeyError.registrationFailed("a") != HotkeyError.registrationFailed("b"))
    }
}

// MARK: - VocabularyError

@Suite("VocabularyError Tests")
struct VocabularyErrorTests {

    @Test("wordTooLong is equatable")
    func wordTooLong() {
        #expect(VocabularyError.wordTooLong("x") == VocabularyError.wordTooLong("x"))
        #expect(VocabularyError.wordTooLong("x") != VocabularyError.wordTooLong("y"))
    }

    @Test("tooManyWords is equatable")
    func tooManyWords() {
        #expect(VocabularyError.tooManyWords(5) == VocabularyError.tooManyWords(5))
        #expect(VocabularyError.tooManyWords(5) != VocabularyError.tooManyWords(10))
    }
}

// MARK: - NotificationError

@Suite("NotificationError Tests")
struct NotificationErrorTests {

    @Test("deliveryFailed is equatable")
    func deliveryFailed() {
        #expect(NotificationError.deliveryFailed("a") == NotificationError.deliveryFailed("a"))
        #expect(NotificationError.deliveryFailed("a") != NotificationError.deliveryFailed("b"))
    }
}
