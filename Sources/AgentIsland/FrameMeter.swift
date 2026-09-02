import AppKit
import QuartzCore

/// Frame-gap meter, armed only while the panel is visible and only when
/// AGENTISLAND_FRAMEPROBE=1 — "smooth" needs a number the way "light" has one, and polishing
/// animation without a frame-time meter is guessing.
final class FrameMeter {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var gaps: [Double] = []

    var enabled: Bool { ProcessInfo.processInfo.environment["AGENTISLAND_FRAMEPROBE"] == "1" }

    func start(on view: NSView) {
        guard enabled, link == nil else { return }
        last = 0; gaps = []
        let l = view.displayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        if last > 0 { gaps.append((l.targetTimestamp - last) * 1000) }
        last = l.targetTimestamp
    }

    /// Stops and reports: p95 gap and dropped-frame count for the session that just ended.
    func stopAndReport() {
        guard let l = link else { return }
        l.invalidate(); link = nil
        guard gaps.count > 30 else { return }
        let sorted = gaps.sorted()
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        let budget = (sorted[sorted.count / 2]) * 1.6   // dropped = well past the median cadence
        let dropped = gaps.filter { $0 > budget }.count
        Diagnostics.log(String(format: "frames: %d samples, p95 %.1fms, %d dropped",
                               gaps.count, p95, dropped))
        gaps = []
    }
}
