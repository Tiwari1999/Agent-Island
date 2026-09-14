// Do the bar's lines fit the boxes the layout gives them? Reads the constants out of Views.swift
// so it checks the real formulas, and measures with the real font rather than assuming an advance
// width. Both lines are clipped, not truncated, so an overrun loses characters with no ellipsis.
// argv: restFloor restCeil restBase restPer  workFloor workCeil workBase workPer
import AppKit
let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard a.count == 8 else { print("bad args"); exit(2) }
let (rFloor, rCeil, rBase, rPer) = (a[0], a[1], a[2], a[3])
let (wFloor, wCeil, wBase, wPer) = (a[4], a[5], a[6], a[7])
// Type.micro. It was 8.5 here long after the scale moved to 10, which under-measured every
// string by ~18% and let lines that actually overran their box pass as fitting.
let f = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
func width(_ s: String) -> Double { (s as NSString).size(withAttributes: [.font: f]).width }
var bad: [String] = []

// Resting: "<vendor> left 5h N% (reset) · wk N% (reset) · $spend · tokens", to its worst case.
for s in ["idle", "claude left 5h 97% (12m) · wk 99% (6d) · $0.02 · 12k",
          "claude left 5h 84% (2h25m) · wk 71% (3d10h) · $57.31 · 309k",
          "claude left 5h 0% (5h00m) · wk 0% (7d00h) · $18942 · 1.9B",
          "codex left 5h 100% (5h00m) · wk 100% (7d00h) · $1999999 · 123.4B"] {
    let needs = width(s) + 10
    let box = max(rFloor, min(rCeil, rBase + Double(s.count) * rPer))
    if needs > box { bad.append("REST \(s) needs \(Int(needs)) box \(Int(box))") }
}

// Working: the labelled counts and both limit windows share the right side, so the box has to
// hold the whole line — wrapping it onto a second row was the reported bug. The counts render a
// point larger than the limits, so measure the lot at the larger size and the bell's width too.
let big = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
let bell = 9.0 + 3
for s in ["1 working left 5h 84% wk 71%", "12 working 3 waiting left 5h 100% wk 100%",
          "1 working 2 blocked left 5h 0% wk 0%", "1 working", "9 waiting left 5h 7% wk 7%"] {
    let needs = (s as NSString).size(withAttributes: [.font: big]).width
        + (s.contains("waiting") ? bell : 0) + 14
    let box = max(wFloor, min(wCeil, wBase + Double(s.count) * wPer))
    if needs > box { bad.append("WORK \(s) needs \(Int(needs)) box \(Int(box))") }
}
print(bad.isEmpty ? "ok" : "CUT: " + bad.joined(separator: "; "))
