// Created by Claude — Classification: INTERNAL
//
// useState that survives a restart via localStorage. Every storage access is
// wrapped: private windows / blocked storage must never break the UI, the value just
// isn't remembered. `validate` turns whatever was stored into a safe value (or null =
// "use the initial one"), so a hand-edited or stale entry can't put the layout in a
// state the code doesn't expect.

import { useCallback, useState } from "react";

export function readStored<T>(key: string, validate: (raw: unknown) => T | null): T | null {
  try {
    const raw = localStorage.getItem(key);
    if (raw === null) return null;
    return validate(JSON.parse(raw));
  } catch {
    return null;
  }
}

export function writeStored(key: string, value: unknown): void {
  try {
    if (value === null || value === undefined) localStorage.removeItem(key);
    else localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* storage unavailable: keep the in-memory value only */
  }
}

export function usePersistentState<T>(key: string, initial: T, validate: (raw: unknown) => T | null): [T, (next: T) => void] {
  const [value, setValue] = useState<T>(() => readStored(key, validate) ?? initial);
  const set = useCallback(
    (next: T) => {
      setValue(next);
      writeStored(key, next);
    },
    [key],
  );
  return [value, set];
}

export const asBool = (raw: unknown): boolean | null => (typeof raw === "boolean" ? raw : null);

export function asClampedNumber(min: number, max: number) {
  return (raw: unknown): number | null =>
    typeof raw === "number" && Number.isFinite(raw) ? Math.min(max, Math.max(min, Math.round(raw))) : null;
}
