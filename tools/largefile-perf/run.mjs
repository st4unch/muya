// Created by Claude — Classification: INTERNAL
// Usage: node run.mjs --base http://localhost:1431 --kinds json,log --sizes 1,5,20 --mode full [--budget-open-ms N]
// Drives the harness page with Playwright chromium, prints one JSON line per case.
import { chromium } from "playwright";
import { execSync } from "node:child_process";

const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; };
const base = arg("base", "http://localhost:1431");
const kinds = arg("kinds", "json").split(",");
const sizes = arg("sizes", "1").split(",").map(Number);
const mode = arg("mode", "full");
const steps = arg("steps", "open,scroll,type,wrap,map,diff").split(",");
const budget = Number(arg("budget-open-ms", "0"));
const budgetHl = Number(arg("budget-hl-ms", "0"));
const budgetType = Number(arg("budget-type-ms", "0"));
const expectBanner = arg("expect-banner", ""); // "yes" | "no": fail when the banner state differs
const shotDir = arg("shots", "");
const TIMEOUT = 90000;

const browser = await chromium.launch({ args: ["--enable-precise-memory-info"] });
const cdp = await browser.newBrowserCDPSession();
async function procs() {
  const { processInfo } = await cdp.send("SystemInfo.getProcessInfo");
  const cpu = processInfo.reduce((a, p) => a + p.cpuTime, 0);
  let rss = 0;
  for (const p of processInfo) {
    try { rss += Number(execSync(`ps -o rss= -p ${p.id}`).toString().trim() || 0); } catch {}
  }
  return { cpu, rssMb: Math.round(rss / 1024) };
}

let failed = false;
for (const kind of kinds) for (const mb of sizes) {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await ctx.newPage();
  const out = { kind, mb, mode };
  try {
    await page.addInitScript(() => {
      window.__t = {};
      new MutationObserver(() => {
        const t = window.__t, now = performance.now();
        const lines = document.querySelectorAll(".monaco-editor:not(.original-in-monaco-diff-editor) .view-line");
        if (!t.first && [...lines].some((l) => l.textContent.length > 0)) t.first = now;
        if (t.first && !t.hl) {
          const cls = new Set();
          for (const s of document.querySelectorAll(".view-line span[class^='mtk']")) cls.add(s.className);
          if (cls.size >= 3) t.hl = now;
        }
      }).observe(document, { subtree: true, childList: true, attributes: true });
    });
    const before = await procs();
    const tNav = Date.now();
    await page.goto(`${base}/tools/largefile-perf/index.html?kind=${kind}&mb=${mb}&mode=${mode}${process.env.EXTRA ?? ""}`, { timeout: TIMEOUT });
    const readyTimeout = steps.includes("open") ? TIMEOUT : 5000;
    await page.waitForFunction(() => window.__t?.first, null, { timeout: readyTimeout, polling: 50 });
    const t = await page.evaluate(() => ({ ...window.__t, mount: window.__perf.mountAt, gen: window.__perf.genMs, bytes: window.__perf.bytes }));
    out.openMs = Math.round(t.first - t.mount);
    out.genMs = Math.round(t.gen);
    // Highlight: wait up to 20 s for >=3 token classes.
    await page.waitForFunction(() => window.__t.hl, null, { timeout: 20000, polling: 100 }).catch(() => {});
    const hl = await page.evaluate(() => window.__t.hl ?? null);
    out.highlightMs = hl ? Math.round(hl - t.mount) : null;
    await page.waitForTimeout(1500);
    const after = await procs();
    out.cpuSecOpen = +(after.cpu - before.cpu).toFixed(2);
    out.rssMb = after.rssMb;
    out.banner = (await page.locator('[data-testid="large-file-banner"]').count()) > 0;
    out.minimapOk = (await page.locator(".minimap").count()) > 0;
    if (shotDir) await page.screenshot({ path: `${shotDir}/${kind}-${mb}mb-${mode}.png` });

    if (steps.includes("scroll")) {
      await page.mouse.move(600, 400);
      await page.evaluate(() => { window.__gaps = []; let last = performance.now(); const f = (n) => { window.__gaps.push(n - last); last = n; window.__raf = requestAnimationFrame(f); }; window.__raf = requestAnimationFrame(f); });
      for (let i = 0; i < 40; i++) { await page.mouse.wheel(0, 600); await page.waitForTimeout(16); }
      await page.waitForTimeout(300);
      const g = await page.evaluate(() => { cancelAnimationFrame(window.__raf); return window.__gaps; });
      g.sort((a, b) => a - b);
      out.scrollMaxFrameMs = Math.round(g[g.length - 1]);
      out.scrollP95FrameMs = Math.round(g[Math.floor(g.length * 0.95)]);
    }
    if (steps.includes("type")) {
      await page.locator(".monaco-editor .view-lines").first().click();
      await page.evaluate(() => {
        window.__lat = [];
        document.addEventListener("keydown", () => { const s = performance.now(); requestAnimationFrame(() => requestAnimationFrame(() => window.__lat.push(performance.now() - s))); }, true);
      });
      for (let i = 0; i < 25; i++) { await page.keyboard.press("x"); await page.waitForTimeout(40); }
      await page.waitForTimeout(300);
      const l = (await page.evaluate(() => window.__lat)).sort((a, b) => a - b);
      out.typeMedianMs = Math.round(l[Math.floor(l.length / 2)]);
      out.typeMaxMs = Math.round(l[l.length - 1]);
    }
    const timeClick = async (label, done) => {
      const btn = page.getByRole("button", { name: label, exact: true });
      if (await btn.isDisabled()) return "disabled";
      const s = Date.now();
      await btn.click();
      await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
      if (done) await page.waitForSelector(done, { timeout: 60000 });
      return Date.now() - s;
    };
    if (steps.includes("wrap")) { out.wrapMs = await timeClick("Wrap"); await page.waitForTimeout(500); }
    if (steps.includes("map")) { out.mapMs = await timeClick("Map"); await page.waitForTimeout(300); }
    if (steps.includes("diff")) { out.diffMs = await timeClick("Diff", ".monaco-diff-editor .view-line"); }
    const fin = await procs();
    out.rssMbEnd = fin.rssMb;
    out.cpuSecTotal = +(fin.cpu - before.cpu).toFixed(2);
    out.totalWallMs = Date.now() - tNav;
    if (budget && out.openMs > budget) { out.overBudget = "open"; failed = true; }
    if (budgetHl && (out.highlightMs === null || out.highlightMs > budgetHl)) { out.overBudget = "highlight"; failed = true; }
    if (budgetType && out.typeMedianMs > budgetType) { out.overBudget = "typing"; failed = true; }
    if (expectBanner && out.banner !== (expectBanner === "yes")) { out.overBudget = "banner"; failed = true; }
  } catch (e) {
    out.error = String(e).split("\n")[0];
    failed = true;
  }
  console.log(JSON.stringify(out));
  await ctx.close();
}
await browser.close();
process.exit(failed ? 1 : 0);
