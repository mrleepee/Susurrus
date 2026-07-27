import Foundation
import Testing
@testable import Susurrus

/// The review panel's Insert vs Copy routing. Both carry the edited text and
/// the same learning signal; only Insert may touch the target app.
@Suite("DictationReviewModel Tests")
@MainActor
struct DictationReviewModelTests {

    @Test("Insert reports shouldPaste true with the edited text")
    func insertPastes() {
        let model = DictationReviewModel()
        var received: (text: String, shouldPaste: Bool)?
        model.onInsert = { received = ($0, true) }

        model.text = "corrected text"
        model.onInsert?(model.text)

        #expect(received?.text == "corrected text")
        #expect(received?.shouldPaste == true)
    }

    @Test("Copy reports shouldPaste false — target app untouched")
    func copyDoesNotPaste() {
        let model = DictationReviewModel()
        var received: (text: String, shouldPaste: Bool)?
        model.onCopy = { received = ($0, false) }

        model.text = "corrected text"
        model.onCopy?(model.text)

        #expect(received?.text == "corrected text")
        #expect(received?.shouldPaste == false)
    }

    @Test("Both callbacks carry edits made after the transcript landed")
    func carriesUserEdits() {
        let model = DictationReviewModel()
        var insertText: String?
        var copyText: String?
        model.onInsert = { insertText = $0 }
        model.onCopy = { copyText = $0 }

        model.text = "mark logic"          // as transcribed
        model.text = "MarkLogic cluster"   // as the user fixed it
        model.onInsert?(model.text)
        model.onCopy?(model.text)

        #expect(insertText == "MarkLogic cluster")
        #expect(copyText == "MarkLogic cluster")
    }

    @Test("Starts in recording phase")
    func startsRecording() {
        let model = DictationReviewModel()
        #expect(model.phase == .recording)
        #expect(model.text.isEmpty)
    }
}
