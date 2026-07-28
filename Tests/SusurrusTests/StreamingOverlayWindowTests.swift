import Testing
@testable import Susurrus

/// Regression coverage for the "blank thing appears and disappears" report:
/// the overlay used to show() an empty card the instant recording started
/// (before any words existed) and beginFinalizing() would pop one up from
/// nothing when a session captured no speech at all.
@Suite("StreamingOverlayWindow Tests")
@MainActor
struct StreamingOverlayWindowTests {

    @Test("show() does not appear for an empty confirmed/unconfirmed pair")
    func showSuppressesEmptyContent() {
        let overlay = StreamingOverlayWindow()
        overlay.show(confirmed: "", unconfirmed: "")
        #expect(!overlay.isShowing)
    }

    @Test("show() appears once there is real text")
    func showAppearsWithRealText() {
        let overlay = StreamingOverlayWindow()
        overlay.show(confirmed: "hello", unconfirmed: "")
        #expect(overlay.isShowing)
    }

    @Test("show() keeps updating through a momentary empty tick once visible")
    func showStaysVisibleOnMomentaryEmptyTick() {
        let overlay = StreamingOverlayWindow()
        overlay.show(confirmed: "hello ", unconfirmed: "world")
        overlay.show(confirmed: "hello world", unconfirmed: "")
        #expect(overlay.isShowing)
    }

    @Test("beginFinalizing() is a no-op if nothing was ever shown — no speech, no flash")
    func beginFinalizingNoOpWhenNeverShown() {
        let overlay = StreamingOverlayWindow()
        overlay.beginFinalizing()
        #expect(!overlay.isShowing)
    }

    @Test("beginFinalizing() proceeds once real text was already showing")
    func beginFinalizingProceedsWhenAlreadyShowing() {
        let overlay = StreamingOverlayWindow()
        overlay.show(confirmed: "hello", unconfirmed: "")
        overlay.beginFinalizing()
        #expect(overlay.isShowing)
    }

    // MARK: - showMessage (replaces a system notification proven unreliable
    // on this machine: UNUserNotificationCenter has been observed dropping
    // banner bodies for this app).

    @Test("showMessage() displays immediately")
    func showMessageDisplays() {
        let overlay = StreamingOverlayWindow()
        overlay.showMessage("No speech detected")
        #expect(overlay.isShowing)
    }

    @Test("showMessage() overrides a stuck finalizing state")
    func showMessageOverridesFinalizing() {
        let overlay = StreamingOverlayWindow()
        overlay.show(confirmed: "hello", unconfirmed: "")
        overlay.beginFinalizing()
        // show()'s isFinalizing guard would otherwise block this.
        overlay.showMessage("No speech detected")
        #expect(overlay.isShowing)
    }

    @Test("A generic hide() while a message is showing does not cut it short")
    func genericHideDoesNotCutMessageShort() {
        let overlay = StreamingOverlayWindow()
        overlay.showMessage("No speech detected", duration: 30)
        // Mirrors stopStreamingSession's unconditional end-of-session hide().
        overlay.hide()
        #expect(overlay.isShowing)
    }
}
