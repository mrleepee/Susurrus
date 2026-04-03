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

    /// Cached anchor point for the overlay — computed once after first show,
    /// so we don't re-locate the menu bar icon on every callback.
    private var cachedAnchorPoint: CGPoint?

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
        ignoresMouseEvents = false

        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        // Content view: frosted glass card
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
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
    /// Anchors to the horizontal center of the screen, just below the menu bar.
    private static func frameForSize(_ size: CGSize) -> CGRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        // Horizontally centered on screen
        let x = screenFrame.midX - size.width / 2
        // Below menu bar (top of screen)
        let y = screenFrame.maxY - size.height
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Returns the anchor point (center-x of menu bar icon) using the mouse location.
    /// Since SwiftUI MenuBarExtra status items are inaccessible via NSStatusBar.system,
    /// we use the current mouse x as a proxy for the icon's horizontal position.
    /// This is cached after the first call to avoid repeated computation.
    private func anchorPoint() -> CGPoint {
        if let cached = cachedAnchorPoint {
            return cached
        }
        guard let screen = NSScreen.main else {
            return NSPoint(x: NSScreen.main?.visibleFrame.midX ?? 0, y: 0)
        }
        // Use current mouse location — the icon is always near the mouse when the
        // user triggers recording via hotkey.
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: screen.visibleFrame.maxY)
        cachedAnchorPoint = point
        return point
    }

    /// Repositions the window so it is horizontally centered on the menu bar icon.
    private func repositionBelowMenuBarIcon() {
        guard let screen = NSScreen.main else { return }

        let anchor = anchorPoint()
        let windowWidth = frame.width
        let newOriginX = anchor.x - windowWidth / 2

        // Clamp to screen bounds
        let clampedX = min(max(newOriginX, screen.visibleFrame.minX),
                           screen.visibleFrame.maxX - windowWidth)

        setFrameOrigin(CGPoint(x: clampedX, y: frame.minY))
    }

    // MARK: - Public API

    /// Shows the overlay with the given text (Behaviour 1.1).
    /// If already visible, updates text immediately.
    func show(confirmed: String, unconfirmed: String) {
        // Invalidate cached anchor on show so position refreshes each session
        cachedAnchorPoint = nil

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
    /// (Behaviour 1.2). Repositions only if already visible.
    func updateText(confirmed: String, unconfirmed: String) {
        // Rebuild the hosting view with new text
        let newView = StreamingOverlayView(confirmed: confirmed, unconfirmed: unconfirmed)
        hostingView.rootView = newView

        let fittingSize = hostingView.fittingSize
        let newHeight = min(fittingSize.height, 120) // cap height to prevent huge overlays
        let newWidth = min(fittingSize.width + 32, Self.maxWidth) // +32 for horizontal padding

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

        if isShowing {
            repositionBelowMenuBarIcon()
        }
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
    override var canBecomeKey: Bool {
        false
    }
}
