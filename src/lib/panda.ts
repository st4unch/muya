// Created by Claude — Classification: INTERNAL
//
// The rail panda's Settings switch and which scene it plays (docs/prd-rail-panda.md,
// docs/prd-rive-panda.md). The scenes are Rive animations of our own rigged panda
// (tools/panda-studio), picked by whether an agent is working (redesign/RailPanda.tsx).

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
  | "sleep"
  | "wave"
  | "flip"
  | "bow"
  | "roll"
  | "fart"
  | "bamboo_eat"
  | "tofu_eat"
  | "manti"
  | "celebrate"
  | "teacher"
  | "gaming"
  | "cookie"
  | "bamboo"
  | "dance"
  | "traveller";

/** Short one-off reactions: clicking the panda plays a click one, pointing at it a hover one. */
export type PandaReaction = "giggle" | "startle" | "heart" | "sneeze" | "dizzy" | "peekaboo" | "aww" | "notice" | "hop";

/** busy = an agent works · idle = nothing runs but someone was here lately · asleep = neither for SLEEP_AFTER_MS */
export type PandaMood = "busy" | "idle" | "asleep";

/** No agent working and no key, click or scroll in Muya for this long → the panda falls asleep. */
export const SLEEP_AFTER_MS = 5 * 60_000;

export function pandaMood(busy: boolean, quietMs: number): PandaMood {
  if (busy) return "busy";
  return quietMs >= SLEEP_AFTER_MS ? "asleep" : "idle";
}

/** How long each scene stays before the next one: its animation's length × loops. */
export const SCENE_MS: Record<PandaScene, number> = {
  sleep: 60_000,
  wave: 6_667, // 2 × 3.33 s
  flip: 6_000, // 2 × 3 s
  bow: 5_667, // 2 × 2.83 s
  roll: 6_383, // once
  fart: 4_667, // once
  bamboo_eat: 4_033, // once
  tofu_eat: 3_533, // once
  manti: 4_933, // once
  celebrate: 2_933, // once
  teacher: 11_600, // 3 × 3.87 s
  gaming: 9_100, // 3 × 3.03 s
  cookie: 7_700, // once
  bamboo: 7_167, // 2 × 3.58 s
  dance: 7_333, // 2 × 3.67 s
  traveller: 6_667, // 2 × 3.33 s
};

// Weighted pools. Working: the teacher (pointing at what Claude is doing) and the gamer most,
// then the kung-fu cookie run and the bamboo splits, the fan dance and the traveller. Idle but
// awake: waves, flips, bows, rolls down a hill, snacks, and (rarely) the fart. Asleep: sleeps. "celebrate" is not in a pool: it plays once when the agents finish.
const POOLS: Record<PandaMood, [PandaScene, number][]> = {
  busy: [["teacher", 3], ["gaming", 3], ["cookie", 2], ["bamboo", 2], ["dance", 1], ["traveller", 1]],
  idle: [["wave", 3], ["flip", 2], ["bow", 2], ["roll", 2], ["bamboo_eat", 2], ["tofu_eat", 1], ["manti", 1], ["fart", 1]],
  asleep: [["sleep", 1]],
};

/** The scene shown first when the mood changes; finishing work (busy → idle) celebrates first. */
export function firstScene(mood: PandaMood, prev?: PandaMood): PandaScene {
  if (mood === "idle" && prev === "busy") return "celebrate";
  return mood === "busy" ? "teacher" : mood === "idle" ? "wave" : "sleep";
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

/** Each reaction's length (its animation, once). */
export const REACTION_MS: Record<PandaReaction, number> = {
  giggle: 2_167,
  startle: 1_600,
  heart: 2_433,
  sneeze: 2_400,
  dizzy: 2_767,
  peekaboo: 2_167,
  aww: 1_900,
  notice: 1_600,
  hop: 1_200,
};

export const CLICK_REACTIONS: readonly PandaReaction[] = ["giggle", "startle", "heart", "sneeze", "dizzy", "peekaboo", "aww"];
export const HOVER_REACTIONS: readonly PandaReaction[] = ["notice", "hop"];

/** Pointing at the panda again within this long does not make it react again. */
export const HOVER_COOLDOWN_MS = 8_000;

/** The next reaction from a shuffled bag: every one in `pool` plays before any repeats, and the
 *  first of a new round is never the one just played. Returns the pick and the bag left over. */
export function nextReaction(
  pool: readonly PandaReaction[],
  bag: readonly PandaReaction[],
  last: PandaReaction | undefined,
  rnd: () => number = Math.random,
): [PandaReaction, PandaReaction[]] {
  let left = bag.filter((r) => pool.includes(r));
  if (!left.length) {
    left = [...pool];
    for (let i = left.length - 1; i > 0; i--) {
      const j = Math.floor(rnd() * (i + 1));
      [left[i], left[j]] = [left[j], left[i]];
    }
    if (left.length > 1 && left[0] === last) left.push(left.shift()!);
  }
  return [left[0], left.slice(1)];
}

/** What the teacher's board says: Claude's spinner verb ("Thinking…"), else the first part of
 *  the working card's line ("Unfurling… · 16.9k tokens" → "Unfurling…"). */
export function boardText(agent: { progress?: { verb?: string }; activity?: string } | undefined): string | undefined {
  const verb = agent?.progress?.verb?.trim() || agent?.activity?.split(" · ")[0]?.trim();
  return verb ? verb : undefined;
}
