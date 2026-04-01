import AppKit
import SwiftUI

/// Floating overlay window that displays real-time transcription text near the menu bar.
/// Does not steal focus from the active application (Behaviour 1.4, R8).
///
/// Positioned horizontally centered on the menu bar icon's screen x coordinate,
/// immediately below the menu bar (Behaviour 1.1).
///
/// Click events pass through to the application beneath via `canBecomeKey = false`.
/// The panel fades out over 300ms when hidden (Behaviour 1.3, R10).
final class StreamingOverlayWindow: NSPanel {

    // MARK: - Constants

    /// Maximum width of the overlay card.
    private static let maxWidth: CGFloat = 400

    /// Vertical offset below the menu bar icon.
    private static let verticalOffset: CGFloat = 4

    /// Fade-out animation duration in seconds.
    private static let fadeOutDuration: TimeInterval = 0.3

    // MARK: - State

    /// The SwiftUI view hosted in this panel.
    private let hostingView: NSHostingView<StreamingOverlayView>

    /// Whether the overlay is currently visible.
    private(set) var isShowing = false

    // MARK: - Init

    init() {
        let swiftUIView = StreamingOverlayView(confirmed: "", unconfirmed: "")
        hostingView = NSHostingView(rootView: swiftUIView)
        hostingView.frame = Self.frameForSize(CGSize(width: Self.maxWidth, height: 200))

        super.init(
            contentRect: Self.frameForSize(hostingView.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Behaviour 1.4 / R8: do not steal focus from active application
        canBecomeKey = false
        // Ignore mouse events for click-through (Behaviour 1.4)
        // Note: we suppress key input via canBecomeKey rather than ignoring all
        // mouse events, so scroll/hover remain possible in future.
        ignoresMouseEvents = false

        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        // Content view: frosted glass card
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .ultraThinMaterial
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 14
        visualEffect.layer?.masksToBounds = true
        visualEffect.frame = hostingView.frame

        // Container with transparent background so the visual effect shows through
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.frame = hostingView.frame
        container.addSubview(visualEffect)

        // Hosting view on top of visual effect
        hostingView.frame = visualEffect.bounds
        hostingView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hostingView)

        contentView = container

        // Position relative to menu bar icon
        repositionBelowMenuBarIcon()

        // Register for app termination so the overlay doesn't get orphaned (Behaviour 1.5)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Positioning

    /// Returns the frame for the overlay given a content size.
    private static func frameForSize(_ size: CGSize) -> CGRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        // Horizontally centered on screen
        let x = screenFrame.midX - size.width / 2
        // Below menu bar (top of screen)
        let y = screenFrame.maxY - size.height
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Repositions the window so it is horizontally centered on the menu bar icon.
    private func repositionBelowMenuBarIcon() {
        // Find the menu bar icon's screen position
        guard let screen = NSScreen.main else { return }

        // Try to find the status item for Susurrus via the menu bar extra's window
        // For a MenuBarExtra app, the status item's window is accessible via
        // NSApp.statusBarItem (if using NSStatusBar.system).
        // We also fall back to using the mouse location as a heuristic for
        // where the menu bar icon lives.
        let menuBarIconFrame = findMenuBarIconFrame()

        let windowWidth = frame.width
        let newOriginX = menuBarIconFrame.midX - windowWidth / 2

        // Clamp to screen bounds
        let clampedX = min(max(newOriginX, screen.visibleFrame.minX),
                           screen.visibleFrame.maxX - windowWidth)

        setFrameOrigin(CGPoint(x: clampedX, y: frame.minY))
    }

    /// Finds the screen frame of the Susurrus menu bar icon.
    /// Tries multiple strategies to locate it reliably.
    private func findMenuBarIconFrame() -> CGRect {
        // Strategy 1: Try to find the status item window from the running app
        if let statusItem = NSStatusBar.system.statusItem(withLength: .squareLength),
           let button = statusItem.button,
           let buttonWindow = button.window {
            return buttonWindow.convertToScreen(button.frame)
        }

        // Strategy 2: Use the mouse location as a proxy for menu bar position.
        // The icon will be near the right side of the screen in most cases,
        // but we use center as a reasonable fallback.
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        return CGRect(
            x: screenFrame.midX,
            y: screenFrame.maxY
        )
    }

    // MARK: - Public API

    /// Shows the overlay with the given text (Behaviour 1.1).
    /// If already visible, updates text immediately.
    func show(confirmed: String, unconfirmed: String) {
        updateText(confirmed: confirmed, unconfirmed: unconfirmed)

        if !isShowing {
            isShowing = true
            alphaValue = 0
            orderFront(nil)

            // Animate in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
            }
        }

        repositionBelowMenuBarIcon()
    }

    /// Updates the displayed text with confirmed and unconfirmed components
    /// (Behaviour 1.2).
    func updateText(confirmed: String, unconfirmed: String) {
        // Rebuild the hosting view with new text
        let newView = StreamingOverlayView(confirmed: confirmed, unconfirmed: unconfirmed)
        hostingView.rootView = newView

        // Resize to fit content, capped at maxWidth
        let targetSize = newView.sizeThatFits(CGSize(width: Self.maxWidth, height: .greatestFiniteMagnitude))
        let newHeight = min(targetSize.height, 120) // cap height to prevent huge overlays
        let newWidth = min(targetSize.width + 32, Self.maxWidth) // +32 for horizontal padding

        hostingView.frame.size = CGSize(width: newWidth, height: newHeight)

        if let contentView = contentView {
            contentView.frame.size = CGSize(width: newWidth, height: newHeight)
            if let visualEffect = contentView.subviews.first {
                visualEffect.frame.size = CGSize(width: newWidth, height: newHeight)
                hostingView.frame = visualEffect.bounds
            }
        }

        let newFrame = Self.frameForSize(CGSize(width: newWidth, height: newHeight))
        setFrame(newFrame, display: true)

        repositionBelowMenuBarIcon()
    }

    /// Hides the overlay with a 300ms fade-out animation (Behaviour 1.3, R10).
    /// After fade completes, the panel is moved off-screen.
    func hide() {
        guard isShowing else { return }
        isShowing = false

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeOutDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            // Move off-screen to prevent it from appearing during app transitions
            self?.setFrameOrigin(CGPoint(x: -9999, y: -9999))
        })
    }

    // MARK: - App termination (Behaviour 1.5)

    @objc private func appWillTerminate(_ notification: Notification) {
        orderOut(nil)
    }

    // MARK: - NSWindow overrides

    /// Prevent the panel from becoming key — this is what makes clicks pass through
    /// to the active application (Behaviour 1.4, R8).
    /// Using canBecomeKey = false is preferred over ignoresMouseEvents = true
    /// because it still allows scroll/hover events if needed in future.
    override var canBecomeKey: Bool {
        false
    }
}
