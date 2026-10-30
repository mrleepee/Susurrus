import Foundation
import SusurrusKit

/// Runs another recognizer's transcripts through the app's finalizer
/// (learned rules + vocabulary corrector), with the corpus's vocabulary
/// snapshot, so engines outside WhisperKit are compared on the same footing.
/// Input and output are the `scripts/asr-bakeoff` run format:
/// `{"engine": …, "vocabTerms": n, "clips": [{"id", "text", "ms", "seconds"}]}`.
enum Finalize {
    static let usage = "finalize --corpus <corpusDir> --in <bakeoff.json> --out <bakeoff.json>"

    struct BakeoffRun: Codable {
        struct Clip: Codable {
            let id: String
            var text: String
            let ms: Int
            let seconds: Double
        }
        var engine: String
        let vocabTerms: Int
        var clips: [Clip]
    }

    static func run(_ args: [String]) async throws {
        let parsed = try ParsedArgs.parse(args, valueOptions: ["corpus", "in", "out"])
        guard parsed.positionals.isEmpty else { throw UsageError(message: "unexpected argument \(parsed.positionals[0])") }
        let corpusDir = URL(fileURLWithPath: try parsed.require("corpus"))
        let inURL = URL(fileURLWithPath: try parsed.require("in"))
        let outURL = URL(fileURLWithPath: try parsed.require("out"))

        let vocab = try JSON.read(VocabularyFile.self, from: corpusDir.appendingPathComponent("vocabulary.json"))
        let rules = vocab.rules.filter(\.enabled)
        var run = try JSONDecoder().decode(BakeoffRun.self, from: Data(contentsOf: inURL))
        let finalizer = TranscriptFinalizer()
        // Built-ins only, not ~/.claude, so a run scores the same on any machine.
        let formatter = SpokenFormatter(commands: SlashCommandCatalog.builtIns)
        for i in run.clips.indices {
            run.clips[i].text = await finalizer.finalize(run.clips[i].text, vocabulary: vocab.entries, rules: rules, formatter: formatter).text
        }
        run.engine += " +corrector"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(to: outURL)
        printErr("finalize: \(run.clips.count) clips -> \(outURL.path)")
    }
}
