// Source-text checks prove the resolve order; they cannot prove a real shell in iTerm2 or
// Terminal.app yields the handle the jump matches on. Takes pids, prints case + handle.
// Run: swiftc -parse-as-library tests/hostresolve.swift Sources/AgentIsland/{HostTerminal,ProcEnv,Proc,Shell,Diagnostics,Cwd}.swift -o /tmp/hostresolve && /tmp/hostresolve <pid>...
import Foundation

@main enum HostResolveCheck {
  static func main() {
    let pids = CommandLine.arguments.dropFirst().compactMap(Int.init)
    // info() only reads a cache prime() fills; resolving without it sees an empty Info.
    ProcEnv.prime(pids: pids)
    for pid in pids {
      let h = HostTerminal.resolve(pid: pid)
      let kind: String
      switch h {
      case .tmux:          kind = "tmux"
      case .warp:          kind = "warp"
      case .iterm:         kind = "iterm"
      case .appleTerminal: kind = "appleTerminal"
      case .kitty:         kind = "kitty"
      case .wezterm:       kind = "wezterm"
      case .app:           kind = "app"
      case .degraded:      kind = "degraded"
      case .unknown:       kind = "unknown"
      }
      print("\(pid)\t\(kind)\t\(h.name)\t\(h.isPrecise)\t\(h.target ?? "-")")
      // The row click runs exactly this; --jump proves the landing, not just the handle.
      if CommandLine.arguments.contains("--jump") { print("jump\t\(pid)\t\(h.jump())") }
    }
  }
}
