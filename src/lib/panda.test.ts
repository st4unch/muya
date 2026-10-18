import { beforeEach, describe, expect, it, vi } from "vitest";
import { PANDA_EVENT, SLEEP_AFTER_MS, firstScene, nextScene, pandaEnabled, pandaMood, setPandaEnabled, type PandaMood, type PandaScene } from "./panda";

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

  it("kung fu first when agents start, the hill roll when they stop, sleep when asleep", () => {
    expect(firstScene("busy")).toBe("kungfu");
    expect(firstScene("idle")).toBe("roll");
    expect(firstScene("asleep")).toBe("sleeping");
  });

  it("busy takes turns, never the same twice in a row, farts rarely, never sleeps", () => {
    const s = seq("busy", 400);
    for (const x of s) expect(["kungfu", "gaming", "bamboo", "tofu", "manti", "fart"]).toContain(x);
    for (let i = 1; i < s.length; i++) expect(s[i]).not.toBe(s[i - 1]);
    for (const x of ["gaming", "bamboo", "tofu", "manti", "fart"] as PandaScene[]) expect(s).toContain(x);
    expect(count(s, "fart")).toBeLessThan(count(s, "kungfu"));
  });

  it("idle stays awake (rolls, snacks) and never sleeps; asleep only sleeps", () => {
    const s = seq("idle", 300);
    for (const x of s) expect(["roll", "tofu", "manti"]).toContain(x);
    for (let i = 1; i < s.length; i++) expect(s[i]).not.toBe(s[i - 1]);
    expect(new Set(seq("asleep", 20))).toEqual(new Set(["sleeping"]));
  });

  it("the edges of the random range pick a real scene", () => {
    expect(nextScene("busy", "kungfu", () => 0)).toBe("gaming");
    expect(nextScene("busy", "kungfu", () => 0.999999)).toBe("fart");
    expect(nextScene("idle", "roll", () => 0)).toBe("tofu");
    expect(nextScene("asleep", "sleeping", () => 0.5)).toBe("sleeping");
  });
});
