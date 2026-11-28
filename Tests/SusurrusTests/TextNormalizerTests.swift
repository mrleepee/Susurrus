import Foundation
import Testing
@testable import SusurrusKit

@Suite("TextNormalizer Tests")
struct TextNormalizerTests {

    @Test("UK and US are written one way", arguments: [
        ("moving to the U.K. next year", "moving to the UK next year"),
        ("moving to the U K. next year", "moving to the UK next year"),
        ("the U. K. and the U.S. differ", "the UK and the US differ"),
        ("I live in the U.K.", "I live in the UK."),
        ("back to the U K. Then home", "back to the UK. Then home"),
        ("the U S market", "the US market"),
    ])
    func abbreviations(input: String, expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test("Other text is untouched", arguments: [
        "the UK and the US",
        "plug in the USB stick",
        "U.S.A. is longer",
        "let us know",
        "a U-turn",
        "Ahmed U Khan",
    ])
    func untouched(input: String) {
        #expect(TextNormalizer.normalize(input) == input)
    }

    @Test("Qwen's slips are fixed", arguments: [
        ("we应该put it all together", "we put it all together"),
        ("I don''t want that", "I don't want that"),
        ("we haven' t seen it", "we haven't seen it"),
        ("I don'. T know", "I don't know"),
        ("we don' need it", "we don't need it"),
        ("It'S fine", "It's fine"),
        ("the run,s and the buildin.g", "the runs and the building"),
        ("there,'s a problem", "there's a problem"),
        ("I, don't think so", "I don't think so"),
        ("I'd, like that", "I'd like that"),
        ("we need to be. published soon", "we need to be published soon"),
        ("Done. . Next", "Done. Next"),
        ("then i said no", "then I said no"),
        ("we have Our data", "we have our data"),
        ("I Can do it", "I can do it"),
        ("if it's pinned, It doesn't move", "if it's pinned, it doesn't move"),
        ("I I should go", "I should go"),
        ("we must we must win", "we must win"),
        ("Push master master now", "Push master now"),
    ])
    func qwenSlips(input: String, expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test("Spoken numbers become digits", arguments: [
        ("scaling the cluster to twelve", "scaling the cluster to 12"),
        ("it took eight seconds", "it took 8 seconds"),
        ("up to forty percent", "up to 40%"),
        ("about twenty-four hosts", "about 24 hosts"),
        ("after a hundred and eighty days", "after 180 days"),
        ("we have thirty-one thousand rows", "we have 31,000 rows"),
        ("over one million records", "over 1 million records"),
        ("about seven point five", "about 7.5"),
        ("from one to one hundred", "from one to 100"),
        ("move it to EC two", "move it to EC2"),
        ("read it from S three", "read it from S3"),
        ("rank with BM twenty five", "rank with BM25"),
        ("the CR one hundred list", "the CR100 list"),
        ("about twelve to sixteen hours", "about 12 to 16 hours"),
    ])
    func numbers(input: String, expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test("Ordinary text is left alone", arguments: [
        "one objective is to ship",
        "let me know at seven thirty",
        "three six nine three",
        "we said twenty twenty, then",
        "go from sixteen a hundred",
        "Twenty people came.",
        "it costs one dollar twenty-five",
        "I had had enough",
        "bye bye for now",
        "use e.g. this one at 8 a.m. today",
        "Back To The Future is a film",
        "node.js and i.e. that",
        "The plan is fine. Then we go",
        "It's two of them",
    ])
    func ordinary(input: String) {
        #expect(TextNormalizer.normalize(input) == input)
    }

    @Test("Scorer mode converts every number")
    func scorerMode() {
        #expect(TextNormalizer.spokenNumbers("Twenty four and one", all: true) == "24 and 1")
    }
}
