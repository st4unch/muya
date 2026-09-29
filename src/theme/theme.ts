import { useCallback, useEffect, useState } from "react";

/**
 * Theme preference/resolution helpers (docs/design/redesign-v0.4/PROMPT.md §1, §6).
 *
 * "system" | "light" | "dark" is the user-facing preference, persisted under the
 * SAME localStorage key the app already used pre-redesign ("apex.theme") so existing
 * installs keep their choice. "system" live-tracks `prefers-color-scheme`. The
 * resolved ("dark" | "light") theme is applied to <html> as both `data-theme` (new
 * token system) and the legacy `.dark` class (Tailwind `dark:` variants on pages not
 * yet migrated to tokens).
 *
 * The very first paint is handled separately by public/theme-boot.js, which reads
 * the same storage key before any CSS loads — this module takes over from there.
 */

export type ThemePreference = "system" | "light" | "dark";
export type ResolvedTheme = "dark" | "light";

export const THEME_STORAGE_KEY = "apex.theme";

const CYCLE_ORDER: readonly ThemePreference[] = ["system", "light", "dark"];

/** Read the persisted preference. Defaults to "system"; never throws (private
 *  browsing / disabled storage / a stale non-preference value all fall back). */
export function readStoredPreference(): ThemePreference {
  try {
    const raw = localStorage.getItem(THEME_STORAGE_KEY);
    if (raw === "system" || raw === "light" || raw === "dark") return raw;
  } catch {
    // localStorage unavailable — fall through to default.
  }
  return "system";
}

/** Persist the preference. Swallows storage errors (quota, private mode). */
export function storePreference(pref: ThemePreference): void {
  try {
    localStorage.setItem(THEME_STORAGE_KEY, pref);
  } catch {
    // Best-effort only.
  }
}

/** Live OS preference. Defaults to false (light) when matchMedia is unavailable. */
export function systemPrefersDark(): boolean {
  try {
    return window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;
  } catch {
    return false;
  }
}

/** Pure resolution: preference + current system state → the theme to actually paint. */
export function resolveTheme(pref: ThemePreference, systemDark: boolean): ResolvedTheme {
  if (pref === "system") return systemDark ? "dark" : "light";
  return pref;
}

/** system → light → dark → system (§6). */
export function nextPreference(pref: ThemePreference): ThemePreference {
  const i = CYCLE_ORDER.indexOf(pref);
  return CYCLE_ORDER[(i + 1) % CYCLE_ORDER.length];
}

/** Applies the resolved theme to <html>: `data-theme` (token system) + `.dark`
 *  class (legacy Tailwind `dark:` variants) kept in sync. */
export function applyThemeToDocument(resolved: ResolvedTheme, root: HTMLElement = document.documentElement): void {
  root.dataset.theme = resolved;
  root.classList.toggle("dark", resolved === "dark");
}

export interface UseThemeResult {
  /** Raw user preference: "system" | "light" | "dark". */
  preference: ThemePreference;
  /** The theme actually painted right now. */
  resolved: ResolvedTheme;
  /** Set an explicit preference (also accepts "system"). Persisted immediately. */
  setPreference: (pref: ThemePreference) => void;
  /** Advance the preference one step in the §6 cycle order. */
  cycle: () => void;
}

/**
 * App-wide theme hook. Owns the preference + live system-match state, keeps
 * `document.documentElement` (`data-theme` + `.dark`) in sync, and persists the
 * preference under the legacy `apex.theme` key.
 */
export function useTheme(): UseThemeResult {
  const [preference, setPreferenceState] = useState<ThemePreference>(readStoredPreference);
  const [systemDark, setSystemDark] = useState<boolean>(systemPrefersDark);

  // Live-track prefers-color-scheme changes while the preference is "system"
  // (and harmlessly while it isn't — resolveTheme ignores systemDark then).
  useEffect(() => {
    let mq: MediaQueryList | undefined;
    try {
      mq = window.matchMedia("(prefers-color-scheme: dark)");
    } catch {
      return;
    }
    const onChange = (e: MediaQueryListEvent) => setSystemDark(e.matches);
    mq.addEventListener("change", onChange);
    return () => mq?.removeEventListener("change", onChange);
  }, []);

  const resolved = resolveTheme(preference, systemDark);

  useEffect(() => {
    applyThemeToDocument(resolved);
  }, [resolved]);

  const setPreference = useCallback((pref: ThemePreference) => {
    storePreference(pref);
    setPreferenceState(pref);
  }, []);

  const cycle = useCallback(() => {
    setPreferenceState((prev) => {
      const next = nextPreference(prev);
      storePreference(next);
      return next;
    });
  }, []);

  return { preference, resolved, setPreference, cycle };
}
