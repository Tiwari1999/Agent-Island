import Combine
import Foundation
import SwiftUI

/// Quota + model, captured from the statusLine payload Claude renders on every turn.
struct Quota {
    var fiveHourPct: Int?
    var sevenDayPct: Int?
    var fiveHourResets: Date?
    var sevenDayResets: Date?
    var model: String?
    /// Percent-per-hour, measured from observed samples rather than assumed.
    var burnPerHour: Double?
    /// When the 5h window is projected to hit 100% at the current rate.
    var exhaustsIn: TimeInterval?

    /// Colour tracks pressure, not decoration: green until it matters, red when it does.
    static func tint(_ pct: Int?) -> Color {
        guard let pct else { return Theme.faint }
        if pct >= 85 { return Theme.failed }
        if pct >= 60 { return Theme.amber }
        return Theme.working
    }

    /// "12%/h" — the rate that decides whether a runaway loop eats the day.
    static func rate(_ perHour: Double?) -> String {
        guard let perHour, perHour >= 0.1 else { return "" }
        return String(format: "%.0f%%/h", perHour)
    }

    static func short(_ s: TimeInterval?) -> String {
        guard let s, s.isFinite, s > 0 else { return "" }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        if h >= 24 { return "\(h / 24)d" }
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }

    static func remaining(_ at: Date?) -> String {
        guard let at else { return "" }
        let s = at.timeIntervalSinceNow
        guard s > 0 else { return "now" }
        let h = Int(s) / 3600, m = (Int(s) % 3600) / 60
        if h >= 24 { return "\(h / 24)d\(h % 24)h" }
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }
}

@MainActor
final class StatusStore: ObservableObject {
    @Published private(set) var quota = Quota()
    private var timer: Timer?
    private let path = "/tmp/agentisland-status.json"
    /// Rolling samples of (time, 5h percent). Burn rate is a measurement, not a guess.
    private var samples: [(Date, Int)] = []
    private static let sampleWindow: TimeInterval = 30 * 60

    func start() {
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.read() }
        }
    }

    private func read() {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        var q = Quota()
        let rl = obj["rate_limits"] as? [String: Any] ?? [:]
        if let f = rl["five_hour"] as? [String: Any] {
            q.fiveHourPct = (f["used_percentage"] as? NSNumber)?.intValue
            if let r = (f["resets_at"] as? NSNumber)?.doubleValue {
                q.fiveHourResets = Date(timeIntervalSince1970: r)
            }
        }
        if let s = rl["seven_day"] as? [String: Any] {
            q.sevenDayPct = (s["used_percentage"] as? NSNumber)?.intValue
            if let r = (s["resets_at"] as? NSNumber)?.doubleValue {
                q.sevenDayResets = Date(timeIntervalSince1970: r)
            }
        }
        q.model = (obj["model"] as? [String: Any])?["display_name"] as? String

        if let pct = q.fiveHourPct {
            let now = Date()
            if samples.last?.1 != pct { samples.append((now, pct)) }
            samples.removeAll { now.timeIntervalSince($0.0) > Self.sampleWindow }
            // A window that reset (percentage fell) invalidates the older samples.
            if let first = samples.first, first.1 > pct { samples = [(now, pct)] }
            if let first = samples.first, samples.count >= 2 {
                let hours = now.timeIntervalSince(first.0) / 3600
                if hours > 0.02 {
                    let rate = Double(pct - first.1) / hours
                    q.burnPerHour = rate
                    if rate > 0.5 { q.exhaustsIn = Double(100 - pct) / rate * 3600 }
                }
            }
        }
        quota = q
    }
}
