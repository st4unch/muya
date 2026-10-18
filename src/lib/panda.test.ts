import { beforeEach, describe, expect, it, vi } from "vitest";
import { PANDA_EVENT, firstScene, nextScene, pandaEnabled, setPandaEnabled, type PandaScene } from "./panda";

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
  const seq = (busy: boolean, n: number) => {
    let x = 0.137;
    const rnd = () => (x = (x * 9301 + 49297) % 1);
    const out: PandaScene[] = [firstScene(busy)];
    for (let i = 0; i < n; i++) out.push(nextScene(busy, out[out.length - 1], rnd));
    return out;
  };

  it("starts with the game while agents work and asleep while idle", () => {
    expect(firstScene(true)).toBe("gaming");
    expect(firstScene(false)).toBe("sleeping");
  });

  it("busy takes turns among the busy scenes, never the same twice in a row", () => {
    const s = seq(true, 400);
    for (const x of s) expect(["gaming", "bamboo", "tofu", "manti", "fart"]).toContain(x);
    for (let i = 1; i < s.length; i++) expect(s[i]).not.toBe(s[i - 1]);
    for (const x of ["bamboo", "tofu", "manti", "fart"]) expect(s).toContain(x);
    // farting is the rare one
    const n = (k: PandaScene) => s.filter((x) => x === k).length;
    expect(n("fart")).toBeLessThan(n("tofu"));
  });

  it("idle mostly sleeps, sometimes rolls down the hill, never rolls twice in a row", () => {
    const s = seq(false, 400);
    for (const x of s) expect(["sleeping", "roll"]).toContain(x);
    const rolls = s.filter((x) => x === "roll").length;
    expect(rolls).toBeGreaterThan(0);
    expect(rolls).toBeLessThan(s.length / 2);
    for (let i = 1; i < s.length; i++) expect(s[i] === "roll" && s[i - 1] === "roll").toBe(false);
  });

  it("the edges of the random range pick a real scene", () => {
    expect(nextScene(true, "gaming", () => 0)).toBe("bamboo");
    expect(nextScene(true, "gaming", () => 0.999999)).toBe("fart");
    expect(nextScene(false, "sleeping", () => 0)).toBe("sleeping");
    expect(nextScene(false, "roll", () => 0.999999)).toBe("sleeping");
  });
});
