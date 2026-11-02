// UI load test: headless WebKit (the engine Muya renders with) on the mock app, with
// every terminal streaming Claude-like output. Prints frame times, input latency,
// switch latency and WebKit CPU/RSS per scenario.
//
//   node scripts/loadtest/ui.mjs                 # build the mock bundle, run all scenarios
//   node scripts/loadtest/ui.mjs --dev           # use the running dev server (:1420)
//   node scripts/loadtest/ui.mjs --sessions 13 --scenario heavy --seconds 10 --json out.json
import { spawn, execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { webkit, chromium } from "playwright";
import { startSampler, pct } from "./sample.mjs";

const root = fileURLToPath(new URL("../..", import.meta.url));
const arg = (name, def) => {
  const i = process.argv.indexOf(`--${name}`);
  return i < 0 ? def : process.argv[i + 1];
};
const DEV = process.argv.includes("--dev");
// --browser chromium: the same page in Chromium (Electron / CEF engine), for comparison.
const ENGINE = arg("browser", "webkit") === "chromium" ? chromium : webkit;
const SECONDS = Number(arg("seconds", 10));
const SESSIONS = arg("sessions", "7,13,25").split(",").map(Number);
// Bytes per second: [the visible terminal, every other terminal].
const SCENARIOS = {
  idle: [0, 0],
  normal: [8_000, 8_000],
  heavy: [1_000_000, 64_000],
};
const PICK = arg("scenario", Object.keys(SCENARIOS).join(",")).split(",");

async function serve() {
  if (DEV) return { url: "http://localhost:1420/", stop() {} };
  const cfg = "scripts/loadtest/vite.loadtest.config.mjs";
  console.log("building the mock bundle…");
  execFileSync("npx", ["vite", "build", "--config", cfg, "--logLevel", "error"], { cwd: root, stdio: "inherit" });
  const p = spawn("npx", ["vite", "preview", "--config", cfg], { cwd: root, stdio: ["ignore", "pipe", "inherit"] });
  await new Promise((ok, fail) => {
    p.stdout.on("data", (d) => String(d).includes("1431") && ok());
    p.on("exit", (c) => fail(new Error(`vite preview exited ${c}`)));
  });
  return { url: "http://localhost:1431/", stop: () => p.kill() };
}

// Runs inside the page: streams output, records frames, measures input and switches.
async function runInPage({ seconds, visibleBps, otherBps }) {
  const start = performance.now();
  const mock = window.__muyaMock;
  const ids = mock.ptyIds();
  // The terminal the operator is looking at: the visible xterm's pty is the newest one
  // fed for the selected tab; mock.feed returns it.
  const visibleId = mock.feed("muya-all", [""]);
  let seq = 0;
  const line = () => {
    const i = seq++;
    return i % 7 === 0
      ? `\r\x1b[2K\x1b[38;5;214m✻\x1b[0m Thinking… \x1b[2m(${i}s · esc to interrupt)\x1b[0m`
      : `\r\n\x1b[38;5;${16 + (i % 200)}m●\x1b[0m Read \x1b[1msrc/components/File${i}.tsx\x1b[0m \x1b[2m(${(i * 37) % 900} lines)\x1b[0m  ` +
          "lorem ipsum dolor sit amet ".repeat(1 + (i % 4));
  };
  const chunk = (bytes) => {
    let s = "";
    while (s.length < bytes) s += line();
    return s;
  };
  const TICK = 20;
  let fedBytes = 0;
  const flood = setInterval(() => {
    for (const id of ids) {
      const bps = id === visibleId ? visibleBps : otherBps;
      if (!bps) continue;
      const c = chunk((bps * TICK) / 1000);
      fedBytes += c.length;
      mock.feedPty(id, [c]);
    }
  }, TICK);

  const frames = [];
  let running = true;
  let last = performance.now();
  const loop = (t) => {
    frames.push(t - last);
    last = t;
    if (running) requestAnimationFrame(loop);
  };
  requestAnimationFrame(loop);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const twoFrames = () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));
  await sleep(1000);

  // Input latency: key press → pty_write → echo written → painted.
  const input = [];
  const visibleTextarea = () =>
    [...document.querySelectorAll(".xterm-helper-textarea")].find((t) => t.closest(".xterm")?.offsetParent !== null);
  for (let k = 0; k < 10; k++) {
    const ta = visibleTextarea();
    if (!ta) break;
    ta.focus();
    const before = mock.writes.length;
    const t0 = performance.now();
    ta.dispatchEvent(new KeyboardEvent("keydown", { key: "x", code: "KeyX", keyCode: 88, bubbles: true }));
    ta.dispatchEvent(new InputEvent("input", { data: "x", inputType: "insertText", bubbles: true }));
    while (mock.writes.length === before && performance.now() - t0 < 1000) await new Promise((r) => setTimeout(r, 0));
    const w = mock.writes[mock.writes.length - 1];
    if (w && mock.writes.length > before) mock.feedPty(w.id, ["x"]);
    await twoFrames();
    input.push(performance.now() - t0);
    await sleep(250);
  }

  // Switch latency: click an agent row → second painted frame.
  const switches = [];
  const rows = [...document.querySelectorAll('[aria-label="Agents"] .rd-agent-card, [aria-label="Agents"] .rd-idle-row')];
  for (let k = 0; k < 6 && rows.length > 1; k++) {
    const row = rows[(k + 1) % rows.length];
    const t0 = performance.now();
    row.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await twoFrames();
    switches.push(performance.now() - t0);
    await sleep(400);
  }
  rows[0]?.dispatchEvent(new MouseEvent("click", { bubbles: true }));

  const rest = seconds * 1000 - (performance.now() - start);
  if (rest > 0) await sleep(rest);
  running = false;
  clearInterval(flood);
  return { frames: frames.slice(1), input, switches, ptys: ids.length, fedBytes };
}

const isEngine = (cmd) => cmd.includes(ENGINE === chromium ? "ms-playwright/chromium" : "ms-playwright/webkit");
const server = await serve();
const browser = await ENGINE.launch({ headless: true });
const results = [];
try {
  for (const n of SESSIONS) {
    for (const name of PICK) {
      const [visibleBps, otherBps] = SCENARIOS[name];
      const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
      const page = await ctx.newPage();
      const errors = [];
      page.on("pageerror", (e) => errors.push(String(e)));
      await page.goto(`${server.url}?mock=1&sessions=${n}`, { waitUntil: "load" });
      await page.waitForTimeout(3000);
      const sampler = startSampler(isEngine);
      const r = await page.evaluate(runInPage, { seconds: SECONDS, visibleBps, otherBps });
      const proc = sampler.stop();
      await ctx.close();
      const row = {
        engine: ENGINE.name(),
        sessions: n,
        scenario: name,
        ptys: r.ptys,
        mbFed: +(r.fedBytes / 1e6).toFixed(1),
        frameP50: +pct(r.frames, 50).toFixed(1),
        frameP95: +pct(r.frames, 95).toFixed(1),
        frameMax: +Math.max(...r.frames).toFixed(0),
        over50ms: r.frames.filter((f) => f > 50).length,
        fps: +(r.frames.length / (r.frames.reduce((a, b) => a + b, 0) / 1000)).toFixed(0),
        inputP50: +pct(r.input, 50).toFixed(0),
        inputMax: +Math.max(...r.input).toFixed(0),
        switchP50: +pct(r.switches, 50).toFixed(0),
        switchMax: +Math.max(...r.switches).toFixed(0),
        cpuAvg: +proc.cpuAvg.toFixed(0),
        rssMaxMb: +proc.rssMaxMb.toFixed(0),
        errors: errors.length,
      };
      results.push(row);
      console.log(JSON.stringify(row));
    }
  }
} finally {
  await browser.close();
  server.stop();
}
console.table(results);
const out = arg("json");
if (out) writeFileSync(out, JSON.stringify(results, null, 2));
