// Golden file for the Rust screen parser port (PRD AC3): runs today's TypeScript parser
// (src/lib/screenState.ts) on every captured screen and writes lines + parsed state, which
// muya-core's tests must reproduce exactly.
//   node native/tools/screen-golden.mjs
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "../..");
const { parseClaudeScreen, parseBusy } = await import(join(root, "src/lib/screenState.ts"));
const dir = join(root, "src/lib/__fixtures__/claude-screens");
const entry = (name, lines) => ({ name, lines, state: parseClaudeScreen(lines), busy: parseBusy(lines) });
const cases = [];
for (const f of readdirSync(dir).filter((f) => f.endsWith(".txt")).sort()) {
  const name = f.replace(/\.txt$/, "");
  const lines = readFileSync(join(dir, f), "utf8").split("\n").slice(0, 40);
  cases.push(entry(name, lines));
  // Edge variants (not counted as captured screens for AC3): the footer or dialog cut off at the
  // top or bottom, as during a redraw.
  const last = lines.findLastIndex((l) => l.trim() !== "");
  for (let k = 1; k <= 8; k++) cases.push(entry(`${name}~tail-${k}`, lines.slice(0, Math.max(0, last + 1 - k))));
  for (let k = 1; k <= 4; k++) cases.push(entry(`${name}~head-${k * 5}`, lines.slice(k * 5)));
}
// Corpus captured from real Claude Code TUIs (native/tools/corpus/corpus.py): several versions,
// widths and scenarios. Names are `<scenario>-v<version>-w<width>-<snap>`; no edge variants.
const corpusDir = join(root, "native/corpus/claude-screens");
if (existsSync(corpusDir)) {
  for (const f of readdirSync(corpusDir).filter((f) => f.endsWith(".txt")).sort()) {
    const lines = readFileSync(join(corpusDir, f), "utf8").split("\n").slice(0, 40);
    cases.push({ ...entry("corpus/" + f.replace(/\.txt$/, ""), lines), captured: true });
  }
}
const out = join(root, "native/crates/muya-core/tests/screen-golden.json");
writeFileSync(out, JSON.stringify(cases, null, 1) + "\n");
console.log(`${cases.length} cases -> ${out.slice(root.length + 1)}`);
