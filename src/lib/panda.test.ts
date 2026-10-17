import { describe, expect, it } from "vitest";
import { BUSY_SCENES, IDLE_SCENES, nextScene, sceneMs, trickFor } from "./panda";

describe("nextScene", () => {
  it("idle: walks the idle scenes in a loop", () => {
    let s = nextScene(null, false);
    const seen = [s];
    for (let i = 0; i < IDLE_SCENES.length; i++) seen.push((s = nextScene(s, false)));
    expect(seen).toEqual([...IDLE_SCENES, IDLE_SCENES[0]]);
  });
  it("work starting: wakes up first, then the busy scenes", () => {
    expect(nextScene("sleep", true)).toBe("wake");
    expect(nextScene(null, true)).toBe("wake");
    expect(nextScene("wake", true)).toBe(BUSY_SCENES[0]);
    expect(nextScene("chop", true)).toBe("stone");
    expect(nextScene("tofu", true)).toBe("kungfu");
    expect(nextScene("kungfu", true)).toBe("chop");
  });
  it("work over: back to the idle scenes", () => {
    expect(IDLE_SCENES).toContain(nextScene("stone", false));
    expect(nextScene("wake", false)).toBe(IDLE_SCENES[0]);
  });
  it("sleep lasts longest, waking up is short", () => {
    expect(sceneMs("sleep")).toBeGreaterThan(sceneMs("eat"));
    expect(sceneMs("wake")).toBeLessThan(sceneMs("eat"));
  });
});

describe("trickFor", () => {
  it("never repeats the current scene and never picks sleep as a trick", () => {
    for (let i = 0; i < 10; i++) {
      const t = trickFor("eat", false, () => i / 10);
      expect(t).not.toBe("eat");
      expect(t).not.toBe("sleep");
    }
    expect(BUSY_SCENES).toContain(trickFor("chop", true, () => 0.5));
  });
});
