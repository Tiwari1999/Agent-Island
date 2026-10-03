import AppKit
import Foundation

enum Diagnostics {
    static let path = "/tmp/agentisland.log"
    /// The log carries session titles, working directories and tool calls, and /tmp is readable
    /// by every account on the machine. It was being created at the default 0644.
    private static let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
    /// Appending forever put days of someone's sessions in one file — 910 KB in a week here, and
    /// only the tail is ever read. Halve it when it passes this, rather than growing without end.
    private static let maxBytes = 512 * 1024

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
            trimIfLarge()
        } else {
            FileManager.default.createFile(atPath: path, contents: data,
                                           attributes: ownerOnly)
        }
    }

    /// Keep the newer half. Rewriting in place keeps the inode, so a tail -f survives it.
    private static func trimIfLarge() {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int,
              size > maxBytes,
              let whole = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = whole.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n")
        try? kept.write(toFile: path, atomically: false, encoding: .utf8)
        try? fm.setAttributes(ownerOnly, ofItemAtPath: path)
    }

    /// Everything someone would otherwise be asked to paste into an issue, in one folder they
    /// can drag onto it. A bug report that is a screenshot of "it broke" costs a round trip;
    /// the log names which half lost a question, and the manifest says what the app believed.
    ///
    /// Nothing is uploaded. The folder is written to the Desktop and revealed, and what goes in
    /// is listed below so the user can look before they send it.
    @discardableResult
    static func export() -> URL? {
        let fm = FileManager.default
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = desktop.appendingPathComponent("AgentIsland-diagnostics-\(stamp)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
        else { return nil }

        // The log is appended to for as long as the app runs; only the tail is ever useful, and
        // a whole one would carry days of someone's session titles into a public issue.
        let whole = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let tail = whole.split(separator: "\n").suffix(2000).joined(separator: "\n")
        try? tail.write(to: dir.appendingPathComponent("agentisland.log"),
                        atomically: true, encoding: .utf8)
        if let rows = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/agentisland.rows.json")) {
            try? rows.write(to: dir.appendingPathComponent("rows.json"))
        }
        try? about().write(to: dir.appendingPathComponent("about.txt"),
                           atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
        log("diagnostics exported to \(dir.path)")
        return dir
    }

    /// What the app is and what it found, which is half of every bug report.
    private static func about() -> String {
        let info = Bundle.main.infoDictionary
        var out = [
            "version:   \(info?["CFBundleShortVersionString"] as? String ?? "dev")",
            "bundle:    \(info?["CFBundleIdentifier"] as? String ?? "-")",
            "macOS:     \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "hooks:     \(Setup.hooksInstalled() ? "installed" : "NOT installed")",
        ]
        for v in Capability.all {
            out.append("\(v.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) "
                       + (Capability.installed(v) ? Capability.summary(v) : "not installed"))
        }
        return out.joined(separator: "\n") + "\n"
    }
}
