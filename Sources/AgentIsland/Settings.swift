import AppKit
import SwiftUI

/// Everything the user can change, written as it changes — there is no Apply. `Surfaces` keeps
/// owning the material, being read statically by every Theme token; Settings presents both.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private static let snoozeKey = "snoozedUntil"
    private static let autoHideKey = "autoHideSeconds"
    private static let reopenKey = "reopenIn"
    private static let welcomeKey = "seenWelcome"
    private static let soundNeedsYouKey = "soundNeedsYou"
    private static let soundDoneKey = "soundDone"
    private static let groupKey = "groupByProject"
    private static let remindKey = "remindMinutes"

    /// Shown once. A returning user opening the panel to check on an agent does not want a
    /// greeting, and Settings has a way back to it for anyone who does.
    var seenWelcome: Bool {
        get { UserDefaults.standard.bool(forKey: Self.welcomeKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.welcomeKey) }
    }

    /// Which terminal a closed chat reopens in when its row is clicked. A live chat is always
    /// focused where it runs; this is only for one whose tab is gone.
    @Published var reopenIn: ReopenTarget {
        didSet { UserDefaults.standard.set(reopenIn.rawValue, forKey: Self.reopenKey) }
    }

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

    /// The app shipped for a while under sh.emergent.agentisland, and preferences live in a
    /// plist named after the bundle id — so renaming it silently reset everyone's settings.
    /// Carried once, and only into keys that are still unset, so it can never overwrite a
    /// choice made since.
    private static func carryLegacySettings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromEmergent"),
              let old = UserDefaults(suiteName: "sh.emergent.agentisland") else { return }
        for key in [snoozeKey, autoHideKey, reopenKey, welcomeKey, "surface", "typeface"] {
            if d.object(forKey: key) == nil, let v = old.object(forKey: key) {
                d.set(v, forKey: key)
            }
        }
        d.set(true, forKey: "migratedFromEmergent")
    }

    private init() {
        Self.carryLegacySettings()
        let d = UserDefaults.standard
        // A fresh install has no value at all, which is different from a stored zero.
        autoHideSeconds = d.object(forKey: Self.autoHideKey) as? Double ?? 4
        reopenIn = d.string(forKey: Self.reopenKey).flatMap(ReopenTarget.init) ?? ReopenTarget.preferred
        // object(forKey:) so a deliberately stored false is not read back as the default.
        soundNeedsYou = d.object(forKey: Self.soundNeedsYouKey) as? Bool ?? true
        soundDone = d.object(forKey: Self.soundDoneKey) as? Bool ?? false
        groupByProject = d.bool(forKey: Self.groupKey)
        remindMinutes = d.object(forKey: Self.remindKey) as? Double ?? 5
        let t = d.double(forKey: Self.snoozeKey)
        snoozedUntil = t > 0 ? Date(timeIntervalSince1970: t) : nil
        armExpiry()
    }

    /// An agent blocked on you is the one thing worth a sound by default.
    @Published var soundNeedsYou: Bool {
        didSet { UserDefaults.standard.set(soundNeedsYou, forKey: Self.soundNeedsYouKey) }
    }

    /// Off by default: finishes are frequent, so this one turns into noise fastest.
    @Published var soundDone: Bool {
        didSet { UserDefaults.standard.set(soundDone, forKey: Self.soundDoneKey) }
    }

    /// Off by default: the flat list sorts by what needs you, and grouping trades that away.
    @Published var groupByProject: Bool {
        didSet { UserDefaults.standard.set(groupByProject, forKey: Self.groupKey) }
    }

    /// Zero is Off. An unanswered ask is nudged up to three times, an unseen finish once.
    @Published var remindMinutes: Double {
        didSet { UserDefaults.standard.set(remindMinutes, forKey: Self.remindKey) }
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
            Task { @MainActor [weak self] in self?.snoozedUntil = nil }
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
    @ObservedObject private var typefaces = Typefaces.shared
    @ObservedObject private var updater = Updater.shared
    var onBack: () -> Void
    @ViewState private var exported = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                group("appearance") {
                    row("Material", note: "\u{2318}\u{2325}G") {
                        choice("Solid", on: !surfaces.sleek) { surfaces.choice = .solid }
                        choice("Sleek", on: surfaces.sleek) { surfaces.choice = .sleek }
                    }
                    row("Typeface", note: "Figures stay aligned in all three") {
                        ForEach(Typeface.allCases, id: \.self) { f in
                            choice(f.label.capitalized, on: typefaces.choice == f) { typefaces.choice = f }
                        }
                    }
                }

                group("the bar") {
                    row("Steps aside after",
                        note: "Only when nothing is running \u{2014} hover the notch to bring it back") {
                        choice("Never", on: prefs.autoHideSeconds == 0) { prefs.autoHideSeconds = 0 }
                        choice("2s", on: prefs.autoHideSeconds == 2) { prefs.autoHideSeconds = 2 }
                        choice("4s", on: prefs.autoHideSeconds == 4) { prefs.autoHideSeconds = 4 }
                        choice("8s", on: prefs.autoHideSeconds == 8) { prefs.autoHideSeconds = 8 }
                    }
                }

                group("list") {
                    row("Group by project", note: "A worktree joins its main repo") {
                        choice("Flat", on: !prefs.groupByProject) { prefs.groupByProject = false }
                        choice("Project", on: prefs.groupByProject) { prefs.groupByProject = true }
                    }
                }

                group("clicks") {
                    row("Reopen a closed chat in",
                        note: "A chat whose tab is still open is focused there") {
                        if ReopenTarget.warpInstalled {
                            choice("Warp", on: prefs.reopenIn == .warp) { prefs.reopenIn = .warp }
                        }
                        choice("Terminal", on: prefs.reopenIn == .terminal) { prefs.reopenIn = .terminal }
                    }
                }

                group("quiet") {
                    if let until = prefs.snoozedUntil, prefs.snoozing {
                        row("Quiet until \(Prefs.clockTime(until))",
                            note: "System notifications still arrive") {
                            choice("Resume now", on: false) { prefs.resume() }
                        }
                    } else {
                        row("Hide the island for", note: "The island stays hidden \u{2014} notifications still arrive") {
                            choice("30 min", on: false) { prefs.snooze(minutes: 30) }
                            choice("1 hour", on: false) { prefs.snooze(minutes: 60) }
                            choice("4 hours", on: false) { prefs.snooze(minutes: 240) }
                        }
                    }
                }

                group("sounds") {
                    row("Play a sound",
                        note: "Silent while Quiet, or while the bar is stepped aside") {
                        choice("Needs you", on: prefs.soundNeedsYou) { prefs.soundNeedsYou.toggle() }
                        choice("Done", on: prefs.soundDone) { prefs.soundDone.toggle() }
                    }
                    row("Remind again after",
                        note: "Up to 3 times while an agent waits \u{2014} not while locked or looking") {
                        ForEach([0.0, 2, 5, 10], id: \.self) { m in
                            choice(m == 0 ? "Off" : "\(Int(m)) min", on: prefs.remindMinutes == m) {
                                prefs.remindMinutes = m
                            }
                        }
                    }
                }

                group("app") {
                    // A bug report that is a screenshot of "it broke" costs a round trip. This
                    // is the log, the manifest and what the app believes about each agent, in a
                    // folder on the Desktop — revealed, not uploaded, so it can be read first.
                    row("Diagnostics", note: "Log and session dump on your Desktop \u{2014} nothing is sent") {
                        choice(exported ? "on your Desktop" : "Export", on: exported) {
                            exported = Diagnostics.export() != nil
                        }
                    }
                    row("What each agent can do", note: "Approvals need a permission hook") {
                        choice("Show", on: false, tint: Theme.amber) {
                            Prefs.shared.seenWelcome = false
                            onBack()
                        }
                    }
                    row("Check for updates",
                        note: updater.available ? "At most once a day, from agentisland.in"
                                                : "Off in this build \u{2014} it carries no update key") {
                        if updater.available {
                            choice("Daily", on: updater.automatic) { updater.automatic = true }
                            choice("Off", on: !updater.automatic) { updater.automatic = false }
                            choice("Now", on: false) { updater.check() }
                        }
                    }
                    row("AgentIsland \(version)", note: nil) {
                        choice("Quit", on: false, tint: Theme.failed) { NSApp.terminate(nil) }
                    }
                }

                Text("\u{2039} Agents")
                    .font(Theme.mono(Type.small)).foregroundColor(Theme.muted)
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
                .font(Theme.mono(Type.micro)).foregroundColor(Theme.agentTint).tracking(1.2)
            content()
        }
    }

    @ViewBuilder
    private func row<C: View>(_ label: String, note: String?,
                              @ViewBuilder _ controls: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Theme.mono(Type.body)).foregroundColor(Theme.text)
                if let note {
                    Text(note).font(Theme.mono(Type.micro)).foregroundColor(Theme.faint)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) { controls() }
        }
    }

    private func choice(_ label: String, on: Bool, tint: Color? = nil,
                        action: @escaping () -> Void) -> some View {
        Text(label)
            .font(Theme.mono(Type.small))
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
