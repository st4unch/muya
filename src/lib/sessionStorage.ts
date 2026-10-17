// Created by Claude — Classification: INTERNAL
//
// How much Claude's saved sessions take, and which ones a clean-up would pick
// (docs/prd-session-housekeeping.md). Pure — the Sessions screen and the heads-up use it.

export interface StoredSession {
  sessionId: string;
  path: string;
  cwd: string;
  name?: string | null;
  lastModified: number;
  sizeBytes: number;
  /** The session's `<id>/` folder (subagents, tool output). */
  extraBytes?: number;
}

const MB = 1024 * 1024;
const DAY = 24 * 60 * 60 * 1000;
/** Over this in total, or one session over HEAVY_ONE_MB, the strip turns amber. */
export const HEAVY_TOTAL_BYTES = 2 * 1024 * MB;
export const HEAVY_ONE_MB = 100;
export const OLD_DAYS = 30;

export const sessionBytes = (s: StoredSession) => s.sizeBytes + (s.extraBytes ?? 0);
export const ageDays = (s: StoredSession, now: number) => Math.max(0, Math.floor((now - s.lastModified) / DAY));

export interface StorageSummary {
  count: number;
  totalBytes: number;
  /** Not used for OLD_DAYS or more. */
  oldCount: number;
  /** Over HEAVY_ONE_MB. */
  bigCount: number;
  /** Worth telling the operator about. */
  heavy: boolean;
}

export function storageSummary(list: readonly StoredSession[], now: number): StorageSummary {
  let totalBytes = 0;
  let oldCount = 0;
  let bigCount = 0;
  for (const s of list) {
    const b = sessionBytes(s);
    totalBytes += b;
    if (ageDays(s, now) >= OLD_DAYS) oldCount++;
    if (b > HEAVY_ONE_MB * MB) bigCount++;
  }
  return { count: list.length, totalBytes, oldCount, bigCount, heavy: totalBytes > HEAVY_TOTAL_BYTES || bigCount > 0 };
}

export interface CleanupFilter {
  /** Pick sessions not used for this many days (null = this rule is off). */
  olderDays: number | null;
  /** Pick sessions larger than this many MB (null = off). */
  largerMb: number | null;
}

/** Written to this recently = in use; the backend refuses to move it (history.rs IN_USE_MS). */
export const IN_USE_MS = 10 * 60 * 1000;

/** Sessions matching ANY enabled rule, never a live or just-used one, biggest first. */
export function cleanupCandidates(
  list: readonly StoredSession[],
  f: CleanupFilter,
  liveIds: ReadonlySet<string>,
  now: number,
): StoredSession[] {
  if (f.olderDays === null && f.largerMb === null) return [];
  return list
    .filter((s) => !liveIds.has(s.sessionId) && now - s.lastModified >= IN_USE_MS)
    .filter(
      (s) =>
        (f.olderDays !== null && ageDays(s, now) >= f.olderDays) ||
        (f.largerMb !== null && sessionBytes(s) > f.largerMb * MB),
    )
    .sort((a, b) => sessionBytes(b) - sessionBytes(a));
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < MB) return `${Math.round(n / 1024)} KB`;
  if (n < 1024 * MB) return `${(n / MB).toFixed(n < 10 * MB ? 1 : 0)} MB`;
  return `${(n / (1024 * MB)).toFixed(1)} GB`;
}
