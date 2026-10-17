// Created by Claude — Classification: INTERNAL
//
// What the rail panda does next (docs/prd-rail-panda.md). Pure, so the order is testable.

export type PandaScene =
  // idle: no agent is working
  | "eat"
  | "flip"
  | "sleep"
  | "roll"
  | "kungfu"
  // busy: an agent is working
  | "wake"
  | "chop"
  | "stone"
  | "tofu";

export const IDLE_SCENES: readonly PandaScene[] = ["eat", "flip", "sleep", "roll", "kungfu"];
export const BUSY_SCENES: readonly PandaScene[] = ["chop", "stone", "tofu", "kungfu"];

/** How long a scene stays on screen, ms. */
export function sceneMs(s: PandaScene): number {
  if (s === "wake") return 1800;
  if (s === "sleep") return 11000;
  return 6500;
}

/** The scene after `current`. Waking up comes first whenever work starts; while busy it
 *  cycles the busy list, while idle the idle one (each from where it left off). */
export function nextScene(current: PandaScene | null, busy: boolean): PandaScene {
  const list = busy ? BUSY_SCENES : IDLE_SCENES;
  if (busy && (current === null || !BUSY_SCENES.includes(current) && current !== "wake")) return "wake";
  const at = current ? list.indexOf(current) : -1;
  return list[(at + 1) % list.length];
}

/** A trick for a click: anything lively from the current mood except what's on now. */
export function trickFor(current: PandaScene | null, busy: boolean, pick = Math.random): PandaScene {
  const pool = (busy ? BUSY_SCENES : IDLE_SCENES.filter((s) => s !== "sleep")).filter((s) => s !== current);
  return pool[Math.floor(pick() * pool.length) % pool.length];
}

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
