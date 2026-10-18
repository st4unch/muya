// Created by Claude — Classification: INTERNAL
//
// The rail panda's Settings switch and which scene it plays (docs/prd-rail-panda.md). The
// scenes are LottieFiles animations picked by whether an agent is working
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

export type PandaScene =
  | "sleeping"
  | "waving"
  | "rolling"
  | "bowing"
  | "celebrating"
  | "teaching"
  | "dance"
  | "traveling"
  | "business";

/** busy = an agent works · idle = nothing runs but someone was here lately · asleep = neither for SLEEP_AFTER_MS */
export type PandaMood = "busy" | "idle" | "asleep";

/** No agent working and no key, click or scroll in Muya for this long → the panda falls asleep. */
export const SLEEP_AFTER_MS = 5 * 60_000;

export function pandaMood(busy: boolean, quietMs: number): PandaMood {
  if (busy) return "busy";
  return quietMs >= SLEEP_AFTER_MS ? "asleep" : "idle";
}

/** How long each scene stays before the next one (a few loops of its animation). */
export const SCENE_MS: Record<PandaScene, number> = {
  sleeping: 60_000,
  waving: 8_500, // 4 × 2.1 s
  rolling: 9_400, // 3 × 3.1 s
  bowing: 7_300, // 2 × 3.6 s
  celebrating: 3_000, // once
  teaching: 11_500, // 4 × 2.9 s
  dance: 8_000, // 4 × 2 s
  traveling: 6_000, // 4 × 1.5 s
  business: 9_000, // 4 × 2.25 s
};

// Weighted pools. Working: the teacher (pointing at what Claude is doing) most, then the fan
// dance, the traveller and the businessman. Idle but awake: waves, rolls, bows. Asleep: sleeps.
// "celebrating" is not in a pool: it plays once when the agents finish (see firstScene).
const POOLS: Record<PandaMood, [PandaScene, number][]> = {
  busy: [["teaching", 3], ["dance", 2], ["traveling", 2], ["business", 2]],
  idle: [["waving", 2], ["rolling", 2], ["bowing", 1]],
  asleep: [["sleeping", 1]],
};

/** The scene shown first when the mood changes; finishing work (busy → idle) celebrates first. */
export function firstScene(mood: PandaMood, prev?: PandaMood): PandaScene {
  if (mood === "idle" && prev === "busy") return "celebrating";
  return mood === "busy" ? "teaching" : mood === "idle" ? "waving" : "sleeping";
}

/** The scene after `prev`. No scene plays twice in a row unless it is the mood's only one. */
export function nextScene(mood: PandaMood, prev: PandaScene, rnd: () => number = Math.random): PandaScene {
  const others = POOLS[mood].filter(([s]) => s !== prev);
  const pool = others.length ? others : POOLS[mood];
  const total = pool.reduce((n, [, w]) => n + w, 0);
  let r = rnd() * total;
  for (const [s, w] of pool) {
    if ((r -= w) < 0) return s;
  }
  return pool[pool.length - 1][0];
}

/** What the teacher's board says: Claude's spinner verb ("Thinking…"), else the first part of
 *  the working card's line ("Unfurling… · 16.9k tokens" → "Unfurling…"). */
export function boardText(agent: { progress?: { verb?: string }; activity?: string } | undefined): string | undefined {
  const verb = agent?.progress?.verb?.trim() || agent?.activity?.split(" · ")[0]?.trim();
  return verb ? verb : undefined;
}
