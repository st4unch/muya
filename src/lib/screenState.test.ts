/**
 * OBSERVED KEY MAPPING (claude v2.1.285, recorded via pty, 120x40, `--permission-mode manual`).
 * Pressing a bare digit selects immediately -- NO Enter needed.
 *
 *   File write/edit dialog ("Do you want to create hello.txt?"):
 *     1 = Yes (approve once)              -> file written, mode stays "manual"
 *     2 = "Yes, and switch to accept edits ... for this session" (approve-always;
 *         footer becomes "accept edits on")
 *     3 = No (deny)                       -> "User rejected write to hello.txt"
 *   Bash dialog ("Do you want to proceed?"):
 *     1 = Yes, 2 = "Yes, and don't ask again for <cmds> in <dir>" (approve-always),
 *     3 = "Yes, and switch to auto mode", 4 = No (deny -> "Interrupted").
 *   Rule: the deny option is always the LAST number; approve-once is always "1";
 *   always-variants are the middle options. Read the kinds from parsed options,
 *   do not hardcode numbers.
 *
 * Mode footers observed (Shift+Tab cycles manual -> accept edits -> plan -> auto -> manual):
 *   "⏸ manual mode on", "⏵⏵ accept edits on", "⏸ plan mode on", "⏵⏵ auto mode on",
 *   "⏵⏵ bypass permissions on" (--dangerously-skip-permissions).
 * NOT captured (parsed from the task description, unit-tested with synthetic lines only):
 *   "thought for 3s" and "4m 15s" long-form spinner segments.
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { Terminal } from "@xterm/headless";
import { describe, expect, it } from "vitest";
import { parseBusy, parseClaudeScreen, readScreenLines } from "./screenState";

const DIR = join(__dirname, "__fixtures__", "claude-screens");
const txt = (n: string) => readFileSync(join(DIR, n + ".txt"), "utf8").split("\n").slice(0, 40);

async function renderBin(n: string): Promise<string[]> {
  const term = new Terminal({ cols: 120, rows: 40, allowProposedApi: true, scrollback: 0 });
  await new Promise<void>((r) => term.write(readFileSync(join(DIR, n + ".bin")), r));
  const lines = readScreenLines(term as never);
  term.dispose();
  return lines;
}

describe("modes (real footers)", () => {
  it.each([
    ["mode-manual", "default"],
    ["mode-acceptedits", "acceptEdits"],
    ["mode-plan", "plan"],
    ["mode-auto", "auto"],
    ["mode-bypass", "bypass"],
  ])("%s -> %s", (fx, mode) => {
    const s = parseClaudeScreen(txt(fx));
    expect(s.mode).toBe(mode);
    expect(s.modeDetected).toBe(true);
    expect(s.permission).toBeUndefined();
    expect(s.activity).toBeUndefined();
  });

  it("always-mode after choosing option 2 in the write dialog", () => {
    expect(parseClaudeScreen(txt("perm-write-after-always")).mode).toBe("acceptEdits");
  });
});

describe("activity (real spinners)", () => {
  it("tokens + thinking", () => {
    const a = parseClaudeScreen(txt("spinner-tokens-thinking")).activity;
    expect(a).toMatchObject({ verb: "Noodling…", elapsed: "2s", tokens: "163", thinking: true });
  });
  it("thinking only", () => {
    expect(parseClaudeScreen(txt("spinner-thinking-only")).activity).toMatchObject({ verb: "Misting…", elapsed: "1s" });
  });
  it("bare verb (busy footer)", () => {
    expect(parseClaudeScreen(txt("spinner-bare")).activity).toMatchObject({ verb: "Concocting…" });
  });
  it("hook status inside parens", () => {
    expect(parseClaudeScreen(txt("spinner-hook")).activity).toMatchObject({ verb: "Concocting…", elapsed: "0s" });
  });
  it("completed-turn line is not activity", () => {
    expect(parseClaudeScreen(txt("idle-done")).activity).toBeUndefined();
  });
  it("synthetic long form", () => {
    const a = parseClaudeScreen([
      "✻ Unfurling… (4m 15s · ↓ 16.9k tokens · thought for 3s)",
      "  ⏸ manual mode on · esc to interrupt",
    ]).activity;
    expect(a).toMatchObject({ verb: "Unfurling…", elapsed: "4m 15s", tokens: "16.9k", thought: "3s" });
    expect(parseClaudeScreen(["✶ Pondering… (12s · ↑ 1 token)"]).activity).toMatchObject({ tokens: "1", elapsed: "12s" });
  });
});

describe("permission dialogs (real)", () => {
  it("write dialog", () => {
    const p = parseClaudeScreen(txt("perm-write-dialog")).permission!;
    expect(p.tool).toBe("Write");
    expect(p.target).toBe("hello.txt");
    expect(p.options.map((o) => [o.key, o.kind])).toEqual([
      ["1", "approve"],
      ["2", "approveAlways"],
      ["3", "deny"],
    ]);
  });
  it("bash dialog with wrapped option and 4 choices", () => {
    const s = parseClaudeScreen(txt("perm-bash-dialog"));
    const p = s.permission!;
    expect(p.tool).toBe("Bash");
    expect(p.target).toBe("mkdir sub && touch sub/a.txt && npm --version");
    expect(p.options.map((o) => [o.key, o.kind])).toEqual([
      ["1", "approve"],
      ["2", "approveAlways"],
      ["3", "approveAlways"],
      ["4", "deny"],
    ]);
    expect(p.options[1].label).toContain("sbx_bashlook");
    expect(s.activity).toBeUndefined();
  });
  it("no permission after the dialog is answered", () => {
    for (const f of ["perm-write-after-deny", "perm-write-after-approve", "perm-write-after-always", "perm-bash-after-deny", "perm-bash-after-always"]) {
      expect(parseClaudeScreen(txt(f)).permission, f).toBeUndefined();
    }
  });
});

describe("readScreenLines on a headless terminal", () => {
  it("renders the .bin identically to the saved .txt", async () => {
    const lines = await renderBin("perm-bash-dialog");
    expect(lines.join("\n").trimEnd()).toBe(txt("perm-bash-dialog").join("\n").trimEnd());
    expect(parseClaudeScreen(lines).permission?.tool).toBe("Bash");
  });
  it("modes from .bin", async () => {
    expect(parseClaudeScreen(await renderBin("mode-plan")).mode).toBe("plan");
  });
});

describe("false positives", () => {
  const prose = [
    "⏺ Here is how it works. Bypass permissions on is a mode where 'bypass permissions on' means no prompts.",
    "  Do you want to proceed?",
    "  1. Yes",
    "  2. No",
    "  You can say: bypass permissions on, accept edits on, plan mode on.",
    "",
    "❯ ",
  ];
  it("prose does not yield mode or permission", () => {
    const s = parseClaudeScreen(prose);
    expect(s.mode).toBe("default");
    expect(s.modeDetected).toBe(false);
    expect(s.permission).toBeUndefined();
  });
  it("question + options without Esc footer is not a dialog", () => {
    expect(parseClaudeScreen(["Do you want to create foo?", "❯ 1. Yes", "  2. No", ""]).permission).toBeUndefined();
  });
  it("a bullet with an ellipsis is not activity", () => {
    expect(parseClaudeScreen(["· Loading… is what the docs say", "· Thinking… done"]).activity).toBeUndefined();
    expect(parseClaudeScreen(["✻ Worked for 4s · done 12:58 AM"]).activity).toBeUndefined();
  });
  it("mode footer text quoted mid-screen (no glyph) is ignored", () => {
    expect(parseClaudeScreen(["  accept edits on (shift+tab to cycle)"]).modeDetected).toBe(false);
  });
  it("old dialog scrolled above is still found only if intact; empty screen is empty", () => {
    expect(parseClaudeScreen([])).toEqual({ mode: "default", modeDetected: false });
  });
});

describe("parseBusy (footer 'esc to interrupt')", () => {
  const fixture = (name: string) =>
    readFileSync(join(__dirname, "__fixtures__", "claude-screens", `${name}.txt`), "utf8").split("\n");

  it("is busy on every captured working screen", () => {
    for (const f of ["spinner-bare", "spinner-hook", "spinner-thinking-only", "spinner-tokens-growing", "spinner-tokens-thinking"]) {
      expect(parseBusy(fixture(f)), f).toBe(true);
    }
  });

  it("is not busy on idle or plain mode screens", () => {
    for (const f of ["idle-done", "mode-manual", "mode-acceptedits", "mode-plan", "mode-auto", "mode-bypass"]) {
      expect(parseBusy(fixture(f)), f).toBe(false);
    }
  });

  it("ignores the phrase when it is only in the conversation text", () => {
    const lines = ["  Tip: press esc to interrupt a long answer.", "", "────────", "> ", "────────", "  ⏸ manual mode on · ? for shortcuts"];
    expect(parseBusy(lines)).toBe(false);
  });
});
