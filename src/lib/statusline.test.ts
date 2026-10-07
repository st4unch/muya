import { describe, expect, it, vi } from "vitest";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
import { STATUS_FIELDS, STATUS_GROUPS, fmtBool, fmtDuration, fmtEpoch, fmtLines, fmtPct, fmtTokens, fmtUsd, statusValue, withChannel, withStatusline, CHANNEL_FLAG } from "./statusline";

const q = (s: string) => `'${s.replace(/'/g, "'\\''")}'`;
const P = "/tmp/muya-status-1/settings.json";

describe("withStatusline", () => {
  it("inserts --settings after claude at command start", () => {
    expect(withStatusline("claude --dangerously-skip-permissions", P, q)).toBe(`claude --settings '${P}' --dangerously-skip-permissions`);
    expect(withStatusline("claude", P, q)).toBe(`claude --settings '${P}'`);
  });
  it("handles cd … && claude --resume and ;", () => {
    expect(withStatusline("cd '/a b' && claude --resume 'x' --dangerously-skip-permissions", P, q)).toBe(
      `cd '/a b' && claude --settings '${P}' --resume 'x' --dangerously-skip-permissions`,
    );
    expect(withStatusline("ls; claude -p", P, q)).toBe(`ls; claude --settings '${P}' -p`);
  });
  it("leaves subcommands untouched", () => {
    for (const c of ["claude agents", "claude attach abc", "claude mcp list", "x && claude update", "claude doctor"]) expect(withStatusline(c, P, q)).toBe(c);
  });
  it("quoted prompts are still launches", () => {
    expect(withStatusline('claude "fix it"', P, q)).toBe(`claude --settings '${P}' "fix it"`);
  });
  it("returns the command unchanged without a path", () => {
    expect(withStatusline("claude --resume x", null, q)).toBe("claude --resume x");
    expect(withStatusline("claude --resume x", undefined, q)).toBe("claude --resume x");
  });
  it("quotes a path with spaces and quotes", () => {
    expect(withStatusline("claude", "/Users/a b/it's/s.json", q)).toBe(`claude --settings '/Users/a b/it'\\''s/s.json'`);
  });
  it("does not touch other words or double-apply", () => {
    expect(withStatusline("echo claudex", P, q)).toBe("echo claudex");
    const once = withStatusline("claude -c", P, q);
    expect(withStatusline(once, P, q)).toBe(once);
  });
});

describe("formatters", () => {
  it("formats values for humans", () => {
    expect(fmtUsd(0.1234)).toBe("$0.12");
    expect(fmtDuration(255000)).toBe("4m 15s");
    expect(fmtDuration(4200)).toBe("4s");
    expect(fmtDuration(3_720_000)).toBe("1h 2m");
    expect(fmtPct(41.6)).toBe("42%");
    expect(fmtTokens(16900)).toBe("16.9k");
    expect(fmtTokens(950)).toBe("950");
    expect(fmtTokens(1_200_000)).toBe("1.2M");
    expect(fmtBool(true)).toBe("on");
    expect(fmtBool(false)).toBe("off");
    expect(fmtLines(156, 23)).toBe("+156 −23");
  });
  it("formats epoch resets", () => {
    const sec = new Date(2026, 0, 5, 18, 30).getTime() / 1000; // Monday
    expect(fmtEpoch(sec)).toBe("18:30");
    expect(fmtEpoch(sec, true)).toBe("Mon 18:30");
    expect(statusValue("rate_limits.five_hour.resets_at", { rate_limits: { five_hour: { resets_at: sec } } })).toBe("resets 18:30");
    expect(statusValue("rate_limits.seven_day.resets_at", { rate_limits: { seven_day: { resets_at: sec } } })).toBe("resets Mon 18:30");
  });
  it("field values", () => {
    const d = { cost: { total_cost_usd: 0.1234, total_lines_added: 156, total_lines_removed: 23 }, prompt_cache: { hit_ratio: 0.91, last_miss_cause: { causes: ["tools_changed"] }, miss_causes: { a: 2 } }, workspace: { added_dirs: ["x", "y"], repo: { owner: "o", name: "n" } }, pr: { number: 7 } };
    expect(statusValue("cost.total_cost_usd", d)).toBe("$0.12");
    expect(statusValue("cost.lines", d)).toBe("+156 −23");
    expect(statusValue("prompt_cache.hit_ratio", d)).toBe("91%");
    expect(statusValue("prompt_cache.last_miss_cause", d)).toBe("tools changed");
    expect(statusValue("prompt_cache.miss_causes", d)).toBe("2");
    expect(statusValue("workspace.added_dirs", d)).toBe("2");
    expect(statusValue("workspace.repo", d)).toBe("o/n");
    expect(statusValue("pr.number", d)).toBe("#7");
  });
  it("absent or null fields give null", () => {
    expect(statusValue("model.display_name", {})).toBeNull();
    expect(statusValue("context_window.used_percentage", { context_window: { used_percentage: null } })).toBeNull();
    expect(statusValue("prompt_cache.last_miss_cause", { prompt_cache: { last_miss_cause: null } })).toBeNull();
    expect(statusValue("nope", { a: 1 })).toBeNull();
    expect(statusValue("version", null)).toBeNull();
  });
});

describe("catalogue", () => {
  it("has unique ids and covers every group", () => {
    const ids = STATUS_FIELDS.map((f) => f.id);
    expect(new Set(ids).size).toBe(ids.length);
    for (const g of STATUS_GROUPS) expect(STATUS_FIELDS.some((f) => f.group === g)).toBe(true);
  });
});

describe("withChannel", () => {
  it("adds Muya's channel flag to every claude launch", () => {
    expect(withChannel("claude --dangerously-skip-permissions", true)).toBe(`claude ${CHANNEL_FLAG} --dangerously-skip-permissions`);
    expect(withChannel("cd '/a b' && claude --resume 'x'", true)).toBe(`cd '/a b' && claude ${CHANNEL_FLAG} --resume 'x'`);
    expect(withChannel('claude "fix it"', true)).toBe(`claude ${CHANNEL_FLAG} "fix it"`);
  });

  it("leaves subcommands, other CLIs, unsupported CLIs and already-flagged commands alone", () => {
    for (const c of ["claude attach abc", "claude agents", "opencode --auto", "echo claudex"]) expect(withChannel(c, true)).toBe(c);
    expect(withChannel("claude", false)).toBe("claude");
    const once = withChannel("claude -c", true);
    expect(withChannel(once, true)).toBe(once);
  });

  it("composes with the status tap", () => {
    expect(withChannel(withStatusline("claude -c", "/s.json"), true)).toBe(`claude ${CHANNEL_FLAG} --settings '/s.json' -c`);
  });
});
