// Created by Claude — Classification: INTERNAL
//
// Pixel-diff the redesigned screens against the English reference designs.
//   node scripts/redesign/verify.mjs <outDir> [--target preview|app] [--url http://localhost:1420]
//
// --target preview  renders src/redesign/Preview (redesign-preview.html) — the screens alone
// --target app      renders the real App with the mock backend (?mock=1)
// Needs vite running (`npx vite --port 1420`). Terminal bodies are masked on BOTH sides:
// the reference's [data-terminal-body] (added by make-en-references) and the app's
// [data-diff-mask]. Masked pixels are excluded from the percentage (see diff.mjs).
// Prints one line per screen and exits 1 if any screen exceeds 1%.

import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { diffPngs } from "./diff.mjs";
import { routeFonts } from "./fonts.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const args = process.argv.slice(2);
const opt = (k, d) => (args.includes(`--${k}`) ? args[args.indexOf(`--${k}`) + 1] : d);
const outDir = args.find((a, i) => !a.startsWith("--") && !args[i - 1]?.startsWith("--"));
if (!outDir) throw new Error("usage: verify.mjs <outDir> [--target preview|app]");
const target = opt("target", "preview");
const base = opt("url", "http://localhost:1420");
mkdirSync(outDir, { recursive: true });

const rects = (page, sel) =>
  page.$$eval(sel, (els) =>
    els.map((e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; }),
  );

const browser = await chromium.launch();
let worst = 0;
try {
  for (const screen of ["control", "grid"]) {
    const viewport = { width: 1440, height: 900 };
    const ref = await browser.newPage({ viewport, deviceScaleFactor: 1 });
    await routeFonts(ref);
    await ref.route("**/support.js", (r) => r.fulfill({ contentType: "text/javascript", body: "" }));
    await ref.goto(pathToFileURL(join(root, "docs", "design", "redesign-v0.4", `${screen}.reference.en.html`)).href);
    await ref.evaluate(() => document.fonts.ready);
    const refPng = join(outDir, `${screen}.reference.en.png`);
    await ref.screenshot({ path: refPng, clip: { x: 0, y: 0, ...viewport } });
    const refMasks = await rects(ref, "[data-terminal-body]");

    const app = await browser.newPage({ viewport, deviceScaleFactor: 1 });
    const errors = [];
    app.on("pageerror", (e) => errors.push(e.message));
    app.on("console", (m) => m.type() === "error" && !/WebGL|GPU|GL_/.test(m.text()) && errors.push(m.text()));
    const url = target === "app"
      ? `${base}/?mock=1&screen=${screen}&theme=dark`
      : `${base}/redesign-preview.html?screen=${screen}&theme=dark`;
    await app.goto(url);
    await app.evaluate(() => document.fonts.ready);
    await app.waitForTimeout(target === "app" ? 1200 : 400);
    const appPng = join(outDir, `${screen}.${target}.dark.png`);
    await app.screenshot({ path: appPng });
    const appMasks = await rects(app, "[data-diff-mask]");

    const r = diffPngs({ ref: refPng, app: appPng, out: join(outDir, `${screen}.${target}.diff.png`), masks: [...refMasks, ...appMasks] });
    worst = Math.max(worst, r.percent);
    console.log(`${screen}: ${r.percent.toFixed(3)}%  (${r.differing} px of ${r.total}; masks ref ${refMasks.length} / app ${appMasks.length}; errors ${errors.length}${errors.length ? ": " + errors.slice(0, 2).join(" | ") : ""})`);
    if (errors.length) worst = Math.max(worst, 100);
    await ref.close();
    await app.close();
  }
} finally {
  await browser.close();
}
process.exit(worst <= 1 ? 0 : 1);
