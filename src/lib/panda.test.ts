import { beforeEach, describe, expect, it, vi } from "vitest";
import { PANDA_EVENT, SLEEP_AFTER_MS, boardText, firstScene, nextScene, pandaEnabled, pandaMood, setPandaEnabled, type PandaMood, type PandaScene } from "./panda";

describe("panda switch", () => {
  beforeEach(() => localStorage.removeItem("apex.panda"));

  it("is on by default and remembers off / on", () => {
    expect(pandaEnabled()).toBe(true);
    setPandaEnabled(false);
    expect(pandaEnabled()).toBe(false);
    setPandaEnabled(true);
    expect(pandaEnabled()).toBe(true);
  });

  it("tells the rail at once", () => {
    const on = vi.fn();
    window.addEventListener(PANDA_EVENT, on);
    setPandaEnabled(false);
    expect(on).toHaveBeenCalledTimes(1);
    window.removeEventListener(PANDA_EVENT, on);
  });
});

describe("panda scenes", () => {
  const seq = (mood: PandaMood, n: number) => {
    let x = 0.137;
    const rnd = () => (x = (x * 9301 + 49297) % 1);
    const out: PandaScene[] = [firstScene(mood)];
    for (let i = 0; i < n; i++) out.push(nextScene(mood, out[out.length - 1], rnd));
    return out;
  };
  const count = (s: PandaScene[], k: PandaScene) => s.filter((x) => x === k).length;

  it("mood: working beats everything; idle sleeps only after 5 quiet minutes", () => {
    expect(pandaMood(true, SLEEP_AFTER_MS * 10)).toBe("busy");
    expect(pandaMood(false, 0)).toBe("idle");
    expect(pandaMood(false, SLEEP_AFTER_MS - 1)).toBe("idle");
    expect(pandaMood(false, SLEEP_AFTER_MS)).toBe("asleep");
    expect(SLEEP_AFTER_MS).toBe(300_000);
  });

  it("the teacher first when agents start, a celebration when they finish, waving otherwise", () => {
    expect(firstScene("busy")).toBe("teaching");
    expect(firstScene("idle", "busy")).toBe("celebrating");
    expect(firstScene("idle")).toBe("waving");
    expect(firstScene("idle", "asleep")).toBe("waving");
    expect(firstScene("asleep", "idle")).toBe("sleeping");
  });

  it("busy takes turns, the teacher most, never the same twice in a row", () => {
    const s = seq("busy", 400);
    for (const x of s) expect(["teaching", "dance", "traveling", "business"]).toContain(x);
    for (let i = 1; i < s.length; i++) expect(s[i]).not.toBe(s[i - 1]);
    for (const x of ["dance", "traveling", "business"] as PandaScene[]) expect(s).toContain(x);
    expect(count(s, "teaching")).toBeGreaterThan(count(s, "dance"));
  });

  it("idle waves, rolls and bows; after the celebration it carries on idle; asleep only sleeps", () => {
    const s = seq("idle", 300);
    for (const x of s) expect(["waving", "rolling", "bowing"]).toContain(x);
    for (let i = 1; i < s.length; i++) expect(s[i]).not.toBe(s[i - 1]);
    expect(["waving", "rolling", "bowing"]).toContain(nextScene("idle", "celebrating", () => 0.5));
    expect(new Set(seq("asleep", 20))).toEqual(new Set(["sleeping"]));
  });

  it("the edges of the random range pick a real scene", () => {
    expect(nextScene("busy", "teaching", () => 0)).toBe("dance");
    expect(nextScene("busy", "teaching", () => 0.999999)).toBe("business");
    expect(nextScene("idle", "waving", () => 0)).toBe("rolling");
    expect(nextScene("asleep", "sleeping", () => 0.5)).toBe("sleeping");
  });

  it("the board shows Claude's spinner verb, else the first part of the working line", () => {
    expect(boardText({ progress: { verb: "Thinking…" }, activity: "x · y" })).toBe("Thinking…");
    expect(boardText({ activity: "Unfurling… · 16.9k tokens" })).toBe("Unfurling…");
    expect(boardText({ activity: "" })).toBeUndefined();
    expect(boardText(undefined)).toBeUndefined();
  });
});
