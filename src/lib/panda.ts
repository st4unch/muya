// Created by Claude — Classification: INTERNAL
//
// The rail panda's Settings switch and which scene it plays (docs/prd-rail-panda.md). The
// panda itself is a set of animated SVGs picked by whether an agent is working
// (redesign/RailPanda.tsx).

const KEY = "apex.panda";
export const PANDA_EVENT = "muya:panda";

/** The Settings switch (on by default; unreadable storage = on). */
export function pandaEnabled(): boolean {
  try {
    return localStorage.getItem(KEY) !== "off";
  } catch {
    return true;
  }
}

export function setPandaEnabled(on: boolean): void {
  try {
    localStorage.setItem(KEY, on ? "on" : "off");
  } catch {
    /* private mode */
  }
  window.dispatchEvent(new Event(PANDA_EVENT));
}

export type PandaScene = "sleeping" | "roll" | "gaming" | "bamboo" | "tofu" | "manti" | "fart";

/** How long each scene stays before the next one (about two loops of its animation). */
export const SCENE_MS: Record<PandaScene, number> = {
  sleeping: 40_000,
  roll: 9_000,
  gaming: 16_000,
  bamboo: 9_200,
  tofu: 12_400,
  manti: 12_400,
  fart: 7_500,
};

// Weighted pools: while agents work it plays, eats and (rarely) farts; idle it mostly sleeps.
const BUSY: [PandaScene, number][] = [["gaming", 3], ["bamboo", 3], ["tofu", 3], ["manti", 3], ["fart", 1]];
const IDLE: [PandaScene, number][] = [["sleeping", 3], ["roll", 1]];

/** The scene shown first when the mood changes. */
export function firstScene(busy: boolean): PandaScene {
  return busy ? "gaming" : "sleeping";
}

/** The scene after `prev`. Only sleeping may play twice in a row. */
export function nextScene(busy: boolean, prev: PandaScene, rnd: () => number = Math.random): PandaScene {
  const pool = (busy ? BUSY : IDLE).filter(([s]) => s !== prev || s === "sleeping");
  const total = pool.reduce((n, [, w]) => n + w, 0);
  let r = rnd() * total;
  for (const [s, w] of pool) {
    if ((r -= w) < 0) return s;
  }
  return pool[pool.length - 1][0];
}
