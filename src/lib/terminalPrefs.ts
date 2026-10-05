// Created by Claude — Classification: INTERNAL
//
// Terminal appearance the operator picks (font size, line/letter spacing, color scheme). One value for every
// terminal, shared through a tiny store so a change re-styles all open terminals at once,
// and remembered in localStorage (unreadable/blocked storage just means defaults).

import { useSyncExternalStore } from "react";
import { readStored, writeStored } from "../redesign/usePersistentState";
import { TERMINAL_SCHEMES, type TerminalSchemeId } from "../theme/terminalThemes";

export interface TerminalPrefs {
  fontSize: number;
  /** Line height as a multiple of the font size. */
  lineHeight: number;
  /** Extra px between characters. */
  letterSpacing: number;
  scheme: TerminalSchemeId;
}

export const FONT_MIN = 9;
export const FONT_MAX = 28;
export const FONT_DEFAULT = 13;
export const LINE_MIN = 1;
export const LINE_MAX = 2;
export const LINE_DEFAULT = 1.6;
export const LETTER_MIN = 0;
export const LETTER_MAX = 4;
export const LETTER_DEFAULT = 0;
const KEY = "muya.terminalPrefs";
const DEFAULTS: TerminalPrefs = { fontSize: FONT_DEFAULT, lineHeight: LINE_DEFAULT, letterSpacing: LETTER_DEFAULT, scheme: "muya" };

const clampFont = (n: number) => Math.min(FONT_MAX, Math.max(FONT_MIN, Math.round(n)));
// Tenths, so repeated ±0.1 steps don't drift (1.6 - 0.1 = 1.5000000000000002).
const clampLine = (n: number) => Math.min(LINE_MAX, Math.max(LINE_MIN, Math.round(n * 10) / 10));
const clampLetter = (n: number) => Math.min(LETTER_MAX, Math.max(LETTER_MIN, Math.round(n)));
const num = (v: unknown, clamp: (n: number) => number, fallback: number) =>
  typeof v === "number" && Number.isFinite(v) ? clamp(v) : fallback;

function validate(raw: unknown): TerminalPrefs | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const fontSize = num(r.fontSize, clampFont, FONT_DEFAULT);
  const lineHeight = num(r.lineHeight, clampLine, LINE_DEFAULT);
  const letterSpacing = num(r.letterSpacing, clampLetter, LETTER_DEFAULT);
  const scheme = TERMINAL_SCHEMES.some((s) => s.id === r.scheme) ? (r.scheme as TerminalSchemeId) : "muya";
  return { fontSize, lineHeight, letterSpacing, scheme };
}

let current: TerminalPrefs = readStored(KEY, validate) ?? DEFAULTS;
const listeners = new Set<() => void>();

export function getTerminalPrefs(): TerminalPrefs {
  return current;
}

export function setTerminalPrefs(patch: Partial<TerminalPrefs>): void {
  const next = validate({ ...current, ...patch }) ?? DEFAULTS;
  if (
    next.fontSize === current.fontSize &&
    next.lineHeight === current.lineHeight &&
    next.letterSpacing === current.letterSpacing &&
    next.scheme === current.scheme
  )
    return;
  current = next;
  writeStored(KEY, next);
  listeners.forEach((l) => l());
}

/** +1 / -1 steps the font; 0 resets it to the default. */
export function stepTerminalFont(delta: -1 | 0 | 1): void {
  setTerminalPrefs({ fontSize: delta === 0 ? FONT_DEFAULT : current.fontSize + delta });
}

/** ±1 steps line spacing by 0.1; 0 resets it to the default. */
export function stepTerminalLine(delta: -1 | 0 | 1): void {
  setTerminalPrefs({ lineHeight: delta === 0 ? LINE_DEFAULT : current.lineHeight + delta / 10 });
}

/** ±1 steps letter spacing by 1 px; 0 resets it to the default. */
export function stepTerminalLetter(delta: -1 | 0 | 1): void {
  setTerminalPrefs({ letterSpacing: delta === 0 ? LETTER_DEFAULT : current.letterSpacing + delta });
}

function subscribe(l: () => void) {
  listeners.add(l);
  return () => listeners.delete(l);
}

export function useTerminalPrefs(): TerminalPrefs {
  return useSyncExternalStore(subscribe, getTerminalPrefs, getTerminalPrefs);
}
