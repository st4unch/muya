// Created by Claude — Classification: INTERNAL
import { describe, expect, it, vi } from "vitest";

const invoke = vi.fn(async (cmd: string, args?: Record<string, unknown>) => {
  if (cmd === "file_history_read") return `old-${args?.id}`;
  if (cmd === "read_file") return "now";
  if (cmd === "file_history_snapshot") return { id: "x" };
  return null;
});
vi.mock("@tauri-apps/api/core", () => ({ invoke: (cmd: string, args?: Record<string, unknown>) => invoke(cmd, args) }));
import { versionsSource, versionTime } from "./fileVersions";

describe("versionsSource", () => {
  const v = [{ id: "7", at: Date.now(), size: 5, kind: "saved" as const }];
  it("diffs a version against the file now", async () => {
    const src = versionsSource("/r/a.ts", v);
    expect(src.files[0].langPath).toBe("/r/a.ts");
    expect(await src.load(src.files[0])).toEqual({ original: "old-7", modified: "now" });
  });
  it("restore keeps the current text as a version first, then writes the old one", async () => {
    invoke.mockClear();
    const done = vi.fn();
    const src = versionsSource("/r/a.ts", v, done);
    await src.action!.run(src.files[0]);
    const seq = invoke.mock.calls.map((c) => `${c[0]}:${(c[1] as Record<string, string>)?.kind ?? (c[1] as Record<string, string>)?.content ?? ""}`);
    expect(seq.indexOf("file_history_snapshot:before-restore")).toBeLessThan(seq.indexOf("write_file:old-7"));
    expect(invoke).toHaveBeenCalledWith("file_history_snapshot", { path: "/r/a.ts", content: "now", kind: "before-restore" });
    expect(done).toHaveBeenCalled();
  });
  it("shows only the time for today", () => {
    const now = new Date(2026, 9, 16, 15, 0, 0).getTime();
    expect(versionTime(new Date(2026, 9, 16, 14, 5, 9).getTime(), now)).toMatch(/14:05:09/);
    expect(versionTime(new Date(2026, 9, 15, 14, 5, 9).getTime(), now)).toMatch(/14:05$/);
  });
});
