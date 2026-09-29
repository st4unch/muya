// Created by Claude — Classification: INTERNAL
//
// WCAG 2.x contrast report for every text token against the surfaces it is used on.
//   node scripts/redesign/contrast.mjs [--theme light|dark] [--markdown]
// Reads the real values from src/styles/tokens.css — the report can't drift from
// what ships. Exits 1 if any pair in the selected theme is below 4.5:1.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const css = readFileSync(join(root, "src", "styles", "tokens.css"), "utf8");

/** Token → hex for one `:root[data-theme="…"]` block. */
function tokens(theme) {
  const start = css.indexOf(`:root[data-theme="${theme}"]`);
  if (start < 0) throw new Error(`no ${theme} block in tokens.css`);
  const body = css.slice(css.indexOf("{", start) + 1, css.indexOf("}", start));
  const out = {};
  for (const m of body.matchAll(/--([\w-]+)\s*:\s*(#[0-9a-fA-F]{3,8})\s*;/g)) out[m[1]] = m[2];
  return out;
}

function lum(hex) {
  let h = hex.slice(1);
  if (h.length === 3) h = [...h].map((c) => c + c).join("");
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
export const ratio = (fg, bg) => {
  const [a, b] = [lum(fg), lum(bg)].sort((x, y) => y - x);
  return (a + 0.05) / (b + 0.05);
};

// Every place a text token actually sits, per the reference designs.
export const PAIRS = [
  ["text", ["bg-app", "bg-chrome", "bg-panel", "bg-input", "bg-control", "bg-selected", "bg-terminal"]],
  ["text-strong", ["bg-rail-active", "bg-segment-active", "bg-chrome", "bg-terminal"]],
  ["text-secondary", ["bg-panel", "bg-selected"]],
  ["text-tertiary", ["bg-segment", "bg-input", "bg-chrome", "bg-control"]],
  ["text-muted", ["bg-app", "bg-chrome", "bg-panel", "bg-input", "bg-terminal", "bg-selected", "bg-table-head", "success-card-bg", "bg-control"]],
  ["text-faint", ["bg-chrome", "bg-panel"]],
  ["text-terminal", ["bg-terminal"]],
  ["accent", ["bg-terminal", "bg-app", "bg-panel"]],
  ["primary-fg", ["primary-bg"]],
  ["success-text", ["success-bg", "bg-terminal", "bg-panel", "bg-selected-head", "bg-chrome"]],
  ["success-card-text", ["success-card-bg"]],
  ["warning-label", ["warning-bg", "warning-card-bg", "bg-panel", "bg-chrome"]],
  ["warning-btn-fg", ["warning-btn-bg"]],
  ["warning-text", ["warning-card-bg", "warning-code-bg", "warning-bg", "bg-chrome"]],
  ["danger-text", ["danger-pill-bg", "danger-btn-bg", "bg-terminal"]],
  ["danger-kbd", ["danger-btn-bg"]],
];

export function report(theme) {
  const t = tokens(theme);
  const rows = [];
  for (const [fg, bgs] of PAIRS) {
    for (const bg of bgs) {
      if (!t[fg] || !t[bg]) throw new Error(`${theme}: missing --${fg} or --${bg}`);
      rows.push({ fg, bg, fgHex: t[fg], bgHex: t[bg], ratio: ratio(t[fg], t[bg]) });
    }
  }
  return rows;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const theme = process.argv.includes("--theme") ? process.argv[process.argv.indexOf("--theme") + 1] : "light";
  const md = process.argv.includes("--markdown");
  const rows = report(theme);
  const bad = rows.filter((r) => r.ratio < 4.5);
  if (md) {
    console.log(`| Metin token | Zemin token | Metin | Zemin | Oran | ≥4.5 |\n|---|---|---|---|---|---|`);
    for (const r of rows) console.log(`| \`--${r.fg}\` | \`--${r.bg}\` | ${r.fgHex} | ${r.bgHex} | ${r.ratio.toFixed(2)}:1 | ${r.ratio >= 4.5 ? "✅" : "❌"} |`);
  } else {
    for (const r of rows) console.log(`${r.ratio >= 4.5 ? "ok " : "LOW"} ${r.ratio.toFixed(2).padStart(5)}  --${r.fg} on --${r.bg}  (${r.fgHex} / ${r.bgHex})`);
  }
  console.log(`\n${theme}: ${rows.length} pairs, ${bad.length} below 4.5:1`);
  process.exit(bad.length ? 1 : 0);
}
