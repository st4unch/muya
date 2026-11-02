# Mini-PRD — load test harness

## 1. Problem
We have no way to say how Muya behaves with many busy sessions. Perf work so far was
measured one-off (scratchpad scripts, 3 idle sessions). The operator runs 13+ Claude
sessions that stream output at the same time; stutter shows up there, not in the
idle mock.

## 2. Outcome
A repeatable `npm run loadtest` that puts the app under realistic and heavy load and
prints a table of numbers to compare before/after any change:
- frame time (p50 / p95 / max) and frames over 50 ms while terminals stream,
- input latency (key press → shown on screen) in the active terminal under load,
- session switch latency under load,
- CPU and memory of the rendering process,
- for the real app: CPU / memory of `muya` and broker (MCP) latency under load.

## 3. Scope
- In: `scripts/loadtest/` (Node + Playwright WebKit, `ps` sampling, hyperfine),
  two mock helpers (`ptyIds`, `feedPty`) in `src/mock/installMock.ts`, an npm script.
- Out: fixing whatever the test finds (separate work), CI integration.

## 4. Behaviour
- **UI load (`ui.mjs`)** — headless WebKit on the mock app (`?mock=1&sessions=N`).
  Every mock pty receives Claude-like ANSI output (colour, cursor moves, long lines)
  at a set rate. Scenarios: idle, normal (all sessions ~8 KB/s), heavy (visible
  ~1 MB/s + rest ~64 KB/s), for N = 7, 13, 25. Measured for 10 s each.
- **Real-app load (`app.mjs`)** — the debug build (`src-tauri/target/debug/muya`)
  with a fake `HOME` and a fake `claude` first on `PATH` that floods output. Sessions
  are opened through the broker socket (`open_session`), then `list_sessions` /
  `read_session` latency is measured while they stream. Only that debug process is
  stopped, by exact path.
- **Broker micro-bench** — hyperfine over one sidecar `tools/list` round trip.

## 5. Integration (evidence)
- Mock feed: `src/mock/installMock.ts` (`__muyaMock.feed`, `spawnMockPty`).
- Terminal input/output: `src/components/Terminal.tsx:544-557` (Channel → `term.write`).
- PTY pipeline: `src-tauri/src/pty.rs:239-305` (32 KB reads, 128 KB batches, 8 ms pace).
- Broker: `src-tauri/src/broker.rs:506-521` (socket, `MUYA_SSH_BROKER_SOCK`), `:618`
  dispatch, `:1154` open_session; uid-checked, JSON line per request.
- Claude resolver: `src-tauri/src/agents.rs:96` (first candidate answering
  `agents --json` wins — the fake claude must answer it).

## 6. Protection list
Host Muya never touched (no broad pkill, no quit). Fake HOME for the debug instance.
Existing `__muyaMock.feed` behaviour unchanged. No private paths in committed files.

## 7. Acceptance criteria
- AC1: `node scripts/loadtest/ui.mjs` runs all scenarios headless and prints one row
  per scenario with frame p50/p95/max, frames >50 ms, input latency, switch latency,
  WebKit CPU avg and RSS max; exit 0.
- AC2: `node scripts/loadtest/app.mjs` starts the debug app on a fake HOME, opens ≥8
  flooding sessions through the broker, prints muya CPU/RSS and broker latency
  p50/p95, and leaves no debug process running; the host PID is unchanged.
- AC3: `npm test`, `npx tsc --noEmit` pass; `grep -rn /Users/ scripts/loadtest` empty.
- AC4: results written to `docs/loadtest-results.md` with the bottlenecks found.
