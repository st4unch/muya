import { beforeEach, describe, expect, it, vi } from "vitest";
import { PANDA_EVENT, pandaEnabled, setPandaEnabled } from "./panda";

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
