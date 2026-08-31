import AppKit

/// Precise Warp tab focus.
///
/// Warp exports `WARP_FOCUS_URL=warp://session/<uuid>` into every session's environment and
/// handles that URL as a pane-navigation intent. Reading it from the agent's own process beats
/// the `warp.sqlite` route, which cannot disambiguate tabs that share a working directory.
enum WarpJump {
    /// The focus URL of the Warp tab hosting `pid`, if that process runs under Warp.
    static func focusURL(pid: Int) -> String? {
        let env = Shell.runSync("/bin/ps", ["eww", "-p", "\(pid)", "-o", "command="])
        for token in env.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            if token.hasPrefix("WARP_FOCUS_URL=") {
                return String(token.dropFirst("WARP_FOCUS_URL=".count))
            }
        }
        return nil
    }

    @discardableResult
    static func jump(pid: Int) -> Bool {
        guard let url = focusURL(pid: pid), let target = URL(string: url) else { return false }
        NSWorkspace.shared.open(target)
        return true
    }
}
