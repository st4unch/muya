import { describe, it, expect } from "vitest";
import { pickNextActiveKey, newSshTabKey, addSshSession, type TabLike } from "./tabs";

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
