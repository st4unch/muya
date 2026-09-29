// Created by Claude — Classification: INTERNAL
// Screenshot any page at a given size: node scripts/redesign/shoot.mjs <url> <out.png> [1440x900]
import { chromium } from "@playwright/test";
const [url, out, size = "1440x900"] = process.argv.slice(2);
const [width, height] = size.split("x").map(Number);
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
const errors = [];
p.on("pageerror", (e) => errors.push(e.message));
await p.goto(url);
await p.evaluate(() => document.fonts.ready);
await p.waitForTimeout(500);
await p.screenshot({ path: out });
await b.close();
console.log(out, errors.length ? `ERRORS: ${errors.join(" | ")}` : "ok");
