// Do the bar's two sides fit the box the layout gives them? Reads the constants out of Views.swift
// so it checks the real formula, and measures with the real font rather than assuming an advance
// width. Both sides are clipped, not truncated, so an overrun loses characters with no ellipsis —
// except the activity text on the left, which sets truncationMode(.tail) and may ellipsize.
// argv: floor ceil leftBase leftPer rightBase rightPer
import AppKit
let a = CommandLine.arguments.dropFirst().compactMap(Double.init)
guard a.count == 6 else { print("bad args"); exit(2) }
let (floorW, ceilW, lBase, lPer, rBase, rPer) = (a[0], a[1], a[2], a[3], a[4], a[5])
// The counts render a point larger than the limits; measure everything at the larger size.
// This was 8.5 here long after the scale moved to 10, which under-measured every string by
// ~18% and let lines that actually overran their box pass as fitting.
let f = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
func width(_ s: String) -> Double { (s as NSString).size(withAttributes: [.font: f]).width }
var bad: [String] = []

// (left, right) as the bar really pairs them: what is happening / what today cost on the left,
// the counts and both remaining windows on the right.
let pairs = [
    ("spent $0.02 · 12k", "left 5h 97% wk 99%"),
    ("spent $438 · 18.2M", "left 5h 74% wk 70%"),
    ("spent $1999999 · 123.4B", "left 5h 100% wk 100%"),
    ("Install and capture the p", "1 working left 5h 74% wk 70%"),
    ("Reticulating splines for t", "12 working 3 waiting left 5h 100% wk 100%"),
    ("idle", "1 working 2 blocked left 5h 0% wk 0%"),
    ("idle", "left 5h 7%"),
]
for (l, r) in pairs {
    // Both sides get the same width: max of what each needs, floored and capped.
    let box = max(floorW, min(ceilW, max(lBase + Double(min(l.count, 34)) * lPer,
                                         rBase + Double(r.count) * rPer)))
    let needsR = width(r) + (r.contains("waiting") ? 12 : 0) + 14
    if needsR > box { bad.append("RIGHT \(r) needs \(Int(needsR)) box \(Int(box))") }
    // The left may ellipsize, so it only has to fit while it is within the width the formula
    // actually counts (34 chars); past that truncation is the design, not a clip.
    if l.count <= 34 {
        let needsL = width(l) + 14
        if needsL > box { bad.append("LEFT \(l) needs \(Int(needsL)) box \(Int(box))") }
    }
}
print(bad.isEmpty ? "ok" : "CUT: " + bad.joined(separator: "; "))
