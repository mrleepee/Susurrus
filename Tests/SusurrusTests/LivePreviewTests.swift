import Foundation
import Testing
@testable import SusurrusKit
import WhisperKit

/// What the live preview (review panel and overlay) shows for an interim tick.
@Suite("Live preview text")
struct LivePreviewTextTests {

    @Test("WhisperKit 1.1 special tokens never reach the preview")
    func stripsSpecialTokens() {
        let preview = StreamingTranscriptionService.preview(
            confirmed: "<|startoftranscript|><|en|><|transcribe|><|0.00|> Hello there<|2.40|>",
            unconfirmed: "<|2.40|> how are you<|endoftext|>"
        )
        #expect(preview.text == "Hello there how are you")
    }

    @Test("A tick of only tokens and silence markers shows nothing")
    func tokensOnlyIsEmpty() {
        let preview = StreamingTranscriptionService.preview(
            confirmed: "<|startoftranscript|><|en|>",
            unconfirmed: "[ Silence ]"
        )
        #expect(preview.text.isEmpty)
    }

    @Test("Before anything is confirmed the unconfirmed tail still shows")
    func tailOnly() {
        let preview = StreamingTranscriptionService.preview(confirmed: "", unconfirmed: "<|0.00|> first words")
        #expect(preview.text == "first words")
    }

    @Test("Corrections apply to the confirmed text only")
    func correctsConfirmedOnly() {
        let preview = StreamingTranscriptionService.preview(
            confirmed: "mark logic query",
            unconfirmed: "mark logic"
        ) { $0.replacingOccurrences(of: "mark logic", with: "MarkLogic") }
        #expect(preview.confirmed == "MarkLogic query")
        #expect(preview.tail == "mark logic")
        #expect(preview.text == "MarkLogic query mark logic")
    }
}

/// Real speech, replayed at real-time pace through the same streaming path
/// the app uses, must produce readable words in the preview — not just fire
/// the callback. Catches the panel staying blank while dictation works (VAD
/// skipping every decode, or tokens-only text). Needs the Whisper Small model
/// the app has already downloaded, so it's opt-in:
/// `SUSURRUS_MODEL_TESTS=1 swift test --filter LivePreviewReplay`.
@Suite(
    "Live preview — real speech replay",
    .tags(.requiresModel),
    .enabled(if: ProcessInfo.processInfo.environment["SUSURRUS_MODEL_TESTS"] == "1")
)
struct LivePreviewReplayTests {

    private static let modelFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Susurrus/models/argmaxinc/whisperkit-coreml/openai_whisper-small")

    /// Synthesises speech with `say` so the test needs no fixture files.
    private func speech(_ sentence: String) throws -> [Float] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("susurrus-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "--data-format=LEI16@16000", sentence]
        try say.run()
        say.waitUntilExit()
        let buffer = try AudioProcessor.loadAudio(fromPath: file.path)
        // A second of silence either side, as when the user starts and stops.
        let silence = [Float](repeating: 0, count: 16_000)
        return silence + AudioProcessor.convertBufferToArray(buffer: buffer) + silence
    }

    @Test("Spoken words appear in the preview while listening")
    func spokenWordsAppear() async throws {
        try #require(FileManager.default.fileExists(atPath: Self.modelFolder.path),
                     "Whisper Small not downloaded at \(Self.modelFolder.path)")
        let service = StreamingTranscriptionService()
        try await service.setupModel(modelFolder: Self.modelFolder.path)

        let audio = try speech("The quick brown fox jumps over the lazy dog near the river bank.")
        let fake = FakeAudioProcessor(samples: audio, chunkMs: 100)
        let latest = LatestPreview()

        // startStreamTranscription only returns when the session ends.
        let session = Task {
            try await service.startStreamTranscription(
                deviceID: nil,
                audioProcessorOverride: fake,
                callback: { transcript in
                    let text = StreamingTranscriptionService
                        .preview(confirmed: transcript.confirmed, unconfirmed: transcript.unconfirmed).text
                    Task { await latest.update(text) }
                }
            )
        }
        let seconds = Double(audio.count) / 16_000
        try await Task.sleep(for: .seconds(seconds + 3))
        await service.cancelStreamTranscription()
        _ = await session.result

        let shown = await latest.longest.lowercased()
        #expect(!shown.isEmpty, "Preview stayed blank for \(seconds)s of speech")
        let words = ["quick", "brown", "fox", "jumps", "over", "lazy", "dog", "river", "bank"]
        let heard = words.filter { shown.contains($0) }
        #expect(heard.count >= 5, "Preview showed: \"\(shown)\"")
        #expect(!shown.contains("<|"), "Special tokens leaked into the preview: \"\(shown)\"")
    }
}

private actor LatestPreview {
    private(set) var longest = ""
    func update(_ text: String) {
        if text.count >= longest.count { longest = text }
    }
}
