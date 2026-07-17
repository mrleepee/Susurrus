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
    /// `dismiss` is for sheet/presentation dismissal and does not reliably
    /// close a `Window(id:)` scene — field-confirmed 2026-07-17: after a
    /// successful in-place fix the window stayed open, fully frozen (see
    /// `closeWindow()`). `dismissWindow` is the scene-correct mechanism.
    @Environment(\.dismissWindow) private var dismissWindow

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
                    // Always enabled, even while a save is in flight — an
                    // escape hatch is non-negotiable after a stuck window
                    // trapped the user with no way to close it.
                    Button("Cancel") { closeWindow() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save & Copy") { save(item) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(isSaving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Text("No dictations yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
                Button("Close") { closeWindow() }
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

    /// Closes this window. `dismissWindow(id:)` is the scene-correct API,
    /// but is called alongside a direct `NSWindow.close()` fallback — the
    /// same "don't trust a success signal, verify the actual effect"
    /// lesson AXTextReplacer already learned the hard way. Also clears
    /// `isSaving` so a future failure to close still leaves the UI usable
    /// rather than permanently frozen.
    private func closeWindow() {
        isSaving = false
        dismissWindow(id: "fixLast")
        for window in NSApp.windows where window.title == "Fix Last Dictation" {
            window.close()
        }
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
        guard changed else {
            traceApp("fixWindow: saved without changes")
            closeWindow()
            return
        }
        guard let snapshot = PasteTracker.shared.snapshot() else {
            traceApp("fixWindow: no paste record — skipping in-place replace")
            closeWindow()
            return
        }
        guard snapshot.record.text == item.text else {
            traceApp("fixWindow: paste record doesn't match item (already fixed or newer paste) — skipping in-place replace")
            closeWindow()
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
        // Reset immediately, not after the delayed close — if closeWindow()
        // somehow fails again, the window must stay usable, not frozen.
        isSaving = false

        let appName = NSRunningApplication(processIdentifier: record.processIdentifier)?
            .localizedName ?? "the app"
        traceApp("fixWindow: replace outcome=\(outcome) app=\(record.bundleIdentifier ?? "?")")

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
            closeWindow()
        }
    }
}
