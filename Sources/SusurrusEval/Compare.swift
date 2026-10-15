import Foundation
import SusurrusKit

enum Compare {
    static let usage = "compare <baseline.json> <candidate.json> [--gate]"

    /// Returns the process exit code.
    static func run(_ args: [String]) throws -> Int32 {
        let parsed = try ParsedArgs.parse(args, valueOptions: [], flagOptions: ["gate"])
        guard parsed.positionals.count == 2 else { throw UsageError(message: "compare needs exactly two run files") }
        let baseline = try JSON.read(RunFile.self, from: expandPath(parsed.positionals[0]))
        let candidate = try JSON.read(RunFile.self, from: expandPath(parsed.positionals[1]))

        // Compare like with like: only clips present in both runs.
        let baseByID = Dictionary(baseline.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let candByID = Dictionary(candidate.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let commonIDs = baseline.clips.map(\.id).filter { candByID[$0] != nil }
        let baseClips = commonIDs.compactMap { baseByID[$0] }
        let candClips = commonIDs.compactMap { candByID[$0] }
        let onlyBase = baseline.clips.count - commonIDs.count
        let onlyCand = candidate.clips.count - commonIDs.count

        printOut("baseline:  \(baseline.name) (\(baseline.gitCommit ?? "no commit"), \(baseline.clips.count) clips)")
        printOut("candidate: \(candidate.name) (\(candidate.gitCommit ?? "no commit"), \(candidate.clips.count) clips)")
        if onlyBase > 0 || onlyCand > 0 {
            printOut("WARNING: clip sets differ (\(onlyBase) only in baseline, \(onlyCand) only in candidate); comparing the \(commonIDs.count) common clips")
        }

        // Audio hash warning (never fails the gate).
        let hashChanged = commonIDs.filter { id in
            let a = baseByID[id]!.audioSHA256, b = candByID[id]!.audioSHA256
            return !a.isEmpty && !b.isEmpty && a != b
        }
        if !hashChanged.isEmpty {
            printOut("WARNING: audioSHA256 differs on \(hashChanged.count) clip(s) (e.g. \(hashChanged.prefix(3).joined(separator: ", "))). "
                + "A macOS update probably changed a `say` voice; the baseline needs regenerating.")
        }

        let baseOverall = Aggregation.aggregate(baseClips, stage: .final)
        let candOverall = Aggregation.aggregate(candClips, stage: .final)

        // Delta table, final stage.
        printOut("\nFinal-stage metrics (baseline -> candidate, delta):")
        let headers = ["group", "clips", "WER", "fmt err", "terms hit", "dropped", "inserted", "extra brk", "RTF"]
        var rows = [row("overall", baseClips, candClips)]
        let tags = Set(baseClips.flatMap(\.tags)).union(candClips.flatMap(\.tags)).sorted()
        for tag in tags {
            rows.append(row("tag:\(tag)", baseClips.filter { $0.tags.contains(tag) }, candClips.filter { $0.tags.contains(tag) }))
        }
        printOut(renderTable(headers: headers, rows: rows))

        // Changed clips, worst regression first.
        var changed: [(id: String, delta: Double)] = []
        for id in commonIDs {
            let d = candByID[id]!.scoreFinal.wer - baseByID[id]!.scoreFinal.wer
            if abs(d) > 1e-9 { changed.append((id, d)) }
        }
        changed.sort { $0.delta > $1.delta }
        printOut("\nClips whose final WER changed: \(changed.count)")
        for (id, delta) in changed {
            let b = baseByID[id]!, c = candByID[id]!
            printOut(String(format: "\n%@  %@ -> %@  (%+.1f pts)", id, pct(b.scoreFinal.wer), pct(c.scoreFinal.wer), delta * 100))
            if !c.reference.isEmpty { printOut("  ref:  \(truncate(c.reference))") }
            printOut("  base: \(truncate(b.final))")
            printOut("  cand: \(truncate(c.final))")
        }

        // Gate.
        var failures: [String] = []
        let werDelta = candOverall.score.wer - baseOverall.score.wer
        if werDelta > 0.005 {
            failures.append(String(format: "overall WER %@ -> %@ (+%.2f pts, limit 0.5)", pct(baseOverall.score.wer), pct(candOverall.score.wer), werDelta * 100))
        }
        let hitDelta = candOverall.score.termsHit - baseOverall.score.termsHit
        if hitDelta < -1 {
            failures.append("terms hit \(baseOverall.score.termsHit) -> \(candOverall.score.termsHit) (\(hitDelta); limit -1)")
        }
        if candOverall.score.droppedRuns > baseOverall.score.droppedRuns {
            failures.append("dropped runs \(baseOverall.score.droppedRuns) -> \(candOverall.score.droppedRuns)")
        }
        if candOverall.score.insertedRuns > baseOverall.score.insertedRuns {
            failures.append("inserted runs \(baseOverall.score.insertedRuns) -> \(candOverall.score.insertedRuns)")
        }
        for clip in candClips where clip.tags.contains("silence") && !clip.final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("silence clip \(clip.id) produced text: \"\(truncate(clip.final, to: 60))\"")
        }

        if parsed.flags.contains("gate") {
            if failures.isEmpty {
                printOut("\nGATE: PASS")
                return 0
            }
            printOut("\nGATE: FAIL")
            for f in failures { printOut("  - \(f)") }
            return 1
        }
        return 0
    }

    private static func row(_ name: String, _ base: [ClipResult], _ cand: [ClipResult]) -> [String] {
        let a = Aggregation.aggregate(base, stage: .final), b = Aggregation.aggregate(cand, stage: .final)
        func rate(_ x: Double, _ y: Double, _ present: Bool) -> String {
            present ? "\(pct(x))->\(pct(y)) (\(String(format: "%+.1f", (y - x) * 100)))" : "-"
        }
        func count(_ x: Int, _ y: Int, _ present: Bool) -> String {
            present ? "\(x)->\(y) (\(String(format: "%+d", y - x)))" : "-"
        }
        let both = !base.isEmpty && !cand.isEmpty
        return [
            name, "\(base.count)->\(cand.count)",
            rate(a.score.wer, b.score.wer, both),
            rate(a.score.formattedErrorRate, b.score.formattedErrorRate, both),
            count(a.score.termsHit, b.score.termsHit, both),
            count(a.score.droppedRuns, b.score.droppedRuns, both),
            count(a.score.insertedRuns, b.score.insertedRuns, both),
            count(a.score.extraSentenceBreaks, b.score.extraSentenceBreaks, both),
            both ? String(format: "%.2f->%.2f", a.rtf, b.rtf) : "-",
        ]
    }
}
