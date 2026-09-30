import { describe, expect, it } from "vitest";
import {
  ANSWERED_GRACE_MS,
  abbreviateHome,
  buildAgents,
  countAgents,
  deriveMode,
  formatSince,
  normalizeTokens,
  pickGridPanels,
  realBranch,
  recordTransitions,
  type AgentModelInput,
  type AgentTab,
} from "./agentModel";
import type { ScreenState } from "../lib/screenState";

const tab = (key: string, extra: Partial<AgentTab> = {}): AgentTab => ({ key, name: key, kind: "terminal", cwd: "/Users/someone/proj", ...extra });

const WRITE_DIALOG: ScreenState = {
  mode: "default",
  modeDetected: false,
  permission: {
    tool: "Write",
    target: "hello.txt",
    question: "Do you want to create hello.txt?",
    options: [
      { key: "1", label: "Yes", kind: "approve" },
      { key: "2", label: "Yes, and switch to accept edits", kind: "approveAlways" },
      { key: "3", label: "No", kind: "deny" },
    ],
  },
};
const SPINNER: ScreenState = { mode: "bypass", modeDetected: true, activity: { verb: "Unfurling…", glyph: "✻", elapsed: "4m 15s", tokens: "16.9k", thought: "3s" } };

function input(over: Partial<AgentModelInput> = {}): AgentModelInput {
  return { tabs: [], sessionStatus: {}, screens: {}, lastModes: {}, liveCwds: {}, branchByCwd: {}, answered: {}, stamps: {}, now: 1_000_000, ...over };
}

describe("formatting", () => {
  it("abbreviates any user's home directory, not just one", () => {
    expect(abbreviateHome("/Users/alice/Documents/x")).toBe("~/Documents/x");
    expect(abbreviateHome("/home/bob/x")).toBe("~/x");
    expect(abbreviateHome("/Users/alice")).toBe("~");
    expect(abbreviateHome("/opt/tool")).toBe("/opt/tool");
  });
  it("formats waiting durations coarsely", () => {
    expect(formatSince(5_000)).toBe("<1m");
    expect(formatSince(60_000)).toBe("1m");
    expect(formatSince(65 * 60_000)).toBe("1h 5m");
    expect(formatSince(50 * 3600_000)).toBe("2d");
  });
  it("normalizes parser token strings", () => {
    expect(normalizeTokens("16.9k")).toBe("16.9k tokens");
    expect(normalizeTokens("↓ 2 tokens")).toBe("2 tokens");
    expect(normalizeTokens(undefined)).toBeUndefined();
  });
});

describe("buildAgents", () => {
  it("only terminal tabs are agents (files are not)", () => {
    const agents = buildAgents(input({ tabs: [tab("a"), { ...tab("f"), kind: "editor" }] }));
    expect(agents.map((a) => a.key)).toEqual(["a"]);
  });

  it("a parsed permission dialog means waiting NOW, before the slow session poll notices", () => {
    const [a] = buildAgents(input({ tabs: [tab("a")], screens: { a: WRITE_DIALOG } }));
    expect(a.status).toBe("waiting");
    expect(a.activity).toBe("Needs permission: Write");
    expect(a.approval).toMatchObject({ tool: "Write", target: "hello.txt", summary: "wants to write a file", actionable: true });
  });

  it("polled waiting-for-input without a readable dialog: waiting, buttons disabled", () => {
    const [a] = buildAgents(input({ tabs: [tab("a")], sessionStatus: { a: "waiting-for-input" } }));
    expect(a.status).toBe("waiting");
    expect(a.approval?.actionable).toBe(false);
    expect(a.activity).toBe("Needs permission: permission prompt");
  });

  it("after the operator answers, a stale polled 'waiting' is ignored for a grace period", () => {
    const base = { tabs: [tab("a")], sessionStatus: { a: "waiting-for-input" as const }, answered: { a: 1_000_000 } };
    expect(buildAgents(input({ ...base, now: 1_000_000 + 1000 }))[0].status).toBe("idle");
    expect(buildAgents(input({ ...base, now: 1_000_000 + ANSWERED_GRACE_MS + 1 }))[0].status).toBe("waiting");
  });

  it("a spinner line means working, with verb, tokens and elapsed", () => {
    const [a] = buildAgents(input({ tabs: [tab("a")], screens: { a: SPINNER } }));
    expect(a.status).toBe("working");
    expect(a.activity).toBe("Unfurling… · 16.9k tokens");
    expect(a.since).toBe("4m 15s");
    expect(a.progress).toEqual({ verb: "Unfurling…", elapsed: "4m 15s", tokens: "16.9k tokens", thought: "3s" });
  });

  it("polled working without a parse still shows a truthful generic line", () => {
    const [a] = buildAgents(input({ tabs: [tab("a")], sessionStatus: { a: "working" } }));
    expect(a.status).toBe("working");
    expect(a.activity).toBe("Working…");
    expect(a.since).toBeUndefined();
  });

  it("uses the live cwd (abbreviated) and the branch known for it", () => {
    const [a] = buildAgents(input({ tabs: [tab("a")], liveCwds: { a: "/Users/x/repo" }, branchByCwd: { "/Users/x/repo": "main" } }));
    expect(a.path).toBe("~/repo");
    expect(a.branch).toBe("main");
  });

  it("classifies the CLI kind", () => {
    const kinds = buildAgents(input({ tabs: [tab("s", { sshServerId: "x" }), tab("o", { agent: "opencode" }), tab("c", { isClaude: true }), tab("p")] })).map((a) => a.kind);
    expect(kinds).toEqual(["ssh", "opencode", "claude", "shell"]);
  });

  it("shows the wait time from the transition stamp", () => {
    const [a] = buildAgents(input({ tabs: [tab("a")], screens: { a: WRITE_DIALOG }, stamps: { a: { status: "waiting", at: 1_000_000 - 120_000 } } }));
    expect(a.since).toBe("2m");
  });
});

describe("mode", () => {
  const t = tab("a");
  it("reads the footer when it is visible", () => {
    expect(deriveMode(t, { mode: "plan", modeDetected: true })).toBe("plan");
  });
  it("keeps the last known mode while a dialog hides the footer (does not flip to default)", () => {
    expect(deriveMode(t, { mode: "default", modeDetected: false }, "acceptEdits")).toBe("acceptEdits");
  });
  it("falls back to the launch flag when nothing was ever seen", () => {
    expect(deriveMode(tab("a", { initialCommand: "claude --dangerously-skip-permissions" }), undefined)).toBe("bypass");
    expect(deriveMode(t, undefined)).toBe("default");
  });
});

describe("recordTransitions", () => {
  it("stamps only on a change and keeps object identity otherwise", () => {
    const a1 = recordTransitions({}, [{ key: "a", status: "idle" }], 10);
    expect(a1.a).toEqual({ status: "idle", at: 10 });
    expect(recordTransitions(a1, [{ key: "a", status: "idle" }], 99)).toBe(a1);
    expect(recordTransitions(a1, [{ key: "a", status: "waiting" }], 50).a).toEqual({ status: "waiting", at: 50 });
  });
  it("honours a stored wait clock for a waiting agent and drops closed tabs", () => {
    const next = recordTransitions({ gone: { status: "idle", at: 1 } }, [{ key: "a", status: "waiting" }], 500, { a: 100 });
    expect(next.a.at).toBe(100);
    expect(next.gone).toBeUndefined();
  });
});

describe("counts and grid panels", () => {
  const list = buildAgents(input({ tabs: [tab("a"), tab("b"), tab("c"), tab("d")], screens: { a: WRITE_DIALOG, b: SPINNER } }));
  it("one model, one set of numbers", () => {
    expect(countAgents(list)).toEqual({ agents: 4, working: 1, waiting: 1 });
  });
  it("panels: chosen first, topped up in list order, capped", () => {
    expect(pickGridPanels(list, ["c", "gone"], 3).map((a) => a.key)).toEqual(["c", "a", "b"]);
    expect(pickGridPanels(list, [], 2).map((a) => a.key)).toEqual(["a", "b"]);
  });
});


describe("realBranch", () => {
  it("drops the backend's not-a-repo placeholder", () => {
    expect(realBranch("—")).toBeUndefined();
    expect(realBranch("")).toBeUndefined();
    expect(realBranch(undefined)).toBeUndefined();
    expect(realBranch("main")).toBe("main");
  });
});
