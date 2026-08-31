import AppKit

/// Event-driven hover over the notch.
///
/// Polling could not work here: even a slow 300pt/s pointer crosses the 32pt strip in ~107ms,
/// inside the poll interval, so most crossings were simply never observed. NSTrackingArea is
/// edge-triggered, so speed is irrelevant.
///
/// It lives in its own tiny window because `ignoresMouseEvents` is window-wide — the main panel
/// must ignore events while collapsed, which would also suppress its tracking area.
final class HoverSensor {
    private var window: NSPanel?
    private let view = HoverView()

    var onEnter: (() -> Void)? {
        get { view.onEnter } set { view.onEnter = newValue }
    }
    var onExit: (() -> Void)? {
        get { view.onExit } set { view.onExit = newValue }
    }

    /// Covers the notch plus the visible bar's inner span. Sizing it to the notch alone meant
    /// most of what the user can see had no sensor under it, so hovering the bar did nothing.
    func install(on screen: NSScreen, notchWidth: CGFloat, notchHeight: CGFloat) {
        let width = (notchWidth > 0 ? notchWidth : 170) + 150
        let rect = NSRect(x: screen.frame.midX - width / 2,
                          y: screen.frame.maxY - notchHeight,
                          width: width, height: notchHeight)
        if let window {
            window.setFrame(rect, display: false)
            return
        }
        let panel = NSPanel(contentRect: rect,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false      // must stay false or tracking never fires
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = view
        panel.orderFrontRegardless()
        window = panel
    }
}

private final class HoverView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
        super.updateTrackingAreas()
        // If the pointer is already inside when the area is installed, AppKit sends no enter.
        if let w = window, bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) {
            onEnter?()
        }
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}
