import SwiftUI
import SusurrusKit

/// Quick-fix window for the most recent dictation. Opened from the menu bar
/// or the Control+Option+Space hotkey right after a dictation pastes.
///
/// Saving records the edit as a correction (feeding rule learning and vocab
/// promotion), puts the fixed text on the clipboard, and — when the paste
/// target is still known and the text unambiguous — replaces the pasted text
/// in the target app in place. The outcome is shown inline in this window
/// (notification banners proved unreliable on macOS), then the window closes.
struct FixLastDictationView: View {
    @Environment(\.dismiss) private var dismiss

    private let historyManager = TranscriptionHistoryManager.shared
    private let clipboard = PasteboardClipboardService()

    @State private var item: TranscriptionHistoryItem?
    @State private var text: String = ""
    @State private var isSaving = false
    @State private var status: SaveStatus?

    private struct SaveStatus {
        let success: Bool
        let message: String
    }

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
                    .disabled(isSaving)

                if let raw = item.rawText, raw != item.text {
                    Text("Heard: \(raw)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .help("The raw transcription before automatic corrections")
                }

                if let status {
                    HStack(spacing: 6) {
                        Image(systemName: status.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(status.success ? .green : .orange)
                        Text(status.message)
                            .font(.callout)
                    }
                    .transition(.opacity)
                }

                HStack {
                    Text(item.date.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                    Button("Save & Copy") { save(item) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

        // In-place replacement only when the paste record matches the item
        // being fixed; otherwise there is nothing safe to update.
        guard changed,
              let snapshot = PasteTracker.shared.snapshot(),
              snapshot.record.text == item.text else {
            dismiss()
            return
        }

        isSaving = true
        let record = snapshot.record
        // The captured AXUIElement is used only inside the detached task and
        // never crosses back to the main actor (it isn't Sendable).
        let element = snapshot.element
        Task.detached {
            let outcome = AXTextReplacer().replaceLastPaste(
                record: record, with: newText, preferredElement: element
            )
            await MainActor.run {
                finish(outcome: outcome, record: record, newText: newText)
            }
        }
    }

    /// Show the outcome inline, then close. The corrected text is on the
    /// clipboard in every case, so failure just means "paste it yourself".
    private func finish(outcome: ReplaceOutcome, record: PasteRecord, newText: String) {
        let appName = NSRunningApplication(processIdentifier: record.processIdentifier)?
            .localizedName ?? "the app"

        switch outcome {
        case .replaced:
            PasteTracker.shared.updateText(to: newText, expecting: record)
            status = SaveStatus(success: true, message: "Updated in \(appName). Also copied.")
        case .textNotFound:
            status = SaveStatus(success: false, message: "Text changed in \(appName) — copied, paste it yourself.")
        case .ambiguous:
            status = SaveStatus(success: false, message: "Text appears twice in \(appName) — copied, paste it yourself.")
        case .notWritable, .focusedElementUnavailable:
            status = SaveStatus(success: false, message: "\(appName) blocks text edits — copied, paste it yourself.")
        case .appNotRunning:
            status = SaveStatus(success: false, message: "\(appName) is gone — copied, paste it yourself.")
        case .recordStale:
            status = SaveStatus(success: false, message: "Pasted too long ago — copied, paste it yourself.")
        case .accessibilityDenied:
            status = SaveStatus(success: false, message: "Accessibility permission needed — copied, paste it yourself.")
        }

        // Long enough to read a short line; success can close sooner.
        let holdSeconds: Double = outcome == .replaced ? 0.9 : 2.2
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(holdSeconds))
            dismiss()
        }
    }
}
