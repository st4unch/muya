import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  CLICK_REACTIONS, HOVER_REACTIONS, PANDA_EVENT, REACTION_MS, SCENE_MS, SLEEP_AFTER_MS, boardText, firstScene, nextReaction, nextScene, pandaEnabled, pandaMood,
  setPandaEnabled, type PandaMood, type PandaReaction, type PandaScene,
} from "./panda";

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
    expect(firstScene("busy")).toBe("teacher");
    expect(firstScene("idle", "busy")).toBe("celebrate");
    expect(firstScene("idle")).toBe("wave");
    expect(firstScene("idle", "asleep")).toBe("wave");
    expect(firstScene("asleep", "idle")).toBe("sleep");
  });

  const BUSY: PandaScene[] = ["teacher", "gaming", "cookie", "bamboo", "dance", "traveller"];
  const IDLE: PandaScene[] = ["wave", "flip", "bow", "roll", "bamboo_eat", "tofu_eat", "manti", "fart"];

  it("busy takes turns, the teacher and the gamer most, never the same twice in a row", () => {
    const s = seq("busy", 600);
    for (const x of s) expect(BUSY).toContain(x);
    for (let i = 1; i < s.length; i++) expect(s[i]).not.toBe(s[i - 1]);
    for (const x of BUSY) expect(s).toContain(x);
    expect(count(s, "teacher")).toBeGreaterThan(count(s, "dance"));
    expect(count(s, "gaming")).toBeGreaterThan(count(s, "traveller"));
  });

  it("idle waves, flips, bows, rolls and snacks; after the celebration it carries on idle; asleep only sleeps", () => {
    const s = seq("idle", 600);
    for (const x of s) expect(IDLE).toContain(x);
    for (let i = 1; i < s.length; i++) expect(s[i]).not.toBe(s[i - 1]);
    for (const x of IDLE) expect(s).toContain(x);
    expect(count(s, "wave")).toBeGreaterThan(count(s, "fart"));
    expect(IDLE).toContain(nextScene("idle", "celebrate", () => 0.5));
    expect(new Set(seq("asleep", 20))).toEqual(new Set(["sleep"]));
  });

  it("the edges of the random range pick a real scene", () => {
    expect(nextScene("busy", "teacher", () => 0)).toBe("gaming");
    expect(nextScene("busy", "teacher", () => 0.999999)).toBe("traveller");
    expect(nextScene("idle", "wave", () => 0)).toBe("flip");
    expect(nextScene("asleep", "sleep", () => 0.5)).toBe("sleep");
  });

  it("every scene has a length", () => {
    for (const x of [...BUSY, ...IDLE, "celebrate", "sleep"] as PandaScene[]) expect(SCENE_MS[x]).toBeGreaterThan(2_000);
  });

  it("the board shows Claude's spinner verb, else the first part of the working line", () => {
    expect(boardText({ progress: { verb: "Thinking…" }, activity: "x · y" })).toBe("Thinking…");
    expect(boardText({ activity: "Unfurling… · 16.9k tokens" })).toBe("Unfurling…");
    expect(boardText({ activity: "" })).toBeUndefined();
    expect(boardText(undefined)).toBeUndefined();
  });
});

describe("panda reactions", () => {
  /** n clicks in a row with a seeded random */
  const clicks = (n: number, seed = 1) => {
    let x = seed;
    const rnd = () => ((x = (x * 16807) % 2147483647) / 2147483647);
    let bag: PandaReaction[] = [];
    let last: PandaReaction | undefined;
    const out: PandaReaction[] = [];
    for (let i = 0; i < n; i++) {
      [last, bag] = nextReaction(CLICK_REACTIONS, bag, last, rnd);
      out.push(last);
    }
    return out;
  };

  it("every click is different: all reactions play before any repeats, never twice in a row", () => {
    for (const seed of [1, 7, 42, 999]) {
      const s = clicks(CLICK_REACTIONS.length * 6, seed);
      for (let r = 0; r < 6; r++) {
        const round = s.slice(r * CLICK_REACTIONS.length, (r + 1) * CLICK_REACTIONS.length);
        expect(new Set(round)).toEqual(new Set(CLICK_REACTIONS));
      }
      for (let i = 1; i < s.length; i++) expect(s[i]).not.toBe(s[i - 1]);
    }
  });

  it("hover and click reactions are separate sets, and each has a length", () => {
    for (const r of HOVER_REACTIONS) expect(CLICK_REACTIONS).not.toContain(r);
    for (const r of [...CLICK_REACTIONS, ...HOVER_REACTIONS]) expect(REACTION_MS[r]).toBeGreaterThan(1_000);
    const [h] = nextReaction(HOVER_REACTIONS, [], undefined, () => 0.5);
    expect(HOVER_REACTIONS).toContain(h);
  });
});
