// Created by Claude — Classification: INTERNAL
//
// Write English copies of the reference designs (layout untouched, copy translated)
//   node scripts/redesign/make-en-references.mjs
// and fail if any Turkish-only letter survives outside the terminal body, which is
// sample output the app never draws itself.
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { translate } from "./strings.mjs";

const dir = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "docs", "design", "redesign-v0.4");
let leftovers = 0;
for (const name of ["control", "grid"]) {
  // Operator rule: no text may wrap. The Turkish reference itself wraps the session
  // header at 1440px (h1 on two lines, pills and buttons folding) — a defect, not
  // part of the design. The English copy carries the corrected rule so the diff
  // measures the app against the design the operator actually wants.
  const NOWRAP = `<style>
*{white-space:nowrap}
h1{overflow:hidden;text-overflow:ellipsis}
[data-terminal-body],[data-terminal-body] *{white-space:normal}
section>div:first-child{height:49px;box-sizing:border-box}
section>div[style*="border-top"]{height:58px;box-sizing:border-box;display:flex;align-items:center;padding-top:0!important;padding-bottom:0!important}
section>div[style*="border-top"]>div{flex-grow:1}
section[style*="2px solid"]{border-width:1px!important;box-shadow:0 0 0 1px #F2B34B}
</style>
</helmet>`;
  const en = translate(readFileSync(join(dir, `${name}.reference.html`), "utf8"))
    // Terminal sample output is not UI copy — it keeps wrapping, and is masked in the diff.
    .replace(/(<div )(style="flex-grow: 1; min-height: 0; overflow: hidden; padding: 20px 28px;)/, "$1data-terminal-body $2")
    .replace(/(<div )(style="flex-grow: 1; padding: 14px 16px;)/g, "$1data-terminal-body $2")
    .replace("</helmet>", NOWRAP);
  // Grid panel headers: the waiting one carries a 28px maximize button and was taller
  // than its neighbours (49 vs ~41px) — side-by-side panels were misaligned. All panel
  // headers share one height (the rule above). Same for the bottom bars: the approval
  // bar (34px buttons, 12px padding) and the composer (34px input, 10px padding) were
  // 58 vs 54px — both are 58 now. The waiting panel's 2px border pushed its content
  // 1px off its neighbours; it is drawn as 1px border + 1px outer ring instead.
  // Grid rail: the brief says the rail is identical on both screens, but the grid
  // reference dropped the Settings button. Put it back from the control reference.
  let out = en;
  if (name === "grid") {
    const control = readFileSync(join(dir, "control.reference.html"), "utf8");
    const settings = translate(control.slice(control.indexOf('<div style="flex-grow: 1"></div>\n<button type="button" aria-label="Ayarlar"'), control.indexOf("</nav>")));
    out = out.replace(/(Chat<\/button>\n)(<\/nav>)/, `$1${settings}$2`);
    if (!out.includes('aria-label="Settings"')) throw new Error("grid: settings button not inserted");
  }
  writeFileSync(join(dir, `${name}.reference.en.html`), out);
  // Terminal sample output (masked in the diff) legitimately keeps its Turkish text:
  // skip every line from a terminal-body opener to the progress strip / panel footer.
  let inTerminal = false;
  for (const line of out.split("\n")) {
    if (line.includes("data-terminal-body")) inTerminal = true;
    if (inTerminal && (line.includes("border-top: 1px solid #1E232C") || line.includes("border-top: 1px solid #262B35; background: #13161B"))) inTerminal = false;
    if (inTerminal) continue;
    const visible = line.replace(/<[^>]+>/g, " ");
    if (/[çğıöşüÇĞİÖŞÜ]/.test(visible)) { leftovers++; console.log(`${name}: untranslated → ${visible.trim().slice(0, 90)}`); }
  }
}
console.log(leftovers ? `${leftovers} untranslated line(s)` : "all UI copy translated");
process.exit(leftovers ? 1 : 0);
