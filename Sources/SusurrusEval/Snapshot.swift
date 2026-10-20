import Foundation
import SusurrusKit

/// Copies the live app's vocabulary, rules and history out of its
/// preferences domain. READ-ONLY: nothing here writes to that domain.
///
/// `VocabularyManager.init` seeds default entries and migrates legacy
/// words (it calls `setEntries`), so it must not be constructed against the
/// live domain; the stored JSON is decoded directly instead. Same for
/// `CorrectionLearningManager`, whose rules are read straight from the key.
enum Snapshot {
    static let usage = "snapshot --out <dir>"

    static let domain = "com.susurrus.app"
    // Read the raw keys: VocabularyManager.init seeds and migrates, which
    // must never happen against the live app domain.
    static let entriesKey = VocabularyManager.entriesStorageKey
    static let rulesKey = CorrectionLearningManager.rulesStorageKey

    static func run(_ args: [String]) throws {
        let parsed = try ParsedArgs.parse(args, valueOptions: ["out"])
        guard parsed.positionals.isEmpty else { throw UsageError(message: "unexpected argument \(parsed.positionals[0])") }
        let outDir = expandPath(try parsed.require("out"))

        guard let defaults = UserDefaults(suiteName: domain) else { throw ToolError("cannot open preferences domain \(domain)") }

        let entries: [VocabularyEntry] = decode([VocabularyEntry].self, defaults: defaults, key: entriesKey) ?? []
        let rules: [CorrectionRule] = decode([CorrectionRule].self, defaults: defaults, key: rulesKey) ?? []

        // TranscriptionHistoryManager's init and reads don't write.
        let history = TranscriptionHistoryManager(defaults: defaults)
        let items = history.items()
        let contextTerms = history.recentBiasTerms()

        let vocab = VocabularyFile(snapshotDate: Date(), entries: entries, rules: rules, contextTerms: contextTerms)
        try JSON.write(vocab, to: outDir.appendingPathComponent("vocabulary.json"))

        var lines: [ScriptEntry] = []
        for item in items {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let words = text.split(whereSeparator: \.isWhitespace).count
            lines.append(ScriptEntry(
                id: String(format: "hist-%03d", lines.count + 1), text: text,
                tags: ["history", words > 75 ? "long" : "short"], silenceSeconds: nil
            ))
        }
        try JSON.writeLines(lines, to: outDir.appendingPathComponent("history-texts.jsonl"))

        printOut("Snapshot written to \(outDir.path)")
        printOut("  vocabulary entries: \(entries.count)")
        printOut("  correction rules:   \(rules.count)")
        printOut("  context terms:      \(contextTerms.count)")
        printOut("  history texts:      \(lines.count) (\(lines.filter { $0.tags.contains("long") }.count) long)")
    }

    private static func decode<T: Decodable>(_ type: T.Type, defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
