// Created by Claude — Classification: INTERNAL
//
// Footer status fields: the user's ordered choice (persisted) and the live status JSON of
// the selected Claude session (polled every 2 s, only while something is chosen).

import { useCallback, useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { statusField, type StatusData } from "../lib/statusline";
import { readStored, writeStored } from "./usePersistentState";

export const STATUS_FIELDS_KEY = "muya.footer.statusFields";
export const STATUS_POLL_MS = 2000;

function validate(raw: unknown): string[] | null {
  if (!Array.isArray(raw)) return null;
  const seen = new Set<string>();
  for (const x of raw) if (typeof x === "string" && statusField(x)) seen.add(x);
  return [...seen];
}

export function useStatusFields() {
  const [fields, setFields] = useState<string[]>(() => readStored(STATUS_FIELDS_KEY, validate) ?? []);
  const commit = useCallback((next: string[]) => {
    setFields(next);
    writeStored(STATUS_FIELDS_KEY, next.length ? next : null);
  }, []);
  const toggle = useCallback(
    (id: string) => setFields((prev) => {
      const next = prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id];
      writeStored(STATUS_FIELDS_KEY, next.length ? next : null);
      return next;
    }),
    [],
  );
  const remove = useCallback(
    (id: string) => setFields((prev) => {
      const next = prev.filter((x) => x !== id);
      writeStored(STATUS_FIELDS_KEY, next.length ? next : null);
      return next;
    }),
    [],
  );
  return { fields, toggle, remove, setFields: commit };
}

/** Polls `statusline_get` for `ptyId` while `enabled`. Null when there is no data. */
export function useStatusData(ptyId: string | undefined, enabled: boolean): StatusData | null {
  const [data, setData] = useState<StatusData | null>(null);
  useEffect(() => {
    if (!enabled || !ptyId) {
      setData(null);
      return;
    }
    let live = true;
    // The JSON usually doesn't change between polls; keeping the old object then
    // spares the whole app a re-render every 2 s.
    let last = "null";
    const put = (d: StatusData | null) => {
      const sig = JSON.stringify(d);
      if (!live || sig === last) return;
      last = sig;
      setData(d);
    };
    const tick = () => {
      if (document.hidden) return; // window in the background: nobody sees the footer
      invoke<StatusData | null>("statusline_get", { ptyId })
        .then((d) => put(d && typeof d === "object" ? d : null))
        .catch(() => put(null));
    };
    setData(null);
    tick();
    const t = window.setInterval(tick, STATUS_POLL_MS);
    return () => { live = false; window.clearInterval(t); };
  }, [ptyId, enabled]);
  return data;
}
