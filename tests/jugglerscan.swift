// The conv-folder layout is Juggler's private shape, so this is checked against a tree a real
// v0.6.4 server wrote, not against the docs. Prints what JugglerSource reads out of a project.
// Run: swiftc -parse-as-library tests/jugglerscan.swift Sources/AgentIsland/{JugglerSource,Proc,Shell,Diagnostics,AgentStore,AgentSource}.swift -o /tmp/jugglerscan && /tmp/jugglerscan <project>
import Foundation

@main enum JugglerScan {
  static func main() {
    for project in CommandLine.arguments.dropFirst() {
      let dir = project + "/.juggler"
      let convs = JugglerSource.conversations(in: dir) ?? []
      let inst = JugglerSource.instance(dir: dir)
      print("project\t\(project)")
      print("instance\t\(inst.map { "pid=\($0.pid) port=\($0.port) host=\($0.host)" } ?? "none")")
      for c in convs.sorted(by: { $0.id < $1.id }) {
        print("conv\t\(c.id)\t\(c.title)\t\(Int(c.modified.timeIntervalSince1970))")
      }
    }
  }
}
