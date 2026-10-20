import Testing
@testable import SusurrusKit

@Suite("TranscriptScorer")
struct TranscriptScorerTests {

    // MARK: - Normalization

    @Test("Normalization folds case, punctuation, hyphens and numbers")
    func normalization() {
        #expect(TranscriptScorer.normalizedWords("Thirty-percent, OK?") == ["30", "percent", "okay"])
        #expect(TranscriptScorer.normalizedWords("30% okay") == ["30", "percent", "okay"])
        #expect(TranscriptScorer.normalizedWords("the first 10,000.") == ["the", "first", "10000"])
        #expect(TranscriptScorer.normalizedWords("It’s 'quoted'") == ["it's", "quoted"])
    }

    @Test("British and American spellings compare equal")
    func spellingVariants() {
        let score = TranscriptScorer.score(reference: "I realised the colour", hypothesis: "I realized the color")
        #expect(score.errors == 0)
    }

    @Test("Formatted tokens keep case, split punctuation, keep compound words")
    func formattedTokens() {
        #expect(TranscriptScorer.formattedTokens("Use xdmp:apply on dev-full, then stop.")
            == ["Use", "xdmp:apply", "on", "dev-full", ",", "then", "stop", "."])
        #expect(TranscriptScorer.formattedTokens("a c8gd.2xlarge box") == ["a", "c8gd.2xlarge", "box"])
    }

    // MARK: - WER

    @Test("Identical text scores zero errors")
    func identical() {
        let score = TranscriptScorer.score(reference: "Hello there, world.", hypothesis: "Hello there, world.")
        #expect(score.errors == 0)
        #expect(score.formattedErrors == 0)
        #expect(score.wer == 0)
    }

    @Test("Counts substitutions, deletions and insertions")
    func editCounts() {
        let score = TranscriptScorer.score(
            reference: "check the document root now",
            hypothesis: "check the document route right now please"
        )
        #expect(score.referenceWords == 5)
        #expect(score.substitutions == 1)
        #expect(score.insertions == 2)
        #expect(score.deletions == 0)
        #expect(abs(score.wer - 0.6) < 1e-9)
    }

    @Test("Case and punctuation errors count only in the formatted rate")
    func formattedOnly() {
        let score = TranscriptScorer.score(reference: "the document cache", hypothesis: "The Document Cache.")
        #expect(score.errors == 0)
        #expect(score.formattedErrors == 4)
    }

    @Test("Empty reference with output is a full error, not a division by zero")
    func emptyReference() {
        #expect(TranscriptScorer.score(reference: "", hypothesis: "").wer == 0)
        let hallucinated = TranscriptScorer.score(reference: "", hypothesis: "Thank you for watching.")
        #expect(hallucinated.wer == 1)
        #expect(hallucinated.insertions == 4)
        #expect(hallucinated.insertedRuns == 1)
    }

    // MARK: - Runs

    @Test("Three consecutive missing words count as one dropped run")
    func droppedRun() {
        let score = TranscriptScorer.score(
            reference: "please tell them first before the meeting",
            hypothesis: "please before the meeting"
        )
        #expect(score.deletions == 3)
        #expect(score.droppedRuns == 1)
    }

    @Test("Two consecutive missing words are not a run")
    func shortGapIsNotRun() {
        let score = TranscriptScorer.score(reference: "a b c d e", hypothesis: "a d e")
        #expect(score.droppedRuns == 0)
    }

    @Test("Invented trailing phrase counts as an inserted run")
    func insertedRun() {
        let score = TranscriptScorer.score(
            reference: "ship it today",
            hypothesis: "ship it today if you're interested in getting a copy"
        )
        #expect(score.insertedRuns == 1)
    }

    // MARK: - Sentence breaks

    @Test("A full stop where the reference has a comma is an extra break")
    func commaBecomesFullStop() {
        let score = TranscriptScorer.score(
            reference: "at 1 million, for example, we get the count.",
            hypothesis: "at 1 million. For example, we get the count."
        )
        #expect(score.extraSentenceBreaks == 1)
    }

    @Test("A full stop inserted mid-sentence is an extra break")
    func insertedFullStop() {
        let score = TranscriptScorer.score(
            reference: "requests per second for each service",
            hypothesis: "requests. Per second for each service"
        )
        #expect(score.extraSentenceBreaks == 1)
    }

    @Test("Matching sentence ends are not extra breaks")
    func matchingBreaks() {
        let score = TranscriptScorer.score(reference: "One. Two. Three.", hypothesis: "One. Two. Three.")
        #expect(score.extraSentenceBreaks == 0)
    }

    // MARK: - Terms

    @Test("Terms are matched exactly and case-sensitively")
    func termRecall() {
        let score = TranscriptScorer.score(
            reference: "MarkLogic runs XQuery and XQuery again",
            hypothesis: "Marklogic runs XQuery and query again",
            terms: ["MarkLogic", "XQuery"]
        )
        #expect(score.termsExpected == 3)
        #expect(score.termsHit == 1)
        #expect(score.missedTerms == ["MarkLogic", "XQuery"])
        #expect(score.termFalseFires == 0)
    }

    @Test("A term in the output that was never said is a false fire")
    func termFalseFire() {
        let score = TranscriptScorer.score(
            reference: "your eyes are tired",
            hypothesis: "URIs are tired",
            terms: ["URIs"]
        )
        #expect(score.termsExpected == 0)
        #expect(score.termFalseFires == 1)
    }

    @Test("Term matching respects word boundaries but allows punctuation joins")
    func termBoundaries() {
        #expect(TranscriptScorer.occurrences(of: "CTS", in: "CTSs and CTS:Register") == 1)
        #expect(TranscriptScorer.occurrences(of: "CAS", in: "CAS-approved hash") == 1)
    }

    // MARK: - Aggregation

    @Test("Summing scores aggregates counts so WER is word-weighted")
    func aggregation() {
        let a = TranscriptScorer.score(reference: "one two three four", hypothesis: "one two three four")
        let b = TranscriptScorer.score(reference: "five six", hypothesis: "five seven")
        let total = a + b
        #expect(total.referenceWords == 6)
        #expect(total.errors == 1)
        #expect(abs(total.wer - 1.0 / 6.0) < 1e-9)
    }
}
