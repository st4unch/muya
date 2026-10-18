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

export type PandaScene = "sleeping" | "roll" | "kungfu" | "gaming" | "bamboo" | "tofu" | "manti" | "fart";

/** busy = an agent works · idle = nothing runs but someone was here lately · asleep = neither for SLEEP_AFTER_MS */
export type PandaMood = "busy" | "idle" | "asleep";

/** No agent working and no key, click or scroll in Muya for this long → the panda falls asleep. */
export const SLEEP_AFTER_MS = 5 * 60_000;

export function pandaMood(busy: boolean, quietMs: number): PandaMood {
  if (busy) return "busy";
  return quietMs >= SLEEP_AFTER_MS ? "asleep" : "idle";
}

/** How long each scene stays before the next one (about two loops of its animation). */
export const SCENE_MS: Record<PandaScene, number> = {
  sleeping: 60_000,
  roll: 9_000,
  kungfu: 15_000,
  gaming: 16_000,
  bamboo: 9_200,
  tofu: 12_400,
  manti: 12_400,
  fart: 7_500,
};

// Weighted pools. Working: kung fu first, then games, bamboo, snacks and (rarely) a fart.
// Idle but awake: rolls down the hill and snacks. Asleep: sleeps.
const POOLS: Record<PandaMood, [PandaScene, number][]> = {
  busy: [["kungfu", 3], ["gaming", 3], ["bamboo", 2], ["tofu", 2], ["manti", 2], ["fart", 1]],
  idle: [["roll", 3], ["tofu", 2], ["manti", 2]],
  asleep: [["sleeping", 1]],
};

/** The scene shown first when the mood changes. */
export function firstScene(mood: PandaMood): PandaScene {
  return mood === "busy" ? "kungfu" : mood === "idle" ? "roll" : "sleeping";
}

/** The scene after `prev`. Only sleeping may play twice in a row. */
export function nextScene(mood: PandaMood, prev: PandaScene, rnd: () => number = Math.random): PandaScene {
  const pool = POOLS[mood].filter(([s]) => s !== prev || s === "sleeping");
  const total = pool.reduce((n, [, w]) => n + w, 0);
  let r = rnd() * total;
  for (const [s, w] of pool) {
    if ((r -= w) < 0) return s;
  }
  return pool[pool.length - 1][0];
}
