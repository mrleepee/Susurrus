import Foundation
import Testing
@testable import SusurrusKit

@Suite("EvalCaptureStore — captured clips, manifest and storage cap")
struct EvalCaptureStoreTests {

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("susurrus-capture-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func capture(seconds: Double = 1, approved: String = "Ask Balvinder about MarkLogic.", date: Date = Date()) -> EvalCaptureStore.Capture {
        let count = Int(seconds * Double(WAV.sampleRate))
        let samples = (0..<count).map { Float(sin(Double($0) / 10)) * 0.25 }
        return EvalCaptureStore.Capture(
            samples: samples, approved: approved, raw: "ask bell vinder about mark logic",
            corrected: "Ask Balvinder about MarkLogic", promptTerms: ["MarkLogic", "Balvinder"],
            model: "openai_whisper-small", date: date
        )
    }

    private func entry(_ id: String, verified: Bool) -> EvalManifestEntry {
        EvalManifestEntry(
            id: id, script: id, audio: "clips/\(id).wav", reference: "r", tags: [],
            source: "captured", voice: "user", variant: "captured", verified: verified
        )
    }

    @Test("Save writes a PCM16 WAV and one unverified manifest line with the capture's extras")
    func saveWritesClipAndManifest() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EvalCaptureStore(directory: dir)

        let saved = try #require(try store.save(capture(seconds: 2)))

        let entries = try store.corpus.readManifest()
        #expect(entries == [saved])
        #expect(saved.source == "captured")
        #expect(saved.verified == false)
        #expect(saved.reference == "Ask Balvinder about MarkLogic.")
        #expect(saved.raw == "ask bell vinder about mark logic")
        #expect(saved.corrected == "Ask Balvinder about MarkLogic")
        #expect(saved.promptTerms == ["MarkLogic", "Balvinder"])
        #expect(saved.model == "openai_whisper-small")
        #expect(saved.seconds == 2)
        #expect(saved.tags == ["captured", "short"])
        #expect(saved.audio == "clips/\(saved.id).wav")
        #expect(saved.id.hasPrefix("cap-"))

        let samples = try WAV.read(url: store.corpus.audioURL(for: saved))
        #expect(samples.count == 2 * WAV.sampleRate)
    }

    @Test("Manifest lines use the harness format: compact sorted JSON, ISO-8601 date")
    func manifestLineFormat() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EvalCaptureStore(directory: dir)
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        try store.save(capture(date: date))

        let text = try String(contentsOf: store.corpus.manifestURL, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 1)
        #expect(text.hasSuffix("\n"))
        let line = String(lines[0])
        #expect(line.hasPrefix("{\"audio\":\"clips/cap-"))
        #expect(line.contains("\"capturedAt\":\"2025-10-09T08:53:20Z\""))
        #expect(line.contains("\"source\":\"captured\""))
        #expect(line.contains("\"verified\":false"))
    }

    @Test("Clips over 30 s are tagged long")
    func longTag() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let saved = try #require(try EvalCaptureStore(directory: dir).save(capture(seconds: 31)))
        #expect(saved.tags == ["captured", "long"])
    }

    @Test("No audio, nothing written")
    func emptySamples() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EvalCaptureStore(directory: dir)
        var empty = capture()
        empty.samples = []
        #expect(try store.save(empty) == nil)
        #expect(!FileManager.default.fileExists(atPath: store.corpus.manifestURL.path))
    }

    @Test("The cap keeps the newest clips and deletes the evicted audio")
    func capDropsOldest() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EvalCaptureStore(directory: dir, maxClips: 3)
        var saved: [EvalManifestEntry] = []
        for i in 0..<5 {
            saved.append(try #require(try store.save(capture(seconds: 0.1, approved: "clip \(i)"))))
        }

        let entries = try store.corpus.readManifest()
        #expect(entries.map(\.reference) == ["clip 2", "clip 3", "clip 4"])
        for old in saved.prefix(2) {
            #expect(!FileManager.default.fileExists(atPath: store.corpus.audioURL(for: old).path))
        }
        for kept in saved.suffix(3) {
            #expect(FileManager.default.fileExists(atPath: store.corpus.audioURL(for: kept).path))
        }
        #expect(store.clipCount() == 3)
    }

    @Test("Eviction drops unverified clips before verified ones, oldest first")
    func evictionPrefersUnverified() {
        let entries = [
            entry("a", verified: true), entry("b", verified: false), entry("c", verified: true),
            entry("d", verified: false), entry("e", verified: false),
        ]
        #expect(EvalCaptureStore.evictions(entries, maxClips: 5).isEmpty)
        #expect(EvalCaptureStore.evictions(entries, maxClips: 3).map(\.id) == ["b", "d"])
        #expect(EvalCaptureStore.evictions(entries, maxClips: 1).map(\.id) == ["b", "d", "e", "a"])
    }

    @Test("A verified clip survives the cap that evicts a newer unverified one")
    func verifiedSurvivesCap() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EvalCaptureStore(directory: dir, maxClips: 2)
        try store.save(capture(seconds: 0.1, approved: "first"))
        try store.corpus.update { entries in entries[0].verified = true }
        try store.save(capture(seconds: 0.1, approved: "second"))
        try store.save(capture(seconds: 0.1, approved: "third"))

        #expect(try store.corpus.readManifest().map(\.reference) == ["first", "third"])
    }

    @Test("Concurrent saves never lose a manifest line")
    func concurrentSaves() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EvalCaptureStore(directory: dir)
        let clip = capture(seconds: 0.05)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try? store.save(clip) }
            }
        }
        let entries = try store.corpus.readManifest()
        #expect(entries.count == 20)
        #expect(Set(entries.map(\.id)).count == 20)
    }

    @Test("deleteAll removes clips and manifest")
    func deleteAll() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = EvalCaptureStore(directory: dir)
        try store.save(capture(seconds: 0.1))
        #expect(store.audioBytes() > 0)

        try store.deleteAll()

        #expect(store.clipCount() == 0)
        #expect(store.audioBytes() == 0)
        #expect(!FileManager.default.fileExists(atPath: store.corpus.clipsURL.path))
    }
}

@Suite("EvalCorpus — manifest reading and writing")
struct EvalCorpusTests {

    private func tempCorpus() -> EvalCorpus {
        EvalCorpus(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("susurrus-corpus-test-\(UUID().uuidString)", isDirectory: true))
    }

    private func entry(_ id: String) -> EvalManifestEntry {
        EvalManifestEntry(
            id: id, script: id, audio: "clips/\(id).wav", reference: "ref \(id)", tags: ["read"],
            source: "read", voice: "user", variant: "read", verified: true
        )
    }

    @Test("Missing manifest reads as empty")
    func missingManifest() throws {
        #expect(try tempCorpus().readManifest().isEmpty)
    }

    @Test("Append adds lines in order, repairing a missing final newline")
    func appendRepairsNewline() throws {
        let corpus = tempCorpus()
        defer { try? FileManager.default.removeItem(at: corpus.directory) }
        try corpus.append(entry("a"))
        // Simulate a hand edit that dropped the trailing newline.
        let text = try String(contentsOf: corpus.manifestURL, encoding: .utf8)
        try text.trimmingCharacters(in: .newlines).write(to: corpus.manifestURL, atomically: true, encoding: .utf8)
        try corpus.append(entry("b"))

        #expect(try corpus.readManifest().map(\.id) == ["a", "b"])
    }

    @Test("Phase 1 manifest lines, without the capture extras, still decode")
    func decodesTTSLines() throws {
        let corpus = tempCorpus()
        defer { try? FileManager.default.removeItem(at: corpus.directory) }
        try FileManager.default.createDirectory(at: corpus.directory, withIntermediateDirectories: true)
        let line = #"{"audio":"clips/x.wav","id":"x","reference":"Hi.","script":"s","source":"tts","tags":["short"],"variant":"clean","verified":true,"voice":"Daniel"}"#
        try (line + "\n").write(to: corpus.manifestURL, atomically: true, encoding: .utf8)

        let entries = try corpus.readManifest()
        #expect(entries.count == 1)
        #expect(entries[0].voice == "Daniel")
        #expect(entries[0].raw == nil)
        #expect(entries[0].capturedAt == nil)
    }

    @Test("Update rewrites the manifest with the transformed entries")
    func updateRewrites() throws {
        let corpus = tempCorpus()
        defer { try? FileManager.default.removeItem(at: corpus.directory) }
        for id in ["a", "b", "c"] { try corpus.append(entry(id)) }

        let removed = try corpus.update { entries -> Int in
            entries[0].reference = "edited"
            entries.removeAll { $0.id == "b" }
            return 1
        }

        #expect(removed == 1)
        let entries = try corpus.readManifest()
        #expect(entries.map(\.id) == ["a", "c"])
        #expect(entries[0].reference == "edited")
    }
}
