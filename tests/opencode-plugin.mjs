// Drives hooks/agentisland-opencode.js the way OpenCode does, with the island's own binary
// answering. NOT run on its own: tests/selftest.py sets the env and reads the JSON it prints.
import { execFileSync } from "node:child_process"
import { readFileSync, writeFileSync } from "node:fs"

const { AgentIsland } = await import(process.env.PLUGIN)
const calls = []
const client = { postSessionIdPermissionsPermissionId: async (o) => { calls.push(o) } }
const h = await AgentIsland({ client, directory: "/w" })
const spool = () => readFileSync(process.env.AGENTISLAND_SPOOL, "utf8").trim().split("\n").map(JSON.parse)
const wait = async (ok) => { for (let i = 0; i < 50 && !ok(); i++) await new Promise((r) => setTimeout(r, 100)) }

writeFileSync(process.env.AGENTISLAND_ALIVE, "")
await h.event({ event: { type: "session.status", properties: { sessionID: "ses_1", status: { type: "busy" } } } })
await h["tool.execute.before"]({ tool: "edit", sessionID: "ses_1", callID: "c1" }, { args: { filePath: "/w/a.ts" } })
await h.event({ event: { type: "permission.asked", properties: {
  id: "per_1", sessionID: "ses_1", permission: "bash", patterns: ["git push *"],
  metadata: { command: "git push --force" }, always: [] } } })
await wait(() => spool().some((l) => l.ap_request_id))
const req = spool().find((l) => l.ap_request_id)
if (req) execFileSync(process.env.BIN, ["--decide", req.ap_request_id, "allow"])
await wait(() => calls.length > 0)
await h.event({ event: { type: "session.status", properties: { sessionID: "ses_1", status: { type: "idle" } } } })
console.log(JSON.stringify({ calls, spool: spool() }))
process.exit(0)
