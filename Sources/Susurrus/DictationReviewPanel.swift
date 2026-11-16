import AppKit
import SwiftUI
import SusurrusKit

/// Observable model bridging the imperative `DictationReviewPanel` to its
/// SwiftUI content. The panel mutates `phase`/`text`; the view renders them
/// and calls `onInsert`/`onCancel` back.
@MainActor
final class DictationReviewModel: ObservableObject {
    enum Phase: Equatable {
        /// Mic open, transcript streaming in read-only.
        case recording
        /// Mic closed, final decode running.
        case processing
        /// Final text in an editable field.
        case editing
        /// Copied or inserted; the panel is about to close itself. Carries
        /// the confirmation to show, and a second line when the result
        /// wasn't what was asked for (an insert that could only copy).
        case finished(String, detail: String?)
    }

    @Published var phase: Phase = .recording
    @Published var text: String = ""
    /// Mid-phrase capitals `CasingProfile` thinks Whisper invented. Offered,
    /// never applied — see that type for why they must not auto-apply.
    @Published var casingSuggestions: [CasingSuggestion] = []

    /// Key hints shown while listening. Push-to-talk finishes on release,
    /// so it has no separate finish keys to advertise.
    @Published var isPushToTalk = false
    @Published var editKeys = GlobalHotkeyService.symbols(for: .default)

    var onInsert: ((String) -> Void)?
    /// Copy to clipboard without touching the app you dictated from —
    /// for when you want the text somewhere else, or nowhere yet.
    var onCopy: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// Listening-phase footer buttons: finish to copy / insert, or to the
    /// editor (nil); and discard the recording.
    var onFinishRecording: ((DictationReviewPanel.QuickFinish?) -> Void)?
    var onCancelRecording: (() -> Void)?

    /// Apply one suggestion and retire its chip. The chip goes away either
    /// way: if the user has already edited that span by hand, the range no
    /// longer matches and there is nothing left to offer.
    func applyCasing(_ suggestion: CasingSuggestion) {
        text = CasingProfile.apply([suggestion], to: text)
        casingSuggestions.removeAll { $0.id == suggestion.id }
    }

    func applyAllCasing() {
        text = CasingProfile.apply(casingSuggestions, to: text)
        casingSuggestions.removeAll()
    }
}

/// The editable surface for "dictate into the panel" mode. While recording
/// the transcript streams in read-only; finishing with the main hotkey makes
/// it an editable field the user fixes, then copies with ⌘⏎ or inserts with
/// ⌥⌘⏎. Finishing with those same keys while still listening skips the
/// editor: the text is copied or inserted and the panel closes. Editing happens entirely in Susurrus's own text field, so no
/// target app's accessibility quirks can block it — the only thing we ever
/// do to another app is one clean paste on insert.
struct DictationReviewView: View {
    @ObservedObject var model: DictationReviewModel
    @FocusState private var editorFocused: Bool

    private var isEmpty: Bool {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Shares the title bar row with the close button.
            HStack {
                Spacer()
                StatusPill(phase: model.phase)
                Spacer()
            }
            .frame(height: 28)
            .padding(.top, 4)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: model.phase)
        .onChange(of: model.phase) { _, newPhase in
            editorFocused = (newPhase == .editing)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .recording, .processing, .finished:
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.text.isEmpty ? "Start speaking…" : model.text)
                        .font(.system(size: 17))
                        .lineSpacing(4)
                        .foregroundStyle(model.text.isEmpty ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 12)
                    Color.clear.frame(height: 1).id("end")
                }
                .scrollIndicators(.never)
                .onChange(of: model.text) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("end", anchor: .bottom) }
                }
            }
            .opacity(model.phase == .recording ? 1 : 0.55)
            .overlay {
                if case .finished(let message, let detail) = model.phase {
                    FinishedBadge(message: message, detail: detail)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }

        case .editing:
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $model.text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    )
                    .focused($editorFocused)
                casingRow
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        switch model.phase {
        case .recording:
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    if model.isPushToTalk {
                        Text("Release to review")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        KeyHintButton(keys: "⌘↩", label: "Copy") { model.onFinishRecording?(.copy) }
                            .help("Stop and copy to the clipboard")
                        KeyHintButton(keys: "⌥⌘↩", label: "Insert") { model.onFinishRecording?(.insert) }
                            .help("Stop and insert into the app you dictated from")
                        KeyHintButton(keys: model.editKeys, label: "Review") { model.onFinishRecording?(nil) }
                            .help("Stop and edit the text before using it")
                    }
                    KeyHintButton(keys: "esc", label: "Cancel") { model.onCancelRecording?() }
                        .help("Discard this dictation")
                }
            }
            .frame(maxWidth: .infinity)

        case .processing, .finished:
            // Holds the footer's height so the text doesn't jump.
            KeyHint(keys: "esc", label: "Cancel").hidden()

        case .editing:
            HStack(spacing: 8) {
                Text("Edits teach Susurrus")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                GlassGroup(spacing: 8) {
                    HStack(spacing: 8) {
                        Button("Cancel") { model.onCancel?() }
                            .keyboardShortcut(.cancelAction)
                            .glassButton()
                        Button("Insert") { model.onInsert?(model.text) }
                            .keyboardShortcut(.return, modifiers: [.command, .option])
                            .help("Insert into the app you dictated from (⌥⌘⏎)")
                            .glassButton()
                            .disabled(isEmpty)
                        Button("Copy") { model.onCopy?(model.text) }
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Copy to the clipboard (⌘⏎)")
                            .glassButton(prominent: true)
                            .disabled(isEmpty)
                    }
                }
            }
            .controlSize(.large)
        }
    }

    /// Whisper Title-Cases noun phrases it mistakes for names. These are
    /// offered rather than applied: roughly one suggestion in four is a real
    /// name that happens to be an ordinary word, which is fine to glance past
    /// and would not be fine to have silently rewritten.
    @ViewBuilder
    private var casingRow: some View {
        if !model.casingSuggestions.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "textformat")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Looks capitalized:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.casingSuggestions) { suggestion in
                    Button {
                        model.applyCasing(suggestion)
                    } label: {
                        Text("\(suggestion.original) → \(suggestion.suggested)")
                            .font(.caption)
                    }
                    .glassButton()
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("Change “\(suggestion.original)” to “\(suggestion.suggested)”")
                }
                if model.casingSuggestions.count > 1 {
                    Button("All") { model.applyAllCasing() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                Spacer()
            }
        }
    }
}

// MARK: - Components

/// Centred title-bar capsule naming what the panel is doing right now.
private struct StatusPill: View {
    let phase: DictationReviewModel.Phase

    var body: some View {
        HStack(spacing: 7) {
            switch phase {
            case .recording:
                PulsingDot()
                Text("Listening")
            case .processing:
                ProgressView().controlSize(.mini)
                Text("Processing")
            case .editing:
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                Text("Review")
            case .finished:
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                Text("Done")
            }
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .glass(in: Capsule(), tint: tint)
        .contentTransition(.opacity)
    }

    private var tint: Color? {
        switch phase {
        case .recording: .red.opacity(0.25)
        case .finished: .green.opacity(0.25)
        case .processing, .editing: nil
        }
    }
}

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 7, height: 7)
            .background(
                Circle()
                    .fill(.red.opacity(0.45))
                    .scaleEffect(pulsing ? 2.6 : 1)
                    .opacity(pulsing ? 0 : 1)
            )
            .onAppear {
                withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}

/// A shortcut and what it does, as a small glass chip.
private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glass(in: Capsule())
    }
}

private struct FinishedBadge: View {
    let message: String
    let detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: detail == nil ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(detail == nil ? AnyShapeStyle(.white) : AnyShapeStyle(.orange),
                                 detail == nil ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
                .symbolEffect(.bounce, value: true)
            Text(message)
                .font(.system(size: 13, weight: .semibold))
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        .glass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Liquid Glass, with pre-Tahoe fallbacks

extension View {
    /// Liquid Glass on macOS 26; a translucent fill on earlier systems.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint), in: shape)
        } else {
            background(shape.fill(tint ?? Color.primary.opacity(0.08)))
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// Lets neighbouring glass shapes blend and morph into each other on
/// macOS 26; a plain passthrough before that.
private struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A `KeyHint` that also works as a button, so the listening footer can be
/// clicked as well as triggered from the keyboard.
private struct KeyHintButton: View {
    let keys: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            KeyHint(keys: keys, label: label)
                .contentShape(Capsule())
        }
        .buttonStyle(ChipButtonStyle())
        // The panel now holds keyboard focus, which would otherwise draw a
        // focus ring round a chip; they're driven by their shortcuts anyway.
        .focusEffectDisabled()
    }
}

/// Visible hover and press feedback for a glass chip: a soft wash and a
/// slight lift under the pointer, darker and shrunk while held, and a
/// pointing-hand cursor — so the chips read as buttons, not labels.
private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration)
    }

    private struct Chip: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .overlay(
                    Capsule().fill(Color.primary.opacity(pressed ? 0.16 : hovering ? 0.08 : 0))
                )
                .scaleEffect(pressed ? 0.95 : hovering ? 1.03 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.06), value: pressed)
                .onHover { hovering = $0 }
                .pointerStyle(.link)
        }
    }
}

/// Takes the first click even while the panel isn't key. The panel opens
/// without taking focus from the app being dictated into, so without this the
/// first click on a button only activates the panel and is otherwise lost.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Panel

/// Floating, key-able panel that hosts `DictationReviewView` on a translucent
/// material. Titled and closable so there is always an obvious escape hatch
/// (the close button acts as Cancel). Reused across sessions — a
/// process-stable single instance.
final class DictationReviewPanel: NSPanel {

    let model = DictationReviewModel()

    /// Matches a Tahoe titled window's own corner so the glass fills it.
    private static let glassCornerRadius: CGFloat = 16

    /// The app that was frontmost when dictation started — where the final
    /// text is pasted on insert.
    var targetApp: NSRunningApplication?

    /// How to finish straight from listening, skipping the editor.
    enum QuickFinish { case copy, insert }

    /// Set when the session is finished with a copy/insert shortcut rather
    /// than the main hotkey; nil means open the editor as usual.
    var quickFinish: QuickFinish?

    /// Bumped on every new session so a pending auto-close from a finished
    /// quick copy can't close the panel out from under the next one.
    private var session = 0

    /// Listening-phase footer actions, wired by the app (they drive the
    /// recording state the panel doesn't own).
    var onFinishRecording: ((QuickFinish?) -> Void)? {
        get { model.onFinishRecording }
        set { model.onFinishRecording = newValue }
    }
    var onCancelRecording: (() -> Void)? {
        get { model.onCancelRecording }
        set { model.onCancelRecording = newValue }
    }

    /// Per-session live-preview diagnostics, logged when listening ends. The
    /// preview sometimes stays blank while dictation itself works; these say
    /// whether text reached the panel and whether macOS considered the panel
    /// visible at the time.
    private var recordingStart = Date()
    private var previewUpdates = 0
    private var firstPreviewAfter: TimeInterval?
    private var occlusionChanges: [String] = []

    /// While a session is live (listening, decoding, editing) the panel keeps
    /// the keyboard. Remote-desktop clients such as Amazon WorkSpaces capture
    /// every key while they're frontmost, so ⌘⏎ / esc would go to the remote
    /// machine instead of Susurrus; if the app being dictated over takes
    /// focus back, the panel reclaims it. Released once the text is delivered
    /// or the panel closes.
    private(set) var holdsFocus = false
    /// Guards against a focus tug-of-war with an app that keeps reactivating.
    private var focusReclaims = 0
    static let maxFocusReclaims = 10

    /// Brings Susurrus to the front. Swappable so tests can count activations
    /// without pulling the test runner forward.
    var activateApp: () -> Void = { NSApplication.shared.activate(ignoringOtherApps: true) }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 340),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        title = "Dictation"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isFloatingPanel = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        // Small enough that the button row can never be squeezed out, however
        // far the user drags the window down.
        minSize = NSSize(width: 440, height: 220)

        let host = FirstMouseHostingView(rootView: DictationReviewView(model: model))
        if #available(macOS 26, *) {
            // The whole panel is one sheet of Liquid Glass, like Spotlight.
            // The window itself must be clear or the glass has nothing
            // behind it to refract.
            isOpaque = false
            backgroundColor = .clear
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.glassCornerRadius
            glass.contentView = host
            contentView = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .popover
            material.blendingMode = .behindWindow
            material.state = .active
            host.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                host.topAnchor.constraint(equalTo: material.topAnchor),
                host.bottomAnchor.constraint(equalTo: material.bottomAnchor),
            ])
            contentView = material
        }

        // Cancel button / Esc / close button all just discard and close —
        // there is no state to unwind, only the window to dismiss.
        model.onCancel = { [weak self] in self?.close(restoringFocus: true) }

        // `setFrameAutosaveName` both restores a previously saved frame (if
        // one exists) and registers the window to keep saving on every future
        // move/resize — so dragging the panel bigger once is remembered
        // across launches, with no bespoke UserDefaults plumbing needed.
        let restored = setFrameAutosaveName("DictationReviewPanel")
        if !restored {
            centerNearTop()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(occlusionDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: self
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    // MARK: - Public API

    /// Set the paste target and show the panel in its live-transcription
    /// phase, taking keyboard focus so its shortcuts work even over apps
    /// that capture the keyboard (see `holdsFocus`). Nothing is typed into
    /// the target until Insert, which hands focus back first. `editCombo` is
    /// the main hotkey, which finishes into the editor in toggle mode.
    func beginRecording(
        targetApp: NSRunningApplication?,
        isPushToTalk: Bool,
        editCombo: HotkeyCombo?
    ) {
        session += 1
        self.targetApp = targetApp
        quickFinish = nil
        model.onInsert = nil
        model.onCopy = nil
        model.text = ""
        model.casingSuggestions = []
        model.isPushToTalk = isPushToTalk
        if let editCombo {
            model.editKeys = GlobalHotkeyService.symbols(for: editCombo)
        }
        model.phase = .recording
        recordingStart = Date()
        previewUpdates = 0
        firstPreviewAfter = nil
        occlusionChanges = []
        holdsFocus = true
        focusReclaims = 0
        takeFocus()
        traceApp("Review panel: listening over \(targetApp?.bundleIdentifier ?? "?"), visible=\(occlusionState.contains(.visible)), onActiveSpace=\(isOnActiveSpace)")
    }

    /// Update the streamed transcript shown during recording.
    func updateStreaming(_ text: String) {
        guard model.phase == .recording else { return }
        if !text.isEmpty {
            previewUpdates += 1
            if firstPreviewAfter == nil { firstPreviewAfter = Date().timeIntervalSince(recordingStart) }
        }
        model.text = text
    }

    /// The mic has closed; show that the final decode is running.
    func beginProcessing() {
        guard model.phase == .recording else { return }
        logPreviewSummary()
        model.phase = .processing
    }

    /// Show the delivered text with a brief confirmation, then close on its
    /// own. Never takes focus from the user's app. A `detail` line (the
    /// insert fell back to copy) stays up longer so it can be read.
    func showFinished(_ text: String, message: String, detail: String? = nil) {
        holdsFocus = false
        model.text = text
        model.phase = .finished(message, detail: detail)
        orderFront(nil)
        let closing = session
        DispatchQueue.main.asyncAfter(deadline: .now() + (detail == nil ? 0.9 : 2.2)) { [weak self] in
            guard let self, self.session == closing, case .finished = self.model.phase else { return }
            self.close(restoringFocus: true)
        }
    }

    /// Switch to the editable phase with the finalized text and take focus.
    /// `onFinish` receives the user's edited text and whether it should be
    /// pasted into the target app (Insert) or only copied (Copy). It reports
    /// the outcome with `showFinished`, which closes the panel.
    func enterEditing(
        finalText: String,
        casingSuggestions: [CasingSuggestion] = [],
        onFinish: @escaping (String, Bool) -> Void
    ) {
        model.text = finalText
        model.casingSuggestions = casingSuggestions
        model.onInsert = { edited in onFinish(edited, true) }
        model.onCopy = { edited in onFinish(edited, false) }
        model.phase = .editing
        takeFocus()
    }

    /// Stop holding the keyboard — the text is about to be delivered, and
    /// Insert must be free to hand focus back to the target app.
    func releaseFocus() {
        holdsFocus = false
    }

    /// Close without inserting (external cancel, e.g. a new session starting).
    func cancel() {
        if model.phase == .recording { logPreviewSummary() }
        close(restoringFocus: true)
    }

    // MARK: - Internals

    /// Hide the panel. If Susurrus had become frontmost (the editor, or a
    /// click on the panel), hand focus back to the app dictated from rather
    /// than leaving the user in a menu bar app with no window.
    private func close(restoringFocus: Bool) {
        holdsFocus = false
        orderOut(nil)
        if restoringFocus, NSApplication.shared.isActive, let targetApp, !targetApp.isTerminated {
            targetApp.activate(options: [])
        }
    }

    /// Susurrus is a menu bar app and never frontmost on its own, so a key
    /// window alone doesn't get the keyboard — the app the user was in keeps
    /// it. Activate the app as well as the panel.
    private func takeFocus() {
        activateApp()
        makeKeyAndOrderFront(nil)
    }

    /// The app being dictated over took focus back (WorkSpaces can do this
    /// as the panel opens): take it again. Other apps are left alone so the
    /// user can still switch away deliberately.
    @objc private func appDidActivate(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        appActivated(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
    }

    /// Decide whether another app's activation should be undone. Returns
    /// whether a reclaim was scheduled.
    @discardableResult
    func appActivated(pid: pid_t, bundleID: String?) -> Bool {
        guard holdsFocus, isVisible,
              let targetApp, pid == targetApp.processIdentifier else { return false }
        guard focusReclaims < Self.maxFocusReclaims else {
            if focusReclaims == Self.maxFocusReclaims {
                focusReclaims += 1
                traceApp("Review panel: \(bundleID ?? "?") keeps taking focus, giving up reclaiming")
            }
            return false
        }
        focusReclaims += 1
        traceApp("Review panel: \(bundleID ?? "?") took focus, reclaiming (\(focusReclaims))")
        DispatchQueue.main.async { [weak self] in
            guard let self, self.holdsFocus else { return }
            self.takeFocus()
        }
        return true
    }

    private func logPreviewSummary() {
        let first = firstPreviewAfter.map { String(format: "%.1fs", $0) } ?? "never"
        let occlusion = occlusionChanges.isEmpty ? "" : ", occlusion changes: \(occlusionChanges.joined(separator: " "))"
        traceApp("Review panel: preview updates=\(previewUpdates), first text after \(first), \(model.text.count) chars shown, visible=\(occlusionState.contains(.visible))\(occlusion)")
    }

    @objc private func occlusionDidChange(_ note: Notification) {
        guard model.phase == .recording else { return }
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(recordingStart))
        occlusionChanges.append("\(elapsed)=\(occlusionState.contains(.visible) ? "visible" : "hidden")")
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
        handleCancel()
    }

    /// The title-bar close button. While listening it must stop the
    /// recording too, not just hide the panel over a live session.
    override func performClose(_ sender: Any?) {
        handleCancel()
    }

    private func handleCancel() {
        if model.phase == .recording, let cancelRecording = model.onCancelRecording {
            cancelRecording()
        } else {
            model.onCancel?()
        }
    }
}
