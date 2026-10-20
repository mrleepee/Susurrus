import Foundation

/// Tier C of the eval harness: the user's own dictations, kept only when
/// they opt in ("Keep recordings for accuracy testing", off by default).
///
/// Each approved review-panel dictation becomes a 16 kHz PCM16 WAV under
/// `<directory>/clips/` plus one `manifest.jsonl` line with
/// `source: "captured"` and `verified: false`. The approved text is only a
/// candidate reference (the user may have reworded, or left an error in),
/// so `susurrus-eval review` confirms each clip before it counts.
///
/// Audio is private: it lives in Application Support, never in the repo.
public struct EvalCaptureStore: Sendable {
    /// UserDefaults key for the opt-in preference.
    public static let enabledKey = "keepRecordingsForEval"
    public static let defaultMaxClips = 500

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Susurrus/eval/captured", isDirectory: true)
    }

    public let corpus: EvalCorpus
    public let maxClips: Int

    public init(directory: URL = EvalCaptureStore.defaultDirectory, maxClips: Int = EvalCaptureStore.defaultMaxClips) {
        corpus = EvalCorpus(directory: directory)
        self.maxClips = max(1, maxClips)
    }

    /// Everything known about one approved dictation.
    public struct Capture: Sendable {
        public var samples: [Float]
        /// The text the user inserted or copied.
        public var approved: String
        public var raw: String
        public var corrected: String
        public var promptTerms: [String]
        public var model: String
        public var date: Date

        public init(
            samples: [Float], approved: String, raw: String, corrected: String,
            promptTerms: [String], model: String, date: Date = Date()
        ) {
            self.samples = samples
            self.approved = approved
            self.raw = raw
            self.corrected = corrected
            self.promptTerms = promptTerms
            self.model = model
            self.date = date
        }
    }

    /// Writes the clip and its manifest line, then enforces the cap.
    /// Returns nil (writing nothing) when there is no audio.
    @discardableResult
    public func save(_ capture: Capture) throws -> EvalManifestEntry? {
        guard !capture.samples.isEmpty else { return nil }
        let id = Self.clipID(for: capture.date)
        let relative = "clips/\(id).wav"
        let seconds = Double(capture.samples.count) / Double(WAV.sampleRate)
        // Whole seconds, so the entry equals what the manifest decodes back.
        let capturedAt = Date(timeIntervalSince1970: capture.date.timeIntervalSince1970.rounded(.down))
        let entry = EvalManifestEntry(
            id: id, script: id, audio: relative, reference: capture.approved,
            tags: ["captured", EvalManifestEntry.lengthTag(seconds: seconds)],
            source: "captured", voice: "user", variant: "captured", verified: false,
            raw: capture.raw, corrected: capture.corrected, promptTerms: capture.promptTerms,
            model: capture.model, seconds: (seconds * 100).rounded() / 100, capturedAt: capturedAt
        )
        // Audio first: a crash between the two leaves an orphan WAV (swept
        // by "Delete recordings"), never a manifest line without audio.
        try WAV.write(samples: capture.samples, to: corpus.directory.appendingPathComponent(relative))
        try corpus.update { entries in
            entries.append(entry)
            for evicted in Self.evictions(entries, maxClips: maxClips) {
                try? FileManager.default.removeItem(at: corpus.audioURL(for: evicted))
                entries.removeAll { $0.id == evicted.id }
            }
        }
        return entry
    }

    /// Clips to drop so at most `maxClips` remain: oldest first, unverified
    /// before verified, since a verified clip carries the user's review work.
    static func evictions(_ entries: [EvalManifestEntry], maxClips: Int) -> [EvalManifestEntry] {
        let excess = entries.count - maxClips
        guard excess > 0 else { return [] }
        let order = entries.filter { !$0.verified } + entries.filter(\.verified)
        return Array(order.prefix(excess))
    }

    public func clipCount() -> Int {
        (try? corpus.readManifest().count) ?? 0
    }

    /// Bytes of audio on disk.
    public func audioBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: corpus.clipsURL, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Removes every clip, the manifest and anything else in the directory.
    public func deleteAll() throws {
        try corpus.withLock {
            let fm = FileManager.default
            guard fm.fileExists(atPath: corpus.directory.path) else { return }
            for url in try fm.contentsOfDirectory(at: corpus.directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent != ".manifest.lock" {
                try fm.removeItem(at: url)
            }
        }
    }

    /// `cap-20261015-201502-3fa1`: sortable local time plus a random suffix
    /// so two captures in the same second can't collide.
    static func clipID(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(format: "%04x", UInt16.random(in: 0...UInt16.max))
        return "cap-\(formatter.string(from: date))-\(suffix)"
    }
}
