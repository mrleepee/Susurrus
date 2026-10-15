import Foundation
import SusurrusKit
@preconcurrency import WhisperKit

enum Run {
    static let usage = "run --corpus <corpusDir> --config <config.json> --out <run.json> [--limit N] [--tag T] [--include-unverified]"

    static let modelAliases: [String: String] = [
        "small": "openai_whisper-small",
        "base": "openai_whisper-base",
        "medium": "openai_whisper-medium",
        "large-v3": "openai_whisper-large-v3",
        "large-v3_turbo": "openai_whisper-large-v3_turbo",
        "distil-large-v3": "distil-whisper_distil-large-v3",
    ]

    static func resolveModelFolder(_ model: String) throws -> String {
        if model.contains("/") || model.hasPrefix("~") {
            let url = expandPath(model)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("model folder not found: \(url.path)") }
            return url.path
        }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Susurrus/models/argmaxinc/whisperkit-coreml")
        let folderName = modelAliases[model] ?? "openai_whisper-\(model)"
        let folder = base.appendingPathComponent(folderName)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw ToolError("model '\(model)' not found at \(folder.path)")
        }
        return folder.path
    }

    static func run(_ args: [String]) async throws {
        let parsed = try ParsedArgs.parse(
            args, valueOptions: ["corpus", "config", "out", "limit", "tag"], flagOptions: ["include-unverified"]
        )
        let includeUnverified = parsed.flags.contains("include-unverified")
        guard parsed.positionals.isEmpty else { throw UsageError(message: "unexpected argument \(parsed.positionals[0])") }
        let corpusDir = expandPath(try parsed.require("corpus"))
        let configURL = expandPath(try parsed.require("config"))
        let outURL = expandPath(try parsed.require("out"))
        var limit: Int?
        if let l = parsed.options["limit"] {
            guard let n = Int(l), n > 0 else { throw UsageError(message: "--limit must be a positive integer") }
            limit = n
        }
        let tagFilter = parsed.options["tag"]

        var config = try JSON.read(EvalConfig.self, from: configURL)
        if config.name == "unnamed" { config.name = configURL.deletingPathExtension().lastPathComponent }

        var manifest = try JSON.readLines(ManifestEntry.self, from: corpusDir.appendingPathComponent("manifest.jsonl"))
        if let tagFilter { manifest = manifest.filter { $0.tags.contains(tagFilter) } }
        if let limit { manifest = Array(manifest.prefix(limit)) }
        guard !manifest.isEmpty else { throw ToolError("no clips selected from \(corpusDir.path)") }
        // Unverified references (tier C before review) may be rewordings, so
        // they never count toward the headline numbers.
        let unverifiedCount = manifest.filter { !$0.verified }.count
        if !includeUnverified {
            manifest = manifest.filter(\.verified)
            if unverifiedCount > 0 {
                printErr("note: skipping \(unverifiedCount) unverified clip(s); run `review` on the corpus, or pass --include-unverified to score them separately")
            }
            guard !manifest.isEmpty else {
                throw ToolError("no verified clips in \(corpusDir.path) (\(unverifiedCount) unverified)")
            }
        }

        let vocabURL = corpusDir.appendingPathComponent("vocabulary.json")
        let vocab = FileManager.default.fileExists(atPath: vocabURL.path)
            ? try JSON.read(VocabularyFile.self, from: vocabURL)
            : VocabularyFile(snapshotDate: Date(), entries: [], rules: [], contextTerms: [])
        if !FileManager.default.fileExists(atPath: vocabURL.path) {
            printErr("note: \(vocabURL.path) missing; running with an empty vocabulary")
        }
        let terms = vocab.trackedTerms
        let activeRules = vocab.rules.filter(\.enabled)

        let modelFolder = try resolveModelFolder(config.model)
        printErr("config '\(config.name)': model \(modelFolder)")

        let service = StreamingTranscriptionService()
        await service.setTracing(false)  // keep ~/susurrus_debug.log clean
        printErr("loading model...")
        let loadStart = Date()
        try await service.setupModel(modelFolder: modelFolder)
        printErr(String(format: "model ready in %.1fs", Date().timeIntervalSince(loadStart)))
        await service.setLanguage("en")
        await service.setFinalDecodeConfig(config.decode)

        let entries = vocab.entries
        let contextTerms = vocab.contextTerms
        let now = vocab.snapshotDate
        switch config.prompt {
        case .ranker:
            let ranker = VocabularyRanker()
            await service.setVocabularySelector { preview in
                ranker.selectTerms(previewText: preview, vocabulary: entries, contextTerms: contextTerms, now: now)
            }
        case .noPrompt:
            await service.setVocabularySelector { _ in [] }
        }

        let finalizer = TranscriptFinalizer()
        var results: [ClipResult] = []

        for (index, entry) in manifest.enumerated() {
            let audioURL = corpusDir.appendingPathComponent(entry.audio)
            let sha = try sha256Hex(of: audioURL)
            let buffer = try AudioProcessor.loadAudio(fromPath: audioURL.path)
            let samples = AudioProcessor.convertBufferToArray(buffer: buffer)
            let seconds = Double(samples.count) / 16_000

            var previewText = ""
            var previewMs = 0
            if config.preview == .decode {
                let t = Date()
                previewText = try await service.previewTranscript(samples: samples)
                previewMs = Int(Date().timeIntervalSince(t) * 1000)
            }

            let transcript: FinalTranscript
            do {
                transcript = try await service.transcribeOffline(samples: samples, previewText: previewText)
            } catch {
                throw ToolError("\(entry.id): transcribeOffline failed: \(error)")
            }

            let raw = transcript.text
            let final: String
            if config.corrector {
                final = await finalizer.finalize(raw, vocabulary: entries, rules: activeRules).text
            } else {
                final = raw
            }
            let scoreRaw = TranscriptScorer.score(reference: entry.reference, hypothesis: raw, terms: terms)
            let scoreFinal = TranscriptScorer.score(reference: entry.reference, hypothesis: final, terms: terms)

            results.append(ClipResult(
                id: entry.id, tags: entry.tags, verified: entry.verified, seconds: seconds, audioSHA256: sha, reference: entry.reference,
                previewText: previewText, previewMs: previewMs,
                promptTerms: transcript.promptTerms, promptTokenCount: transcript.promptTokenCount,
                outcome: transcript.outcome.rawValue, decodeMs: transcript.decodeMs, failure: transcript.failure,
                raw: raw, final: final, scoreRaw: scoreRaw, scoreFinal: scoreFinal,
                segments: transcript.segments
            ))
            printErr(String(
                format: "[%d/%d] %@  %@  %dms  WER %@ -> %@",
                index + 1, manifest.count, entry.id, transcript.outcome.rawValue, transcript.decodeMs,
                pct(scoreRaw.wer), pct(scoreFinal.wer)
            ))
        }

        let verified = results.filter { $0.verified != false }
        let unverified = results.filter { $0.verified == false }
        let run = RunFile(
            name: config.name, createdAt: Date(), gitCommit: gitCommit(), osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            modelFolder: modelFolder, config: config, corpus: corpusDir.path, clips: verified,
            summary: Aggregation.summary(verified),
            unverifiedSkipped: includeUnverified ? nil : unverifiedCount,
            unverifiedClips: includeUnverified ? unverified : nil,
            unverifiedSummary: includeUnverified && !unverified.isEmpty ? Aggregation.summary(unverified) : nil
        )
        try JSON.write(run, to: outURL)
        printErr("wrote \(outURL.path)")
        if verified.isEmpty {
            printOut("No verified clips.")
        } else {
            if unverifiedCount > 0 { printOut("Verified clips:") }
            printOut(summaryTable(run.summary))
        }
        if let unverifiedSummary = run.unverifiedSummary {
            printOut("\nUnverified clips (references not yet reviewed; not in the headline numbers):")
            printOut(summaryTable(unverifiedSummary))
        } else if unverifiedCount > 0 && !includeUnverified {
            printOut("\n\(unverifiedCount) unverified clip(s) not scored.")
        }
    }

    static func gitCommit() -> String? {
        guard let out = try? runProcess("/usr/bin/git", ["rev-parse", "--short", "HEAD"], currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)),
              out.status == 0 else { return nil }
        let sha = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    static func summaryTable(_ summary: RunSummary) -> String {
        let headers = ["group", "clips", "WER raw->final", "fmt err final", "terms hit/exp", "dropped", "inserted", "extra brk", "RTF"]
        func row(_ name: String, _ s: StageAggregates) -> [String] {
            let f = s.final.score
            return [
                name, "\(s.final.clips)", "\(pct(s.raw.wer))->\(pct(s.final.wer))", pct(f.formattedErrorRate),
                "\(f.termsHit)/\(f.termsExpected)", "\(f.droppedRuns)", "\(f.insertedRuns)", "\(f.extraSentenceBreaks)",
                String(format: "%.2f", s.final.rtf),
            ]
        }
        var rows = [row("overall", summary.overall)]
        for tag in summary.byTag.keys.sorted() { rows.append(row("tag:\(tag)", summary.byTag[tag]!)) }
        return renderTable(headers: headers, rows: rows)
    }
}
