import AppKit

/// The one dictation most recently thrown away with Esc / Cancel / the close
/// button, so an accidental Esc can be undone from the menu bar. Memory only
/// and never written to history: if it isn't restored it's simply replaced by
/// the next discard, or lost when Susurrus quits.
@MainActor
final class DiscardedDictationStore {

    enum Content: Equatable {
        /// Discarded while listening: the audio so far (16 kHz mono) and the
        /// live preview text, which feeds the final decode's term ranking.
        case audio(samples: [Float], preview: String)
        /// Discarded from the editor: the text as the user left it, plus the
        /// corrector's output and the raw ASR it came from, so a restored edit
        /// still teaches the corrector like any other.
        case text(edited: String, corrected: String, raw: String)
    }

    struct Item {
        let content: Content
        /// Where Insert pastes after a restore — the app dictated from.
        let targetApp: NSRunningApplication?
    }

    /// Below half a second there's nothing worth decoding.
    static let minAudioSamples = 8_000

    private(set) var item: Item?

    /// Told whenever something becomes restorable or stops being so.
    var onAvailabilityChange: ((Bool) -> Void)?

    var hasItem: Bool { item != nil }

    /// Keep `content` in place of whatever was kept before. Content with
    /// nothing in it (a cancel before speaking) is ignored and leaves the
    /// previous discard restorable. Returns whether it was kept.
    @discardableResult
    func keep(_ content: Content, targetApp: NSRunningApplication?) -> Bool {
        guard Self.isWorthKeeping(content) else { return false }
        item = Item(content: content, targetApp: targetApp)
        onAvailabilityChange?(true)
        return true
    }

    /// Hand over the kept dictation and forget it — restoring is one-shot.
    func take() -> Item? {
        guard let item else { return nil }
        self.item = nil
        onAvailabilityChange?(false)
        return item
    }

    static func isWorthKeeping(_ content: Content) -> Bool {
        switch content {
        case .audio(let samples, _):
            samples.count >= minAudioSamples
        case .text(let edited, _, _):
            !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
