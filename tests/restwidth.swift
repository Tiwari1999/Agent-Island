// Does the resting usage line fit the box the layout gives it? Reads the constants out of
// Views.swift so it checks the real formula, and measures with the real font rather than
// assuming an advance width. argv: floor ceil base perChar
import AppKit
let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard a.count == 4 else { print("bad args"); exit(2) }
let (floorW, ceilW, base, per) = (a[0], a[1], a[2], a[3])
let f = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular)
var bad: [String] = []
for s in ["idle", "claude 3% · $0.02 · 12.0K", "claude 28% · $1894 · 888.1M",
          "claude 100% · $18942 · 1.9B", "codex 100% · $199999 · 12.3B",
          "codex 100% · $1999999 · 123.4B"] {
    let needs = (s as NSString).size(withAttributes: [.font: f]).width + 10
    let box = max(floorW, min(ceilW, base + Double(s.count) * per))
    if needs > box { bad.append("\(s) needs \(needs) box \(box)") }
}
print(bad.isEmpty ? "ok" : "CUT: " + bad.joined(separator: "; "))
