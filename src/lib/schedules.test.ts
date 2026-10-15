import { describe, expect, it } from "vitest";
import { dayTimes, describeSchedule, emptyInput, initialMemory, rememberSchedule, fmtClock, fmtDurationMs, jobState, relTime, serviceLine, summarize, withKind, type JobView } from "./schedules";

const job = (p: Partial<JobView>): JobView => ({
  id: "a", name: "A", prompt: "p", folder: "/w", schedule: { kind: "daily", time: "09:00" }, enabled: true, timeoutMin: 30, bypass: true, chrome: true,
  created: 0, updated: 0, nextRun: null, running: false, queued: false, runs: 0, ok: 0, failed: 0, last: null, ...p,
});

describe("describeSchedule", () => {
  it("says it in words", () => {
    expect(describeSchedule({ kind: "interval", minutes: 15 })).toBe("Every 15 min");
    expect(describeSchedule({ kind: "interval", minutes: 60 })).toBe("Every hour");
    expect(describeSchedule({ kind: "interval", minutes: 180 })).toBe("Every 3 hours");
    expect(describeSchedule({ kind: "daily", time: "09:30" })).toBe("Every day at 09:30");
    expect(describeSchedule({ kind: "weekly", days: [4, 0, 1, 2, 3], time: "08:00" })).toBe("Weekdays at 08:00");
    expect(describeSchedule({ kind: "weekly", days: [5, 6], time: "10:00" })).toBe("Weekends at 10:00");
    expect(describeSchedule({ kind: "weekly", days: [2, 0], time: "18:00" })).toBe("Mon, Wed at 18:00");
  });
});

describe("time formatting", () => {
  const now = new Date(2026, 0, 5, 12, 0).getTime();
  it("relative", () => {
    expect(relTime(now - 10_000, now)).toBe("just now");
    expect(relTime(now - 5 * 60_000, now)).toBe("5 min ago");
    expect(relTime(now + 2 * 3_600_000, now)).toBe("in 2 h");
    expect(relTime(now - 3 * 86_400_000, now)).toBe("3 d ago");
  });
  it("clock and duration", () => {
    expect(fmtClock(new Date(2026, 0, 5, 9, 5).getTime(), now)).toBe("today 09:05");
    expect(fmtClock(new Date(2026, 0, 6, 9, 5).getTime(), now)).toBe("tomorrow 09:05");
    expect(fmtClock(new Date(2026, 0, 9, 9, 5).getTime(), now)).toBe("9 Jan 09:05");
    expect(fmtDurationMs(4_200)).toBe("4s");
    expect(fmtDurationMs(125_000)).toBe("2m 5s");
    expect(fmtDurationMs(3_720_000)).toBe("1h 2m");
  });
});

describe("summarize + jobState", () => {
  it("adds up runs and finds the latest failure", () => {
    const s = summarize([
      job({ id: "a", name: "A", runs: 10, ok: 9, failed: 1, last: { started: 1, ended: 50, status: "failed" } }),
      job({ id: "b", name: "B", enabled: false, runs: 2, ok: 1, failed: 1, last: { started: 1, ended: 90, status: "timeout" } }),
      job({ id: "c", name: "C" }),
    ]);
    expect(s).toEqual({ schedules: 3, enabled: 2, runs: 12, ok: 10, failed: 2, successRate: 83, lastFailure: { name: "B", at: 90 } });
    expect(summarize([]).successRate).toBeNull();
    expect(summarize([]).lastFailure).toBeNull();
  });
  it("state pill", () => {
    expect(jobState(job({ running: true })).label).toBe("Running");
    expect(jobState(job({ queued: true })).label).toBe("Waiting");
    expect(jobState(job({})).label).toBe("Never run");
    expect(jobState(job({ last: { started: 0, ended: 1, status: "success" } })).tone).toBe("success");
    expect(jobState(job({ last: { started: 0, ended: 1, status: "timeout" } })).label).toBe("Timed out");
  });
});

describe("withKind", () => {
  it("keeps the time when switching kinds", () => {
    expect(withKind({ kind: "daily", time: "07:15" }, "weekly")).toEqual({ kind: "weekly", days: [0, 1, 2, 3, 4], time: "07:15" });
    expect(withKind({ kind: "weekly", days: [6], time: "07:15" }, "daily")).toEqual({ kind: "daily", time: "07:15" });
    expect(withKind({ kind: "daily", time: "07:15" }, "interval")).toEqual({ kind: "interval", minutes: 60 });
    expect(emptyInput().bypass).toBe(true);
  });
  it("a detour through another kind keeps the picked days, time and minutes", () => {
    let mem = initialMemory({ kind: "weekly", days: [5], time: "17:45" });
    const viaInterval = withKind({ kind: "weekly", days: [5], time: "17:45" }, "interval", mem);
    mem = rememberSchedule({ kind: "weekly", days: [5], time: "17:45" }, mem);
    expect(withKind({ ...viaInterval, minutes: 30 } as never, "weekly", mem)).toEqual({ kind: "weekly", days: [5], time: "17:45" });
    mem = rememberSchedule({ kind: "interval", minutes: 30 }, mem);
    expect(withKind({ kind: "weekly", days: [5], time: "17:45" }, "interval", mem)).toEqual({ kind: "interval", minutes: 30 });
  });
});

describe("serviceLine", () => {
  it("says what the background service is doing", () => {
    expect(serviceLine(null).text).toBe("Checking…");
    expect(serviceLine({ state: "off", running: false, version: null }).tone).toBe("muted");
    expect(serviceLine({ state: "approval", running: false, version: null }).tone).toBe("warning");
    expect(serviceLine({ state: "on", running: false, version: null }).text).toBe("On, starting…");
    expect(serviceLine({ state: "on", running: true, version: "4.1.2" }, "4.1.2").text).toMatch(/even after you quit/);
    expect(serviceLine({ state: "on", running: true, version: "4.1.1" }, "4.1.2").text).toMatch(/moves to 4.1.2/);
    expect(serviceLine({ state: "unavailable", running: false, version: null }).text).toMatch(/installed Muya app/);
  });
});

describe("several times a day", () => {
  it("lists every time sorted and once", () => {
    expect(dayTimes({ time: "19:00", extraTimes: ["09:00", "19:00", "13:30"] })).toEqual(["09:00", "13:30", "19:00"]);
    expect(describeSchedule({ kind: "daily", time: "09:00", extraTimes: ["19:00"] })).toBe("Every day at 09:00, 19:00");
    expect(describeSchedule({ kind: "weekly", days: [0, 1, 2, 3, 4], time: "18:00", extraTimes: ["08:00"] })).toBe("Weekdays at 08:00, 18:00");
  });
  it("keeps extra times across a detour through interval, and drops an empty list", () => {
    const d = { kind: "daily" as const, time: "09:00", extraTimes: ["19:00"] };
    const mem = initialMemory(d);
    const back = withKind(withKind(d, "interval", mem), "weekly", mem);
    expect(back).toEqual({ kind: "weekly", days: [0, 1, 2, 3, 4], time: "09:00", extraTimes: ["19:00"] });
    expect(withKind({ kind: "daily", time: "09:00" }, "weekly")).toEqual({ kind: "weekly", days: [0, 1, 2, 3, 4], time: "09:00" });
  });
});
