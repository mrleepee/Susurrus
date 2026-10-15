import Foundation

/// Pure helpers for `susurrus-eval review`, which confirms the candidate
/// references of captured clips.
public enum EvalReview {
    /// Raw-vs-approved normalized WER above this suggests the user reworded
    /// the dictation rather than fixing recognition errors, so the approved
    /// text is probably not what was said.
    public static let rewriteThreshold = 0.15

    /// Normalized WER of the raw ASR against the approved text.
    public static func rawWER(raw: String, approved: String) -> Double {
        TranscriptScorer.score(reference: approved, hypothesis: raw).wer
    }

    public static func isProbableRewrite(raw: String, approved: String, threshold: Double = rewriteThreshold) -> Bool {
        rawWER(raw: raw, approved: approved) > threshold
    }

    /// One piece of a token diff from raw ASR to approved text.
    public enum DiffPart: Equatable, Sendable {
        case same(String)
        case changed(from: String, to: String)
        case removed(String)
        case added(String)
    }

    /// Case- and punctuation-sensitive token diff from `raw` to `approved`,
    /// with adjacent edits merged so a reworded phrase reads as one change.
    public static func diff(raw: String, approved: String) -> [DiffPart] {
        let a = TranscriptScorer.formattedTokens(raw)
        let b = TranscriptScorer.formattedTokens(approved)
        var parts: [DiffPart] = []
        var i = 0, j = 0
        var pendingFrom: [String] = [], pendingTo: [String] = []

        func flush() {
            switch (pendingFrom.isEmpty, pendingTo.isEmpty) {
            case (false, false):
                parts.append(.changed(from: pendingFrom.joined(separator: " "), to: pendingTo.joined(separator: " ")))
            case (false, true): parts.append(.removed(pendingFrom.joined(separator: " ")))
            case (true, false): parts.append(.added(pendingTo.joined(separator: " ")))
            case (true, true): break
            }
            pendingFrom = []
            pendingTo = []
        }

        for op in TranscriptScorer.align(a, b) {
            switch op {
            case .match:
                flush()
                if case .same(let prev) = parts.last {
                    parts[parts.count - 1] = .same(prev + " " + a[i])
                } else {
                    parts.append(.same(a[i]))
                }
                i += 1; j += 1
            case .substitute:
                pendingFrom.append(a[i]); pendingTo.append(b[j])
                i += 1; j += 1
            case .delete:
                pendingFrom.append(a[i]); i += 1
            case .insert:
                pendingTo.append(b[j]); j += 1
            }
        }
        flush()
        return parts
    }
}
