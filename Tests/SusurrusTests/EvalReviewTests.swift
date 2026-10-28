import Testing
@testable import SusurrusKit

@Suite("EvalReview — rewrite detection and raw→approved diff")
struct EvalReviewTests {

    @Test("A recognition fix is not flagged as a rewrite")
    func smallFixNotFlagged() {
        let raw = "We should move the mark logic job to dev full before Friday and tell the team"
        let approved = "We should move the MarkLogic job to dev-full before Friday and tell the team."
        #expect(!EvalReview.isProbableRewrite(raw: raw, approved: approved))
    }

    @Test("Casing and punctuation edits alone never count toward the rewrite WER")
    func formattingOnly() {
        #expect(EvalReview.rawWER(raw: "the cts query. Runs fast", approved: "The CTS query runs fast.") == 0)
    }

    @Test("Rewording well over 15% is flagged")
    func rewordingFlagged() {
        let raw = "we need some kind of formal communication about this"
        let approved = "we need a meeting and an MVP being defined about this"
        #expect(EvalReview.rawWER(raw: raw, approved: approved) > 0.15)
        #expect(EvalReview.isProbableRewrite(raw: raw, approved: approved))
    }

    @Test("The threshold is exclusive and adjustable")
    func threshold() {
        // 1 substitution in 5 reference words = 20%.
        let raw = "one two three four nine", approved = "one two three four five"
        #expect(EvalReview.isProbableRewrite(raw: raw, approved: approved, threshold: 0.15))
        #expect(!EvalReview.isProbableRewrite(raw: raw, approved: approved, threshold: 0.2))
    }

    @Test("Diff merges adjacent edits and keeps unchanged runs together")
    func diffParts() {
        let parts = EvalReview.diff(raw: "ask bell vinder about mark logic today", approved: "ask Balvinder about MarkLogic today")
        #expect(parts == [
            .same("ask"),
            .changed(from: "bell vinder", to: "Balvinder"),
            .same("about"),
            .changed(from: "mark logic", to: "MarkLogic"),
            .same("today"),
        ])
    }

    @Test("Diff reports pure insertions and deletions")
    func diffInsertDelete() {
        #expect(EvalReview.diff(raw: "a b c", approved: "a b c d") == [.same("a b c"), .added("d")])
        #expect(EvalReview.diff(raw: "a b c d", approved: "a b c") == [.same("a b c"), .removed("d")])
        #expect(EvalReview.diff(raw: "same", approved: "same") == [.same("same")])
    }
}
