import AppKit
import Testing
@testable import Susurrus

/// The listening panel's behaviour over apps that capture the keyboard
/// (Amazon WorkSpaces): it must take focus when it opens, take it back if
/// the dictated-over app grabs it, let go once the text is delivered, and
/// route Esc / the close button / the footer to the recording, not just the
/// window. Also that streamed text lands in the panel while listening.
@Suite("DictationReviewPanel — focus and listening", .serialized)
@MainActor
struct DictationReviewPanelTests {

    private final class Counter { var value = 0 }

    /// A panel whose app activation is counted instead of performed, so the
    /// test runner isn't pulled to the front. The target is this process —
    /// any running app with a stable pid will do.
    private func makeListeningPanel() -> (DictationReviewPanel, Counter) {
        let panel = DictationReviewPanel()
        let activations = Counter()
        panel.activateApp = { activations.value += 1 }
        panel.beginRecording(targetApp: .current, isPushToTalk: false, editCombo: nil)
        return (panel, activations)
    }

    private var targetPID: pid_t { NSRunningApplication.current.processIdentifier }

    /// Reclaims are dispatched to the main queue; let it drain.
    private func drainMainQueue() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - Taking focus

    @Test("Opening to listen activates Susurrus and shows the panel")
    func listeningTakesFocus() {
        let (panel, activations) = makeListeningPanel()
        defer { panel.cancel() }

        #expect(activations.value == 1)
        #expect(panel.holdsFocus)
        #expect(panel.isVisible)
    }

    @Test("Reclaims focus when the dictated-over app takes it back")
    func reclaimsFromTargetApp() async throws {
        let (panel, activations) = makeListeningPanel()
        defer { panel.cancel() }

        #expect(panel.appActivated(pid: targetPID, bundleID: "com.amazon.workspaces"))
        try await drainMainQueue()
        #expect(activations.value == 2)
    }

    @Test("Leaves other apps alone, so the user can still switch away")
    func ignoresOtherApps() async throws {
        let (panel, activations) = makeListeningPanel()
        defer { panel.cancel() }

        #expect(!panel.appActivated(pid: targetPID &+ 100_000, bundleID: "com.example.other"))
        try await drainMainQueue()
        #expect(activations.value == 1)
    }

    @Test("Stops reclaiming after a bounded number of tries")
    func reclaimIsBounded() async throws {
        let (panel, activations) = makeListeningPanel()
        defer { panel.cancel() }

        for _ in 0..<DictationReviewPanel.maxFocusReclaims {
            #expect(panel.appActivated(pid: targetPID, bundleID: nil))
        }
        #expect(!panel.appActivated(pid: targetPID, bundleID: nil))
        try await drainMainQueue()
        #expect(activations.value == 1 + DictationReviewPanel.maxFocusReclaims)
    }

    @Test("A new session gets a fresh reclaim budget")
    func reclaimBudgetResetsPerSession() {
        let (panel, _) = makeListeningPanel()
        defer { panel.cancel() }
        for _ in 0...DictationReviewPanel.maxFocusReclaims {
            panel.appActivated(pid: targetPID, bundleID: nil)
        }

        panel.beginRecording(targetApp: .current, isPushToTalk: false, editCombo: nil)
        #expect(panel.appActivated(pid: targetPID, bundleID: nil))
    }

    // MARK: - Letting go

    @Test("Releasing before delivery stops reclaiming, so Insert can hand focus back")
    func releaseBeforeDelivery() {
        let (panel, _) = makeListeningPanel()
        defer { panel.cancel() }

        panel.releaseFocus()
        #expect(!panel.holdsFocus)
        #expect(!panel.appActivated(pid: targetPID, bundleID: nil))
    }

    @Test("Showing the result releases focus")
    func finishedReleasesFocus() {
        let (panel, _) = makeListeningPanel()
        defer { panel.cancel() }

        panel.showFinished("done", message: "Copied to Clipboard")
        #expect(!panel.holdsFocus)
        #expect(!panel.appActivated(pid: targetPID, bundleID: nil))
    }

    @Test("Cancelling hides the panel and releases focus")
    func cancelReleasesFocus() {
        let (panel, _) = makeListeningPanel()

        panel.cancel()
        #expect(!panel.holdsFocus)
        #expect(!panel.isVisible)
    }

    @Test("The editor keeps holding focus")
    func editingHoldsFocus() {
        let (panel, activations) = makeListeningPanel()
        defer { panel.cancel() }

        panel.beginProcessing()
        panel.enterEditing(finalText: "final") { _, _ in }
        #expect(panel.holdsFocus)
        #expect(activations.value == 2)
        #expect(panel.model.phase == .editing)
    }

    // MARK: - Live text

    @Test("Streamed text shows in the panel while listening")
    func liveTextReachesPanel() {
        let (panel, _) = makeListeningPanel()
        defer { panel.cancel() }

        panel.updateStreaming("hello")
        panel.updateStreaming("hello world")
        #expect(panel.model.text == "hello world")
    }

    @Test("A new session starts with no leftover text")
    func newSessionClearsText() {
        let (panel, _) = makeListeningPanel()
        defer { panel.cancel() }
        panel.updateStreaming("previous dictation")

        panel.beginRecording(targetApp: .current, isPushToTalk: false, editCombo: nil)
        #expect(panel.model.text.isEmpty)
        #expect(panel.model.phase == .recording)
    }

    @Test("Late preview ticks after the mic closes don't overwrite the panel")
    func lateTicksIgnored() {
        let (panel, _) = makeListeningPanel()
        defer { panel.cancel() }
        panel.updateStreaming("spoken words")

        panel.beginProcessing()
        panel.updateStreaming("stale tick")
        #expect(panel.model.text == "spoken words")
    }

    // MARK: - Cancel and footer routing

    @Test("Esc while listening cancels the recording, not just the window")
    func escCancelsRecording() {
        let (panel, _) = makeListeningPanel()
        defer { panel.cancel() }
        let cancels = Counter()
        panel.onCancelRecording = { cancels.value += 1 }

        panel.cancelOperation(nil)
        #expect(cancels.value == 1)
    }

    @Test("The close button while listening cancels the recording")
    func closeButtonCancelsRecording() {
        let (panel, _) = makeListeningPanel()
        defer { panel.cancel() }
        let cancels = Counter()
        panel.onCancelRecording = { cancels.value += 1 }

        panel.performClose(nil)
        #expect(cancels.value == 1)
    }

    @Test("Esc in the editor just closes the panel")
    func escInEditorCloses() {
        let (panel, _) = makeListeningPanel()
        let cancels = Counter()
        panel.onCancelRecording = { cancels.value += 1 }
        panel.beginProcessing()
        panel.enterEditing(finalText: "final") { _, _ in }

        panel.cancelOperation(nil)
        #expect(cancels.value == 0)
        #expect(!panel.isVisible)
        #expect(!panel.holdsFocus)
    }

    @Test("Footer Copy / Insert / Review / Cancel reach the app's handlers")
    func footerRouting() {
        let (panel, _) = makeListeningPanel()
        defer { panel.cancel() }
        var finishes: [DictationReviewPanel.QuickFinish?] = []
        let cancels = Counter()
        panel.onFinishRecording = { finishes.append($0) }
        panel.onCancelRecording = { cancels.value += 1 }

        // What the footer buttons call.
        panel.model.onFinishRecording?(.copy)
        panel.model.onFinishRecording?(.insert)
        panel.model.onFinishRecording?(nil)
        panel.model.onCancelRecording?()

        #expect(finishes == [.copy, .insert, nil])
        #expect(cancels.value == 1)
    }
}

/// Esc in the editor hands the text over to be kept for a restore, and the
/// panel still closes at once — no lingering undo prompt.
@Suite("DictationReviewPanel — discard and restore", .serialized)
@MainActor
struct DictationReviewPanelDiscardTests {

    private func makeEditingPanel(text: String) -> DictationReviewPanel {
        let panel = DictationReviewPanel()
        panel.activateApp = {}
        panel.beginRecording(targetApp: .current, isPushToTalk: false, editCombo: nil)
        panel.beginProcessing()
        panel.enterEditing(finalText: text) { _, _ in }
        return panel
    }

    @Test("Esc in the editor reports the edited text and closes immediately")
    func escInEditorReportsText() {
        let panel = makeEditingPanel(text: "as transcribed")
        var kept: [String] = []
        panel.onDiscardEdits = { kept.append($0) }
        panel.model.text = "as the user fixed it"

        panel.cancelOperation(nil)
        #expect(kept == ["as the user fixed it"])
        #expect(!panel.isVisible)
    }

    @Test("The editor's Cancel button reports the text too")
    func cancelButtonReportsText() {
        let panel = makeEditingPanel(text: "some text")
        var kept: [String] = []
        panel.onDiscardEdits = { kept.append($0) }

        panel.model.onCancel?()
        #expect(kept == ["some text"])
        #expect(!panel.isVisible)
    }

    @Test("Esc while listening doesn't report editor text — the app keeps the audio")
    func escWhileListeningNotEdits() {
        let panel = DictationReviewPanel()
        panel.activateApp = {}
        panel.beginRecording(targetApp: .current, isPushToTalk: false, editCombo: nil)
        defer { panel.cancel() }
        var kept: [String] = []
        panel.onDiscardEdits = { kept.append($0) }
        panel.onCancelRecording = {}

        panel.cancelOperation(nil)
        #expect(kept.isEmpty)
    }

    @Test("A new dictation drops the previous session's discard hook")
    func newSessionClearsHook() {
        let panel = makeEditingPanel(text: "old")
        panel.onDiscardEdits = { _ in Issue.record("stale hook fired") }

        panel.beginRecording(targetApp: .current, isPushToTalk: false, editCombo: nil)
        panel.beginProcessing()
        panel.enterEditing(finalText: "new") { _, _ in }
        panel.cancelOperation(nil)
    }

    @Test("Restoring reopens the panel processing, focused, pasting to the original app")
    func beginRestoring() {
        let panel = DictationReviewPanel()
        var activations = 0
        panel.activateApp = { activations += 1 }
        defer { panel.cancel() }

        panel.beginRestoring(targetApp: .current)
        #expect(panel.model.phase == .processing)
        #expect(panel.targetApp == .current)
        #expect(panel.isVisible)
        #expect(panel.holdsFocus)
        #expect(activations == 1)

        panel.enterEditing(finalText: "restored") { _, _ in }
        #expect(panel.model.text == "restored")
        #expect(panel.model.phase == .editing)
    }
}
