import { beforeEach, describe, expect, it } from "vitest";
import { LAST_ACTIVE_KEY, LAUNCH_GRACE_MS, RECENT_MS, TOUCH_EVERY_MS, isRecent, readLastActive, touchActive, writeLastActive } from "./recentActivity";

const HOUR = 60 * 60 * 1000;
const NOW = 1_800_000_000_000;

describe("recentActivity", () => {
  beforeEach(() => localStorage.clear());

  it("an idle agent is recent at 5 h, not at 7 h or with no time; a busy one always is", () => {
    expect(isRecent("idle", NOW - 5 * HOUR, NOW)).toBe(true);
    expect(isRecent("idle", NOW - 7 * HOUR, NOW)).toBe(false);
    expect(isRecent("idle", undefined, NOW)).toBe(false);
    expect(isRecent("working", undefined, NOW)).toBe(true);
    expect(isRecent("waiting", NOW - 30 * HOUR, NOW)).toBe(true);
    expect(RECENT_MS).toBe(6 * HOUR);
  });

  it("stamps working/waiting agents, at most once a minute", () => {
    const a = touchActive({}, [{ key: "a", status: "working" }, { key: "b", status: "idle" }], NOW);
    expect(a).toEqual({ a: NOW });
    expect(touchActive(a, [{ key: "a", status: "working" }], NOW + TOUCH_EVERY_MS - 1)).toBe(a);
    expect(touchActive(a, [{ key: "a", status: "waiting" }], NOW + TOUCH_EVERY_MS)).toEqual({ a: NOW + TOUCH_EVERY_MS });
  });

  it("does not count the resume right after launch as activity", () => {
    const launched = NOW - 10_000;
    expect(touchActive({}, [{ key: "a", status: "working" }], NOW, {}, launched)).toEqual({});
    expect(touchActive({}, [{ key: "a", status: "working" }], launched + LAUNCH_GRACE_MS, {}, launched)).toEqual({ a: launched + LAUNCH_GRACE_MS });
    // a real last message still seeds during the grace
    expect(touchActive({}, [{ key: "a", status: "idle" }], NOW, { a: NOW - HOUR }, launched)).toEqual({ a: NOW - HOUR });
  });

  it("drops the v1 map, which held launch-time stamps", () => {
    localStorage.setItem("muya.lastActive", JSON.stringify({ a: NOW }));
    expect(readLastActive()).toEqual({});
    expect(localStorage.getItem("muya.lastActive")).toBeNull();
  });

  it("seeds from a newer transcript time and ignores an older one", () => {
    const prev = { a: NOW - 3 * HOUR };
    expect(touchActive(prev, [{ key: "a", status: "idle" }], NOW, { a: NOW - HOUR })).toEqual({ a: NOW - HOUR });
    expect(touchActive(prev, [{ key: "a", status: "idle" }], NOW, { a: NOW - 5 * HOUR })).toBe(prev);
  });

  it("drops closed tabs, but not before any tab is known", () => {
    const prev = { a: NOW, gone: NOW };
    expect(touchActive(prev, [], NOW)).toBe(prev);
    expect(touchActive(prev, [{ key: "a", status: "idle" }], NOW)).toEqual({ a: NOW });
  });

  it("survives a reload through localStorage and ignores junk", () => {
    writeLastActive({ a: NOW });
    expect(readLastActive()).toEqual({ a: NOW });
    localStorage.setItem(LAST_ACTIVE_KEY, JSON.stringify({ a: "x", b: 5 }));
    expect(readLastActive()).toEqual({ b: 5 });
    localStorage.setItem(LAST_ACTIVE_KEY, "not json");
    expect(readLastActive()).toEqual({});
  });
});
