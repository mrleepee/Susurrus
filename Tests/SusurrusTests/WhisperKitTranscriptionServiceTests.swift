import Foundation
import Testing
@testable import SusurrusKit

@Suite("WhisperKitTranscriptionService Tests")
struct WhisperKitTranscriptionServiceTests {

    @Test("isModelReady returns false initially")
    func notReadyInitially() async {
        let service = WhisperKitTranscriptionService()
        let ready = await service.isModelReady()
        #expect(ready == false)
    }

    @Test("transcribe throws modelNotReady when model not loaded")
    func transcribeThrowsModelNotReady() async {
        let service = WhisperKitTranscriptionService()
        do {
            _ = try await service.transcribe(audio: [0.1, 0.2, 0.3])
            #expect(Bool(false), "Should have thrown")
        } catch let error as TranscriptionError {
            #expect(error == .modelNotReady)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("transcribe throws modelNotReady even with empty audio")
    func transcribeModelNotReadyPrecedesEmptyAudio() async {
        let service = WhisperKitTranscriptionService()
        do {
            _ = try await service.transcribe(audio: [])
            #expect(Bool(false), "Should have thrown")
        } catch let error as TranscriptionError {
            // modelNotReady guard fires first (before emptyAudio check)
            #expect(error == .modelNotReady)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("setVocabularyPrompt stores prompt")
    func setVocabularyPrompt() async {
        let service = WhisperKitTranscriptionService()
        await service.setVocabularyPrompt("custom vocab")
        // Can't read back directly, but it shouldn't crash
    }

    @Test("unloadModel sets modelReady to false")
    func unloadModel() async {
        let service = WhisperKitTranscriptionService()
        await service.unloadModel()
        let ready = await service.isModelReady()
        #expect(ready == false)
    }
}
