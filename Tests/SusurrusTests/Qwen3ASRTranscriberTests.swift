import Testing
@testable import SusurrusKit

@Suite("Qwen3ASRTranscriber Tests")
struct Qwen3ASRTranscriberTests {

    @Test("Context is the ranked terms, comma-separated, blanks dropped")
    func contextFormat() {
        #expect(Qwen3ASRTranscriber.context(for: ["Balvinder", " MarkLogic ", "", "SPARQL"])
                == "Balvinder, MarkLogic, SPARQL")
    }

    @Test("No terms means no context")
    func emptyContext() {
        #expect(Qwen3ASRTranscriber.context(for: []) == nil)
        #expect(Qwen3ASRTranscriber.context(for: ["  "]) == nil)
    }

    @Test("Context keeps only the top-ranked terms")
    func contextCap() {
        let terms = (1...60).map { "Term\($0)" }
        let parts = Qwen3ASRTranscriber.context(for: terms)?.components(separatedBy: ", ") ?? []
        #expect(parts.count == Qwen3ASRTranscriber.maxContextTerms)
        #expect(parts.first == "Term1")
    }

    @Test("Qwen3-ASR is a supported model id")
    func catalog() {
        #expect(Qwen3ASRTranscriber.isQwen3("qwen3-asr-1.7b"))
        #expect(!Qwen3ASRTranscriber.isQwen3("parakeet-v2"))
        #expect(TranscriptionModelCatalog.isSupported(Qwen3ASRTranscriber.modelID))
        #expect(TranscriptionModelCatalog.defaultModel == ParakeetTranscriber.Variant.v2.rawValue)
    }
}
