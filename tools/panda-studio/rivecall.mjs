// Call one Rive MCP tool over HTTP: node rivecall.mjs <tool> <args.json | @file-to-upload>
import fs from "fs"; import path from "path";
const U = "http://127.0.0.1:9791/mcp";
const H = { "content-type": "application/json", accept: "application/json, text/event-stream" };
async function call(body, sid) {
  const r = await fetch(U, { method: "POST", headers: sid ? { ...H, "mcp-session-id": sid } : H, body: JSON.stringify(body) });
  const t = await r.text(); const m = t.match(/data: (.*)/g);
  return { sid: r.headers.get("mcp-session-id"), json: m ? JSON.parse(m[m.length - 1].slice(6)) : (t ? JSON.parse(t) : null) };
}
const [tool, arg] = process.argv.slice(2);
let args;
if (arg.startsWith("@")) {
  const f = arg.slice(1);
  const mt = f.endsWith(".svg") ? "image/svg+xml" : "application/octet-stream";
  args = { file: `data:${mt};name=${encodeURIComponent(path.basename(f))};base64,${fs.readFileSync(f).toString("base64")}` };
  if (process.argv[4]) args.name = process.argv[4];
} else args = JSON.parse(arg);
const a = await call({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "rivecall", version: "1" } } });
await fetch(U, { method: "POST", headers: { ...H, "mcp-session-id": a.sid }, body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) });
const b = await call({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: tool, arguments: args } }, a.sid);
console.log(JSON.stringify(b.json?.result ?? b.json).slice(0, 2000));
