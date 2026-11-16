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
}
