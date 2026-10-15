import Foundation
import SusurrusKit

/// Confirms the references of unverified clips (tier C captures): plays
/// each one, shows the approved text, and takes one keystroke.
///
/// Every verdict is written straight away under the corpus lock, so the app
/// can keep capturing while a review is open and quitting loses nothing.
enum Review {
    static let usage = "review --corpus <corpusDir> [--no-play] [--threshold 0.15]"

    struct Tally {
        var accepted = 0, edited = 0, rejected = 0, skipped = 0
    }

    static func run(_ args: [String]) throws {
        let parsed = try ParsedArgs.parse(args, valueOptions: ["corpus", "threshold"], flagOptions: ["no-play"])
        guard parsed.positionals.isEmpty else { throw UsageError(message: "unexpected argument \(parsed.positionals[0])") }
        let corpus = EvalCorpus(directory: expandPath(try parsed.require("corpus")))
        var threshold = EvalReview.rewriteThreshold
        if let t = parsed.options["threshold"] {
            guard let v = Double(t), v >= 0 else { throw UsageError(message: "--threshold must be a non-negative number") }
            threshold = v
        }
        let player = ClipPlayer(enabled: !parsed.flags.contains("no-play"))
        defer { player.stop() }
        Terminal.installSignalHandlers()

        let pending = try corpus.readManifest().filter { !$0.verified }
        guard !pending.isEmpty else {
            printOut("Nothing to review: no unverified clips in \(corpus.directory.path).")
            return
        }
        printOut("\(pending.count) unverified clip(s). Keys: \(keyHelp)\n")

        var tally = Tally()
        clips: for (index, entry) in pending.enumerated() {
            show(entry, index: index, of: pending.count, threshold: threshold)
            let audio = corpus.audioURL(for: entry)
            let hasAudio = FileManager.default.fileExists(atPath: audio.path)
            if hasAudio { player.play(audio) } else { printOut(Terminal.yellow("  (audio missing: \(entry.audio))")) }

            while true {
                printOut(Terminal.dim("  \(keyHelp)"))
                guard let key = Terminal.choose(["a", "e", "r", "s", "p", "q"]) else {
                    printOut("(end of input)")
                    break clips
                }
                player.stop()
                switch key {
                case "a":
                    try setVerified(entry.id, reference: nil, in: corpus)
                    tally.accepted += 1
                    printOut(Terminal.green("  accepted"))
                case "e":
                    guard let edited = try editInEditor(entry.reference) else {
                        printOut("  edit cancelled (empty text); clip unchanged")
                        continue
                    }
                    try setVerified(entry.id, reference: edited, in: corpus)
                    tally.edited += 1
                    printOut(Terminal.green("  saved: ") + edited)
                case "r":
                    try reject(entry, in: corpus)
                    tally.rejected += 1
                    printOut(Terminal.red("  rejected (clip deleted)"))
                case "s":
                    tally.skipped += 1
                    printOut("  skipped")
                case "p":
                    if hasAudio { player.play(audio) }
                    continue
                default:  // "q"
                    break clips
                }
                printOut("")
                continue clips
            }
        }

        let remaining = (try? corpus.readManifest().filter { !$0.verified }.count) ?? 0
        printOut("accepted \(tally.accepted), edited \(tally.edited), rejected \(tally.rejected), skipped \(tally.skipped); \(remaining) still unverified")
    }

    static let keyHelp = "[a]ccept  [e]dit  [r]eject  [s]kip  [p]lay again  [q]uit"

    static func show(_ entry: EvalManifestEntry, index: Int, of total: Int, threshold: Double) {
        var header = "[\(index + 1)/\(total)] \(entry.id)"
        if let seconds = entry.seconds { header += String(format: "  %.1fs", seconds) }
        if let model = entry.model { header += "  \(model)" }
        printOut(Terminal.bold(header))
        printOut("  approved: \(entry.reference)")
        guard let raw = entry.raw else { return }
        if raw == entry.reference {
            printOut(Terminal.dim("  raw ASR:  (identical)"))
            return
        }
        printOut("  raw ASR:  \(raw)")
        printOut("  changes:  \(renderDiff(EvalReview.diff(raw: raw, approved: entry.reference)))")
        let wer = EvalReview.rawWER(raw: raw, approved: entry.reference)
        if wer > threshold {
            printOut(Terminal.yellow("  ⚠ probable rewrite: raw vs approved WER \(pct(wer)). Check the approved text is what you said."))
        }
    }

    /// Only the changed spans, with a little context: `… [raw → approved] …`.
    static func renderDiff(_ parts: [EvalReview.DiffPart]) -> String {
        var out: [String] = []
        for (i, part) in parts.enumerated() {
            switch part {
            case .same(let text):
                let words = text.split(separator: " ")
                let isFirst = i == 0, isLast = i == parts.count - 1
                if words.count <= 6 {
                    out.append(text)
                } else {
                    let head = isFirst ? "" : words.prefix(3).joined(separator: " ")
                    let tail = isLast ? "" : words.suffix(3).joined(separator: " ")
                    out.append([head, "…", tail].filter { !$0.isEmpty }.joined(separator: " "))
                }
            case .changed(let from, let to):
                out.append("[" + Terminal.red(from) + " → " + Terminal.green(to) + "]")
            case .removed(let from):
                out.append("[-" + Terminal.red(from) + "]")
            case .added(let to):
                out.append("[+" + Terminal.green(to) + "]")
            }
        }
        return out.joined(separator: " ")
    }

    static func setVerified(_ id: String, reference: String?, in corpus: EvalCorpus) throws {
        try corpus.update { entries in
            guard let i = entries.firstIndex(where: { $0.id == id }) else {
                printErr("note: \(id) is no longer in the manifest (evicted by the cap?)")
                return
            }
            if let reference { entries[i].reference = reference }
            entries[i].verified = true
        }
    }

    static func reject(_ entry: EvalManifestEntry, in corpus: EvalCorpus) throws {
        try corpus.update { entries in
            entries.removeAll { $0.id == entry.id }
        }
        try? FileManager.default.removeItem(at: corpus.audioURL(for: entry))
    }

    /// Opens `$VISUAL`/`$EDITOR` (default `vi`) on the text. Returns the
    /// result with surrounding whitespace trimmed, or nil when saved empty.
    static func editInEditor(_ text: String) throws -> String? {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("susurrus-review-\(UUID().uuidString).txt")
        try (text + "\n").write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let env = ProcessInfo.processInfo.environment
        let editor = [env["VISUAL"], env["EDITOR"]].compactMap { $0 }.first { !$0.isEmpty } ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The editor string may carry its own arguments ("code -w").
        process.arguments = ["-c", "\(editor) \"$1\"", "sh", file.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ToolError("editor '\(editor)' exited with status \(process.terminationStatus)") }

        let edited = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return edited.isEmpty ? nil : edited
    }
}
