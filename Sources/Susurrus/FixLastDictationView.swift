import SwiftUI
import SusurrusKit

/// Quick-fix window for the most recent dictation. Opened from the menu bar
/// or the Control+Option+Space hotkey right after a dictation pastes.
///
/// Saving records the edit as a correction (feeding rule learning and vocab
/// promotion), updates history, and puts the fixed text on the clipboard.
/// It does NOT touch text already pasted into another app — re-paste if you
/// need the fixed version there.
struct FixLastDictationView: View {
    @Environment(\.dismiss) private var dismiss

    private let historyManager = TranscriptionHistoryManager.shared
    private let clipboard = PasteboardClipboardService()

    @State private var item: TranscriptionHistoryItem?
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let item {
                Text("Fix your last dictation — Susurrus learns from every change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .frame(minHeight: 120)

                if let raw = item.rawText, raw != item.text {
                    Text("Heard: \(raw)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .help("The raw transcription before automatic corrections")
                }

                HStack {
                    Text(item.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save & Copy") { save(item) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text("No dictations yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(16)
        .frame(minWidth: 420, idealWidth: 480)
        .onAppear { load() }
    }

    private func load() {
        item = historyManager.items().first
        text = item?.text ?? ""
    }

    private func save(_ item: TranscriptionHistoryItem) {
        let newText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return }
        let changed = newText != item.text
        if changed {
            // Records the correction pair -> rule learning, vocab promotion,
            // and the "Susurrus learned…" notification via onLearn.
            historyManager.updateText(id: item.id, newText: newText)
        }
        clipboard.writeText(newText)
        if changed {
            replaceInTargetApp(item: item, newText: newText)
        }
        dismiss()
    }

    /// Replace the auto-pasted text in the app it was pasted into, when it
    /// can be done safely — the record must match the item being fixed and
    /// the pasted string must still be present verbatim and unambiguously.
    /// Anything else leaves the target app untouched (the corrected text is
    /// already on the clipboard).
    private func replaceInTargetApp(item: TranscriptionHistoryItem, newText: String) {
        guard let record = PasteTracker.shared.last(), record.text == item.text else { return }

        let outcome = AXTextReplacer().replaceLastPaste(record: record, with: newText)
        let appName = NSRunningApplication(processIdentifier: record.processIdentifier)?
            .localizedName ?? "the app"

        switch outcome {
        case .replaced:
            // A second fix of the same dictation should still work.
            PasteTracker.shared.set(PasteRecord(
                text: newText,
                bundleIdentifier: record.bundleIdentifier,
                processIdentifier: record.processIdentifier
            ))
            UserNotificationService.shared.showNotification(
                title: "Fixed in \(appName)",
                body: "The pasted text was updated in place. The corrected version is also on the clipboard."
            )
        case .textNotFound:
            notifyManualPaste("The original text has changed in \(appName), so it wasn't touched.")
        case .ambiguous:
            notifyManualPaste("The text appears more than once in \(appName), so nothing was touched.")
        case .notWritable, .focusedElementUnavailable:
            notifyManualPaste("\(appName) doesn't allow text replacement.")
        case .appNotRunning:
            notifyManualPaste("The app it was pasted into is no longer running.")
        case .accessibilityDenied:
            notifyManualPaste("Accessibility permission is needed to edit text in other apps.")
        }
    }

    private func notifyManualPaste(_ reason: String) {
        UserNotificationService.shared.showNotification(
            title: "Fixed — paste to update",
            body: "\(reason) The corrected text is on the clipboard."
        )
    }
}
