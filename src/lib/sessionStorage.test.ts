import { describe, expect, it } from "vitest";
import { cleanupCandidates, formatBytes, storageSummary, type StoredSession } from "./sessionStorage";

const DAY = 86_400_000;
const MB = 1024 * 1024;
const now = 100 * DAY;
const s = (id: string, days: number, mb: number, extraMb = 0): StoredSession => ({
  sessionId: id,
  path: `/p/${id}.jsonl`,
  cwd: "/w",
  lastModified: now - days * DAY,
  sizeBytes: mb * MB,
  extraBytes: extraMb * MB,
});

describe("storageSummary", () => {
  it("counts size (with the session folder), old and big sessions", () => {
    const sum = storageSummary([s("a", 1, 10, 5), s("b", 40, 1), s("c", 2, 150)], now);
    expect(sum).toEqual({ count: 3, totalBytes: 166 * MB, oldCount: 1, bigCount: 1, heavy: true });
  });
  it("is calm for a small, recent history", () => {
    expect(storageSummary([s("a", 1, 10)], now).heavy).toBe(false);
    expect(storageSummary([], now)).toEqual({ count: 0, totalBytes: 0, oldCount: 0, bigCount: 0, heavy: false });
  });
  it("goes heavy past 2 GB in total", () => {
    const many = Array.from({ length: 25 }, (_, i) => s(`x${i}`, 1, 90));
    expect(storageSummary(many, now).heavy).toBe(true);
  });
});

describe("cleanupCandidates", () => {
  const list = [s("old", 45, 1), s("big", 2, 120), s("both", 60, 200), s("fresh", 1, 2), s("live", 90, 300)];
  const live = new Set(["live"]);
  it("picks sessions matching either rule, never a live one, biggest first", () => {
    const ids = cleanupCandidates(list, { olderDays: 30, largerMb: 100 }, live, now).map((x) => x.sessionId);
    expect(ids).toEqual(["both", "big", "old"]);
  });
  it("leaves a session used in the last 10 minutes alone", () => {
    const busy = { ...s("busy", 0, 500), lastModified: now - 60_000 };
    expect(cleanupCandidates([busy], { olderDays: null, largerMb: 100 }, new Set(), now)).toEqual([]);
  });
  it("one rule at a time, and nothing with both off", () => {
    expect(cleanupCandidates(list, { olderDays: 30, largerMb: null }, live, now).map((x) => x.sessionId)).toEqual(["both", "old"]);
    expect(cleanupCandidates(list, { olderDays: null, largerMb: 100 }, live, now).map((x) => x.sessionId)).toEqual(["both", "big"]);
    expect(cleanupCandidates(list, { olderDays: null, largerMb: null }, live, now)).toEqual([]);
  });
});

describe("formatBytes", () => {
  it("reads like Finder", () => {
    expect(formatBytes(512)).toBe("512 B");
    expect(formatBytes(2048)).toBe("2 KB");
    expect(formatBytes(3.5 * MB)).toBe("3.5 MB");
    expect(formatBytes(201 * MB)).toBe("201 MB");
    expect(formatBytes(2.4 * 1024 * MB)).toBe("2.4 GB");
  });
});
