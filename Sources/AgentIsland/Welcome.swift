import SwiftUI

/// The first thing a stranger sees.
///
/// Not a wizard. Three facts and two buttons, on one screen: where it reads from, what it will
/// and will not do for the agents they actually have, and the two permissions it would otherwise
/// ask for out of nowhere. The first five minutes decide whether anyone stays, and "an empty
/// panel that wants Accessibility" is not a first five minutes anyone stays through.
struct WelcomeView: View {
    var onDone: () -> Void
    @State private var hooksReady = Setup.hooksInstalled()
    @State private var installing = false
    @State private var askedNotifications = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AgentIsland \(version)")
                        .font(Theme.name(Type.title)).foregroundColor(Theme.text)
                    // The first question anyone asks about a thing that watches their agents.
                    Text("Reads the transcripts your agents already write to this disk. "
                         + "Nothing leaves the machine, and there is no account.")
                        .font(Theme.mono(Type.small)).foregroundColor(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                agents
                gatekeeper
                actions

                Text("Hover the notch to bring the island back. \u{2318}\u{2325}G opens settings.")
                    .font(Theme.mono(Type.micro)).foregroundColor(Theme.faint)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What it can do for the agents on THIS machine, rather than a table of everything it could
    /// do for someone else's. An agent that cannot be approved from the notch says so here, once,
    /// instead of leaving someone waiting for a card that is never coming.
    @ViewBuilder
    private var agents: some View {
        let present = Capability.present
        VStack(alignment: .leading, spacing: 6) {
            Text(present.isEmpty ? "no agents found yet" : "what it can do for yours")
                .font(Theme.mono(Type.micro)).foregroundColor(Theme.faint)
            if present.isEmpty {
                Text("Start one with `claude`, `codex` or `cursor-agent` and it appears here.")
                    .font(Theme.mono(Type.small)).foregroundColor(Theme.muted)
            }
            ForEach(present, id: \.rawValue) { v in
                HStack(alignment: .top, spacing: 8) {
                    Text(v.label)
                        .font(Theme.label(Type.body)).foregroundColor(Theme.text)
                        .frame(width: 52, alignment: .leading)
                    Text(Capability.summary(v))
                        .font(Theme.mono(Type.small))
                        .foregroundColor(Capability.approvals(v) ? Theme.muted : Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Only on an unsigned build, and only once. Someone who got past Gatekeeper already knows
    /// they did something unusual; leaving it unexplained is what makes a downloaded app feel
    /// like something they should not have opened.
    @ViewBuilder
    private var gatekeeper: some View {
        if !Setup.signedForDistribution {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.open")
                    .font(.system(size: 10)).foregroundColor(Theme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This build is not notarized by Apple yet")
                        .font(Theme.label(Type.body)).foregroundColor(Theme.text)
                    Text("That is why opening it needed right-click \u{203A} Open. It is signed "
                         + "only by the machine that built it, so macOS cannot vouch for it — "
                         + "read the source or build it yourself if that matters to you.")
                        .font(Theme.mono(Type.small)).foregroundColor(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.amber.opacity(0.08)))
        }
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Both of these would otherwise be a system prompt with no explanation behind it.
            HStack(spacing: 7) {
                button(hooksReady ? "hooks installed" : (installing ? "installing…" : "install hooks"),
                       done: hooksReady, tint: Theme.amber) {
                    guard !installing, !hooksReady else { return }
                    installing = true
                    Setup.install { ok in installing = false; hooksReady = ok }
                }
                button(askedNotifications ? "notifications asked" : "allow notifications",
                       done: askedNotifications, tint: Theme.working) {
                    askedNotifications = true
                    Notifier.requestAuthorization()
                }
                Spacer(minLength: 0)
                button("done", done: false, tint: Theme.text, action: onDone)
            }
            Text(hooksReady
                 ? "Hooks are registered in each agent's own settings, backed up first, and "
                   + "removed by scripts/uninstall-hooks.py."
                 : "Live activity, approvals and questions need hooks. One click writes them into "
                   + "each agent's settings, after backing the file up.")
                .font(Theme.mono(Type.micro)).foregroundColor(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func button(_ label: String, done: Bool, tint: Color,
                        action: @escaping () -> Void) -> some View {
        Text(label)
            .font(Theme.mono(Type.small))
            .foregroundColor(done ? Theme.faint : tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().stroke(done ? Theme.hairline : tint.opacity(0.45)))
            .contentShape(Capsule())
            .onTapGesture(perform: action)
    }
}
