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
        if newText != item.text {
            // Records the correction pair -> rule learning, vocab promotion,
            // and the "Susurrus learned…" notification via onLearn.
            historyManager.updateText(id: item.id, newText: newText)
        }
        clipboard.writeText(newText)
        dismiss()
    }
}
