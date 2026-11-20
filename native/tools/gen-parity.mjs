#!/usr/bin/env node
// Generates docs/native/parity.md (feature-parity list for the native rewrite).
//
//   node native/tools/gen-parity.mjs            regenerate docs/native/parity.md
//   node native/tools/gen-parity.mjs --check    fail if a done/verified row has no evidence
//
// Deterministic: no timestamps, stable ordering. Status/evidence of rows whose
// kind+id still exist are preserved on regeneration. No npm dependencies.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "..", "..");
const OUT_REL = "docs/native/parity.md";

export const KINDS = [
  ["command", "Commands (Tauri)"],
  ["event", "Events (emitted to the UI)"],
  ["shortcut", "Shortcuts"],
  ["dialog", "Dialogs and popovers"],
  ["settings-row", "Settings rows"],
  ["localstorage", "localStorage keys"],
  ["view", "Views"],
  ["viewer", "Viewer kinds"],
  ["token-group", "Token groups"],
  ["terminal-scheme", "Terminal schemes"],
];
const KIND_TITLE = Object.fromEntries(KINDS);
const DONE_STATES = new Set(["done", "verified"]);

// ---------- helpers ----------
const read = (root, rel) => fs.readFileSync(path.join(root, rel), "utf8");
const exists = (root, rel) => fs.existsSync(path.join(root, rel));
const lineOf = (text, index) => text.slice(0, index).split("\n").length;
const cell = (s) => String(s).replace(/\|/g, "\\|").replace(/\s+/g, " ").trim();
const uncell = (s) => s.replace(/\\\|/g, "|").trim();

function walk(root, rel, exts, out = []) {
  const dir = path.join(root, rel);
  if (!fs.existsSync(dir)) return out;
  for (const name of fs.readdirSync(dir).sort()) {
    const r = `${rel}/${name}`;
    const st = fs.statSync(path.join(root, r));
    if (st.isDirectory()) walk(root, r, exts, out);
    else if (exts.some((e) => name.endsWith(e))) out.push(r);
  }
  return out;
}

function section(md, headingRe) {
  const lines = md.split("\n");
  const start = lines.findIndex((l) => headingRe.test(l));
  if (start < 0) return { start: 0, lines: [] };
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^## /.test(lines[i])) { end = i; break; }
  }
  return { start, lines: lines.slice(start, end) }; // start is 0-based index of heading
}

function mdTable(sec) {
  const rows = [];
  sec.lines.forEach((l, i) => {
    if (!l.startsWith("|")) return;
    const cells = l.split(/(?<!\\)\|/).slice(1, -1).map((c) => c.trim());
    if (cells.every((c) => /^:?-+:?$/.test(c))) return;
    rows.push({ cells, line: sec.start + i + 1 });
  });
  return rows.slice(1); // drop header row
}

const stripMd = (s) => s.replace(/`/g, "").replace(/\*\*/g, "").trim();

// ---------- phase rules ----------
const FAZ = (n) => `Faz ${n}`;

function commandPhase(mod, name) {
  if (/pty/.test(name) || name === "release_agent_session" || name === "ssh_release_session") return FAZ(1);
  if (name === "get_startup_files") return FAZ(3);
  const m = {
    pty: 1, agents: 1, sessions: 1, agent_ops: 1, agent_files: 1, broker: 1,
    bridge: 1, bridge_exec: 1, bridge_remote: 1, bridge_mcp: 1, schedules: 1,
    app_prefs: 1, login_item: 1, debuglog: 1, claude_settings: 1,
    workspace_roots: 1, bg_service: 1, metrics: 1, spotlight: 1, opencode: 1,
    statusline: 2, slash_commands: 2, titlebar: 2,
    fs: 3, file_history: 3, watcher: 3,
    history: 4, term_history: 4, pm: 4, credstore: 4, vault: 4, cyberark: 4, ssh: 4,
  };
  return FAZ(m[mod] ?? 1);
}

function eventPhase(name) {
  if (name === "menu:check-update") return FAZ(5);
  if (name === "menu:quit-hint") return FAZ(2);
  if (name === "menu:new-file" || name === "menu:open-file" || name === "menu:close-tab" ||
      name === "menu:reopen-closed-tab" || name === "apex://open-file" || name.startsWith("fs-")) return FAZ(3);
  if (name.startsWith("menu:")) return FAZ(4);
  return FAZ(1); // bridge://, muya://, ssh-broker-*, schedules-changed
}

function localStoragePhase(key) {
  if (/composerHistory|panels\.|gridKeys|gridLayout|viewMode|selectedAgent|openTabs|pinnedAgents|splitGroups|notifications|composerOpen|sessionHeaderCollapsed|lastActive|waitingSince|terminalPrefs|footer\.|workspaces|selectedRoot|worktrees/.test(key)) return FAZ(2);
  if (/openFiles|autoSave/.test(key)) return FAZ(3);
  return FAZ(4); // theme, autoApprove, resumeOnLaunch, mergeQueue, headsUp, gate, ssh/vault collapse
}

function dialogPhase(id) {
  const t = id.toLowerCase();
  if (/update-ready/.test(t)) return FAZ(5);
  if (/clean up/.test(t)) return FAZ(4);
  if (/file access gate|review changes|file tree|drop overlay/.test(t)) return FAZ(3);
  if (/broadcast|rename agent|confirm|slash-commands|status field|terminal appearance|notification|path action|terminal context|agent\/workspace|session|toast|auto-allow|storage heads-up/.test(t)) return FAZ(2);
  return FAZ(4);
}

function viewPhase(id) {
  if (/^Control \(agents|^Grid/.test(id)) return FAZ(2);
  if (/^Control \(files/.test(id)) return FAZ(3);
  return FAZ(4);
}

function shortcutPhase(id) {
  const t = id.toLowerCase();
  if (/command palette|^⌘,|settings|version history|check for updates|modals:|menus:|resize handles|segmented/.test(t)) return FAZ(4);
  if (/^editor:|review dialog|⌘o open file|⌘n new file|⌘w|reopen closed tab|file tree/.test(t)) return FAZ(3);
  return FAZ(2);
}

// ---------- extractors (each returns [{kind,id,source,phase}]) ----------
function extractCommands(root) {
  const rel = "src-tauri/src/lib.rs";
  const text = read(root, rel);
  const at = text.indexOf("generate_handler![");
  if (at < 0) throw new Error("generate_handler! not found in lib.rs");
  let i = at + "generate_handler![".length, depth = 1, j = i;
  while (j < text.length && depth > 0) {
    if (text[j] === "[") depth++;
    else if (text[j] === "]") depth--;
    j++;
  }
  const body = text.slice(i, j - 1).replace(/\/\/[^\n]*/g, "");
  const rustFiles = walk(root, "src-tauri/src", [".rs"]);
  const rustText = new Map(rustFiles.map((f) => [f, read(root, f)]));
  const items = [];
  for (const raw of body.split(",")) {
    const entry = raw.trim();
    if (!entry) continue;
    const parts = entry.split("::");
    const name = parts[parts.length - 1];
    const mod = parts.length > 1 ? parts[parts.length - 2] : "";
    let src = rel;
    const prefer = mod ? [`src-tauri/src/${mod}.rs`] : [];
    const candidates = [...prefer, ...rustFiles];
    for (const f of candidates) {
      const t = rustText.get(f);
      const m = t && new RegExp(`\\bfn\\s+${name}\\b`).exec(t);
      if (m) { src = `${f}:${lineOf(t, m.index)}`; break; }
    }
    items.push({ kind: "command", id: name, source: src, phase: commandPhase(mod || path.basename(src.split(":")[0], ".rs"), name) });
  }
  return items;
}

export function extractEvents(root) {
  const items = new Map();
  // Emitters live in src-tauri (shell) and in native/crates/* (bridge, fs watcher moved there).
  const roots = ["src-tauri/src"];
  if (exists(root, "native/crates")) {
    for (const c of fs.readdirSync(path.join(root, "native/crates")).sort()) roots.push(`native/crates/${c}/src`);
  }
  const files = roots.flatMap((r) => walk(root, r, [".rs"]));
  for (const f of files) {
    const t = read(root, f);
    const consts = new Map();
    for (const m of t.matchAll(/const\s+([A-Z_0-9]+)\s*:\s*&str\s*=\s*"([^"]+)"/g)) consts.set(m[1], m[2]);
    const re = /\.emit(?:_to)?\(\s*(?:[^"(),]+,\s*)?(?:"([^"]+)"|([A-Z][A-Z_0-9]+))/g;
    for (const m of t.matchAll(re)) {
      const name = m[1] ?? consts.get(m[2]);
      if (!name || items.has(name)) continue;
      items.set(name, { kind: "event", id: name, source: `${f}:${lineOf(t, m.index)}`, phase: eventPhase(name) });
    }
  }
  return [...items.values()].sort((a, b) => a.id.localeCompare(b.id));
}

function extractLocalStorage(root) {
  const keys = new Map();
  const files = walk(root, "src", [".ts", ".tsx"]).filter((f) => !/\.test\.|^src\/mock\//.test(f));
  const re = /["'`]((?:apex|muya)\.[A-Za-z0-9_.-]+)["'`]/g;
  for (const f of files) {
    const t = read(root, f);
    for (const m of t.matchAll(re)) {
      if (keys.has(m[1])) continue;
      keys.set(m[1], { kind: "localstorage", id: m[1], source: `${f}:${lineOf(t, m.index)}`, phase: localStoragePhase(m[1]) });
    }
    // template-built keys, e.g. `apex.composerHistory.${kind}`
    for (const m of t.matchAll(/`((?:apex|muya)\.[A-Za-z0-9_.-]+\.)\$\{[^}]+\}`/g)) {
      const id = `${m[1]}<kind>`;
      if (!keys.has(id)) keys.set(id, { kind: "localstorage", id, source: `${f}:${lineOf(t, m.index)}`, phase: localStoragePhase(id) });
    }
  }
  return [...keys.values()].sort((a, b) => a.id.localeCompare(b.id));
}

function extractViewers(root) {
  const rel = "src/lib/format.ts";
  const t = read(root, rel);
  const m = /export function viewerKindFor\([^)]*\)\s*:\s*([^{]+)\{/.exec(t);
  const line = m ? lineOf(t, m.index) : 1;
  const kinds = m ? [...m[1].matchAll(/"([a-z]+)"/g)].map((x) => x[1]) : [];
  return kinds.map((k) => ({ kind: "viewer", id: k, source: `${rel}:${line}`, phase: FAZ(3) }));
}

function extractTokenGroups(root) {
  const rel = "src/styles/tokens.css";
  const t = read(root, rel);
  const groups = new Map();
  const re = /^\s*--([a-z0-9]+)(?:-[a-z0-9-]*)?\s*:/gm;
  for (const m of t.matchAll(re)) {
    const g = `--${m[1]}`;
    const g0 = groups.get(g) ?? { count: 0, line: lineOf(t, m.index) };
    g0.count++;
    groups.set(g, g0);
  }
  return [...groups.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([g, v]) => ({
    kind: "token-group", id: g, source: `${rel}:${v.line}`, phase: FAZ(2),
  }));
}

function extractSchemes(root) {
  const rel = "src/theme/terminalThemes.ts";
  const t = read(root, rel);
  const at = t.indexOf("TERMINAL_SCHEMES");
  const end = t.indexOf("] as const", at);
  const out = [];
  for (const m of t.slice(at, end).matchAll(/id:\s*"([^"]+)"/g)) {
    out.push({ kind: "terminal-scheme", id: m[1], source: `${rel}:${lineOf(t, at + m.index)}`, phase: FAZ(2) });
  }
  return out;
}

const INV_FE = "docs/native/inventory-frontend.md";

function extractViews(root, md) {
  const sec = section(md, /^## 1\. Screens/);
  return mdTable(sec).map(({ cells, line }) => {
    const id = stripMd(cells[0]);
    return { kind: "view", id, source: `${INV_FE}:${line}`, phase: viewPhase(id) };
  });
}

function extractSettingsRows(root, md) {
  const sec = section(md, /^## 6\. Modals/);
  return mdTable(sec).filter(({ cells }) => /^\d+$/.test(cells[0])).map(({ cells, line }) => {
    const id = `${stripMd(cells[1])}: ${stripMd(cells[2]).replace(/\s*\(helper.*$/, "")}`;
    return { kind: "settings-row", id, source: `${INV_FE}:${line}`, phase: FAZ(4) };
  });
}

function extractDialogs(root, md) {
  const sec = section(md, /^## 6\. Modals/);
  const items = [];
  const start = sec.lines.findIndex((l) => /^Dialogs and popovers/.test(l));
  for (let i = start + 1; i < sec.lines.length; i++) {
    const l = sec.lines[i];
    if (/^Settings rows/.test(l)) break;
    const m = /^(\d+)\.\s+(.*)$/.exec(l);
    if (!m) continue;
    const num = Number(m[1]);
    const line = sec.start + i + 1;
    const text = m[2];
    const push = (id) => {
      id = stripMd(id).replace(/\s*\(.*$/, "").replace(/[.:;,\s]+$/, "").trim();
      if (id) items.push({ kind: "dialog", id, source: `${INV_FE}:${line}`, phase: dialogPhase(id) });
    };
    if (num === 20) text.split(";").forEach(push);
    else if (num === 21) text.replace(/^Toasts:\s*/, "").split(",").forEach((s) => push(`Toast: ${s.trim()}`));
    else push(text.split(":")[0].replace(/\s*\(.*$/, "") || text);
  }
  return items;
}

function extractShortcuts(root, md) {
  const sec = section(md, /^## 7\. Keyboard shortcuts/);
  const items = [];
  const seen = new Set();
  const add = (id, i) => {
    id = stripMd(id).replace(/\s*\(.*$/, "").replace(/[.;\s]+$/, "").trim();
    if (!id) return;
    let u = id, n = 2;
    while (seen.has(u)) u = `${id} (${n++})`;
    seen.add(u);
    items.push({ kind: "shortcut", id: u, source: `${INV_FE}:${sec.start + i + 1}`, phase: shortcutPhase(u) });
  };
  sec.lines.forEach((l, i) => {
    if (/^- /.test(l)) return add(l.slice(2), i);
    if (/^Native menu items/.test(l)) {
      const body = l.replace(/^Native menu items[^:]*:\s*/, "");
      return body.replace("⌘, Settings", "⌘\u0000 Settings").split(/,\s+/).forEach((p) => add(`Menu ${p.replace("\u0000", ",")}`, i));
    }
    if (/^Composer:/.test(l)) {
      return l.split(/\.\s+(?=[A-Z])/).forEach((p) => add(p.replace(/\.$/, ""), i));
    }
  });
  return items;
}

export function extractAll(root = REPO) {
  const md = read(root, INV_FE);
  const all = [
    ...extractCommands(root),
    ...extractEvents(root),
    ...extractShortcuts(root, md),
    ...extractDialogs(root, md),
    ...extractSettingsRows(root, md),
    ...extractLocalStorage(root),
    ...extractViews(root, md),
    ...extractViewers(root),
    ...extractTokenGroups(root),
    ...extractSchemes(root),
  ];
  // enforce unique kind+id and relative paths
  const seen = new Set();
  return all.map((r) => {
    let id = r.id, n = 2;
    while (seen.has(`${r.kind}\0${id}`)) id = `${r.id} (${n++})`;
    seen.add(`${r.kind}\0${id}`);
    if (r.source.startsWith("/")) throw new Error(`absolute path in ${r.kind} ${id}`);
    return { ...r, id, status: "todo", evidence: "" };
  });
}

// ---------- render / parse ----------
export function render(rows, notes = {}) {
  const counts = KINDS.map(([k, title]) => [k, title, rows.filter((r) => r.kind === k).length]);
  const out = [];
  out.push("# Native rewrite parity list", "");
  out.push("Generated by `native/tools/gen-parity.mjs` from source code (Tauri handlers, emit calls, localStorage keys,");
  out.push("tokens.css, terminalThemes.ts) and from `docs/native/inventory-frontend.md` (views, shortcuts, dialogs,");
  out.push("Settings rows). Do not hand-edit ids, sources or phases. Edit only the `status` and `evidence` columns.", "");
  out.push("Regenerate: `node native/tools/gen-parity.mjs` (status/evidence of rows that still exist are preserved).");
  out.push("Gate: `node native/tools/gen-parity.mjs --check` exits 1 if a `done` or `verified` row has an empty evidence column.");
  out.push("Evidence = an automated test id or a screenshot path. Status values: `todo`, `wip`, `done`, `verified`, `dropped`.", "");
  out.push("| Kind | Rows |", "|---|---|");
  for (const [, title, n] of counts) out.push(`| ${title} | ${n} |`);
  out.push(`| **Total** | **${rows.length}** |`, "");
  for (const [k, title] of KINDS) {
    const rs = rows.filter((r) => r.kind === k);
    out.push(`## ${title}`, "");
    if (notes[k]) out.push(notes[k], "");
    out.push("| id | source | phase | status | evidence |", "|---|---|---|---|---|");
    for (const r of rs) out.push(`| ${cell(r.id)} | ${cell(r.source)} | ${r.phase} | ${r.status} | ${cell(r.evidence)} |`);
    out.push("");
  }
  return out.join("\n");
}

export function parse(md) {
  const rows = [];
  let kind = null;
  for (const l of md.split("\n")) {
    const h = /^## (.*)$/.exec(l);
    if (h) { kind = KINDS.find(([, t]) => t === h[1].trim())?.[0] ?? null; continue; }
    if (!kind || !l.startsWith("|")) continue;
    const c = l.split(/(?<!\\)\|/).slice(1, -1).map(uncell);
    if (c.length !== 5 || c[0] === "id" || /^-+$/.test(c[0])) continue;
    rows.push({ kind, id: c[0], source: c[1], phase: c[2], status: c[3], evidence: c[4] });
  }
  return rows;
}

export function mergePreserved(fresh, old) {
  const prev = new Map(old.map((r) => [`${r.kind}\0${r.id}`, r]));
  return fresh.map((r) => {
    const p = prev.get(`${r.kind}\0${r.id}`);
    return p ? { ...r, status: p.status, evidence: p.evidence } : r;
  });
}

export function check(md) {
  return parse(md).filter((r) => DONE_STATES.has(r.status) && r.evidence.trim() === "");
}

// ---------- main ----------
function main(argv) {
  const root = REPO;
  const outPath = path.join(root, OUT_REL);
  if (argv.includes("--check")) {
    if (!fs.existsSync(outPath)) { console.error(`${OUT_REL} missing; run the generator first`); return 1; }
    const bad = check(fs.readFileSync(outPath, "utf8"));
    if (bad.length) {
      console.error(`parity check FAILED: ${bad.length} row(s) marked done/verified without evidence`);
      for (const r of bad) console.error(`  ${r.kind} | ${r.id} | ${r.status} | ${r.source}`);
      return 1;
    }
    console.log("parity check OK");
    return 0;
  }
  const fresh = extractAll(root);
  const old = fs.existsSync(outPath) ? parse(fs.readFileSync(outPath, "utf8")) : [];
  const rows = mergePreserved(fresh, old);
  const md = render(rows);
  if (/\/Users\//.test(md)) throw new Error("output contains an absolute path");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, md);
  for (const [k, , n] of KINDS.map(([k, t]) => [k, t, rows.filter((r) => r.kind === k).length])) console.log(`${k}: ${n}`);
  console.log(`total: ${rows.length}`);
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exit(main(process.argv.slice(2)));
}
