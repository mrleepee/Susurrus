import Testing
@testable import SusurrusKit

@Suite("Vocabulary Tests")
struct VocabularyTests {

    private func makeManager() -> VocabularyManager {
        VocabularyManager.createForTesting()
    }

    @Test("Empty vocabulary by default")
    func emptyByDefault() {
        let manager = makeManager()
        #expect(manager.vocabularyWords().isEmpty)
    }

    @Test("Set and get vocabulary words")
    func setAndGetWords() {
        let manager = makeManager()
        manager.setVocabularyWords(["algorithm", "API", "recursion"])
        #expect(manager.vocabularyWords() == ["algorithm", "API", "recursion"])
    }

    @Test("Prompt string joins with comma and space")
    func promptString() {
        let manager = makeManager()
        manager.setVocabularyWords(["Swift", "Objective-C"])
        #expect(manager.promptString() == "Swift, Objective-C")
    }

    @Test("Empty vocabulary gives empty prompt")
    func emptyPrompt() {
        let manager = makeManager()
        #expect(manager.promptString() == "")
    }

    @Test("Single word has no separator")
    func singleWord() {
        let manager = makeManager()
        manager.setVocabularyWords(["Kubernetes"])
        #expect(manager.promptString() == "Kubernetes")
    }

    @Test("Overwrite replaces previous words")
    func overwriteWords() {
        let manager = makeManager()
        manager.setVocabularyWords(["old"])
        manager.setVocabularyWords(["new"])
        #expect(manager.vocabularyWords() == ["new"])
    }

    @Test("VocabularyError equality")
    func errorEquality() {
        #expect(VocabularyError.wordTooLong("a") == VocabularyError.wordTooLong("a"))
        #expect(VocabularyError.tooManyWords(1) == VocabularyError.tooManyWords(1))
        #expect(VocabularyError.tooManyWords(1) != VocabularyError.tooManyWords(2))
    }
}
