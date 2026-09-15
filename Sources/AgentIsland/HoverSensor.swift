import AppKit

/// Event-driven hover over the notch.
///
/// Polling could not work here: even a slow 300pt/s pointer crosses the 32pt strip in ~107ms,
/// inside the poll interval, so most crossings were simply never observed. A mouse-moved monitor
/// is event-driven, so speed is irrelevant.
///
/// It used to be a tiny always-on-top panel with a tracking area. That panel hit-tested, so every
/// click inside its strip was swallowed — with a browser in fullscreen the strip sits directly on
/// the tab bar, and the tabs under it simply could not be clicked. A monitor observes the same
/// events without consuming any of them, so nothing underneath loses a click.
final class HoverSensor {
    private var global: Any?
    private var local: Any?
    /// Asked fresh on every crossing: the bar's width changes with what it says, and a strip
    /// captured once would stop matching it the moment an agent started or finished.
    var rect: (() -> NSRect)?
    private var fallback: NSRect = .zero
    private var inside = false

    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    /// The strip that reveals the island while it is HIDDEN — there is nothing on screen to aim
    /// at then, so it has to be a guess about intent. At notch + 150 it covered a third of the
    /// menu bar and opened on the way past to something else; at notch + 24 it was so tight you
    /// had to hit the middle. This sits between them, and costs little now that the sensor holds
    /// no window and steals no clicks. Once the bar IS on screen, Island widens this to the bar.
    static func hotWidth(notchWidth: CGFloat) -> CGFloat {
        (notchWidth > 0 ? notchWidth : 120) + 80
    }

    func install(on screen: NSScreen, notchWidth: CGFloat, notchHeight: CGFloat) {
        let width = Self.hotWidth(notchWidth: notchWidth)
        fallback = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - notchHeight,
                          width: width, height: notchHeight)
        guard global == nil else { return }
        // Global fires while another app is frontmost, which is nearly always for an accessory
        // app; local covers the moments our own panel holds focus, e.g. the console composer.
        global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in self?.sample()
        }
        local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] e in self?.sample(); return e
        }
    }

    /// Edge-triggered: the callbacks fire on the crossing, not on every event inside the strip.
    private func sample() {
        let now = (rect?() ?? fallback).contains(NSEvent.mouseLocation)
        guard now != inside else { return }
        inside = now
        if now { onEnter?() } else { onExit?() }
    }
}
