import { describe, it, expect } from "vitest";
import { pickNextActiveKey, newSshTabKey, addSshSession, canResumeTab, resumeCommand, pushClosed, reopenSpec, MAX_CLOSED_TABS, type ClosedTab, type TabLike } from "./tabs";
import { singleQuote } from "./agent";

const T = (key: string, kind: TabLike["kind"]): TabLike => ({ key, kind });

describe("pickNextActiveKey — closing a file never lands on a terminal", () => {
  const tabs = [T("f1", "editor"), T("f2", "editor"), T("f3", "editor"), T("t1", "terminal")];

  it("closing a middle file focuses the adjacent file, not the terminal", () => {
    // REGRESSION: it used to jump to the terminal, so the next ⌘W killed it.
    expect(pickNextActiveKey(tabs, "f2")).toBe("f1"); // nearest same-kind before
  });

  it("closing the last file focuses the previous file", () => {
    expect(pickNextActiveKey(tabs, "f3")).toBe("f2");
  });

  it("closing the first file focuses the next file", () => {
    expect(pickNextActiveKey(tabs, "f1")).toBe("f2");
  });

  it("only falls back to a terminal when no files remain", () => {
    expect(pickNextActiveKey([T("f1", "editor"), T("t1", "terminal")], "f1")).toBe("t1");
  });

  it("closing a terminal prefers another terminal", () => {
    const two = [T("t1", "terminal"), T("f1", "editor"), T("t2", "terminal")];
    expect(pickNextActiveKey(two, "t1")).toBe("t2");
  });

  it("returns null when the last tab is closed", () => {
    expect(pickNextActiveKey([T("f1", "editor")], "f1")).toBeNull();
  });
});

describe("SSH multi-session — Connect opens independent parallel terminals (L28)", () => {
  interface Tab { key: string; sshServerId?: string }

  it("newSshTabKey is prefixed for the server and unique per call", () => {
    const a = newSshTabKey("srv1");
    const b = newSshTabKey("srv1");
    expect(a.startsWith("ssh:srv1:")).toBe(true); // duplicate/restore still recognise it
    expect(a).not.toBe(b);
  });

  it("stays unique even for two Connects in the same millisecond", () => {
    // REGRESSION: a timestamp-only key collided on a fast double-click, so the
    // second tab deduped away. The random suffix keeps them distinct.
    let r = 0;
    const rand = () => [0.11, 0.99][r++]; // fixed values, same `now`
    const a = newSshTabKey("srv1", 1000, rand);
    const b = newSshTabKey("srv1", 1000, rand);
    expect(a).not.toBe(b);
  });

  it("addSshSession keeps the server's existing tab — a 2nd terminal to one host", () => {
    // REGRESSION: openSshServer filtered out `ssh:<id>*` on every Connect, so a
    // second session to the SAME host replaced the first instead of coexisting.
    const prev: Tab[] = [{ key: "ssh:hostA:1", sshServerId: "hostA" }];
    const next = addSshSession(prev, { key: "ssh:hostA:2", sshServerId: "hostA" });
    expect(next.map((t) => t.key)).toEqual(["ssh:hostA:1", "ssh:hostA:2"]);
  });

  it("addSshSession never drops a different host's tab either", () => {
    const prev: Tab[] = [{ key: "ssh:hostA:1", sshServerId: "hostA" }];
    const next = addSshSession(prev, { key: "ssh:hostB:1", sshServerId: "hostB" });
    expect(next).toHaveLength(2);
    expect(next.some((t) => t.sshServerId === "hostA")).toBe(true);
    expect(next.some((t) => t.sshServerId === "hostB")).toBe(true);
  });
});

describe("canResumeTab: restore must not depend on the volatile isClaude flag", () => {
  it("resumes on sessionId alone, even when isClaude is false (the v0.2.41 regression)", () => {
    // A stale CLI made session discovery return nothing, so isClaude was persisted
    // false on every tab. The tab still knows its conversation — it must resume.
    expect(canResumeTab({ kind: "terminal", sessionId: "abc-123" })).toBe(true);
  });

  it("does not resume a tab that never held a session", () => {
    expect(canResumeTab({ kind: "terminal" })).toBe(false);
    expect(canResumeTab({ kind: "terminal", sessionId: "" })).toBe(false);
  });

  it("never resumes a non-terminal tab (editor/viewer)", () => {
    expect(canResumeTab({ kind: "editor", sessionId: "abc-123" })).toBe(false);
  });
});

describe("resumeCommand: resume where the session actually ran", () => {
  it("cds into the recorded session folder first", () => {
    expect(resumeCommand({ sessionId: "abc-123", sessionCwd: "/tmp/muya live's demo" }, singleQuote)).toBe(
      `cd '/tmp/muya live'\\''s demo' && claude --resume 'abc-123' --dangerously-skip-permissions`,
    );
  });
  it("falls back to the tab's own folder when none was recorded (older saved tabs)", () => {
    expect(resumeCommand({ sessionId: "abc-123" }, singleQuote)).toBe(
      "claude --resume 'abc-123' --dangerously-skip-permissions",
    );
  });
});

describe("reopen closed tabs (⌘⇧T)", () => {
  const q = (s: string) => `'${s}'`;

  it("keeps the newest 20, newest last", () => {
    let stack: ClosedTab[] = [];
    for (let i = 0; i < 25; i++) stack = pushClosed(stack, { key: `k${i}`, name: `n${i}`, kind: "terminal" });
    expect(stack).toHaveLength(MAX_CLOSED_TABS);
    expect(stack[0].key).toBe("k5");
    expect(stack[stack.length - 1].key).toBe("k24");
  });

  it("a file comes back as the same tab", () => {
    const f: ClosedTab = { key: "mdview:/p/a.md", name: "a.md", kind: "mdview", filePath: "/p/a.md" };
    expect(reopenSpec(f, q, 1)).toEqual(f);
  });

  it("a Claude tab resumes its own conversation in its session folder", () => {
    const s = reopenSpec({ key: "claude-1", name: "api", kind: "terminal", cwd: "/p", sessionId: "abc", sessionCwd: "/p/sub", initialCommand: "claude" }, q, 7);
    expect(s.key).toBe("reopen-7");
    expect(s.initialCommand).toBe("cd '/p/sub' && claude --resume 'abc' --dangerously-skip-permissions");
    expect(s.sessionId).toBe("abc");
    expect(s.cwd).toBe("/p");
  });

  it("an SSH tab reconnects to the same server under a fresh ssh: key", () => {
    const s = reopenSpec({ key: "ssh:srv1:1:aa", name: "prod", kind: "terminal", sshServerId: "srv1" }, q, 9);
    expect(s.key.startsWith("ssh:srv1:9:")).toBe(true);
    expect(s.sshServerId).toBe("srv1");
    expect(s.initialCommand).toBeUndefined();
  });

  it("a plain terminal reopens as a shell in its folder, re-running its command", () => {
    expect(reopenSpec({ key: "term-1", name: "t", kind: "terminal", cwd: "/w" }, q, 3)).toEqual({ key: "reopen-3", name: "t", kind: "terminal", cwd: "/w", userRenamed: undefined, initialCommand: undefined });
    expect(reopenSpec({ key: "claude-2", name: "c", kind: "terminal", cwd: "/w", initialCommand: "claude --dangerously-skip-permissions" }, q, 4).initialCommand).toBe("claude --dangerously-skip-permissions");
  });
});
