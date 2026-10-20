// Export the open Rive document via the MCP HTTP endpoint and write it to disk (never prints the bytes).
import fs from "fs";
const [format, dest] = process.argv.slice(2);
const U = "http://127.0.0.1:9791/mcp";
const H = { "content-type": "application/json", accept: "application/json, text/event-stream" };
async function call(body, sid) {
  const r = await fetch(U, { method: "POST", headers: sid ? { ...H, "mcp-session-id": sid } : H, body: JSON.stringify(body) });
  const t = await r.text(); const m = t.match(/data: (.*)/g);
  return { sid: r.headers.get("mcp-session-id"), json: m ? JSON.parse(m[m.length - 1].slice(6)) : JSON.parse(t) };
}
const a = await call({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "riveexport", version: "1" } } });
await fetch(U, { method: "POST", headers: { ...H, "mcp-session-id": a.sid }, body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) });
const b = await call({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "export_file", arguments: { format, destination: dest, embed_assets: false, inline_base64: true } } }, a.sid);
const p = JSON.parse(b.json.result.content[0].text);
if (!p.data) { console.log(JSON.stringify(p).slice(0, 300)); process.exit(1); }
const out = dest + "/" + p.filename; fs.writeFileSync(out, Buffer.from(p.data, "base64")); console.log(out, fs.statSync(out).size);
