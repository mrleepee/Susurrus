import Foundation

/// An eval corpus directory: `manifest.jsonl` plus `clips/`.
///
/// Every manifest change goes through an exclusive `flock` on
/// `.manifest.lock`, because two processes write the captured corpus: the
/// app appends a line per captured dictation while `susurrus-eval review`
/// may be rewriting the file with the user's verdicts. Rewrites re-read the
/// manifest under the lock and are atomic, so neither side loses a line.
public struct EvalCorpus: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var manifestURL: URL { directory.appendingPathComponent("manifest.jsonl") }
    public var clipsURL: URL { directory.appendingPathComponent("clips") }
    private var lockURL: URL { directory.appendingPathComponent(".manifest.lock") }

    public func audioURL(for entry: EvalManifestEntry) -> URL {
        directory.appendingPathComponent(entry.audio)
    }

    // MARK: - Encoding

    /// Compact, sorted keys, ISO-8601 dates: one stable line per entry.
    public static func lineEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func lineDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Reading and writing

    /// The manifest's entries in file order; empty when there is no manifest.
    public func readManifest() throws -> [EvalManifestEntry] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let text = try String(contentsOf: manifestURL, encoding: .utf8)
        let decoder = Self.lineDecoder()
        var entries: [EvalManifestEntry] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            do {
                entries.append(try decoder.decode(EvalManifestEntry.self, from: Data(trimmed.utf8)))
            } catch {
                throw EvalCorpusError("manifest.jsonl line \(index + 1): \(error)")
            }
        }
        return entries
    }

    /// Appends one entry, creating the directory and manifest as needed.
    public func append(_ entry: EvalManifestEntry) throws {
        try withLock {
            try appendUnlocked(entry)
        }
    }

    /// Reads the manifest, lets `transform` change it, and writes it back
    /// atomically, all under the lock.
    @discardableResult
    public func update<T>(_ transform: (inout [EvalManifestEntry]) throws -> T) throws -> T {
        try withLock {
            var entries = try readManifest()
            let result = try transform(&entries)
            try writeUnlocked(entries)
            return result
        }
    }

    /// Runs `body` holding the manifest lock. Not reentrant: `body` must
    /// not call `append`, `update` or `withLock` on the same corpus.
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw EvalCorpusError("cannot open \(lockURL.path): errno \(errno)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw EvalCorpusError("cannot lock \(lockURL.path): errno \(errno)") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func appendUnlocked(_ entry: EvalManifestEntry) throws {
        var line = try Self.lineEncoder().encode(entry)
        line.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: manifestURL.path) {
            try line.write(to: manifestURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forUpdating: manifestURL)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        // A hand-edited manifest may lack its final newline.
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { line.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: line)
    }

    private func writeUnlocked(_ entries: [EvalManifestEntry]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = Self.lineEncoder()
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        try data.write(to: manifestURL, options: .atomic)
    }
}

public struct EvalCorpusError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}
