// Transcribe an eval corpus with a non-Whisper recognizer and write the text
// and timing per clip. Scoring is done by scripts/asr-bakeoff/score.py.
//
// Usage: asr-bakeoff <engine> <corpusDir> <out.json> [--vocab vocabulary.json [--strict]]
//        asr-bakeoff compact <corpusDir> <outDir>   (squeeze long pauses with Silero VAD)
// engine: parakeet-v2 | parakeet-v3 | parakeet-ultra | parakeet-unified | apple-dictation | apple-speech
import AVFoundation
import FluidAudio
import Foundation
import Speech

struct Clip: Decodable {
    let id: String
    let audio: String
    let seconds: Double?
    let verified: Bool?
}

struct ClipResult: Encodable {
    let id: String
    let text: String
    let ms: Int
    let seconds: Double
}

struct RunOutput: Encodable {
    let engine: String
    let vocabTerms: Int
    let clips: [ClipResult]
}

protocol Engine {
    func transcribe(_ url: URL) async throws -> String
}

// MARK: - Parakeet (FluidAudio)

final class ParakeetEngine: Engine {
    let asr: AsrManager
    let converter = AudioConverter()
    let boosting: VocabularyBoostingSession?

    init(version: AsrModelVersion, terms: [String], strict: Bool) async throws {
        let models = try await AsrModels.downloadAndLoad(version: version)
        asr = AsrManager(config: .default)
        try await asr.loadModels(models)
        if terms.isEmpty {
            boosting = nil
        } else {
            let ctc = try await CtcModels.downloadAndLoad()
            let vocab = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
            // strict: no acoustic rescue, so a term only replaces text that already looks like it.
            let config = strict ? VocabularyRescorer.Config(spotterRescueEnabled: false) : nil
            boosting = try await VocabularyBoostingSession(vocabulary: vocab, ctcModels: ctc, config: config)
        }
    }

    func transcribe(_ url: URL) async throws -> String {
        let samples = try converter.resampleAudioFile(url)
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(samples, decoderState: &state)
        guard let boosting, let timings = result.tokenTimings,
              let rescored = await boosting.rescore(text: result.text, tokenTimings: timings, audioSamples: samples),
              rescored.wasModified
        else { return result.text }
        return rescored.text
    }
}

// MARK: - Parakeet Unified (FluidAudio, offline 15 s full-attention encoder)

final class UnifiedEngine: Engine {
    let asr = UnifiedAsrManager()
    let converter = AudioConverter()

    init() async throws {
        try await asr.loadModels()
    }

    func transcribe(_ url: URL) async throws -> String {
        try await asr.transcribe(try converter.resampleAudioFile(url))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Apple SpeechAnalyzer (macOS 26)

final class AppleEngine: Engine {
    let dictation: Bool
    let locale: Locale
    let terms: [String]

    init(dictation: Bool, terms: [String]) async throws {
        self.dictation = dictation
        self.terms = terms
        let wanted = Locale(identifier: "en-GB")
        let supported = dictation
            ? await DictationTranscriber.supportedLocale(equivalentTo: wanted)
            : await SpeechTranscriber.supportedLocale(equivalentTo: wanted)
        guard let supported else { throw NSError(domain: "asr-bakeoff", code: 1, userInfo: [NSLocalizedDescriptionKey: "en-GB unsupported"]) }
        locale = supported
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeModule().module]) {
            FileHandle.standardError.write("installing Apple speech assets…\n".data(using: .utf8)!)
            try await request.downloadAndInstall()
        }
    }

    private func makeModule() -> (module: any SpeechModule, results: () -> AsyncThrowingStream<String, Error>) {
        if dictation {
            let t = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                         reportingOptions: [], attributeOptions: [])
            return (t, { AsyncThrowingStream { c in
                Task { do { for try await r in t.results { c.yield(String(r.text.characters)) }; c.finish() } catch { c.finish(throwing: error) } }
            } })
        }
        let t = SpeechTranscriber(locale: locale, preset: .transcription)
        return (t, { AsyncThrowingStream { c in
            Task { do { for try await r in t.results { c.yield(String(r.text.characters)) }; c.finish() } catch { c.finish(throwing: error) } }
        } })
    }

    func transcribe(_ url: URL) async throws -> String {
        let (module, results) = makeModule()
        let analyzer = SpeechAnalyzer(modules: [module])
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            try await analyzer.setContext(context)
        }
        let stream = results()
        let collector = Task { () throws -> String in
            var parts: [String] = []
            for try await part in stream { parts.append(part) }
            return parts.joined(separator: " ")
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let text = try await collector.value
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Silence compaction

/// Writes a copy of the corpus where every non-speech gap longer than
/// `keep * 2` is cut down to its first and last `keep` seconds of room tone,
/// using Silero VAD. Long silences are where every model invents words.
func compactCorpus(from corpus: URL, to out: URL, keep: Double) async throws {
    let vad = try await VadManager()
    let converter = AudioConverter()
    let fm = FileManager.default
    try fm.createDirectory(at: out.appendingPathComponent("clips"), withIntermediateDirectories: true)
    let vocab = out.appendingPathComponent("vocabulary.json")
    try? fm.removeItem(at: vocab)
    try fm.copyItem(at: corpus.appendingPathComponent("vocabulary.json"), to: vocab)

    let config = VadSegmentationConfig(minSilenceDuration: 0.6, maxSpeechDuration: 3600, speechPadding: 0.15)
    let keepSamples = Int(keep * 16000)
    var lines: [String] = []
    let manifest = try String(contentsOf: corpus.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
    for line in manifest.split(separator: "\n") {
        guard var entry = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let audio = entry["audio"] as? String else { continue }
        let samples = try converter.resampleAudioFile(corpus.appendingPathComponent(audio))
        let segments = try await vad.segmentSpeech(samples, config: config)
        var outSamples: [Float] = []
        var cursor = 0
        for seg in segments {
            let start = seg.startSample(sampleRate: 16000), end = min(samples.count, Int(seg.endTime * 16000))
            let gap = start - cursor
            if gap > keepSamples * 2 {
                outSamples += samples[cursor..<(cursor + keepSamples)]
                outSamples += samples[(start - keepSamples)..<start]
            } else if gap > 0 {
                outSamples += samples[cursor..<start]
            }
            outSamples += samples[start..<end]
            cursor = end
        }
        let tail = samples.count - cursor
        outSamples += samples[cursor..<(cursor + min(tail, keepSamples))]

        let rel = "clips/" + URL(fileURLWithPath: audio).lastPathComponent
        try writeWav(outSamples, to: out.appendingPathComponent(rel))
        let before = Double(samples.count) / 16000, after = Double(outSamples.count) / 16000
        entry["audio"] = rel
        entry["seconds"] = (after * 10).rounded() / 10
        entry.removeValue(forKey: "audioSHA256")
        lines.append(String(data: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), encoding: .utf8)!)
        print(String(format: "%@  %.1fs -> %.1fs  (%d speech segments)", entry["id"] as? String ?? "?", before, after, segments.count))
    }
    try (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("manifest.jsonl"), atomically: true, encoding: .utf8)
}

func writeWav(_ samples: [Float], to url: URL) throws {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(bytes)
    for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
    try data.write(to: url)
}

// MARK: - Main

func loadTerms(_ path: String?) throws -> [String] {
    guard let path else { return [] }
    struct Snapshot: Decodable { struct Entry: Decodable { let term: String }; let entries: [Entry] }
    return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path))).entries.map(\.term)
}

let args = CommandLine.arguments
if args.count >= 4, args[1] == "compact" {
    do {
        try await compactCorpus(from: URL(fileURLWithPath: args[2]), to: URL(fileURLWithPath: args[3]), keep: 0.3)
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
guard args.count >= 4 else {
    print("usage: asr-bakeoff <engine> <corpusDir> <out.json> [--vocab vocabulary.json]")
    exit(2)
}
let engineName = args[1]
let corpus = URL(fileURLWithPath: args[2])
let outURL = URL(fileURLWithPath: args[3])
let vocabPath = args.firstIndex(of: "--vocab").map { args[$0 + 1] }
let strict = args.contains("--strict")

do {
    let terms = try loadTerms(vocabPath)
    let engine: Engine
    switch engineName {
    case "parakeet-v2": engine = try await ParakeetEngine(version: .v2, terms: terms, strict: strict)
    case "parakeet-v3": engine = try await ParakeetEngine(version: .v3, terms: terms, strict: strict)
    case "parakeet-ultra": engine = try await ParakeetEngine(version: .ultra, terms: terms, strict: strict)
    case "parakeet-unified": engine = try await UnifiedEngine()
    case "apple-dictation": engine = try await AppleEngine(dictation: true, terms: terms)
    case "apple-speech": engine = try await AppleEngine(dictation: false, terms: terms)
    default: print("unknown engine \(engineName)"); exit(2)
    }

    let manifest = try String(contentsOf: corpus.appendingPathComponent("manifest.jsonl"), encoding: .utf8)
    let clips = try manifest.split(separator: "\n").map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
        .filter { $0.verified ?? true }

    // Warm-up: the first inference pays model compilation.
    if let first = clips.first { _ = try await engine.transcribe(corpus.appendingPathComponent(first.audio)) }

    var results: [ClipResult] = []
    for (i, clip) in clips.enumerated() {
        let start = Date()
        let text = try await engine.transcribe(corpus.appendingPathComponent(clip.audio))
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        results.append(ClipResult(id: clip.id, text: text, ms: ms, seconds: clip.seconds ?? 0))
        print("[\(i + 1)/\(clips.count)] \(clip.id) \(ms)ms  \(text.prefix(70))")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(RunOutput(engine: engineName + (strict ? " strict" : ""), vocabTerms: terms.count, clips: results)).write(to: outURL)
} catch {
    print("error: \(error)")
    exit(1)
}
