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

/// Turning a raw transcript entry into the words a human would recognise.
///
/// Every vendor injects synthetic context as if the user had typed it — Codex wraps environment
/// and plugin blurbs in XML-ish tags, Cursor prefixes a `<timestamp>` and a `<user_query>`. Left
/// alone these become the row's title, which is worse than no title: it is confidently wrong.
enum PromptText {
    /// Whole messages that are machinery, not instructions.
    private static let injected = ["<environment_context", "<recommended_plugins",
                                   "<skills_instructions", "<user_instructions",
                                   "<additional_data", "# AGENTS.md instructions"]

    private static let tag = try? NSRegularExpression(pattern: "</?[A-Za-z_][A-Za-z0-9_]*>")

    /// The first line the user actually wrote, or nil if the entry is entirely machinery.
    static func humanLine(_ raw: String) -> String? {
        let head = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !injected.contains(where: { head.hasPrefix($0) }) else { return nil }

        var body = head
        // A `<timestamp>…</timestamp>` preamble describes the turn; it is never its content.
        if let end = body.range(of: "</timestamp>") { body = String(body[end.upperBound...]) }
        if let tag {
            body = tag.stringByReplacingMatches(
                in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "\n")
        }
        return body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { line in
                guard !line.isEmpty, !line.hasPrefix("<") else { return false }
                // A heading or a bare `USER:` label announces the prompt; it is not the prompt.
                if line.hasPrefix("#") { return false }
                if line.hasSuffix(":") && line.count <= 14 { return false }
                return true
            }
    }
}
