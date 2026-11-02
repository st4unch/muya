// Real-app load test: the debug build on a throwaway HOME, N sessions opened through
// the MCP broker, each running a stand-in `claude` that streams output. Measures the
// app's CPU/memory and broker latency while they stream.
//
//   node scripts/loadtest/app.mjs [--sessions 8] [--bps 64000] [--seconds 20]
//
// Needs the dev server on :1420 (`npm run dev`) and `cargo build` done. Only the debug
// process this script starts is stopped; an installed Muya.app is never touched.
import { spawn, execFileSync } from "node:child_process";
import { copyFileSync, chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createConnection } from "node:net";
import { fileURLToPath } from "node:url";
import { startSampler, pct } from "./sample.mjs";

const root = fileURLToPath(new URL("../..", import.meta.url));
const arg = (name, def) => {
  const i = process.argv.indexOf(`--${name}`);
  return i < 0 ? def : process.argv[i + 1];
};
const N = Number(arg("sessions", 8));
const BPS = Number(arg("bps", 64000));
const SECONDS = Number(arg("seconds", 20));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const bin = join(root, arg("bin", "src-tauri/target/debug/muya"));
if (!existsSync(bin)) throw new Error("no debug build — run `cargo build` in src-tauri first");

function psRows() {
  return execFileSync("ps", ["-axo", "pid=,command="], { encoding: "utf8" })
    .split("\n")
    .map((l) => l.trim().match(/^(\d+)\s+(.*)$/))
    .filter(Boolean)
    .map((m) => ({ pid: Number(m[1]), cmd: m[2] }));
}
function descendants(root) {
  const rows = execFileSync("ps", ["-axo", "pid=,ppid="], { encoding: "utf8" })
    .split("\n")
    .map((l) => l.trim().split(/\s+/).map(Number))
    .filter((r) => r.length === 2);
  const out = [];
  const walk = (p) => rows.filter(([, pp]) => pp === p).forEach(([c]) => (out.push(c), walk(c)));
  walk(root);
  return out;
}
const installedMuya = () => psRows().filter((r) => r.cmd.endsWith("Muya.app/Contents/MacOS/muya")).map((r) => r.pid);
const webContent = () => new Set(psRows().filter((r) => r.cmd.includes("com.apple.WebKit.WebContent")).map((r) => r.pid));

// Throwaway HOME with the stand-in claude first on PATH (also for login shells).
const home = mkdtempSync(join(tmpdir(), "muya-loadtest-"));
const fakeBin = join(home, ".local/bin");
mkdirSync(fakeBin, { recursive: true });
mkdirSync(join(home, ".claude"), { recursive: true });
copyFileSync(join(root, "scripts/loadtest/fake-claude.sh"), join(fakeBin, "claude"));
chmodSync(join(fakeBin, "claude"), 0o755);
const PATH = `${fakeBin}:/usr/bin:/bin:/usr/sbin:/sbin`;
// Login shells run /etc/zprofile (path_helper) after .zshenv and reorder PATH, which
// put an installed claude first — so set it again in .zprofile and .zshrc.
for (const f of [".zshenv", ".zprofile", ".zshrc"]) writeFileSync(join(home, f), `export PATH="${PATH}"\n`);
const sock = join(home, ".claude/muya-ssh-broker.sock");

function broker(req) {
  return new Promise((ok, fail) => {
    const t0 = performance.now();
    const c = createConnection(sock);
    let buf = "";
    c.on("data", (d) => {
      buf += d;
      const nl = buf.indexOf("\n");
      if (nl >= 0) {
        c.end();
        ok({ ms: performance.now() - t0, resp: JSON.parse(buf.slice(0, nl)) });
      }
    });
    c.on("error", fail);
    c.write(JSON.stringify(req) + "\n");
  });
}

const hostBefore = installedMuya();
const wcBefore = webContent();
const app = spawn(bin, [], {
  cwd: home,
  env: { HOME: home, PATH, SHELL: "/bin/zsh", USER: process.env.USER, LOADTEST_BPS: String(BPS), TMPDIR: tmpdir() },
  stdio: ["ignore", "ignore", "ignore"],
});
const ourWc = new Set();
const isOurs = (cmd, pid) => pid === app.pid || ourWc.has(pid);
const report = {};

try {
  for (let i = 0; i < 120 && !existsSync(sock); i++) await sleep(500);
  if (!existsSync(sock)) throw new Error("broker socket never appeared — is the dev server on :1420 running?");
  await sleep(8000); // let the window and webview settle
  for (const pid of webContent()) if (!wcBefore.has(pid)) ourWc.add(pid);

  report.webContentProcs = ourWc.size;
  let s = startSampler(isOurs);
  await sleep(10_000);
  report.idle = s.stop();

  const opened = [];
  for (let i = 0; i < N; i++) {
    const r = await broker({ op: "open_session", name: `load-${i + 1}`, cwd: home });
    if (r.resp.ok) opened.push(r.resp.name);
    await sleep(300);
  }
  await sleep(5000);
  const floods = psRows().filter((r) => r.cmd.includes("muya-loadtest-flood")).length;
  report.sessions = { asked: N, opened: opened.length, streaming: floods, bpsEach: BPS };
  // Anything but the stand-in would be a real claude running on a throwaway HOME.
  if (floods < opened.length) {
    const seen = execFileSync("ps", ["-o", "comm=", "-p", descendants(app.pid).join(",") || "0"], { encoding: "utf8" });
    throw new Error(`only ${floods}/${opened.length} sessions run the stand-in claude — aborting. Started: ${seen.split("\n").filter(Boolean).join(", ")}`);
  }
  for (const pid of webContent()) if (!wcBefore.has(pid)) ourWc.add(pid);

  s = startSampler(isOurs);
  const sMuya = startSampler((cmd, pid) => pid === app.pid);
  const sWeb = startSampler((cmd, pid) => ourWc.has(pid));
  // --sample <file>: macOS call-stack profile of the app for 5 s under load.
  const sampleOut = arg("sample");
  const sampler5 = sampleOut ? spawn("/usr/bin/sample", [String(app.pid), "5", "-file", sampleOut], { stdio: "ignore" }) : null;
  const lat = { list_sessions: [], read_session: [] };
  const until = performance.now() + SECONDS * 1000;
  for (let k = 0; performance.now() < until; k++) {
    const op = k % 2 ? "read_session" : "list_sessions";
    const r = await broker(op === "read_session" ? { op, target: opened[k % opened.length] ?? "load-1", limit: 20 } : { op });
    lat[op].push(r.ms);
    await sleep(200);
  }
  report.load = s.stop();
  if (sampler5 && sampler5.exitCode === null) await new Promise((r) => sampler5.on("exit", r));
  report.loadMuyaOnly = sMuya.stop();
  report.loadWebContentOnly = sWeb.stop();
  report.broker = Object.fromEntries(
    Object.entries(lat).map(([k, v]) => [k, { n: v.length, p50: +pct(v, 50).toFixed(1), p95: +pct(v, 95).toFixed(1), max: +Math.max(...v).toFixed(1) }]),
  );
  for (const name of opened) await broker({ op: "close_session", target: name }).catch(() => {});
} finally {
  // Everything the debug app started (shells, stand-in claudes), then the app itself.
  const kids = descendants(app.pid);
  for (const pid of kids) {
    try {
      process.kill(pid, "SIGKILL");
    } catch {}
  }
  app.kill("SIGTERM");
  await sleep(2000);
  if (app.exitCode === null) app.kill("SIGKILL");
  await sleep(500);
  const leftovers = psRows().filter((r) => r.pid === app.pid || kids.includes(r.pid)).length;
  const hostAfter = installedMuya();
  report.cleanup = {
    leftovers,
    installedMuyaUntouched: JSON.stringify(hostBefore) === JSON.stringify(hostAfter),
  };
  rmSync(home, { recursive: true, force: true });
}

const fmt = (x) => ({ cpuAvg: +x.cpuAvg.toFixed(0), cpuMax: +x.cpuMax.toFixed(0), rssMaxMb: +x.rssMaxMb.toFixed(0) });
console.log(JSON.stringify({ ...report, idle: fmt(report.idle), load: fmt(report.load), loadMuyaOnly: fmt(report.loadMuyaOnly), loadWebContentOnly: fmt(report.loadWebContentOnly) }, null, 2));
const out = arg("json");
if (out) writeFileSync(out, JSON.stringify(report, null, 2));
