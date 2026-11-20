// Faz 0 S0 (information only, PRD D13): cost of a "mount xterm only for visible sessions" design
// in today's Tauri app. Hidden sessions would keep raw output in JS and build an xterm on switch,
// replaying the held bytes. This measures that switch in headless WebKit: new xterm + WebGL
// renderer, write N bytes of Claude-like output, until the next frame.
//
//   node native/spikes/s0-xterm/switch-cost.mjs [--browser chromium]
import { webkit, chromium } from "playwright";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../..");
const engine = process.argv.includes("--browser") && process.argv[process.argv.indexOf("--browser") + 1] === "chromium" ? chromium : webkit;
const browser = await engine.launch();
const page = await browser.newPage({ viewport: { width: 1400, height: 900 } });
await page.setContent(`<!doctype html><html><body style="margin:0;background:#111"><div id="t" style="width:900px;height:560px"></div></body></html>`);
await page.addStyleTag({ path: path.join(root, "node_modules/@xterm/xterm/css/xterm.css") });
await page.addScriptTag({ path: path.join(root, "node_modules/@xterm/xterm/lib/xterm.js") });
await page.addScriptTag({ path: path.join(root, "node_modules/@xterm/addon-webgl/lib/addon-webgl.js") });

const result = await page.evaluate(async () => {
  const lines = [];
  for (let i = 0; i < 400; i++) {
    lines.push(`\x1b[38;5;${16 + (i % 200)}m*\x1b[0m Read \x1b[1msrc/components/File${i}.tsx\x1b[0m lorem ipsum şğüİı 日本語 ${i}\r\n`);
  }
  const blob = new TextEncoder().encode(lines.join(""));
  const make = (bytes) => {
    const out = new Uint8Array(bytes);
    for (let o = 0; o < bytes; o += blob.length) out.set(blob.subarray(0, Math.min(blob.length, bytes - o)), o);
    return out;
  };
  const frame = () => new Promise((r) => requestAnimationFrame(() => r()));
  const results = {};
  for (const kb of [64, 256, 1024]) {
    const data = make(kb * 1024);
    const times = [];
    for (let run = 0; run < 8; run++) {
      const el = document.getElementById("t");
      el.innerHTML = "";
      await frame();
      const t0 = performance.now();
      const term = new window.Terminal({ cols: 110, rows: 32, scrollback: 5000, fontSize: 13 });
      term.open(el);
      let gl = "dom";
      try { const addon = new window.WebglAddon.WebglAddon(); term.loadAddon(addon); gl = "webgl"; } catch { /* DOM renderer */ }
      await new Promise((r) => term.write(data, r));
      await frame();
      times.push(performance.now() - t0);
      results.renderer = gl;
      term.dispose();
    }
    times.sort((a, b) => a - b);
    results[`${kb}KB`] = { p50: +times[4].toFixed(1), max: +times[7].toFixed(1) };
  }
  return results;
});
console.log(JSON.stringify({ engine: engine.name(), ...result }));
await browser.close();
