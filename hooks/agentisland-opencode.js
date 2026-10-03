// AgentIsland bridge for OpenCode: mirrors session events into the island's spool, and puts
// permission asks on the notch, answering through OpenCode's own server. Every failure is silent.
import { appendFileSync, existsSync, lstatSync, mkdirSync, readFileSync, statSync, unlinkSync } from "node:fs"

const SPOOL = process.env.AGENTISLAND_SPOOL || "/tmp/agentisland-events.jsonl"
const DECISIONS = process.env.AGENTISLAND_DECISIONS || "/tmp/agentisland-decisions"
const ALIVE = process.env.AGENTISLAND_ALIVE || "/tmp/agentisland.alive"

function write(line) {
  try { appendFileSync(SPOOL, JSON.stringify(line) + "\n", { mode: 0o600 }) } catch {}
}
// ai_ppid is this process: the island walks up from it, and opencode itself is the first hop.
const emit = (payload) => write({ ai_ppid: process.pid, ai_ts: Math.floor(Date.now() / 1000), payload })

// The island's vocabulary is Claude's: capitalised tools, snake_case file paths.
function tool(name, args = {}) {
  const input = { ...args }
  if (input.filePath && !input.file_path) input.file_path = input.filePath
  return { tool_name: name ? name[0].toUpperCase() + name.slice(1) : "tool", tool_input: input }
}

const owned = (p) => { try { const s = lstatSync(p); return !s.isSymbolicLink() && s.uid === process.getuid() } catch { return false } }
const fresh = () => { try { return Date.now() - statSync(ALIVE).mtimeMs < 15000 } catch { return false } }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export const AgentIsland = async ({ client, directory }) => {
  const replied = new Set()
  const base = (sid, event) => ({ session_id: sid, hook_event_name: event, cwd: directory })

  // Same contract as agentisland-permission.sh: 20s, or 5 min once the reader engages.
  async function ask(p) {
    const req = p.permission === "bash" ? tool("bash", { command: p.metadata?.command ?? (p.patterns || []).join(" && ") })
      : p.permission === "edit" ? tool("edit", { file_path: p.metadata?.filepath ?? (p.patterns || [])[0] })
      : tool(p.permission, { patterns: p.patterns })
    emit({ ...base(p.sessionID, "Notification"), notification_type: "permission_prompt",
           message: `${req.tool_name} needs your permission` })
    if (!fresh()) return
    if (!existsSync(DECISIONS)) mkdirSync(DECISIONS, { recursive: true, mode: 0o700 })
    if (!owned(DECISIONS)) return   // one somebody else made is one they can plant an "allow" in
    const id = `ap-${process.pid}-${Date.now()}`
    const file = `${DECISIONS}/${id}`
    // agentisland-permission.sh's exact shape: an ai_ppid wrapper would hide the request id.
    write({ ap_request_id: id, payload: { ...base(p.sessionID, "PermissionRequest"), ...req } })
    for (let t = 0; t < 3000 && !replied.has(p.id); t++) {
      if (t >= 200 && !existsSync(file + ".touched")) break
      if (existsSync(file + ".skip")) break
      if (existsSync(file) && owned(file)) {
        const decision = readFileSync(file, "utf8").trim()
        try { unlinkSync(file) } catch {}
        if (decision !== "allow" && decision !== "deny") break
        await client.postSessionIdPermissionsPermissionId({
          path: { id: p.sessionID, permissionID: p.id },
          body: { response: decision === "allow" ? "once" : "reject" },
        }).catch(() => {})
        break
      }
      await sleep(100)
    }
    for (const f of [file + ".touched", file + ".skip"]) try { unlinkSync(f) } catch {}
  }

  return {
    event: async ({ event }) => {
      const p = event.properties || {}
      switch (event.type) {
        case "session.status":
          if (p.status?.type === "busy") emit(base(p.sessionID, "UserPromptSubmit"))
          if (p.status?.type === "idle") emit(base(p.sessionID, "Stop"))
          break
        case "permission.asked":
          ask(p).catch(() => {})
          break
        case "permission.replied":
          replied.add(p.requestID)
          emit(base(p.sessionID, "PostToolUse"))
          break
      }
    },
    "tool.execute.before": async (input, output) => {
      emit({ ...base(input.sessionID, "PreToolUse"), ...tool(input.tool, output.args) })
    },
    "tool.execute.after": async (input) => {
      emit({ ...base(input.sessionID, "PostToolUse"), ...tool(input.tool, input.args) })
    },
  }
}
