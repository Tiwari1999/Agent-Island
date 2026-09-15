import AppKit

/// Hover over the notch, without a window.
///
/// Two designs were tried and both failed, in opposite directions:
///
/// - An `NSPanel` with a tracking area sees every crossing, but a window whose
///   `ignoresMouseEvents` is false is handed the click by the window server before anything
///   underneath — with a browser fullscreen the strip sits on its tab bar, and those tabs could
///   not be clicked. Declining `hitTest` does not help: that only reroutes within the window, so
///   the click is swallowed silently instead of being swallowed visibly.
/// - A global `NSEvent` monitor consumes nothing, but never saw the crossings (0 of 40 synthetic
///   moves, and no better by hand).
///
/// So: no window, and ask where the pointer is. The old objection to polling was that a pointer
/// crosses a 32pt strip in ~107ms and a slower poll misses it — but missing a fast pass-through is
/// the behaviour we want, since that is someone on their way to the menu bar, and a deliberate
/// hover has to outlast the 350ms dwell anyway. 80ms notices that with room to spare, and costs
/// one cursor read.
final class HoverSensor {
    private var timer: Timer?
    private var fallback: NSRect = .zero
    private var inside = false

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    /// Asked fresh on every sample: the bar's width changes with what it says, and a strip
    /// captured once would stop matching it the moment an agent started or finished.
    var rect: (() -> NSRect)?

    /// The strip that reveals the island while it is HIDDEN — there is nothing on screen to aim
    /// at then, so it has to be a guess about intent. At notch + 150 it covered a third of the
    /// menu bar and opened on the way past to something else; at notch + 24 it was so tight you
    /// had to hit the middle. This sits between them. Once the bar IS on screen, Island widens
    /// this to the bar's own width.
    static func hotWidth(notchWidth: CGFloat) -> CGFloat {
        (notchWidth > 0 ? notchWidth : 120) + 80
    }

    func install(on screen: NSScreen, notchWidth: CGFloat, notchHeight: CGFloat) {
        let width = Self.hotWidth(notchWidth: notchWidth)
        fallback = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - notchHeight,
                          width: width, height: notchHeight)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in self?.sample() }
        // .common so the crossing still registers while a menu or a scroll is tracking.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Edge-triggered: the callbacks fire on the crossing, not on every sample inside the strip.
    private func sample() {
        let now = (rect?() ?? fallback).contains(NSEvent.mouseLocation)
        guard now != inside else { return }
        inside = now
        if now { onEnter?() } else { onExit?() }
    }

    /// Nothing to resize — the rect is read at every sample. Kept so callers need not care which
    /// of the three designs is in place.
    func resize() {}
}
