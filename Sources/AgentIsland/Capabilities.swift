import Foundation

/// What each agent can actually do here.
///
/// The README's table once promised approvals for all three vendors when only one publishes a
/// permission hook. The promise and the wiring are the same facts now, in one place, so the app
/// can tell a Codex user what it will and will not do for them before they wait for a card that
/// is never coming.
enum Capability {
    /// Answering a permission prompt from the notch. Needs the agent to ask through a hook
    /// BEFORE it acts, and to accept an answer back. Only Claude Code publishes one
    /// (`PermissionRequest`); Codex and Cursor expose lifecycle and tool events with nothing to
    /// answer, so a card there would be a button that does nothing. Gemini's BeforeTool hook can
    /// deny but never grant; OpenCode's plugin can reply to a pending ask through its own server.
    static func approvals(_ v: Vendor) -> Bool { v == .claude || v == .opencode }

    /// One line a stranger can act on, rather than a table they have to interpret.
    static func summary(_ v: Vendor) -> String {
        approvals(v)
            ? "lists, jumps, and answers approvals and questions in the notch"
            : "lists, shows live activity and jumps — \(v.label) has no hook that can grant a "
              + "permission, so approvals stay in its own terminal"
    }

    /// Whether the agent is on this machine at all, by the directory it keeps its sessions in.
    static func installed(_ v: Vendor) -> Bool {
        let dir: String
        switch v {
        case .claude: dir = "/.claude"
        case .codex:  dir = "/.codex"
        case .cursor: dir = "/.cursor"
        case .gemini: dir = "/.gemini"
        case .opencode: dir = "/.local/share/opencode"
        }
        return FileManager.default.fileExists(atPath: Home.path + dir)
    }

    static let all: [Vendor] = [.claude, .codex, .cursor, .gemini, .opencode]
    static var present: [Vendor] { all.filter(installed) }
}
