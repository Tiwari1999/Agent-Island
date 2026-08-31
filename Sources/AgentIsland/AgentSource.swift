import Foundation

/// Which tool is running the session. Agents are not all Claude Code, and each vendor keeps its
/// session state somewhere different — but once discovered they are all just a pid in a terminal,
/// which is why jump and host detection stay vendor-agnostic.
enum Vendor: String {
    case claude, codex, cursor

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "Codex"
        case .cursor: return "Cursor"
        }
    }
}

/// One vendor's way of answering "what sessions exist right now".
///
/// Discovery is the only genuinely per-vendor part. Everything downstream — the row, the jump,
/// the host resolution — works off a pid and a cwd, which every vendor has.
protocol AgentSource {
    var vendor: Vendor { get }
    /// True when this tool is present on the machine at all; absent tools cost nothing.
    var isAvailable: Bool { get }
    /// Sessions this vendor knows about, newest activity first. Called off the main actor.
    func discover() -> [Agent]
}

extension AgentSource {
    /// How far back a vendor's sessions stay interesting.
    ///
    /// Not uniform, because "session" means different things. A Claude Code session is a working
    /// session you return to for days. A Cursor session is one chat — 570 of them accumulate, 151
    /// inside ten days — so the same window that keeps Claude useful buries it in one-off
    /// questions. Shorter window, same intent: what could you plausibly still be working on.
    static var maxAge: TimeInterval { 10 * 24 * 3600 }
}
