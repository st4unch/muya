// Reference screenshots of today's Muya UI (WKWebView == WebKit) from the mock backend.
//   usage: node native/ui-reference/capture.mjs [--only name,name] [--sizes 1440x900,1120x732] [--themes dark,light]
// Needs `npm run dev` (vite) on :1420. Mock data only (src/mock/fixtures.ts) — no real user data.
import { createRequire } from "node:module";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(path.join(here, "../../package.json"));
const { webkit } = require("playwright-core");

const arg = (k, d) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const ONLY = arg("--only", "") ? arg("--only").split(",") : null;
const SIZES = arg("--sizes", "1440x900,1120x732").split(",").map((s) => s.split("x").map(Number));
const THEMES = arg("--themes", "dark,light").split(",");
const BASE = arg("--base", "http://localhost:1420/?mock=1");
const OUT = path.join(here, "screens");

const wait = (p, ms = 350) => p.waitForTimeout(ms);
const vis = (loc) => loc.locator("visible=true").first();
const clickText = async (p, text, opts = {}) => vis(p.getByText(text, { exact: opts.exact ?? true })).click({ timeout: 3000 });
const clickLabel = (p, l) => vis(p.locator(`[aria-label="${l}"]`)).click({ timeout: 3000 });
const rail = (p, l) => vis(p.locator(`nav[aria-label="Main navigation"] [aria-label="${l}"]`)).click({ timeout: 3000 });
const domClick = (p, re) => p.evaluate((src) => { const r = new RegExp(src); const el = [...document.querySelectorAll("button")].find((b) => r.test(b.textContent || "") && b.offsetParent); if (!el) throw new Error("no button " + src); el.click(); }, re);
const openInspector = async (p) => { if (!(await p.locator('[aria-label="Hide inspector"]').count())) { await p.keyboard.press("Alt+Meta+b"); await p.waitForTimeout(500); } };
const key = (p, k) => p.keyboard.press(k);

// name -> async (page) setup. Each runs on a freshly loaded page.
const SHOTS = {
  "control": async () => {},
  "control-agents-hidden": async (p) => { await key(p, "Meta+b"); await wait(p); },
  "control-inspector-activity": async (p) => { await openInspector(p); await clickText(p, "Activity"); },
  "control-terminal-focus": async (p) => { await key(p, "Meta+b"); await key(p, "Alt+Meta+b"); await wait(p); },
  "grid": async (p) => { await p.evaluate(() => [...document.querySelectorAll('[aria-label="Split to grid"]')].find((e) => e.offsetParent)?.click()); await wait(p, 800); },
  "files": async (p) => { await rail(p, "Files"); await wait(p, 600); },
  "files-tree": async (p) => { await rail(p, "Files"); await wait(p, 500); await vis(p.getByText(/^FILES/)).click({ timeout: 3000 }); await wait(p, 700); },
  "files-context-menu": async (p) => {
    await rail(p, "Files"); await wait(p, 500); await vis(p.getByText(/^FILES/)).click({ timeout: 3000 }); await wait(p, 700);
    const row = vis(p.getByText("notes.ts", { exact: true }));
    await row.click({ button: "right", timeout: 3000 }); await wait(p);
  },
  "files-editor": async (p) => {
    await rail(p, "Files"); await wait(p, 500); await vis(p.getByText(/^FILES/)).click({ timeout: 3000 }); await wait(p, 700);
    await vis(p.getByText("notes.ts", { exact: true })).click({ timeout: 3000 }); await wait(p, 2500);
  },
  "sessions": async (p) => { await rail(p, "Sessions"); await wait(p, 800); },
  "sessions-cleanup": async (p) => { await rail(p, "Sessions"); await wait(p, 800); await vis(p.getByText("Clean up", { exact: false })).click({ timeout: 3000 }); await wait(p, 600); },
  "queue": async (p) => { await rail(p, "Queue"); await wait(p, 800); },
  "kanban": async (p) => { await rail(p, "Kanban"); await wait(p, 800); },
  "resources": async (p) => { await rail(p, "Resources"); await wait(p, 800); },
  "resources-marketplace": async (p) => { await rail(p, "Resources"); await wait(p, 600); await vis(p.getByText("Marketplace", { exact: false })).click({ timeout: 3000 }); await wait(p, 800); },
  "ssh-servers": async (p) => { await rail(p, "SSH"); await wait(p, 800); },
  "ssh-cyberark": async (p) => { await rail(p, "SSH"); await wait(p, 500); await clickText(p, "CyberArk"); await wait(p, 600); },
  "ssh-store": async (p) => { await rail(p, "SSH"); await wait(p, 500); await clickText(p, "Password Store"); await wait(p, 600); },
  "ssh-add-server": async (p) => { await rail(p, "SSH"); await wait(p, 500); await vis(p.getByText("Add server", { exact: false })).click({ timeout: 3000 }); await wait(p, 600); },
  "schedules": async (p) => { await rail(p, "Schedules"); await wait(p, 800); },
  "schedules-editor": async (p) => { await rail(p, "Schedules"); await wait(p, 600); await domClick(p, "New schedule"); await wait(p, 600); },
  "branches": async (p) => { await key(p, "Meta+k"); await wait(p); await p.keyboard.type("branches"); await wait(p, 300); await key(p, "Enter"); await wait(p, 900); },
  "settings": async (p) => { await clickLabel(p, "Settings"); await wait(p, 600); },
  "palette": async (p) => { await key(p, "Meta+k"); await wait(p, 500); },
  "palette-query": async (p) => { await key(p, "Meta+k"); await wait(p); await p.keyboard.type("ses"); await wait(p, 400); },
  "new-agent": async (p) => { await vis(p.getByText("New agent", { exact: false })).click({ timeout: 3000 }); await wait(p, 600); },
  "notifications": async (p) => { await clickLabel(p, "Notifications"); await wait(p, 600); },
  "footer-add-status": async (p) => { await clickLabel(p, "Add status field"); await wait(p, 500); },
  "terminal-appearance": async (p) => { await clickLabel(p, "Terminal appearance"); await wait(p, 500); },
  "composer-slash": async (p) => { await vis(p.getByText("/ Commands", { exact: false })).click({ timeout: 3000 }); await wait(p, 500); },
  "inspector-review-diff": async (p) => { await openInspector(p); await vis(p.getByText("Review diff", { exact: false })).click({ timeout: 3000 }); await wait(p, 1500); },
  "inspector-commit": async (p) => { await openInspector(p); await domClick(p, "^Commit"); await wait(p, 700); },
  "more-actions": async (p) => { await p.setViewportSize({ width: 1000, height: 700 }); await wait(p, 500); await domClick(p, "More actions|^$").catch(() => {}); await p.evaluate(() => document.querySelector('[aria-label="More actions"]')?.click()); await wait(p, 500); },
  "agent-card-menu": async (p) => { await vis(p.getByText("documents-44", { exact: true })).click({ button: "right", timeout: 3000 }); await wait(p, 500); },
  "workspace-switcher": async (p) => { await vis(p.getByText("Workspace", { exact: false })).click({ timeout: 3000 }); await wait(p, 500); },
  "theme-toggle-system": async () => {},
};

mkdirSync(OUT, { recursive: true });
const browser = await webkit.launch();
const report = { generated: new Date().toISOString(), engine: "playwright webkit", shots: [] };

for (const [w, h] of SIZES) {
  for (const theme of THEMES) {
    for (const [name, setup] of Object.entries(SHOTS)) {
      if (name === "theme-toggle-system") continue;
      if (ONLY && !ONLY.includes(name)) continue;
      const ctx = await browser.newContext({ viewport: { width: w, height: h }, colorScheme: theme, deviceScaleFactor: 1 });
      const page = await ctx.newPage();
      const file = `${name}-${theme}-${w}x${h}.png`;
      let ok = true, err = "";
      // The mock's agent states occasionally come up "Idle" (0 working) — reload the shot until the footer says
      // "2 working" (max 4 tries), so every screenshot shows the same fixture state.
      for (let attempt = 0; attempt < 4; attempt++) {
        ok = true; err = "";
        try {
          await page.goto(BASE, { waitUntil: "load" });
          await page.waitForTimeout(2200);
          if (!(await page.locator("text=2 working").count())) { await page.evaluate(() => { try { localStorage.clear(); sessionStorage.clear(); } catch {} }); continue; }
          await setup(page);
        } catch (e) { ok = false; err = String(e.message).split("\n")[0]; }
        break;
      }
      await page.screenshot({ path: path.join(OUT, file) });
      report.shots.push({ name, theme, size: `${w}x${h}`, file, setupOk: ok, err });
      console.log(ok ? "ok  " : "FAIL", file, err);
      await ctx.close();
    }
  }
}
await browser.close();
writeFileSync(path.join(here, `capture-report-${THEMES.join("+")}-${SIZES.map((s) => s.join("x")).join("+")}.json`), JSON.stringify(report, null, 2));
