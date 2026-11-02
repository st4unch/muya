// Samples CPU % and RSS of processes whose command line matches a pattern, via `ps`.
// Used by the load tests to measure the app (or the WebKit test browser) while they run.
import { execFileSync } from "node:child_process";

function snapshot(match) {
  const out = execFileSync("ps", ["-axo", "pid=,%cpu=,rss=,command="], { encoding: "utf8" });
  let cpu = 0;
  let rssKb = 0;
  let n = 0;
  for (const line of out.split("\n")) {
    const m = line.trim().match(/^(\d+)\s+([\d.]+)\s+(\d+)\s+(.*)$/);
    if (!m || !match(m[4], Number(m[1]))) continue;
    cpu += Number(m[2]);
    rssKb += Number(m[3]);
    n++;
  }
  return { cpu, rssMb: rssKb / 1024, procs: n };
}

/** Starts sampling every `everyMs`; `stop()` returns { cpuAvg, cpuMax, rssMaxMb, samples }. */
export function startSampler(match, everyMs = 500) {
  const samples = [];
  const timer = setInterval(() => samples.push(snapshot(match)), everyMs);
  return {
    stop() {
      clearInterval(timer);
      if (!samples.length) samples.push(snapshot(match));
      const cpus = samples.map((s) => s.cpu);
      return {
        cpuAvg: cpus.reduce((a, b) => a + b, 0) / cpus.length,
        cpuMax: Math.max(...cpus),
        rssMaxMb: Math.max(...samples.map((s) => s.rssMb)),
        samples: samples.length,
      };
    },
  };
}

export const pct = (a, p) => {
  if (!a.length) return NaN;
  const s = a.slice().sort((x, y) => x - y);
  return s[Math.min(s.length - 1, Math.floor((p / 100) * s.length))];
};
