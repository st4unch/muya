// Parses what the user actually sees on a Claude Code terminal screen.
// Formats verified against `claude` v2.1.285 (see __fixtures__/claude-screens/).
// Pure and conservative: unknown or ambiguous layouts yield undefined fields.

export type ScreenMode = "bypass" | "acceptEdits" | "plan" | "auto" | "default";

export interface ScreenActivity {
  verb: string; // e.g. "Unfurling…"
  glyph: string;
  elapsed?: string; // "4m 15s"
  tokens?: string; // "16.9k"
  thought?: string; // "3s" (from "thought for 3s")
  thinking?: boolean; // "· thinking" status
}

export type PermissionKind = "approve" | "approveAlways" | "deny";

export interface PermissionOption {
  key: string; // digit to press, e.g. "1"
  label: string;
  kind: PermissionKind;
}

export interface ScreenPermission {
  tool: string; // "Bash" | "Write" | "Edit" | ... (or the dialog title if unknown)
  target: string; // file path or command (first line)
  question: string;
  options: PermissionOption[];
}

export interface ScreenState {
  activity?: ScreenActivity;
  mode: ScreenMode;
  /** true only when a mode footer was actually seen (dialogs hide the footer). */
  modeDetected: boolean;
  permission?: ScreenPermission;
}

const SPINNER_GLYPHS = "·✢✳✶✻✽*";
const ACTIVITY_RE = new RegExp(
  `^\\s*([${SPINNER_GLYPHS}])\\s+(\\p{Lu}[\\p{L}-]*…)\\s*(?:\\((.*)\\))?\\s*$`,
  "u",
);
const MODE_RE = /^\s*(?:⏵⏵|⏸)\s+(bypass permissions|accept edits|plan mode|auto mode|manual mode) on\b/;
const QUESTION_RE = /^\s*(Do you want to .+\?)\s*$/;
const OPTION_RE = /^\s*(?:❯\s*)?(\d{1,2})\.\s+(\S.*?)\s*$/;
const SEPARATOR_RE = /^\s*[─╌]{10,}\s*$/;
const ELAPSED_RE = /^(?:\d+h\s+)?(?:\d+m\s+)?\d+s$/;

const MODE_MAP: Record<string, ScreenMode> = {
  "bypass permissions": "bypass",
  "accept edits": "acceptEdits",
  "plan mode": "plan",
  "auto mode": "auto",
  "manual mode": "default",
};

const FOOTER_WINDOW = 5; // footer lives in the last few non-empty rows

function tailNonEmpty(lines: string[], n: number): string[] {
  const out: string[] = [];
  for (let i = lines.length - 1; i >= 0 && out.length < n; i--) {
    if (lines[i].trim() !== "") out.push(lines[i]);
  }
  return out;
}

function parseMode(lines: string[]): ScreenMode | undefined {
  for (const l of tailNonEmpty(lines, FOOTER_WINDOW)) {
    const m = MODE_RE.exec(l);
    if (m) return MODE_MAP[m[1]];
  }
  return undefined;
}

function parseActivity(lines: string[]): ScreenActivity | undefined {
  const footerBusy = tailNonEmpty(lines, FOOTER_WINDOW).some((l) => /esc to interrupt/.test(l));
  for (let i = lines.length - 1; i >= 0; i--) {
    const m = ACTIVITY_RE.exec(lines[i]);
    if (!m) continue;
    const act: ScreenActivity = { verb: m[2], glyph: m[1] };
    let hasMetric = false;
    if (m[3]) {
      for (const seg of m[3].split(" · ").map((s) => s.trim())) {
        if (ELAPSED_RE.test(seg)) {
          act.elapsed = seg;
          hasMetric = true;
          continue;
        }
        const tok = /^[↑↓]\s*([\d.,]+k?)\s*tokens?$/i.exec(seg);
        if (tok) {
          act.tokens = tok[1];
          hasMetric = true;
          continue;
        }
        const th = /^thought for (.+)$/i.exec(seg);
        if (th) {
          act.thought = th[1];
          hasMetric = true;
          continue;
        }
        if (/^thinking$/i.test(seg)) {
          act.thinking = true;
          hasMetric = true;
        }
      }
    }
    // Guard against bullet-list prose: need a busy footer or spinner metrics.
    if (!footerBusy && !hasMetric) continue;
    return act;
  }
  return undefined;
}

function classify(label: string): PermissionKind | undefined {
  if (/^No\b/i.test(label)) return "deny";
  if (/^Yes\b/i.test(label)) {
    if (/^Yes,\s+and\b/i.test(label) || /don't ask again|for this session/i.test(label)) return "approveAlways";
    return "approve";
  }
  return undefined;
}

function toolFromTitle(title: string): string {
  if (/^Bash command$/i.test(title)) return "Bash";
  if (/^Create file$/i.test(title)) return "Write";
  if (/^(Edit|Update) file$/i.test(title)) return "Edit";
  if (/^Read file$/i.test(title)) return "Read";
  return title;
}

function parsePermission(lines: string[]): ScreenPermission | undefined {
  for (let q = lines.length - 1; q >= 0; q--) {
    const qm = QUESTION_RE.exec(lines[q]);
    if (!qm) continue;

    // Options directly under the question; wrapped labels continue on indented lines.
    const options: PermissionOption[] = [];
    let sawEsc = false;
    let i = q + 1;
    for (; i < lines.length; i++) {
      const l = lines[i];
      if (l.trim() === "") break;
      if (/Esc to cancel/.test(l)) {
        sawEsc = true;
        break;
      }
      const om = OPTION_RE.exec(l);
      if (om) {
        const kind = classify(om[2]);
        if (!kind) return undefined;
        options.push({ key: om[1], label: om[2], kind });
      } else if (options.length > 0 && /^\s{4,}\S/.test(l)) {
        options[options.length - 1].label += " " + l.trim();
      } else {
        return undefined;
      }
    }
    if (!sawEsc) {
      // Allow the footer one blank line below the options.
      const next = lines.slice(i, i + 3).some((l) => /Esc to cancel/.test(l));
      if (!next) continue;
    }
    if (options.length < 2) continue;
    if (options[0].key !== "1" || options[0].kind !== "approve") continue;
    if (options[options.length - 1].kind !== "deny") continue;
    // Keys must be 1..N consecutive.
    if (!options.every((o, idx) => o.key === String(idx + 1))) continue;

    // Find the dialog's top separator, then read title + target below it.
    let sep = -1;
    for (let j = q - 1; j >= 0; j--) {
      if (SEPARATOR_RE.test(lines[j]) && /^\s*─{10,}\s*$/.test(lines[j])) {
        sep = j;
        break;
      }
    }
    let tool = "";
    let target = "";
    if (sep >= 0) {
      const body = lines.slice(sep + 1, q).map((l) => l.trim());
      const title = body.find((l) => l !== "") ?? "";
      tool = toolFromTitle(title);
      const rest = body.slice(body.indexOf(title) + 1).filter((l) => l !== "" && !/^Tip:/.test(l) && !SEPARATOR_RE.test(l));
      target = rest[0] ?? "";
    }
    return { tool, target, question: qm[1], options };
  }
  return undefined;
}

export function parseClaudeScreen(lines: string[]): ScreenState {
  const detected = parseMode(lines);
  const permission = parsePermission(lines);
  const activity = permission ? undefined : parseActivity(lines);
  return {
    ...(activity ? { activity } : {}),
    mode: detected ?? "default",
    modeDetected: detected !== undefined,
    ...(permission ? { permission } : {}),
  };
}

interface LineLike {
  translateToString(trimRight?: boolean): string;
}
export interface TerminalLike {
  buffer: { active: { length: number; viewportY: number; getLine(i: number): LineLike | undefined } };
  rows: number;
}

/** Visible viewport lines (top to bottom), right-trimmed. Works with @xterm/xterm and @xterm/headless. */
export function readScreenLines(term: TerminalLike): string[] {
  const buf = term.buffer.active;
  const out: string[] = [];
  for (let i = 0; i < term.rows; i++) {
    const idx = buf.viewportY + i;
    if (idx >= buf.length) break;
    out.push(buf.getLine(idx)?.translateToString(true) ?? "");
  }
  return out;
}
