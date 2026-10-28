import Foundation
import SusurrusKit
@preconcurrency import WhisperKit

/// Turns one long recording into dictation-length, unverified clips for
/// `review`. The reference is a larger model's transcript (a candidate for
/// the user to correct), `raw` is the production model's output.
///
/// Models load one at a time. Re-running with the same audio and output
/// directory resumes: clips whose ids are already in the manifest are skipped.
enum Segment {
    static let usage = "segment --audio <file> --out <corpusDir> [--reference-model large-v3] [--raw-model small] [--min 4] [--max 28] [--limit N]"

    static let frameSamples = 480  // 30 ms at 16 kHz
    static let minPauseFrames = 10  // 0.3 s
    static let padSamples = 3_200  // 0.2 s
    static let silenceFraction: Float = 0.35  // threshold = p10 + fraction * (p90 - p10), in dB
    static let minSpeechFraction = 0.1

    struct Item {
        var id: String
        var samples: [Float]
        var seconds: Double { Double(samples.count) / Double(WAV.sampleRate) }
    }

    static func run(_ args: [String]) async throws {
        let parsed = try ParsedArgs.parse(args, valueOptions: ["audio", "out", "reference-model", "raw-model", "min", "max", "limit"])
        guard parsed.positionals.isEmpty else { throw UsageError(message: "unexpected argument \(parsed.positionals[0])") }
        let audioURL = expandPath(try parsed.require("audio"))
        let corpus = EvalCorpus(directory: expandPath(try parsed.require("out")))
        let minSeconds = try number(parsed, "min", default: 4)
        let maxSeconds = try number(parsed, "max", default: 28)
        guard minSeconds > 0, maxSeconds > minSeconds else { throw UsageError(message: "--min must be positive and less than --max") }
        var limit: Int?
        if let l = parsed.options["limit"] {
            guard let n = Int(l), n > 0 else { throw UsageError(message: "--limit must be a positive integer") }
            limit = n
        }
        let referenceFolder = try Run.resolveModelFolder(parsed.options["reference-model"] ?? "large-v3")
        let rawFolder = try Run.resolveModelFolder(parsed.options["raw-model"] ?? "small")
        guard FileManager.default.fileExists(atPath: audioURL.path) else { throw ToolError("audio not found: \(audioURL.path)") }

        let samples: [Float]
        do { samples = AudioProcessor.convertBufferToArray(buffer: try AudioProcessor.loadAudio(fromPath: audioURL.path)) } catch {
            throw ToolError("cannot load \(audioURL.lastPathComponent): \(error)")
        }
        let slug = slug(audioURL.deletingPathExtension().lastPathComponent)
        var items = split(samples: samples, minSeconds: minSeconds, maxSeconds: maxSeconds).enumerated().map { index, range in
            Item(id: String(format: "\(slug)-%03d", index + 1), samples: Array(samples[range]))
        }
        if let limit { items = Array(items.prefix(limit)) }
        guard !items.isEmpty else { throw ToolError("no speech segments of \(minSeconds)s or more found in \(audioURL.lastPathComponent)") }
        let done = Set(try corpus.readManifest().map(\.id))
        let todo = items.filter { !done.contains($0.id) }
        printErr(String(format: "%d segment(s), %.0fs of audio; %d already in %@", items.count, items.reduce(0) { $0 + $1.seconds }, items.count - todo.count, corpus.directory.path))

        var written = 0
        var writtenSeconds = 0.0
        if !todo.isEmpty {
            printErr("reference model: \(referenceFolder)")
            var empty = 0
            try await transcribe(modelFolder: referenceFolder, items: todo) { index, item, text in
                printErr(String(format: "[%d/%d] %@  %.1fs  ref: %@", index + 1, todo.count, item.id, item.seconds, String(text.prefix(60))))
                guard !text.isEmpty else { empty += 1; return }
                let relative = "clips/\(item.id).wav"
                try WAV.write(samples: item.samples, to: corpus.directory.appendingPathComponent(relative))
                try corpus.append(EvalManifestEntry(
                    id: item.id, script: slug, audio: relative, reference: text,
                    tags: ["conversation", EvalManifestEntry.lengthTag(seconds: item.seconds)],
                    source: "conversation", voice: "unknown", variant: "conversation", verified: false,
                    seconds: (item.seconds * 100).rounded() / 100, capturedAt: nil
                ))
                written += 1
                writtenSeconds += item.seconds
            }
            if empty > 0 { printErr("note: \(empty) segment(s) had an empty reference transcript and were skipped") }
        }

        let pending = try corpus.readManifest().filter { $0.script == slug && $0.source == "conversation" && $0.raw == nil }
        if !pending.isEmpty {
            printErr("raw model: \(rawFolder)")
            let modelName = URL(fileURLWithPath: rawFolder).lastPathComponent
            var rawItems: [Item] = []
            for entry in pending {
                rawItems.append(Item(id: entry.id, samples: try WAV.read(url: corpus.audioURL(for: entry))))
            }
            try await transcribe(modelFolder: rawFolder, items: rawItems) { index, item, text in
                try corpus.update { entries in
                    guard let i = entries.firstIndex(where: { $0.id == item.id }) else { return }
                    entries[i].raw = text
                    entries[i].model = modelName
                }
                printErr("[\(index + 1)/\(rawItems.count)] \(item.id)  raw done")
            }
        }

        if written == 0 && pending.isEmpty {
            printOut("All \(items.count) segment(s) already in the corpus; nothing to do.")
            return
        }
        printOut(String(format: "Wrote %d new segment(s), %.0fs of audio, to %@; %d raw pass(es) filled (all unverified).", written, writtenSeconds, corpus.directory.path, pending.count))
        printOut("Next: susurrus-eval review --corpus \(corpus.directory.path)")
    }

    static func number(_ parsed: ParsedArgs, _ name: String, default value: Double) throws -> Double {
        guard let text = parsed.options[name] else { return value }
        guard let n = Double(text), n.isFinite else { throw UsageError(message: "--\(name) must be a number") }
        return n
    }

    /// Loads the model, decodes each item with no vocabulary prompt, and
    /// hands the text to `handle`. The service is released on return, so only
    /// one model is resident at a time.
    static func transcribe(
        modelFolder: String, items: [Item], handle: (Int, Item, String) throws -> Void
    ) async throws {
        let service = StreamingTranscriptionService()
        await service.setTracing(false)
        printErr("loading model...")
        let start = Date()
        try await service.setupModel(modelFolder: modelFolder)
        printErr(String(format: "model ready in %.1fs", Date().timeIntervalSince(start)))
        await service.setLanguage("en")
        await service.setVocabularySelector { _ in [] }
        for (index, item) in items.enumerated() {
            do {
                let transcript = try await service.transcribeOffline(samples: item.samples, previewText: "")
                try handle(index, item, transcript.text.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch let error as ToolError {
                throw error
            } catch {
                throw ToolError("\(item.id): transcription failed: \(error)")
            }
        }
    }

    /// Lowercased base name, non-alphanumeric runs collapsed to `-`, at most 32 chars.
    static func slug(_ name: String) -> String {
        var out = ""
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if !out.hasSuffix("-") {
                out += "-"
            }
        }
        let trimmed = String(out.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "audio" : trimmed
    }

    // MARK: - Splitting

    /// 30 ms frame levels in dB (RMS).
    static func frameLevels(_ samples: [Float]) -> [Float] {
        (0..<(samples.count / frameSamples)).map { f in
            var sum: Float = 0
            for i in (f * frameSamples)..<((f + 1) * frameSamples) { sum += samples[i] * samples[i] }
            return 10 * log10(sum / Float(frameSamples) + 1e-12)
        }
    }

    /// Sample ranges of speech segments between `minSeconds` and `maxSeconds`
    /// long (measured after the padding trim). Silence is a frame
    /// below p10 + 35% of the p10..p90 level spread, so the cut-off follows
    /// the recording's own noise floor. Each segment ends at the centre of
    /// the longest pause (>= 0.3 s) in its allowed window, ties going to the
    /// pause nearest the window's middle; with no pause it is cut hard at
    /// `maxSeconds`. Segments are then trimmed to 0.2 s around their speech,
    /// and dropped if shorter than `minSeconds` or less than 10% speech.
    static func split(samples: [Float], minSeconds: Double, maxSeconds: Double) -> [Range<Int>] {
        let levels = frameLevels(samples)
        guard levels.count > 1 else { return [] }
        let sorted = levels.sorted()
        let p10 = sorted[sorted.count / 10], p90 = sorted[sorted.count * 9 / 10]
        guard p90 > -60 else { return [] }
        let threshold = p10 + silenceFraction * (p90 - p10)
        let silent = levels.map { $0 < threshold }

        var pauses: [Range<Int>] = []
        var runStart: Int?
        for (f, isSilent) in silent.enumerated() {
            if isSilent { runStart = runStart ?? f } else if let s = runStart {
                if f - s >= minPauseFrames { pauses.append(s..<f) }
                runStart = nil
            }
        }
        if let s = runStart, silent.count - s >= minPauseFrames { pauses.append(s..<silent.count) }

        let framesPerSecond = Double(WAV.sampleRate) / Double(frameSamples)
        let minFrames = Int(minSeconds * framesPerSecond), maxFrames = Int(maxSeconds * framesPerSecond)
        var cuts: [Range<Int>] = []
        var pos = 0
        while pos < levels.count {
            if levels.count - pos <= maxFrames {
                cuts.append(pos..<levels.count)
                break
            }
            let window = (pos + minFrames)...(pos + maxFrames)
            let middle = Double(pos) + Double(minFrames + maxFrames) / 2
            let best = pauses
                .filter { window.contains(($0.lowerBound + $0.upperBound) / 2) }
                .max { a, b in
                    if a.count != b.count { return a.count < b.count }
                    return abs(Double(a.lowerBound + a.upperBound) / 2 - middle) > abs(Double(b.lowerBound + b.upperBound) / 2 - middle)
                }
            let cut = best.map { ($0.lowerBound + $0.upperBound) / 2 } ?? (pos + maxFrames)
            cuts.append(pos..<cut)
            pos = cut
        }

        var out: [Range<Int>] = []
        for cut in cuts {
            let speech = cut.filter { !silent[$0] }
            guard let first = speech.first, let last = speech.last,
                  Double(speech.count) / Double(cut.count) >= minSpeechFraction else { continue }
            let start = max(cut.lowerBound * frameSamples, first * frameSamples - padSamples)
            let end = min(cut.upperBound * frameSamples, (last + 1) * frameSamples + padSamples)
            guard Double(end - start) / Double(WAV.sampleRate) >= minSeconds else { continue }
            out.append(start..<end)
        }
        return out
    }
}
