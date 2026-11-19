import AppKit
import Testing
@testable import Susurrus
@testable import SusurrusKit

/// Undoing an accidental Esc: only the last discard is kept, in memory, and
/// restoring it is one-shot.
@Suite("Discarded dictation store")
@MainActor
struct DiscardedDictationStoreTests {

    private let speech = [Float](repeating: 0.1, count: DiscardedDictationStore.minAudioSamples)

    @Test("Keeps audio discarded while listening")
    func keepsAudio() {
        let store = DiscardedDictationStore()
        #expect(store.keep(.audio(samples: speech, preview: "hello"), targetApp: .current))
        #expect(store.item?.content == .audio(samples: speech, preview: "hello"))
        #expect(store.item?.targetApp == .current)
    }

    @Test("Keeps text discarded from the editor")
    func keepsText() {
        let store = DiscardedDictationStore()
        #expect(store.keep(.text(edited: "fixed", corrected: "fixd", raw: "fixd"), targetApp: nil))
        #expect(store.hasItem)
    }

    @Test("Ignores a cancel with nothing in it, keeping the previous discard")
    func ignoresEmpty() {
        let store = DiscardedDictationStore()
        store.keep(.text(edited: "worth keeping", corrected: "", raw: ""), targetApp: nil)

        #expect(!store.keep(.audio(samples: [0.1, 0.2], preview: ""), targetApp: nil))
        #expect(!store.keep(.text(edited: "  \n", corrected: "", raw: ""), targetApp: nil))
        #expect(store.item?.content == .text(edited: "worth keeping", corrected: "", raw: ""))
    }

    @Test("Only the last discard is kept")
    func keepsOnlyLast() {
        let store = DiscardedDictationStore()
        store.keep(.text(edited: "first", corrected: "", raw: ""), targetApp: nil)
        store.keep(.text(edited: "second", corrected: "", raw: ""), targetApp: nil)
        #expect(store.item?.content == .text(edited: "second", corrected: "", raw: ""))
    }

    @Test("Restoring is one-shot")
    func takeIsOneShot() {
        let store = DiscardedDictationStore()
        store.keep(.text(edited: "once", corrected: "", raw: ""), targetApp: nil)
        #expect(store.take()?.content == .text(edited: "once", corrected: "", raw: ""))
        #expect(store.take() == nil)
        #expect(!store.hasItem)
    }

    @Test("Reports availability so the menu item can show and hide")
    func reportsAvailability() {
        let store = DiscardedDictationStore()
        var states: [Bool] = []
        store.onAvailabilityChange = { states.append($0) }

        store.keep(.text(edited: "x", corrected: "", raw: ""), targetApp: nil)
        _ = store.take()
        _ = store.take()
        #expect(states == [true, false])
    }
}

@Suite("Restore discarded — app state")
@MainActor
struct RestoreDiscardedStateTests {

    @Test("Restore runs only between dictations, when something is kept")
    func restoreGuard() {
        let state = AppState()
        var restores = 0
        state.onRestoreDiscarded = { restores += 1 }

        state.requestRestoreDiscarded()
        #expect(restores == 0, "nothing kept")

        state.canRestoreDiscarded = true
        state.requestRestoreDiscarded()
        #expect(restores == 1)
    }
}
