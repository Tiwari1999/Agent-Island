import AppKit
import SwiftUI

/// Everything the user can change, written as it changes — there is no Apply. `Surfaces` keeps
/// owning the material, being read statically by every Theme token; Settings presents both.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private static let snoozeKey = "snoozedUntil"
    private static let autoHideKey = "autoHideSeconds"

    /// Zero means the bar never steps aside. Only has an effect where it covers something.
    @Published var autoHideSeconds: Double {
        didSet { UserDefaults.standard.set(autoHideSeconds, forKey: Self.autoHideKey) }
    }

    @Published var snoozedUntil: Date? {
        didSet {
            UserDefaults.standard.set(snoozedUntil?.timeIntervalSince1970 ?? 0, forKey: Self.snoozeKey)
            armExpiry()
        }
    }

    private var expiry: Timer?

    private init() {
        let d = UserDefaults.standard
        // A fresh install has no value at all, which is different from a stored zero.
        autoHideSeconds = d.object(forKey: Self.autoHideKey) as? Double ?? 4
        let t = d.double(forKey: Self.snoozeKey)
        snoozedUntil = t > 0 ? Date(timeIntervalSince1970: t) : nil
        armExpiry()
    }

    var snoozing: Bool { (snoozedUntil ?? .distantPast) > Date() }

    func snooze(minutes: Double) {
        snoozedUntil = Date().addingTimeInterval(minutes * 60)
    }

    func resume() { snoozedUntil = nil }

    /// Quiet has to end on its own: nothing else is watching the clock, so without this the
    /// island stays hidden until something unrelated redraws it.
    private func armExpiry() {
        expiry?.invalidate()
        guard let until = snoozedUntil, until > Date() else { return }
        expiry = Timer.scheduledTimer(withTimeInterval: until.timeIntervalSinceNow,
                                      repeats: false) { [weak self] _ in
            Task { @MainActor in self?.snoozedUntil = nil }
        }
    }

    static func clockTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

/// The settings screen, shown in the panel's list area like any other mode.
struct SettingsView: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var surfaces = Surfaces.shared
    var onBack: () -> Void

    /// The bar only covers content where there is no notch to sit in.
    private var hasNotch: Bool { (NSScreen.main?.safeAreaInsets.top ?? 0) > 0 }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                group("appearance") {
                    row("material", note: "\u{2318}\u{2325}G") {
                        choice("solid", on: !surfaces.sleek) { surfaces.choice = .solid }
                        choice("sleek", on: surfaces.sleek) { surfaces.choice = .sleek }
                    }
                }

                group("the bar") {
                    row("steps aside after",
                        note: hasNotch ? "this display has a notch \u{2014} it covers nothing here" : nil) {
                        choice("never", on: prefs.autoHideSeconds == 0) { prefs.autoHideSeconds = 0 }
                        choice("4s", on: prefs.autoHideSeconds == 4) { prefs.autoHideSeconds = 4 }
                        choice("8s", on: prefs.autoHideSeconds == 8) { prefs.autoHideSeconds = 8 }
                    }
                }

                group("quiet") {
                    if let until = prefs.snoozedUntil, prefs.snoozing {
                        row("quiet until \(Prefs.clockTime(until))",
                            note: "system notifications still arrive") {
                            choice("resume now", on: false) { prefs.resume() }
                        }
                    } else {
                        row("hide the island for", note: "nothing pops over your screen") {
                            choice("30 min", on: false) { prefs.snooze(minutes: 30) }
                            choice("1 hour", on: false) { prefs.snooze(minutes: 60) }
                            choice("4 hours", on: false) { prefs.snooze(minutes: 240) }
                        }
                    }
                }

                group("app") {
                    row("AgentIsland \(version)", note: nil) {
                        choice("quit", on: false, tint: Theme.failed) { NSApp.terminate(nil) }
                    }
                }

                Text("\u{2039} agents")
                    .font(Theme.mono(9)).foregroundColor(Theme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().stroke(Theme.hairline))
                    .contentShape(Capsule())
                    .onTapGesture(perform: onBack)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(Theme.mono(8)).foregroundColor(Theme.agentTint).tracking(1.2)
            content()
        }
    }

    @ViewBuilder
    private func row<C: View>(_ label: String, note: String?,
                              @ViewBuilder _ controls: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.mono(10)).foregroundColor(Theme.text)
                if let note {
                    Text(note).font(Theme.mono(8)).foregroundColor(Theme.faint)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) { controls() }
        }
    }

    private func choice(_ label: String, on: Bool, tint: Color? = nil,
                        action: @escaping () -> Void) -> some View {
        Text(label)
            .font(Theme.mono(9))
            .foregroundColor(on ? Theme.bg : (tint ?? Theme.muted))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(on ? (tint ?? Theme.muted) : Color.clear)
                    .overlay(Capsule().stroke(on ? Color.clear : (tint ?? Theme.hairline)))
            )
            .contentShape(Capsule())
            .onTapGesture { withAnimation(Motion.quick, action) }
    }
}
