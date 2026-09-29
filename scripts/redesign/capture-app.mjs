// Created by Claude — Classification: INTERNAL
//
// Screenshot the app's web build with the mock backend.
//   node scripts/redesign/capture-app.mjs <outDir> [--screen control|grid] [--theme dark|light]
//        [--size 1440x900] [--url http://localhost:1420]
// Needs `npm run dev` (vite on :1420) running. Fails on any console error or page
// error — a screenshot of a half-broken page is worse than no screenshot.
// Writes <outDir>/<screen>.<theme>.<size>.png and prints the [data-diff-mask] rects.

import { chromium } from "@playwright/test";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const opt = (k, d) => (args.includes(`--${k}`) ? args[args.indexOf(`--${k}`) + 1] : d);
const outDir = args.find((a, i) => !a.startsWith("--") && !args[i - 1]?.startsWith("--"));
if (!outDir) throw new Error("usage: capture-app.mjs <outDir> [...]");
const screen = opt("screen", "control");
const theme = opt("theme", "dark");
const [width, height] = opt("size", "1440x900").split("x").map(Number);
const base = opt("url", "http://localhost:1420");
mkdirSync(outDir, { recursive: true });

export async function capture({ page, screen, theme }) {
  const errors = [];
  page.on("pageerror", (e) => errors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => {
    // WebGL/GPU driver notices from xterm's renderer are environment noise, not app errors.
    if (m.type() === "error" && !/WebGL|GPU|GL_/.test(m.text())) errors.push(`console: ${m.text()}`);
  });
  await page.goto(`${base}/?mock=1&screen=${screen}&theme=${theme}`);
  await page.evaluate(() => document.fonts.ready);
  await page.waitForTimeout(800); // terminals fit + first mock output
  const masks = await page.$$eval("[data-diff-mask]", (els) =>
    els.map((e) => { const r = e.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; }),
  );
  return { errors, masks };
}

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
  const { errors, masks } = await capture({ page, screen, theme });
  const file = join(outDir, `${screen}.${theme}.${width}x${height}.png`);
  await page.screenshot({ path: file });
  writeFileSync(file.replace(/\.png$/, ".masks.json"), JSON.stringify(masks));
  console.log(JSON.stringify({ file, masks: masks.length, errors }));
  if (errors.length) process.exitCode = 1;
} finally {
  await browser.close();
}
