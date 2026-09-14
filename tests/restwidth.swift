// Do the bar's two sides fit the boxes the layout gives them? Reads the constants out of
// Views.swift so it checks the real formula, and measures with the real font rather than assuming
// an advance width. Both sides are clipped, not truncated, so an overrun loses characters with no
// ellipsis — except the activity text on the left, which sets truncationMode(.tail) and may
// ellipsize once past the width the formula counts.
// argv: lFloor lCeil lBase lPer  rFloor rCeil rBase rPer
import AppKit
let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard a.count == 8 else { print("bad args"); exit(2) }
let (lFloor, lCeil, lBase, lPer) = (a[0], a[1], a[2], a[3])
let (rFloor, rCeil, rBase, rPer) = (a[4], a[5], a[6], a[7])
// The counts render a point larger than the limits; measure everything at the larger size.
// This was 8.5 here long after the scale moved to 10, which under-measured every string by
// ~18% and let lines that actually overran their box pass as fitting.
let f = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
func width(_ s: String) -> Double { (s as NSString).size(withAttributes: [.font: f]).width }
var bad: [String] = []

// What the right side really prints: the limits, plus counts only when there is more than one
// thing to count. A single working agent is said by the pulse, not by a number.
for r in ["left 5h 97% wk 69%", "left 5h 100% wk 100%", "left 5h 0% wk 0%", "left 5h 7%",
          "2 working left 5h 74% wk 70%", "12 working 3 waiting left 5h 100% wk 100%",
          "2 working 4 blocked left 5h 0% wk 0%"] {
    let box = max(rFloor, min(rCeil, rBase + Double(r.count) * rPer))
    let needs = width(r) + (r.contains("waiting") ? 12 : 0) + 14
    if needs > box { bad.append("RIGHT \(r) needs \(Int(needs)) box \(Int(box))") }
}

// The left holds a sentence while something runs, and what the day cost when nothing does. It
// may ellipsize, so it only has to fit while within the 30 characters the formula counts.
for l in ["idle", "spent $0.02 · 12k", "spent $438 · 18.2M", "spent $1999999 · 123.4B",
          "Install and capture the panel"] {
    let box = max(lFloor, min(lCeil, lBase + Double(min(l.count, 30)) * lPer))
    let needs = width(l) + 14
    if l.count <= 30, needs > box { bad.append("LEFT \(l) needs \(Int(needs)) box \(Int(box))") }
}
print(bad.isEmpty ? "ok" : "CUT: " + bad.joined(separator: "; "))
