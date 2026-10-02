// Created by Claude — Classification: INTERNAL
import { describe, it, expect } from "vitest";
import { asNotifications, detectEvents } from "./agentNotifications";

const none = new Set<string>();
const kinds = (ev: { key: string; kind: string }[]) => ev.map((e) => `${e.key}:${e.kind}`);

describe("bell notifications", () => {
  it("logs waiting and working → idle (finished)", () => {
    const ev = detectEvents(
      { a: "working", b: "working", c: "idle" },
      [{ key: "a", name: "A", status: "idle" }, { key: "b", name: "B", status: "waiting" }, { key: "c", name: "C", status: "working" }],
      none,
      5,
    );
    expect(kinds(ev)).toEqual(["a:finished", "b:waiting"]);
    expect(ev[0]).toMatchObject({ name: "A", at: 5 });
  });

  it("nothing for unchanged, first-seen, watched, startup settling, or waiting → idle", () => {
    expect(detectEvents({ a: "idle" }, [{ key: "a", name: "A", status: "waiting" }], none, 1)).toEqual([]);
    expect(detectEvents({ a: "idle" }, [{ key: "a", name: "A", status: "idle" }], none, 1)).toEqual([]);
    expect(detectEvents({}, [{ key: "a", name: "A", status: "waiting" }], none, 1)).toEqual([]);
    expect(detectEvents({ a: "working" }, [{ key: "a", name: "A", status: "idle" }], new Set(["a"]), 1)).toEqual([]);
    expect(detectEvents({ a: "waiting" }, [{ key: "a", name: "A", status: "idle" }], none, 1)).toEqual([]);
  });

  it("persisted list drops malformed entries", () => {
    expect(asNotifications("x")).toBeNull();
    expect(asNotifications([{ id: "1", key: "a", name: "A", kind: "finished", at: 1 }, { id: 2 }, null])).toHaveLength(1);
  });
});
