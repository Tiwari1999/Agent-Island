import Foundation
// Edge cases for Explain.split(), which decides what lands under which option. Kept in step
// with Sources/AgentIsland/Explain.swift by hand; the suite checks both still agree.
// Run: swift tests/explainsplit.swift
func split(_ text: String) -> (lead: String, byIndex: [Int: String]) {
    var lead: [String] = []
    var byIndex: [Int: String] = [:]
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if let mark = line.firstIndex(where: { $0 == "." || $0 == ")" }),
           let n = Int(line[line.startIndex..<mark]), (1...4).contains(n) {
            byIndex[n] = String(line[line.index(after: mark)...]).trimmingCharacters(in: .whitespaces)
        } else if byIndex.isEmpty { lead.append(line) }
    }
    return (lead.joined(separator: " "), byIndex)
}
var fails = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "  PASS  \(name)" : "  FAIL  \(name)"); if !ok { fails += 1 } }

let real = """
How should the card respond when options overflow the available space?
1. Pin header/footer controls and scroll only the options list; choose when actions must remain accessible.
2. Grow the card and scroll everything as one; choose for simpler unified scrolling behavior.
"""
let r = split(real)
check("the lead is the unnumbered first line", r.lead.hasPrefix("How should the card"))
check("each numbered line lands on its own option", r.byIndex.count == 2
      && r.byIndex[1]!.hasPrefix("Pin header") && r.byIndex[2]!.hasPrefix("Grow the card"))
check("the number and its punctuation are stripped", !r.byIndex[1]!.hasPrefix("1"))

let unnumbered = split("This is one paragraph with no numbering at all.")
check("an unnumbered answer is kept whole as the lead",
      unnumbered.byIndex.isEmpty && unnumbered.lead.contains("no numbering"))

let paren = split("Lead line.\n1) first\n2) second")
check("\"1)\" is accepted as well as \"1.\"", paren.byIndex[1] == "first" && paren.byIndex[2] == "second")

// A sentence that merely opens with a number must not be mistaken for an option line.
let decoy = split("2024. was the year.\n1. real option")
check("an out-of-range number is not an option", decoy.byIndex.count == 1 && decoy.byIndex[1] == "real option")

// Prose after the options belongs to nothing; it must not be prepended to the lead.
let trailing = split("Lead.\n1. one\nSome trailing remark.")
check("trailing prose does not leak into the lead", trailing.lead == "Lead.")

print(fails == 0 ? "RESULT: 0 failure(s)" : "RESULT: \(fails) failure(s)")
