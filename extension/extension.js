// AgentIsland opens <scheme>://agentisland.ide-focus/focus?pid=<agent and its ancestors>.
// The window owning a terminal whose shell is one of those pids shows that terminal.
const vscode = require("vscode");
const fs = require("fs");
const path = require("path");

const LOG = "/tmp/agentisland-ide.log";
const BUS = "/tmp/agentisland-ide";

function log(msg) {
  try {
    fs.appendFileSync(LOG, `${new Date().toISOString()} ${vscode.env.uriScheme} ${msg}\n`);
  } catch (_) {}
}

async function focus(pids, via) {
  for (const t of vscode.window.terminals) {
    const p = await t.processId;
    if (p && pids.includes(p)) {
      t.show(false);
      log(`focus pid=${p} -> shown "${t.name}" via ${via} in ${vscode.workspace.name || "no folder"}`);
      return true;
    }
  }
  return false;
}

function activate(context) {
  const bus = path.join(BUS, `${vscode.env.uriScheme}.json`);
  try { fs.mkdirSync(BUS, { recursive: true }); } catch (_) {}

  context.subscriptions.push(vscode.window.registerUriHandler({
    async handleUri(uri) {
      const pids = (new URLSearchParams(uri.query).get("pid") || "")
        .split(",").map(Number).filter((n) => n > 1);
      if (!pids.length || (await focus(pids, "uri"))) return;
      // The editor delivers a URI to its last-active window only, so pass it to the others.
      log(`pid=${pids.join(",")} not in ${vscode.workspace.name || "no folder"}, asking other windows`);
      fs.writeFileSync(bus, JSON.stringify({ pids, at: Date.now() }));
    },
  }));

  let seen = 0;
  try {
    const w = fs.watch(BUS, async (_e, name) => {
      if (name !== path.basename(bus)) return;
      let req;
      try { req = JSON.parse(fs.readFileSync(bus, "utf8")); } catch (_) { return; }
      if (req.at <= seen || Date.now() - req.at > 5000) return;
      seen = req.at;
      // The receiving window raises itself once its handler returns; raise ours after that.
      // ponytail: Cursor has no focusWindow command, so there the tab is selected but not raised.
      if (await focus(req.pids, "broadcast")) {
        setTimeout(() => vscode.commands.executeCommand("workbench.action.focusWindow")
          .then(undefined, () => {}), 300);
      }
    });
    context.subscriptions.push({ dispose: () => w.close() });
  } catch (e) {
    log(`cannot watch ${BUS}: ${e.message}`);
  }
}

module.exports = { activate, deactivate() {} };
