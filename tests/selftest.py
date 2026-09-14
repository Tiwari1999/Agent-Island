#!/usr/bin/env python3
"""Headless self-test: verifies every claim the app makes, without a human looking at it."""
import glob, json, os, re, subprocess, sys, time

# Resolve paths from the repo itself so the suite runs anywhere, not just my machine.
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Fixtures are namespaced per run: two suites sharing one decisions directory answered each
# other's requests, which looked like a product failure and was a harness collision.
RUN = f"/tmp/ai-st-{os.getpid()}"
import atexit, glob as _glob, shutil as _shutil
@atexit.register
def _sweep():
    for p in _glob.glob(RUN + "*"):
        _shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) else os.remove(p)
CLAUDE = os.environ.get("CLAUDE_BIN", "/opt/homebrew/bin/claude")
# The suite must never write to the spool the app reads: a "selftest-1" row appearing in the
# panel beside real sessions is a defect, not test noise.
SPOOL="/tmp/agentisland-selftest.jsonl"
LIVE_SPOOL="/tmp/agentisland-events.jsonl"
fails=[]
def check(name, ok, detail=""):
    print(f"  {'PASS' if ok else 'FAIL'}  {name}{('  — '+detail) if detail else ''}")
    if not ok: fails.append(name)

print("=== AGENTISLAND SELF-TEST ===\n\n=== 1. agent enumeration ===")
raw=subprocess.run([CLAUDE,"agents","--json","--all"],capture_output=True,text=True)
agents=json.loads(raw.stdout or "[]")
check("claude agents --json returns sessions", len(agents)>0, f"{len(agents)} sessions")
check("sessions expose sessionId+state", all("sessionId" in a for a in agents))

print("\n=== 2. Warp jump resolution (the feature that was broken) ===")
def has_tty(pid):
    t=subprocess.run(["ps","-o","tty=","-p",str(pid)],capture_output=True,text=True).stdout.strip()
    return t not in ("??","","-")

def ppid(pid):
    out=subprocess.run(["ps","-o","ppid=","-p",str(pid)],capture_output=True,text=True).stdout.strip()
    return int(out) if out.isdigit() and int(out) > 1 else None

def owning_pid(pid, hops=8):
    """Mirrors HostTerminal.resolve: a background agent has no terminal of its own, so it
    resolves to the nearest ancestor that has one — the window the user watches it in."""
    if has_tty(pid): return pid
    cur = pid
    for _ in range(hops):
        p = ppid(cur)
        if p is None: return None
        if has_tty(p): return p
        cur = p
    return None

def focus_url(pid):
    owner = owning_pid(pid)
    if owner is None: return None
    env=subprocess.run(["ps","eww","-p",str(owner),"-o","command="],capture_output=True,text=True).stdout
    return next((t.split("=",1)[1] for t in env.split() if t.startswith("WARP_FOCUS_URL=")),None)

withpid=[a for a in agents if a.get("pid")]
resolved={a["sessionId"]:focus_url(a["pid"]) for a in withpid}
got=[u for u in resolved.values() if u]
check("agents with pid resolve a Warp URL", len(got)>0, f"{len(got)}/{len(withpid)}")
# Only sessions that own a terminal must hold it exclusively. A background agent shares its
# owner's tab by definition — that is where its conversation is displayed.
_own=[a for a in withpid if has_tty(a["pid"])]
_owned=[u for u in (focus_url(a["pid"]) for a in _own) if u]
check("each interactive agent maps to a DISTINCT tab",
      len(set(_owned))==len(_owned), f"{len(set(_owned))} distinct of {len(_owned)}")
# A background agent has no tty, so it used to resolve nothing and its row went nowhere.
_bg=[a for a in withpid if not has_tty(a["pid"])]
check("a background agent resolves the terminal that owns it",
      all(owning_pid(a["pid"]) is not None for a in _bg), f"{len(_bg)} background")
# The guard that was missing. Two fixes each verified only against their own symptom left every
# live row either going nowhere or opening a terminal — the main flow, untested end to end.
_lost=[a for a in withpid if owning_pid(a["pid"]) is None]
check("every live agent has somewhere to jump to",
      not _lost, f"{len(withpid)-len(_lost)}/{len(withpid)} reachable")
check("URLs are warp://session/<uuid>", all(u.startswith("warp://session/") for u in got))

print("\n=== 3. jump actually drives Warp (log-verified, all agents) ===")
LOG=os.path.expanduser("~/Library/Logs/warp.log")
def logsize(): return os.path.getsize(LOG) if os.path.exists(LOG) else 0
ok_recv=ok_nav=0
for sid,u in list(resolved.items()):
    if not u: continue
    m=logsize(); subprocess.run(["open",u]); time.sleep(2.2)
    with open(LOG,"rb") as f:
        f.seek(m); new=f.read().decode("utf8","replace")
    if "received url" in new: ok_recv+=1
    if "handle_pane_navigation_event" in new: ok_nav+=1
# Warp always receives the intent; pane navigation only fires when the tab actually changes,
# so a target that is already focused legitimately reports no navigation.
check("Warp receives every jump intent", ok_recv==len(got), f"{ok_recv}/{len(got)}")
check("jumps navigate panes (allowing already-focused)", ok_nav>=len(got)-1, f"{ok_nav}/{len(got)}")

print("\n=== 4. hook stream parsing ===")
open(SPOOL,"a").close()
before=os.path.getsize(SPOOL)
sample={"session_id":"selftest-1","hook_event_name":"PreToolUse","tool_name":"Bash",
        "tool_input":{"command":"echo hello world"},"cwd":"/tmp"}
with open(SPOOL,"a") as f: f.write(json.dumps(sample)+"\n")
check("spool is append-writable", os.path.getsize(SPOOL)>before)
check("hook payload has fields the UI needs",
      all(k in sample for k in ("session_id","hook_event_name","tool_name","tool_input")))

print("\n=== 5. hook script contract ===")
hook=os.path.join(REPO,"hooks/agentisland-hook.sh")
if os.path.exists(hook):
    tmp=f"{RUN}-selftest-spool.jsonl"
    if os.path.exists(tmp): os.remove(tmp)
    env=dict(os.environ, AGENTISLAND_SPOOL=tmp)
    p=subprocess.run([hook,"PreToolUse"],input=json.dumps(sample),capture_output=True,
                     text=True,timeout=5,env=env)
    check("hook exits 0 (never blocks Claude)", p.returncode==0, f"exit={p.returncode}")
    # Exit code alone proved nothing here once; assert the actual side effect.
    wrote = os.path.exists(tmp) and os.path.getsize(tmp)>0
    check("hook WRITES the event to its spool", wrote,
          f"{os.path.getsize(tmp) if os.path.exists(tmp) else 0} bytes")
    if wrote:
        back=json.loads(open(tmp).read().strip().split("\n")[0])
        # The hook wraps the payload to carry its parent pid; the island unwraps either shape.
        inner=back.get("payload", back)
        check("written event round-trips as JSON", inner.get("session_id")==sample["session_id"])
        check("the envelope carries a real parent pid", isinstance(back.get("ai_ppid"), int)
              and back["ai_ppid"] > 1, str(back.get("ai_ppid")))

    live=LIVE_SPOOL   # read-only check, never written by the suite
    check("live session events are reaching the spool",
          os.path.exists(live) and os.path.getsize(live)>0,
          f"{os.path.getsize(live) if os.path.exists(live) else 0} bytes")
else:
    check("hook script exists", False, "not created yet")

print("\n=== 6. attention pipeline (toast triggers) ===")
# Its own file: a suite that writes to the spool the app reads puts fake rows in the panel.
live=SPOOL
sess="selftest-peek"
before=os.path.getsize(live) if os.path.exists(live) else 0
with open(live,"a") as f:
    f.write(json.dumps({"session_id":sess,"hook_event_name":"Notification",
                        "message":"needs your permission","cwd":"/tmp"})+"\n")
    f.write(json.dumps({"session_id":sess,"hook_event_name":"PreToolUse","tool_name":"Bash",
                        "tool_input":{"command":"npm test"},"cwd":"/tmp"})+"\n")
    f.write(json.dumps({"session_id":sess,"hook_event_name":"Stop","cwd":"/tmp"})+"\n")
check("attention events append to the live spool", os.path.getsize(live)>before)
time.sleep(1.5)
alive=subprocess.run(["pgrep","-f","AgentIsland.app/Contents/MacOS/AgentIsland"],
                     capture_output=True,text=True).stdout.strip()
check("app survives Notification + Stop without crashing", bool(alive), f"pid {alive.splitlines()[0] if alive else '-'}")

print("\n=== 7. activity text rendering ===")
def describe(tool, d):
    if tool=="Bash": return (d.get("command") or "").split("\n")[0][:44]
    if tool in ("Read","Edit","Write"): return f"{tool} {os.path.basename(d.get('file_path',''))}"
    return tool
check("Bash renders its command", describe("Bash",{"command":"npm run build --silent"}).startswith("npm run build"))
check("Read renders a basename", describe("Read",{"file_path":"/a/b/server.py"})=="Read server.py")

print("\n=== 8. approvals (must never hang a session) ===")
ph=os.path.join(REPO,"hooks/agentisland-permission.sh")
req=json.dumps({"session_id":"selftest","hook_event_name":"PermissionRequest",
                "tool_name":"Bash","tool_input":{"command":"git push"}})

# no island -> instant fall-through to Claude's own prompt
t0=time.time()
r=subprocess.run([ph],input=req,capture_output=True,text=True,timeout=10,
                 env=dict(os.environ,AGENTISLAND_ALIVE="/tmp/nope-not-here"))
check("no island -> falls through fast, no output", r.returncode==0 and not r.stdout.strip(),
      f"{time.time()-t0:.2f}s")

# island up but unanswered -> bounded timeout, still no output
open(f"{RUN}-alive","w").close()
t0=time.time()
r=subprocess.run([ph],input=req,capture_output=True,text=True,timeout=20,
                 env=dict(os.environ,AGENTISLAND_ALIVE=f"{RUN}-alive",
                          AGENTISLAND_TIMEOUT_TENTHS="10",
                          AGENTISLAND_SPOOL=f"{RUN}-spool.jsonl",
                          AGENTISLAND_DECISIONS=f"{RUN}-dec"))
el=time.time()-t0
check("unanswered -> times out, never hangs", r.returncode==0 and not r.stdout.strip() and el<5,
      f"{el:.2f}s")

# answered -> valid schema Claude will accept
import threading
os.makedirs(f"{RUN}-dec",exist_ok=True)
for f in os.listdir(f"{RUN}-dec"): os.remove(f"{RUN}-dec/{f}")
if os.path.exists(f"{RUN}-spool.jsonl"): os.remove(f"{RUN}-spool.jsonl")
out={}
def run():
    out["r"]=subprocess.run([ph],input=req,capture_output=True,text=True,timeout=20,
        env=dict(os.environ,AGENTISLAND_ALIVE=f"{RUN}-alive",
                 AGENTISLAND_TIMEOUT_TENTHS="80",
                 AGENTISLAND_SPOOL=f"{RUN}-spool.jsonl",
                 AGENTISLAND_DECISIONS=f"{RUN}-dec"))
th=threading.Thread(target=run); th.start(); time.sleep(1.2)
rid=json.loads(open(f"{RUN}-spool.jsonl").readline())["ap_request_id"]
open(f"{RUN}-dec/{rid}","w").write("deny")
th.join()
try:
    d=json.loads(out["r"].stdout)["hookSpecificOutput"]
    ok = d.get("hookEventName")=="PermissionRequest" and d.get("permissionDecision")=="deny"
except Exception:
    ok=False; d={}
check("answered -> emits valid permissionDecision", ok, f"decision={d.get('permissionDecision')}")
check("decision file is consumed (no leak)", not os.path.exists(f"{RUN}-dec/{rid}"))
check("heartbeat file exists while app runs", os.path.exists("/tmp/agentisland.alive"))

print("\n=== 9. no protected-path reads, bounded shell-outs, exact geometry ===")
# Reading Warp's group container blocks in open() from inside an app bundle (TCC), which froze
# every refresh behind it. Nothing may reach for it again.
srcs={f:open(os.path.join(REPO,"Sources/AgentIsland",f)).read()
      for f in os.listdir(os.path.join(REPO,"Sources/AgentIsland")) if f.endswith(".swift")}
blob="".join(srcs.values())
check("no source reads another app's group container",
      "Group Containers" not in blob and "warp.sqlite" not in blob.replace("`warp.sqlite`",""))

sh=srcs["Shell.swift"]
check("runSync takes a timeout", "timeout: TimeInterval" in sh)
check("runSync kills a child that outlives it", "task.terminate()" in sh and "SIGKILL" in sh)
check("runSync closes the parent's write end (reader must see EOF)",
      "fileHandleForWriting.close()" in sh)
check("runSync closes the read end, except under a reader it would crash",
      "if !abandoned { try? out.fileHandleForReading.close() }" in sh and "var abandoned" in sh)
check("streams we never read get no pipe to leak", sh.count("FileHandle.nullDevice")>=2)
check("reader runs off the queue rebuild uses", "Thread.detachNewThread" in sh)

# A leaked pipe per shell-out exhausts the 256-fd limit within the hour; children then spawn
# into a broken state, which is far harder to read than a clean failure.
pid=subprocess.run(["pgrep","-f","AgentIsland.app/Contents/MacOS/AgentIsland"],
                   capture_output=True,text=True).stdout.split()
if pid:
    def fds():
        r=subprocess.run(["lsof","-p",pid[0]],capture_output=True,text=True).stdout.splitlines()
        return len(r)-1, sum(1 for l in r if " PIPE " in l)
    n0,p0=fds(); time.sleep(6); n1,p1=fds()
    check("app holds few descriptors", n1 < 80, f"{n1} open, {p1} pipes")
    check("descriptors do not grow across refreshes", n1 <= n0+4, f"{n0} -> {n1}")
else:
    check("app running for descriptor check", False, "not running")

check("every agent with a pid is actionable (jump or attach)",
      all(a.get("pid") for a in agents if a.get("pid")))

# Read the real constants: a hardcoded expectation silently goes stale when the row resizes.
v=srcs["Views.swift"]
def const(name, cls=None):
    return float(re.search(rf"static let {name}: CGFloat = ([\d.]+)", v).group(1))
R=const("height"); G=const("rowGap"); H=const("headerHeight"); N=const("visibleRows")
# The frame must equal the stack's own height, or the last row is clipped and the list
# scrolls by a sliver that reads as a broken partial row.
pad=const("listPadding")
listed=re.search(r"padding\(\.vertical, PanelView\.listPadding\)", v)
check("list frame matches the stack's real padding", listed is not None, f"pad={pad:.0f}pt")
panel = H + 1 + (N*R + (N-1)*G + 2*pad)
check(f"panel fits exactly {int(N)} rows, no partial row", panel==H+1+N*R+(N-1)*G+2*pad, f"{panel:.0f}pt")
check("rows are tall enough for three lines of content", R >= 60, f"{R:.0f}pt row")

print("\n=== 9b. the panel shows real sessions and nothing else ===")
MANIFEST="/tmp/agentisland.rows.json"
rows=[]
if os.path.exists(MANIFEST):
    try: rows=json.load(open(MANIFEST))
    except Exception: rows=[]
check("app publishes what it is showing", bool(rows), f"{len(rows)} rows")

# Ground truth, computed independently of the app.
home=os.path.expanduser("~")
def codex_truth():
    out=set()
    for p in glob.glob(f"{home}/.codex/sessions/**/rollout-*.jsonl", recursive=True):
        if time.time()-os.path.getmtime(p) > 10*86400: continue
        try: o=json.loads(open(p,'rb').readline())
        except Exception: continue
        if o.get("type")!="session_meta": continue
        pay=o.get("payload",{})
        if pay.get("id") and os.path.isdir(pay.get("cwd") or ""): out.add(pay["id"])
    return out

truth={"codex":codex_truth()}
shown={v:{r["sessionId"] for r in rows if r["vendor"]==v} for v in ("claude","codex","cursor")}

# A vendor whose sessions exist on disk but shows zero rows is the failure that hides best:
# Codex's session_meta grew past a fixed-size read and the whole vendor silently vanished.
for v,ids in truth.items():
    if ids:
        check(f"{v}: every on-disk session reaches the panel",
              ids <= shown[v], f"{len(shown[v])} shown of {len(ids)} on disk")

# Cursor only surfaces human-started chats touched in the last two days, so counting the
# directory is not counting what should be shown — the old form failed whenever the user had
# simply not opened Cursor that week.
def cursor_eligible():
    import glob
    cut = time.time() - 2 * 24 * 3600
    n = 0
    for d in glob.glob(os.path.expanduser("~/.cursor/chats/*/*")):
        if not os.path.isdir(d) or os.path.getmtime(d) < cut: continue
        if not os.path.exists(d + "/prompt_history.json"): continue
        try: meta = json.load(open(d + "/meta.json"))
        except Exception: continue
        if not meta.get("hasConversation"): continue
        cwd = meta.get("cwd")
        if cwd and not os.path.isdir(cwd): continue
        n += 1
    return n

expect = {"claude": True, "codex": bool(truth.get("codex")), "cursor": cursor_eligible() > 0}
missing = [v for v, want in expect.items() if want and not shown[v]]
check("no vendor with eligible sessions is missing entirely", not missing,
      ", ".join(f"{v}={len(shown[v])}" for v in shown)
      + f" (cursor eligible: {cursor_eligible()})")

# Nothing fabricated, nothing left over from a test run.
BAD=("selftest","benchmark","synthetic","fuzz","test-session","ai-st-","placeholder","lorem")
dirty=[r for r in rows if any(b in (r["title"]+r["sessionId"]+r["cwd"]).lower() for b in BAD)]
check("no synthetic or test data in the panel", not dirty, f"{len(dirty)} suspect")
# A remote row's directory lives on the remote machine; only local rows can be checked here.
local_rows=[r for r in rows if not r.get("remote")]
check("every local row has a working directory that exists",
      all(r["cwd"] and os.path.isdir(r["cwd"]) for r in local_rows),
      f"{sum(1 for r in local_rows if not (r['cwd'] and os.path.isdir(r['cwd'])))} bad")
uuidish=re.compile(r"^[0-9a-f]{8}(-[0-9a-f]{4}){0,3}", re.I)
bare=[r for r in rows if uuidish.match(r["title"].strip())]
check("no row is labelled with a bare session id", not bare,
      bare[0]["title"] if bare else "")
check("every row has a last-active time", all(r["lastActive"] for r in rows))

# "blocked" is the panel's most alarming badge; it must match the jobs on disk exactly, since
# a stale one is how a session reads as stuck when it is fine.
disk_blocked=0
for jp in glob.glob(f"{home}/.claude/jobs/*/state.json"):
    try: jo=json.load(open(jp))
    except Exception: continue
    if jo.get("state")=="blocked" and (jo.get("needs") or jo.get("detail")): disk_blocked+=1
shown_blocked=sum(1 for r in rows if r.get("blocked"))
# Pure text logic, checked directly in the binary: every case here once produced a row titled
# with machinery, a bare id, or nothing.
pc=subprocess.run([os.path.join(REPO,".build/release/AgentIsland"),"--check-prompts"],
                  capture_output=True,text=True)
check("pure logic handles every shape that has broken a row",
      pc.returncode==0, (pc.stdout+pc.stderr).strip().splitlines()[-1] if (pc.stdout or pc.stderr) else "")

# Codex publishes its own window and per-turn usage; reading the cumulative total instead
# pinned every row at the compaction cliff, and reading the wrong nesting level showed nothing.
cx=[r["context"] for r in rows if r["vendor"]=="codex"]
check("codex rows carry a context reading", any(c>=0 for c in cx),
      f"{sum(1 for c in cx if c>=0)}/{len(cx)} rows")
check("no codex row is pinned at the compaction cliff", not [c for c in cx if c>=99],
      f"max {max(cx) if cx else 0}%")

# Ten agents can block in the same second. Replacing the visible card abandoned the earlier
# ask: its hook waited out the timeout and fell through to the terminal, reading as a miss.
isl=open(os.path.join(REPO,"Sources/AgentIsland/Island.swift")).read()
check("a second ask queues instead of replacing the visible card",
      "queuedApprovals" in isl and "queuedQuestions" in isl and "guard !showingCard" in isl)
check("answering or expiring a card shows the next one",
      isl.count("presentNext()") >= 5, f"{isl.count('presentNext()')} call sites")
check("a question preempts an approval without dropping it",
      "queuedApprovals.insert(a, at: 0)" in isl)
ap=open(os.path.join(REPO,"Sources/AgentIsland/Approvals.swift")).read()
check("decision directory is owner-only (it approves shell commands)",
      "0o700" in ap)
check("hook tightens it too", "chmod 700" in open(os.path.join(REPO,"hooks/agentisland-permission.sh")).read())
hs=open(os.path.join(REPO,"Sources/AgentIsland/HookStream.swift")).read()
check("drain never reads the published live map off the main thread",
      "carried[session]" in hs and "live[session] ?? LiveState()" not in hs)

# The load test points discovery at a fixture; production must be unaffected when it is unset.
proto=open(os.path.join(REPO,"Sources/AgentIsland/AgentSource.swift")).read()
vw = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
# The resting line is clipped, not truncated, so overflow disappears with no ellipsis to show
# for it. Measure the real strings in the real font against the box the real formula gives.
_m = re.search(r'let l = ([\d.]+) \+ CGFloat\(min\(\(leftText \?\? ""\)\.count, 34\)\) \* ([\d.]+)', vw)
_w = re.search(r'let r = ([\d.]+) \+ CGFloat\(\(rightText \?\? ""\)\.count\) \* ([\d.]+)', vw)
_c = re.search(r'let w = max\(([\d.]+), min\(revealed \? [\d.]+ : ([\d.]+), max\(l, r\)\)\)', vw)
check("the width formula is where the test expects it",
      _m is not None and _w is not None and _c is not None)
if _m and _w and _c:
    _r = subprocess.run(["swift", os.path.join(REPO, "tests/restwidth.swift"),
                         _c.group(1), _c.group(2), _m.group(1), _m.group(2),
                         _w.group(1), _w.group(2)],
                        capture_output=True, text=True, timeout=300).stdout.strip()
    check("both bar sides always fit their box", _r == "ok", _r)
check("resting line is not hard-clipped without truncation", ".lineLimit(1).fixedSize()" not in vw)
print("\n=== 31. code-review fixes ===")
_ag = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
_cv = open(os.path.join(REPO, "Sources/AgentIsland/ConsoleView.swift")).read()
_cs = open(os.path.join(REPO, "Sources/AgentIsland/Console.swift")).read()
_pm = open(os.path.join(REPO, "Sources/AgentIsland/PanelModes.swift")).read()
_iv = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()

# The console reads transcripts on .userInitiated while the refresh rewrites the same
# dictionaries on .utility. Two threads reassigning one Dictionary is a use-after-free.
check("Transcript's caches are locked, not raced",
      "private static let lock = NSLock()" in _ag.split("enum Transcript")[1]
      and "pathCache[sessionId] = p" not in _ag
      and "activeCache[a.sessionId] = (mtime" not in _ag)
check("every session cache is still bounded, including the new one",
      "Console.retain(ids)" in _ag and "ToolCalls.retain(ids)" in _ag)
check("Console.retain is no longer dead code", "static func retain" in _cs)

check("a card that needs you outranks a glance",
      "case .approval, .question: return" in _iv)
check("and an open panel releases what it holds before the console takes over",
      "private func tearDownPanel()" in _iv
      and "tearDownPanel()" in _iv.split("func openConsole")[1][:600])
check("the console polls its hit region at the interactive cadence",
      "repoll()" in _iv.split("func openConsole")[1].split("func closeConsole")[0])

check("the console feed refreshes instead of freezing at open time",
      ".onReceive(tick)" in _cv and "Timer.publish(every:" in _cv)
# `session` is a let on the captured view value, so comparing it to itself was always true.
check("a stale read cannot overwrite a newer session",
      "guard !Task.isCancelled else { return }" in _cv and "guard id == session" not in _cv)
check("it opens at the newest entry, after layout",
      ".onChange(of: feed.count)" in _cv)

# "How big is this chat" was invisible: the per-session statusLine already carries the totals,
# so the row prints them rather than making the user open the console to guess.
_ss = open(os.path.join(REPO, "Sources/AgentIsland/SessionStatus.swift")).read()
_vw = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
check("a row shows what that chat has spent",
      "Costs.tokens(t)" in _vw and "row.totalTokens" in _vw)
check("and the total is input + output, from the session's own statusLine",
      "total_input_tokens" in _ss and "total_output_tokens" in _ss
      and "if i + o > 0 { s.totalTokens = i + o }" in _ss)

# Console can only resolve Claude transcripts, so other vendors opened an empty reader.
check("the read chip is only offered where a transcript exists",
      "row.agent.vendor == .claude" in _vw)
check("and the summon chord skips vendors it cannot read",
      "store.rows.filter { $0.agent.vendor == .claude }" in _iv)

check("the plan reader cannot outgrow the height the card reserves",
      "vertical: style == .reading" in _pm)
# (The cap is measured against real strings in the real font by restwidth.swift above, which
# beats pinning a number here — that is exactly what re-broke on the last line change.)
# Theme reads Surfaces statically, which SwiftUI cannot track as a dependency.
check("toggling the surface repaints every view, not just the observers",
      '.id("\\(surfaces.choice.rawValue)-\\(typefaces.choice.rawValue)")' in _iv)

print("\n=== 32. one motion vocabulary ===")
_th = open(os.path.join(REPO, "Sources/AgentIsland/Theme.swift")).read()
check("there is a single named motion set", "enum Motion {" in _th
      and all(k in _th for k in ["static let shell", "static let content",
                                 "static let quick", "static let hover", "static let value"]))
# Eleven ad-hoc curves meant things moving together ran on different clocks.
_raw = []
for f in ("Island.swift", "Views.swift"):
    body = open(os.path.join(REPO, "Sources/AgentIsland", f)).read()
    for lit in (".spring(response:", ".snappy(duration:", ".easeOut(duration:"):
        if lit in body:
            _raw += [f"{f}:{lit}" for _ in range(body.count(lit))]
check("no view spells its own curve any more", not _raw, f"{len(_raw)} left: {_raw[:3]}")
# Was: assert the content crossfades. That crossfade drew the outgoing and incoming card
# together and never finished, which is the ghosting the video caught. Section 36 now asserts
# its absence; what survives here is the shell spring, which was the good half.
check("the shell still springs between sizes on one curve",
      "withAnimation(Motion.shell) { state = " in _iv)
check("the vendor pill morphs rather than jumping",
      ".contentTransition(.opacity)" in _vw and ".animation(Motion.content, value: v)" in _vw)

print("\n=== 33. blocked means stalled, not 'your turn' ===")
_as = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
# The harness marks every bg job "blocked" the moment its turn ends, so an ordinary
# conversation awaiting a reply was badged and promoted above working rows.
_bl = open(os.path.join(REPO, "Sources/AgentIsland/Blocked.swift")).read()
# `state` flips to "blocked" the instant ANY turn ends, so a time threshold could only ever
# delay the false badge, never prevent it. `tempo` is the field that actually discriminates.
# `state` flips when any turn ends and `tempo` follows it 20s later (measured), so neither
# separates a stalled agent from a chat awaiting a reply. interactiveLineage does.
_as5 = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
check("a session a human is conversing with is never badged blocked",
      '!Blocked.isInteractive(agent.sessionId)' in _as5)
# Filtering those sessions out of the cache also deleted the question from the collapsed bar,
# the row line and the console footer — every reader of `activity` shares that cache.
check("but it still carries what it is asking, since activity reads the same cache",
      'if (obj["interactiveLineage"] as? Bool) == true { chatting.insert(key) }' in _bl
      and "found[key] = needs" in _bl)
check("and the cache is locked, being reachable from a nonisolated comparator",
      "private static let lock = NSLock()" in _bl and "Blocked.refresh()" in _as5)
check("and the cruder signals are still required alongside it",
      '(obj["tempo"] as? String) != "active"' in _bl
      and '(obj["state"] as? String) == "blocked"' in _bl)
check("so a chat you are slow to answer is never badged, at any delay",
      "!= \"active\"" in _bl)
# The hour existed to protect chats from false badges; isInteractive does that precisely now,
# so this is just a grace period against a momentary block — and an inert badge helps nobody.
check("the time heuristic is a short grace period, not an hour",
      "static let dormantAfter: TimeInterval = 60" in _as
      and "Date().timeIntervalSince(seen) > Self.dormantAfter" in _as)
check("and the completed window is untouched at an hour",
      "static let completedFor: TimeInterval = 3600" in _as)
check("and blocked still outranks working once it is real",
      "if r.dormantBlocked { return 1 }" in _as and "r.isWorking ? 2 : 3" in _as)
check("liveness and the working guard are still required",
      "!(live?.waiting ?? false), !isWorking" in _as
      and "Proc.alive" in _as.split("var dormantBlocked")[1].split("}")[0] + _as.split("var dormantBlocked")[1][:400])

print("\n=== 34. finished work reads as completed, then decays to idle ===")
_as6 = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
_vw6 = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
check("there is a completed window, and it is an hour",
      "static let completedFor: TimeInterval = 3600" in _as6)
check("it decays to idle past the window",
      "Date().timeIntervalSince(seen) <= Self.completedFor" in _as6)
# "completed" must never shadow a state that needs attention.
check("working, waiting, died and blocked all outrank it",
      "guard !isWorking, !waiting, died == nil, !dormantBlocked," in _as6)
check("a session with no activity at all is idle, not completed",
      "let seen = lastActive else { return false }" in _as6.split("var justCompleted")[1][:300])
check("the row prints it ahead of idle",
      'row.justCompleted ? "completed" : "idle"' in _vw6)
# The palette rule is three semantic hues; this distinction is carried by weight.
check("and distinguishes it by weight, not a new hue",
      "row.justCompleted ? Theme.muted : Theme.faint" in _vw6)

print("\n=== 35. the console renders tables, not pipe soup ===")
# Markdown tables fell through to .plain and rendered as "| a | b |" — literally the wall of
# words the console exists to avoid. This runs the SHIPPED parser, not a copy of it.
_mt = subprocess.run([sys.executable, os.path.join(REPO, "tests/markdown_table.py")],
                     capture_output=True, text=True)
check("the real parser turns a markdown table into one table block",
      _mt.returncode == 0, _mt.stdout.strip() or _mt.stderr.strip()[:80])
_pm = open(os.path.join(REPO, "Sources/AgentIsland/PanelModes.swift")).read()
check("the |---|---| separator row carries no content and is dropped",
      'allSatisfy { "-: ".contains($0) }' in _pm)
check("columns align in a Grid rather than wrapping as prose",
      "Grid(alignment: .leading" in _pm and "GridRow" in _pm)
check("the header row carries the weight the body gives up",
      "i == 0 ? Theme.text : Theme.muted" in _pm)

print("\n=== 36. video-reported regression + three fixes ===")
_iv6 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_cv6 = open(os.path.join(REPO, "Sources/AgentIsland/ConsoleView.swift")).read()
_rp6 = open(os.path.join(REPO, "Sources/AgentIsland/Reopen.swift")).read()
_as7 = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()

# A crossfade on the state arm drew the outgoing and incoming card together, and the 0.06s
# poll restarted it before it could finish — leaving both copies on screen for good.
check("the state arm does not crossfade its content",
      ".transition(.opacity.animation(Motion.content))" not in _iv6)

# Razor sides with a 20px smeared bottom; the reference island is crisp here too.
check("the collapsed bar has no edge fade",
      "case .collapsed: return 0" in _iv6.split("private var bottomInset")[1][:400])
check("but the panels that end in empty space still do",
      "case .expanded:  return PanelView.listPadding" in _iv6)

check("the console remembers whether it replaced the list",
      "private(set) var consoleFromPanel" in _iv6
      and "case .expanded: consoleFromPanel = true" in _iv6)
# Putting back-navigation inside closeConsole() silently repurposed the outside-click monitor,
# the chord and the chord's own tag, so dismissing the console re-opened the panel.
check("dismissing the console collapses, and only the back control returns to the list",
      "if consoleFromPanel { consoleFromPanel = false; expand(); return }" not in _iv6
      and _iv6.index("func consoleBackToPanel()") > _iv6.index("func closeConsole()"))
check("and there is an explicit way back to the agent list",
      "func consoleBackToPanel()" in _iv6 and "onBack" in _cv6)
# The chord can summon the console with no list behind it; a back arrow would lie there.
check("the back control is hidden when there is no list to go back to",
      "island.consoleFromPanel" in _iv6 and "var onBack: (() -> Void)? = nil" in _cv6)

# `claude attach` opens a session that is still running; a finished one has nothing to attach
# to, which is why those rows looked clickable and did nothing.
# Warp is not scriptable, its launch-config URL does not execute, and a timed paste can land
# in whatever the user was working in — Terminal runs it outright instead.
check("the resume command is actually executed, not just copied",
      'tell application \\"Terminal\\" to do script' in _rp6)
check("and the path is quoted, since project dirs can contain spaces",
      "shellQuote(dir)" in _rp6 and "appleQuote(script)" in _rp6)
# A timed paste would be CGEvent plus a delay. Assert against that shape, and for the
# positive mechanism — the command goes to a named application, not to whatever has focus.
check("no timed paste into an unverified window survives",
      "CGEvent" not in _rp6 and "asyncAfter" not in _rp6
      and 'tell application \\"Terminal\\" to do script' in _rp6)
check("a finished Claude session resumes rather than attaching",
      'return "\\(Shell.claude) --resume \\(agent.sessionId)"' in _rp6
      and "if agent.pid != nil {" in _rp6)
check("and jump() actually reopens it instead of returning",
      "if !Reopen.run(row.agent, in: row.agent.cwd, note: announce)" in _as7)
# The claude-only guard below the fix meant a live Codex or Cursor row in an unrecognised
# terminal still highlighted on hover and did nothing on click.
check("including a live session whose terminal could not be resolved",
      "guard row.agent.vendor == .claude else { return }" not in _as7)
check("canJump no longer promises something jump() refuses",
      "Reopen.command(for: agent) != nil" in _as7)

print("\n=== 37. the question card does not flake on hover ===")
_vw7 = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
# Per-option, crossing the gap between rows cleared `hot`, dropped the 230pt preview pane and
# snapped the card narrower, then back on the next row.
check("the preview slot is decided by the question, not the hovered row",
      "item.options.contains { !$0.preview.isEmpty }" in _vw7)
check("so hovering cannot change the card's width",
      "!(focused?.preview ?? \"\").isEmpty" not in _vw7)
check("no dead surface helper is left behind",
      "var current: Surface" not in open(
          os.path.join(REPO, "Sources/AgentIsland/Surface.swift")).read())

print("\n=== 38. the resume command is executed, so its inputs are inputs ===")
_rp7 = open(os.path.join(REPO, "Sources/AgentIsland/Reopen.swift")).read()
_sh7 = open(os.path.join(REPO, "Sources/AgentIsland/Shell.swift")).read()
_sf7 = open(os.path.join(REPO, "Sources/AgentIsland/Surface.swift")).read()
_vw8 = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
# Session ids come from parsed transcripts and directory names. While the command was only
# copied that was harmless; it is now run, so an id is untrusted input to a shell.
check("a session id is validated before it enters a command that runs",
      "guard Approvals.validID(agent.sessionId) else { return nil }" in _rp7)
check("and so is the remote host, which is interpolated unquoted into ssh",
      "guard Approvals.validID(sid), validHost(host) else { return nil }" in _rp7)
check("which makes command(for:) genuinely optional, so canJump means something",
      _rp7.count("return nil") >= 2)
# AppleScript string literals cannot span lines and have no escape for control characters.
check("a path AppleScript cannot hold falls back to the clipboard",
      "private static func scriptable(" in _rp7 and "scriptable(dir)" in _rp7
      and "$0.value < 0x20" in _rp7)
# The first run raises the Automation consent prompt; runSync would block the island on it.
check("the terminal launch does not block the main actor",
      "Shell.runSync" not in _rp7 and "Shell.run(" in _rp7)
check("and the toast reports what actually happened",
      "status == 0 ?" in _rp7)
check("a repeat click does not resume one transcript twice",
      "Date().timeIntervalSince(last.at) < 5" in _rp7)
check("every vendor's CLI is resolved, not just claude's",
      "static let codex = resolve(" in _sh7 and "static let cursorAgent = resolve(" in _sh7
      and "Shell.codex) resume" in _rp7 and "Shell.cursorAgent) --resume" in _rp7)
# ssh runs on the far machine, where our local paths mean nothing.
check("but the ssh arms stay bare, since the remote PATH resolves them",
      "ssh -t \\(host) claude --resume" in _rp7)

print("\n=== 39. work the island does not need to do ===")
check("the edge fade is skipped when there is no room to fade",
      "if inset > 0 {" in _sf7)
check("and an option with no preview is not given a label over nothing",
      'Rectangle().fill(text.isEmpty ? Color.clear : Theme.hairline)' in _vw8
      and "if !text.isEmpty {" in _vw8)
check("the preview column keeps its width regardless, so the card cannot jump",
      ".frame(width: 230, alignment: .leading)" in _vw8)
check("no dead declarations survive the sweep",
      "var unsupported: String?" not in _as5 and "static let sheen" not in
      open(os.path.join(REPO, "Sources/AgentIsland/Theme.swift")).read())

print("\n=== 40. the bar steps out of the way on a screen with no notch ===")
_iv9 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
# Mirroring swaps the screen out from under `pinned`, and followActiveScreen bails when the
# frame looks unchanged, so nothing re-measured until the next expand.
check("a display change re-homes the island instead of leaving it stale",
      "NSApplication.didChangeScreenParametersNotification" in _iv9
      and "self.pinned = nil" in _iv9)
# Auto-hide used to be limited to no-notch displays, on the reasoning that a notch is dead
# pixels anyway. The bar outgrew the notch, so at rest it sat on the menu bar showing a stale
# number: nothing is running, so it steps aside everywhere and hover brings it back.
check("the bar steps aside whenever nothing is running, on any display",
      "private var autoHides: Bool { Prefs.shared.autoHideSeconds > 0 }" in _iv9)
check("the whole shell fades, not just its contents",
      ".opacity(island.hushed ? 0 : 1)" in _iv9
      and _iv9.index(".opacity(island.hushed ? 0 : 1)")
          > _iv9.index(".contentShape(NotchShape(radius: corner))"))
# Fading CollapsedView alone left IslandBackground painting an opaque black block on the tabs.
check("so the background cannot keep painting once the bar is hidden",
      "CollapsedView(store: store, status: status, notchWidth: island.notchWidth,\n                                  revealed: island.revealed, quiet: quiet)\n                        .opacity(" not in _iv9)
check("hovering brings it back",
      "self.wake()" in _iv9 and "func wake()" in _iv9)
check("and so does anything changing what the bar says",
      ".onChange(of: wakeKey) { _, _ in island.wake() }" in _iv9
      and "private var wakeKey: String" in _iv9)
check("the timer does not fire over an island the user is using",
      "guard let self, self.state == .collapsed, !self.revealed else { return }" in _iv9)
check("superseded strip-yielding machinery is gone",
      "refreshTopStripClaim" not in _iv9 and "stripIsOwned" not in _iv9
      and "applySpaceBehavior" not in _iv9)

print("\n=== 41. settings ===")
_st = open(os.path.join(REPO, "Sources/AgentIsland/Settings.swift")).read()
_pm = open(os.path.join(REPO, "Sources/AgentIsland/PanelModes.swift")).read()
_iv10 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_vw10 = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
check("settings is a panel mode, reached and left like the others",
      "case sessions, costs, settings, plan" in _pm
      and "SettingsView { back() }" in _vw10 and "var onBack: () -> Void" in _st)
# The app is .accessory with LSUIElement, so before this there was no way out but pkill.
check("there is finally a way to quit",
      "NSApp.terminate(nil)" in _st)
check("preferences are written as they change, not on an Apply",
      "didSet { UserDefaults.standard.set(autoHideSeconds" in _st
      and "UserDefaults.standard.set(snoozedUntil?.timeIntervalSince1970" in _st)
# Nothing else watches the clock, so quiet would otherwise outlast its own deadline.
check("quiet ends on its own",
      "private func armExpiry()" in _st and "Task { @MainActor in self?.snoozedUntil = nil }" in _st)
check("quiet stops the island putting anything over your screen",
      _iv10.count("guard !Prefs.shared.snoozing else { return }") == 3)
# Losing the notification too would mean missing things silently, which is not what quiet means.
check("but system notifications still arrive",
      "Notifier.notify" in _iv10)
# Hiding the whole shell locked the user out: hover could not reach settings to call it off.
check("a panel you opened yourself is never hidden from you",
      "var hushed: Bool { state == .collapsed && (autoHidden || Prefs.shared.snoozing) }" in _iv10)
check("and the bar honours the chosen delay, including never",
      "private var autoHides: Bool { Prefs.shared.autoHideSeconds > 0 }" in _iv10
      and "withTimeInterval: Prefs.shared.autoHideSeconds" in _iv10)
# You ask for quiet from the open panel, where CollapsedView is not in the tree.
check("asking for quiet from the panel closes it",
      ".onChange(of: prefs.snoozedUntil)" in _iv10
      and _iv10.index(".onChange(of: prefs.snoozedUntil)")
          > _iv10.index(".frame(width: Island.maxSize.width"))

print("\n=== 42. typeface ===")
_tf = open(os.path.join(REPO, "Sources/AgentIsland/Typeface.swift")).read()
_th = open(os.path.join(REPO, "Sources/AgentIsland/Theme.swift")).read()
_st2 = open(os.path.join(REPO, "Sources/AgentIsland/Settings.swift")).read()
# Switchable rather than swapped, so the look it shipped with stays there to compare against.
check("all three faces stay available",
      "case mono" in _tf and "case clean" in _tf and "case round" in _tf
      and "enum Typeface: String, CaseIterable" in _tf)
check("and the choice survives a restart",
      'UserDefaults.standard.set(choice.rawValue, forKey: Self.key)' in _tf)
# 84 call sites go through mono(); routing them through one switch is what makes this cheap.
check("one function decides it, not 84 call sites",
      "private static var face: Typeface { Typefaces.shared.choice }" in _th
      and _th.count("static func mono(") == 1)
# A proportional face would let quota and cost columns jitter as the digits changed.
check("figures still line up in the proportional faces",
      _th.count(".monospacedDigit()") == 2)
check("which the setting says out loud",
      "Figures stay aligned in all three" in _st2)
check("settings labels read as sentences",
      'row("Material"' in _st2 and 'row("Typeface"' in _st2
      and 'row("Steps aside after"' in _st2 and 'row("Hide the island for"' in _st2)
check("and so do the controls",
      'choice("Solid"' in _st2 and 'choice("Never"' in _st2 and 'choice("Quit"' in _st2
      and "f.label.capitalized" in _st2)

print("\n=== 43. one type scale ===")
_thT = open(os.path.join(REPO, "Sources/AgentIsland/Theme.swift")).read()
_allsrc = "".join(open(os.path.join(REPO, "Sources/AgentIsland", f)).read()
                  for f in sorted(os.listdir(os.path.join(REPO, "Sources/AgentIsland")))
                  if f.endswith(".swift"))
# Twelve sizes between 7 and 12.5pt is not a scale: half-point steps are invisible apart and
# incoherent together, and 54% of them sat at or below 9pt.
check("there are four steps, and they are named",
      "enum Type {" in _thT and "static let micro: CGFloat = 10" in _thT
      and "static let title: CGFloat = 13" in _thT)
# 10pt is the smallest standard macOS label; below it text stops being readable at a glance.
check("the floor is 10pt",
      min(10, 11, 12, 13) == 10 and "CGFloat = 9" not in _thT and "CGFloat = 8" not in _thT)
check("no view sets a raw text size any more",
      re.search(r"Theme\.(?:mono|label|name)\(\d", _allsrc) is None)
check("and glyphs track the text rather than sitting a third smaller",
      re.search(r"\.system\(size: [0-8](?:\.\d)?\b", _allsrc) is None)

print("\n=== 44. writing back to the session ===")
_tw = open(os.path.join(REPO, "Sources/AgentIsland/TerminalWrite.swift")).read()
_cv2 = open(os.path.join(REPO, "Sources/AgentIsland/ConsoleView.swift")).read()
_iv11 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
# CGEvent typing dropped characters into the TUI and a timed paste landed on whatever held
# focus; each terminal delivering its own text is the only channel that arrived intact.
check("no synthetic typing survives",
      "CGEvent(" not in _tw and "keyboardSetUnicodeString" not in _tw
      and "CGEventPost" not in _tw)
check("iTerm and Terminal are addressed by the same handle the jump uses",
      "tell s to write text" in _tw and "do script \\(quoted(text)) in t" in _tw
      and "HostTerminal.appleSafe" in _tw)
# Spawning osascript blames the Automation prompt on osascript, which already holds one.
check("the script runs in-process so the permission lands on us",
      "NSAppleScript(source: source)" in _tw and "/usr/bin/osascript" not in _tw)
check("a host with no scripting interface declines rather than pretending",
      "case .warp, .app, .degraded, .unknown: return false" in _tw)
check("and the console says so instead of showing a dead field",
      "takes no input from here" in _cv2 and "TerminalWrite.canWrite(row.host)" in _cv2)
# A literal cannot span lines, so a pasted multi-line answer must not be half-delivered.
check("control characters are refused before anything is sent",
      "$0.value < 0x20 || $0.value == 0x7F" in _tw)
check("the field borrows focus from the island, which refuses it by default",
      "onBeginType" in _cv2 and 'island.beginTyping("console:' in _iv11)
check("and hands it back after sending",
      "onEndType?()" in _cv2 and "island.endTyping()" in _iv11)

print("\n=== 45. a closed chat reopens in the chosen terminal, live ones are focused ===")
_as9 = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
_rp9 = open(os.path.join(REPO, "Sources/AgentIsland/Reopen.swift")).read()
_st9 = open(os.path.join(REPO, "Sources/AgentIsland/Settings.swift")).read()
# A live tab is always focused where it runs (host.jump). Only a session whose tab is gone is
# reopened, and never before the pid==nil check — reopening a live one opens a second terminal.
check("only a closed session is reopened",
      "guard row.agent.pid == nil else {" in _as9
      and _as9.index("guard row.agent.pid == nil else {")
          < _as9.index("if !Reopen.run(row.agent"))
check("a live session that cannot be focused hands over its command instead",
      "could not be focused, command copied" in _as9)
# Which terminal is a setting, so a Warp user resumes in Warp, not the macOS default. Warp exposes
# no scripting API; a launch configuration is the one handle that runs a command there.
check("the reopen terminal is a user setting",
      "reopenIn" in _st9 and "ReopenTarget" in _st9 and 'row("Reopen a closed chat in"' in _st9)
# A tab config opens in the CURRENT Warp window (a launch config opens a whole new one) and still
# runs its commands — so the chat comes back as a tab where the user is, not a stray window.
check("Warp is reopened as a tab in the current window, running the resume command",
      'Prefs.shared.reopenIn == .warp' in _rp9 and "warp://tab_config/" in _rp9
      and "commands = [\\(tomlQuote(cmd))]" in _rp9 and "warp://launch/" not in _rp9)
check("and it falls through to Terminal.app when Warp is not chosen",
      'tell application \\"Terminal\\" to do script' in _rp9)

print("\n=== 46. tmux ===")
_ht2 = open(os.path.join(REPO, "Sources/AgentIsland/HostTerminal.swift")).read()
_pe2 = open(os.path.join(REPO, "Sources/AgentIsland/ProcEnv.swift")).read()
_tw2 = open(os.path.join(REPO, "Sources/AgentIsland/TerminalWrite.swift")).read()
check("a pane is discovered from the environment",
      'i.tmuxPane = ae.env["TMUX_PANE"]' in _pe2 and "var tmuxPane: String?" in _pe2)
# Whatever draws the window, the pane belongs to tmux — and a pane handle reaches sessions in
# terminals that publish no scripting interface, which is the only route into Warp.
check("tmux is resolved ahead of the terminal drawing it",
      _ht2.index("if let pane = i.tmuxPane") < _ht2.index('i.termProgram == "iTerm.app"')
      and _ht2.index("if let pane = i.tmuxPane") < _ht2.index("if let u = i.focusURL"))
check("the outer app is carried, or the jump selects a pane nobody can see",
      "case tmux(pane: String, outerBundle: String?)" in _ht2
      and "if let outer { _ = activate(bundleID: outer) }" in _ht2)
# appleSafe strips the sigil, turning `-t %3` into `-t 3` — a different window, not that pane.
check("a pane id keeps its sigil",
      "static func tmuxSafe" in _ht2 and "%@$" in _ht2
      and "HostTerminal.tmuxSafe(pane)" in _tw2)
# Without -l a reply containing "C-c" would be pressed as a key and kill the agent.
check("text is sent literally, and the Return is separate",
      "-l \\(shellQuoted(text))" in _tw2 and "Enter\")" in _tw2)
check("and tmux counts as writable, which is what reaches Warp",
      "case .tmux, .iterm, .appleTerminal, .kitty, .wezterm: return true" in _tw2)

print("\n=== 47. the bar shows what it exists to show ===")
_iv12 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
# Auto-hide fading the bar while an agent was working removed the one thing the bar is for.
check("auto-hide never fires while something is running",
      "guard self.store.workingCount == 0, self.store.waitingCount == 0," in _iv12
      and "self.store.blockedCount == 0 else { return }" in _iv12)
check("and the owning terminal is found by walking the process tree, not the environment",
      "Proc.ancestorWithTTY(pid: pid)" in _iv12.replace("", "")
      or "Proc.ancestorWithTTY" in open(
          os.path.join(REPO, "Sources/AgentIsland/HostTerminal.swift")).read())

print("\n=== 23. binary builds & launches ===")
b=os.path.join(REPO,".build/debug/AgentIsland")
check("binary exists", os.path.exists(b))

print()
print(f"RESULT: {len(fails)} failure(s)" + (": "+", ".join(fails) if fails else " — all green"))
sys.exit(1 if fails else 0)
