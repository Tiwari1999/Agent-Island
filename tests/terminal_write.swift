import Foundation
// Lifted verbatim from TerminalWrite.send's guard and quoting.
func accepted(_ line: String) -> Bool {
    let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return !text.isEmpty && text.count <= 4096
        && !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
}
func quoted(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
func shellQuoted(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

var fails = 0
func check(_ name: String, _ ok: Bool) {
    if !ok { fails += 1 }
    print("  \(ok ? "PASS" : "FAIL")  \(name)")
}

check("a normal reply is accepted", accepted("yes, use option 2"))
check("leading/trailing space is trimmed, not rejected", accepted("   ok   "))
check("empty is rejected", !accepted("   "))
check("a newline is rejected — a literal cannot span lines", !accepted("a\nb"))
check("a carriage return is rejected", !accepted("a\rb"))
check("a NUL is rejected", !accepted("a\u{0}b"))
check("DEL is rejected", !accepted("a\u{7F}b"))
check("an escape sequence is rejected", !accepted("\u{1B}[31mred"))
check("4096 chars ok, 4097 not", accepted(String(repeating: "x", count: 4096))
                              && !accepted(String(repeating: "x", count: 4097)))
check("unicode survives", accepted("हाँ, ठीक है ✅"))

// AppleScript literal: a quote must not close the string early
check("a quote is escaped for AppleScript", quoted("say \"hi\"") == "\"say \\\"hi\\\"\"")
check("a backslash is escaped first", quoted("a\\b") == "\"a\\\\b\"")
// Shell: a single quote must not break out
check("a single quote cannot break the shell word",
      shellQuoted("it's") == "'it'\\''s'")
check("shell metacharacters stay inert",
      shellQuoted("a; rm -rf /") == "'a; rm -rf /'")

print(fails == 0 ? "\nRESULT: ok" : "\nRESULT: \(fails) failure(s)")
exit(fails == 0 ? 0 : 1)
