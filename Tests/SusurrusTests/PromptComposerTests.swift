import Testing
@testable import SusurrusKit

@Suite("Prompt Composer Tests")
struct PromptComposerTests {

    private let composer = PromptComposer()

    @Test("Base only returns base unchanged")
    func baseOnly() {
        let result = composer.compose(base: "Clean up transcription text.")
        #expect(result == "Clean up transcription text.")
    }

    @Test("All sections populated produces correctly formatted output")
    func allSections() {
        let result = composer.compose(
            base: "Clean up text.",
            vocabularyContext: "DataBid is a product name.",
            correctionExamples: "Raw: \"data bid\" → Fixed: \"DataBid\""
        )
        #expect(result.contains("Clean up text."))
        #expect(result.contains("Vocabulary guidance:"))
        #expect(result.contains("DataBid is a product name."))
        #expect(result.contains("Examples of previous corrections by this user:"))
    }

    @Test("Empty sections are omitted")
    func emptySectionsOmitted() {
        let result = composer.compose(
            base: "Clean up text.",
            vocabularyContext: "DataBid is a product name.",
            correctionExamples: ""
        )
        #expect(result.contains("Vocabulary guidance:"))
        #expect(!result.contains("Examples of previous corrections"))
    }

    @Test("All empty context returns just base")
    func allEmptyContext() {
        let result = composer.compose(
            base: "Clean up text.",
            vocabularyContext: "",
            correctionExamples: ""
        )
        #expect(result == "Clean up text.")
    }

    @Test("Whitespace-only sections are treated as empty")
    func whitespaceOnlySections() {
        let result = composer.compose(
            base: "Clean up text.",
            vocabularyContext: "   \n  ",
            correctionExamples: "\n"
        )
        #expect(result == "Clean up text.")
    }

    @Test("Sections are separated by double newline")
    func sectionSeparators() {
        let result = composer.compose(
            base: "Base prompt.",
            vocabularyContext: "Vocab info."
        )
        #expect(result == "Base prompt.\n\nVocabulary guidance:\nVocab info.")
    }
}
