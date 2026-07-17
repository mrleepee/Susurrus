import AppKit
import SwiftUI

/// Observable model bridging the imperative `DictationReviewPanel` to its
/// SwiftUI content. The panel mutates `phase`/`text`; the view renders them
/// and calls `onInsert`/`onCancel` back.
@MainActor
final class DictationReviewModel: ObservableObject {
    enum Phase { case recording, editing }

    @Published var phase: Phase = .recording
    @Published var text: String = ""

    var onInsert: ((String) -> Void)?
    var onCancel: (() -> Void)?
}

/// The editable surface for "dictate into the panel" mode. While the hotkey
/// is held the transcript streams in read-only; on release it becomes an
/// editable field the user fixes, then inserts with ⌘⏎. Editing happens
/// entirely in Susurrus's own text field, so no target app's accessibility
/// quirks can block it — the only thing we ever do to another app is one
/// clean paste on insert.
struct DictationReviewView: View {
    @ObservedObject var model: DictationReviewModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.phase {
            case .recording:
                HStack(spacing: 8) {
                    Circle().fill(.red).frame(width: 9, height: 9)
                    Text("Listening… release to edit")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(model.text.isEmpty ? "Speak now…" : model.text)
                        .font(.body)
                        .foregroundStyle(model.text.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 90, maxHeight: 160)

            case .editing:
                Text("Fix anything, then ⌘⏎ to insert — Susurrus learns from your edits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                    .frame(minHeight: 100, maxHeight: 220)
                    .focused($editorFocused)
                HStack {
                    Spacer()
                    Button("Cancel") { model.onCancel?() }
                        .keyboardShortcut(.cancelAction)
                    Button("Insert") { model.onInsert?(model.text) }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .frame(width: 480)
        .onChange(of: model.phase) { _, newPhase in
            editorFocused = (newPhase == .editing)
        }
    }
}

/// Floating, key-able panel that hosts `DictationReviewView`. Titled and
/// closable so there is always an obvious escape hatch (the red button acts
/// as Cancel). Reused across sessions — a process-stable single instance.
final class DictationReviewPanel: NSPanel {

    private let model = DictationReviewModel()

    /// The app that was frontmost when dictation started — where the final
    /// text is pasted on insert.
    var targetApp: NSRunningApplication?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Dictation"
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isFloatingPanel = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: DictationReviewView(model: model))
        contentView = host

        // Cancel button / Esc / close button all just discard and close —
        // there is no state to unwind, only the window to dismiss.
        model.onCancel = { [weak self] in self?.orderOut(nil) }
    }

    // MARK: - Public API

    /// Set the paste target and show the panel in its live-transcription
    /// phase (non-key, so it doesn't steal focus while the user is still
    /// holding the hotkey).
    func beginRecording(targetApp: NSRunningApplication?) {
        self.targetApp = targetApp
        model.onInsert = nil
        model.text = ""
        model.phase = .recording
        sizeToFit()
        centerNearTop()
        orderFront(nil)
    }

    /// Update the streamed transcript shown during recording.
    func updateStreaming(_ text: String) {
        guard model.phase == .recording else { return }
        model.text = text
    }

    /// Switch to the editable phase with the finalized text and take focus.
    /// `onInsert` is invoked with the user's edited text when they insert.
    func enterEditing(finalText: String, onInsert: @escaping (String) -> Void) {
        model.text = finalText
        model.onInsert = { [weak self] edited in
            onInsert(edited)
            self?.orderOut(nil)
        }
        model.phase = .editing
        sizeToFit()
        makeKeyAndOrderFront(nil)
    }

    /// Close without inserting (external cancel, e.g. a new session starting).
    func cancel() {
        orderOut(nil)
    }

    // MARK: - Internals

    private func sizeToFit() {
        guard let contentView else { return }
        let fitting = contentView.fittingSize
        setContentSize(NSSize(width: 480, height: max(160, min(fitting.height, 420))))
    }

    private func centerNearTop() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.maxY - frame.height - 80
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    // Panels default to not becoming key; this one must, to edit text.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Esc in the panel discards and closes.
        orderOut(nil)
    }
}
