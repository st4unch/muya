// Created by Claude — Classification: INTERNAL
//
// Render the two reference designs at 1440×900 to PNG.
//   node scripts/redesign/render-reference.mjs [outDir] [--en]
// Output: <outDir>/control.reference(.en).png, <outDir>/grid.reference(.en).png
// --en renders the English copies made by make-en-references.mjs (the UI is English).

import { chromium } from "@playwright/test";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { routeFonts } from "./fonts.mjs";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const refDir = join(root, "docs", "design", "redesign-v0.4");
const args = process.argv.slice(2);
const suffix = args.includes("--en") ? ".en" : "";
const outDir = args.find((a) => !a.startsWith("--")) ?? join(refDir, "diff");
mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch();
try {
  for (const name of ["control", "grid"]) {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
    await routeFonts(page);
    // The design tool's runtime isn't in the zip and isn't needed: every style is inline.
    await page.route("**/support.js", (r) => r.fulfill({ contentType: "text/javascript", body: "" }));
    await page.goto(pathToFileURL(join(refDir, `${name}.reference${suffix}.html`)).href);
    await page.evaluate(() => document.fonts.ready);
    const out = join(outDir, `${name}.reference${suffix}.png`);
    await page.screenshot({ path: out, clip: { x: 0, y: 0, width: 1440, height: 900 } });
    const fonts = await page.evaluate(() =>
      [...document.fonts].filter((f) => f.status === "loaded").map((f) => `${f.family} ${f.weight}`),
    );
    console.log(`${name}: ${out}  fonts loaded: ${[...new Set(fonts)].join(", ")}`);
    await page.close();
  }
} finally {
  await browser.close();
}
