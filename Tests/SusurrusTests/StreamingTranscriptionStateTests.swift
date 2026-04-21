import Testing
@testable import SusurrusKit
@preconcurrency import WhisperKit

@Suite("Streaming Transcription State Tests")
struct StreamingTranscriptionStateTests {

    // MARK: - extractTextFromSegments

    @Test("Extracts confirmed segments only")
    func extractConfirmedOnly() {
        let segments = [makeSegment("Hello "), makeSegment("world")]
        let result = StreamingTranscriptionService.extractTextFromSegments(
            confirmed: segments, unconfirmed: []
        )
        #expect(result == "Hello world")
    }

    @Test("Extracts confirmed and unconfirmed segments")
    func extractConfirmedAndUnconfirmed() {
        let confirmed = [makeSegment("Hello ")]
        let unconfirmed = [makeSegment("world")]
        let result = StreamingTranscriptionService.extractTextFromSegments(
            confirmed: confirmed, unconfirmed: unconfirmed
        )
        #expect(result == "Hello world")
    }

    @Test("Returns unconfirmed only when no confirmed segments")
    func extractUnconfirmedOnly() {
        let unconfirmed = [makeSegment("Hello "), makeSegment("world")]
        let result = StreamingTranscriptionService.extractTextFromSegments(
            confirmed: [], unconfirmed: unconfirmed
        )
        #expect(result == "Hello world")
    }

    @Test("Returns empty string when no segments")
    func extractEmpty() {
        let result = StreamingTranscriptionService.extractTextFromSegments(
            confirmed: [], unconfirmed: []
        )
        #expect(result == "")
    }

    @Test("Trims leading and trailing whitespace")
    func extractTrimsWhitespace() {
        let segments = [makeSegment("  Hello  ")]
        let result = StreamingTranscriptionService.extractTextFromSegments(
            confirmed: segments, unconfirmed: []
        )
        #expect(result == "Hello")
    }

    @Test("Handles single segment")
    func extractSingleSegment() {
        let segments = [makeSegment("Single utterance")]
        let result = StreamingTranscriptionService.extractTextFromSegments(
            confirmed: segments, unconfirmed: []
        )
        #expect(result == "Single utterance")
    }

    // MARK: - stripNoiseTokens

    @Test("Strips Whisper special tokens")
    func stripsSpecialTokens() {
        let input = "<|startoftranscript|><|en|><|transcribe|>Hello world"
        let result = StreamingTranscriptionService.stripNoiseTokens(from: input)
        #expect(result == "Hello world")
    }

    @Test("Strips timestamp tokens")
    func stripsTimestampTokens() {
        let input = "<|0.00|>Hello<|1.23|> world"
        let result = StreamingTranscriptionService.stripNoiseTokens(from: input)
        #expect(result == "Hello world")
    }

    @Test("Strips ellipsis from truncated audio")
    func stripsEllipsis() {
        let result = StreamingTranscriptionService.stripNoiseTokens(from: "Hello world...")
        #expect(result == "Hello world")
    }

    @Test("Strips double ellipsis")
    func stripsDoubleEllipsis() {
        let result = StreamingTranscriptionService.stripNoiseTokens(from: "Hello......")
        #expect(result == "Hello")
    }

    @Test("Strips hallucinated noise phrases")
    func stripsNoisePhrases() {
        let phrases = [
            "Thank you.",
            "Thanks for watching!",
            "Subscribe!",
            "Bye.",
            "Bye!",
            "Thank you for watching.",
            "The end.",
            "See you next time.",
            "Okay."
        ]
        for phrase in phrases {
            let result = StreamingTranscriptionService.stripNoiseTokens(from: phrase)
            #expect(result == "", "Expected empty for noise phrase: \(phrase)")
        }
    }

    @Test("Strips blank audio tokens")
    func stripsBlankAudioTokens() {
        let tokens = ["[BLANK_AUDIO]", "[NO_SPEECH]", "(blank_audio)", "Waiting for speech"]
        for token in tokens {
            let result = StreamingTranscriptionService.stripNoiseTokens(from: token)
            #expect(result == "", "Expected empty for token: \(token)")
        }
    }

    @Test("Preserves normal text")
    func preservesNormalText() {
        let input = "This is a normal transcription with no special tokens."
        let result = StreamingTranscriptionService.stripNoiseTokens(from: input)
        #expect(result == input)
    }

    @Test("Strips noise from mixed text")
    func stripsNoiseFromMixed() {
        let input = "<|en|>Hello Thank you. world"
        let result = StreamingTranscriptionService.stripNoiseTokens(from: input)
        #expect(result == "Hello  world")
    }

    @Test("Strips all special tokens together")
    func stripsAllNoiseCombined() {
        let input = "<|startoftranscript|><|en|>Hello... Thank you."
        let result = StreamingTranscriptionService.stripNoiseTokens(from: input)
        #expect(result == "Hello")
    }

    @Test("Handles empty string")
    func stripsEmptyString() {
        let result = StreamingTranscriptionService.stripNoiseTokens(from: "")
        #expect(result == "")
    }

    @Test("Handles whitespace-only string")
    func stripsWhitespaceOnly() {
        let result = StreamingTranscriptionService.stripNoiseTokens(from: "   ")
        #expect(result == "")
    }

    @Test("Does not strip single period")
    func preservesSinglePeriod() {
        let result = StreamingTranscriptionService.stripNoiseTokens(from: "Hello.")
        #expect(result == "Hello.")
    }

    @Test("Strips two or more periods")
    func stripsTwoPeriods() {
        let result = StreamingTranscriptionService.stripNoiseTokens(from: "Hello..")
        #expect(result == "Hello")
    }

    @Test("End-to-end: segments with noise")
    func endToEndNoiseStripping() {
        let confirmed = [makeSegment("<|en|> Hello... Thank you.")]
        let extracted = StreamingTranscriptionService.extractTextFromSegments(
            confirmed: confirmed, unconfirmed: []
        )
        let cleaned = StreamingTranscriptionService.stripNoiseTokens(from: extracted)
        #expect(cleaned == "Hello")
    }

    // MARK: - Actor edge cases

    @Test("stopStreamTranscription returns empty string when no transcriber exists")
    func stopWithoutTranscriber() async throws {
        let service = StreamingTranscriptionService()
        let result = try await service.stopStreamTranscription()
        #expect(result == "")
    }

    @Test("cancelStreamTranscription does not crash when no transcriber exists")
    func cancelWithoutTranscriber() async {
        let service = StreamingTranscriptionService()
        await service.cancelStreamTranscription()
        // Should not crash — no assertions needed, just survival
    }

    @Test("isModelReady returns false initially")
    func notReadyInitially() async {
        let service = StreamingTranscriptionService()
        let ready = await service.isModelReady()
        #expect(ready == false)
    }

    @Test("setVocabularyPrompt stores prompt")
    func vocabularyPromptIsSet() async {
        let service = StreamingTranscriptionService()
        await service.setVocabularyPrompt("custom vocabulary terms")
        // No crash — we can't read it back directly, but we verify it doesn't fail
    }
}

// MARK: - Helpers

/// Creates a mock TranscriptionSegment with the given text.
private func makeSegment(_ text: String) -> TranscriptionSegment {
    TranscriptionSegment(
        id: 0,
        seek: 0,
        start: 0.0,
        end: 0.0,
        text: text,
        tokens: [],
        tokenLogProbs: [[:]],
        temperature: 1.0,
        avgLogprob: 0.0,
        compressionRatio: 1.0,
        noSpeechProb: 0.0,
        words: nil
    )
}
