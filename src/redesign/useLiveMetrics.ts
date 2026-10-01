// Created by Claude — Classification: INTERNAL
//
// The header's CPU / RAM / clock readout, polled by the readout itself. This state
// used to live in App.tsx, so every 2.5 s poll re-rendered the whole app (every
// terminal host, agent row and panel) just to change two numbers in the header. Kept
// here, a tick re-renders three spans — and only when the shown text actually changed.

import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

export interface LiveMetrics {
  cpu: string;
  ram: string;
  clock: string;
}

export const METRICS_POLL_MS = 2500;
const CLOCK_TICK_MS = 10_000;

export function formatRam(memMb: number): string {
  return memMb < 1024 ? `${Math.round(memMb)} MB` : `${(memMb / 1024).toFixed(1)} GB`;
}

const clockNow = () => new Date().toTimeString().slice(0, 5);

/** Live readout; `enabled=false` (fixtures, previews) never polls. */
export function useLiveMetrics(enabled: boolean): LiveMetrics {
  const [m, setM] = useState<LiveMetrics>(() => ({ cpu: "0%", ram: "0 MB", clock: clockNow() }));
  useEffect(() => {
    if (!enabled) return;
    let alive = true;
    // Same text → same object → React skips the render.
    const merge = (patch: Partial<LiveMetrics>) =>
      setM((prev) => (Object.entries(patch).every(([k, v]) => prev[k as keyof LiveMetrics] === v) ? prev : { ...prev, ...patch }));
    const tickClock = () => merge({ clock: clockNow() });
    const poll = () => {
      if (document.hidden) return; // nobody is looking; the next visible tick catches up
      invoke<{ cpu: number; memMb: number }>("app_metrics")
        .then((r) => {
          if (alive) merge({ cpu: `${Math.round(r.cpu)}%`, ram: formatRam(r.memMb) });
        })
        .catch(() => {});
    };
    tickClock();
    poll();
    const c = setInterval(tickClock, CLOCK_TICK_MS);
    const p = setInterval(poll, METRICS_POLL_MS);
    return () => {
      alive = false;
      clearInterval(c);
      clearInterval(p);
    };
  }, [enabled]);
  return m;
}
