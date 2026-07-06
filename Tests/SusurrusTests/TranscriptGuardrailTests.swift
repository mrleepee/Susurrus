import Foundation
import Testing
@testable import SusurrusKit

@Suite("TranscriptGuardrail Tests")
struct TranscriptGuardrailTests {

    @Test("Punctuation and casing cleanup is accepted")
    func acceptsCleanup() {
        let input = "so i think we should um ship the marklogic connector on friday"
        let output = "So I think we should ship the MarkLogic connector on Friday."
        #expect(TranscriptGuardrail.accepts(input: input, output: output))
    }

    @Test("Identical text is accepted")
    func acceptsIdentical() {
        let text = "Nothing to fix here."
        #expect(TranscriptGuardrail.accepts(input: text, output: text))
    }

    @Test("Wholesale rephrasing is rejected")
    func rejectsRephrase() {
        let input = "we need to move the deployment to thursday because the cluster is down"
        let output = "The deployment has been rescheduled owing to infrastructure unavailability."
        #expect(!TranscriptGuardrail.accepts(input: input, output: output))
    }

    @Test("Answering instead of correcting is rejected")
    func rejectsAnswer() {
        let input = "what time is the standup tomorrow"
        let output = "The standup is at 9:30 AM every weekday. Let me know if you need a calendar invite."
        #expect(!TranscriptGuardrail.accepts(input: input, output: output))
    }

    @Test("Severe truncation is rejected")
    func rejectsTruncation() {
        let input = "first point about the budget second point about hiring third point about the roadmap for next quarter"
        let output = "First point about the budget."
        #expect(!TranscriptGuardrail.accepts(input: input, output: output))
    }

    @Test("Empty output is rejected")
    func rejectsEmpty() {
        #expect(!TranscriptGuardrail.accepts(input: "some text", output: ""))
    }

    @Test("Filler-word removal is accepted")
    func acceptsFillerRemoval() {
        let input = "um so like i was thinking you know we could uh refactor the parser"
        let output = "So I was thinking we could refactor the parser."
        #expect(TranscriptGuardrail.accepts(input: input, output: output))
    }
}
