// Created by Claude — Classification: INTERNAL
//
// Terminal appearance the operator picks (font size, color scheme). One value for every
// terminal, shared through a tiny store so a change re-styles all open terminals at once,
// and remembered in localStorage (unreadable/blocked storage just means defaults).

import { useSyncExternalStore } from "react";
import { readStored, writeStored } from "../redesign/usePersistentState";
import { TERMINAL_SCHEMES, type TerminalSchemeId } from "../theme/terminalThemes";

export interface TerminalPrefs {
  fontSize: number;
  scheme: TerminalSchemeId;
}

export const FONT_MIN = 9;
export const FONT_MAX = 28;
export const FONT_DEFAULT = 13;
const KEY = "muya.terminalPrefs";
const DEFAULTS: TerminalPrefs = { fontSize: FONT_DEFAULT, scheme: "muya" };

const clampFont = (n: number) => Math.min(FONT_MAX, Math.max(FONT_MIN, Math.round(n)));

function validate(raw: unknown): TerminalPrefs | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const fontSize = typeof r.fontSize === "number" && Number.isFinite(r.fontSize) ? clampFont(r.fontSize) : FONT_DEFAULT;
  const scheme = TERMINAL_SCHEMES.some((s) => s.id === r.scheme) ? (r.scheme as TerminalSchemeId) : "muya";
  return { fontSize, scheme };
}

let current: TerminalPrefs = readStored(KEY, validate) ?? DEFAULTS;
const listeners = new Set<() => void>();

export function getTerminalPrefs(): TerminalPrefs {
  return current;
}

export function setTerminalPrefs(patch: Partial<TerminalPrefs>): void {
  const next = validate({ ...current, ...patch }) ?? DEFAULTS;
  if (next.fontSize === current.fontSize && next.scheme === current.scheme) return;
  current = next;
  writeStored(KEY, next);
  listeners.forEach((l) => l());
}

/** +1 / -1 steps the font; 0 resets it to the default. */
export function stepTerminalFont(delta: -1 | 0 | 1): void {
  setTerminalPrefs({ fontSize: delta === 0 ? FONT_DEFAULT : current.fontSize + delta });
}

function subscribe(l: () => void) {
  listeners.add(l);
  return () => listeners.delete(l);
}

export function useTerminalPrefs(): TerminalPrefs {
  return useSyncExternalStore(subscribe, getTerminalPrefs, getTerminalPrefs);
}
