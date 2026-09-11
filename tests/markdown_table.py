#!/usr/bin/env python3
"""Lift MarkdownLite.blocks verbatim out of the app and run it, so the table parser is
tested as shipped rather than as a re-implementation."""
import pathlib, subprocess, sys, tempfile, os

REPO = pathlib.Path(__file__).resolve().parent.parent
src = (REPO / "Sources/AgentIsland/PanelModes.swift").read_text()
start = src.index("    static func blocks(_ raw: String) -> [Block] {")
i = src.index("{", start); depth = 0
for j in range(i, len(src)):
    if src[j] == "{": depth += 1
    elif src[j] == "}":
        depth -= 1
        if depth == 0: end = j + 1; break
body = src[start:end]

PROG = '''import Foundation
enum MarkdownLite {
    enum Block: Equatable {
        case heading(Int, String), bullet(String), code(String), rule, plain(String)
        case table([[String]])
    }
''' + body + '''
}
@main enum T {
  static func main() {
    let md = """
    Prose before.

    | scenario | badged? |
    |---|---|
    | you are replying | no |
    | agent genuinely stuck | YES |

    Prose after.
    """
    var tables = 0, leaks = 0, rowCount = 0
    for b in MarkdownLite.blocks(md) {
        switch b {
        case .table(let rows): tables += 1; rowCount = rows.count
        case .plain(let t): if t.contains("|") { leaks += 1 }
        default: break
        }
    }
    print("tables=\\(tables) rows=\\(rowCount) pipeLeaks=\\(leaks)")
    exit(tables == 1 && rowCount == 3 && leaks == 0 ? 0 : 1)
  }
}
'''
with tempfile.TemporaryDirectory() as d:
    f = pathlib.Path(d) / "p.swift"; f.write_text(PROG)
    b = pathlib.Path(d) / "p"
    c = subprocess.run(["swiftc", "-parse-as-library", "-O", str(f), "-o", str(b)],
                       capture_output=True, text=True)
    if c.returncode != 0:
        print("COMPILE FAIL:", c.stderr[:300]); sys.exit(1)
    r = subprocess.run([str(b)], capture_output=True, text=True)
    print(r.stdout.strip())
    sys.exit(r.returncode)
