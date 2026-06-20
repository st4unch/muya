# Apex Mission Control

A native desktop control plane for running, watching, and steering **multiple parallel [Claude Code](https://claude.com/claude-code) agents** from a single window.

Built with **Tauri v2** (Rust core) + **React 19** — ~12 MB, starts instantly, and only ever touches the project folders you point it at.

> Migrated from a single-file UI prototype into a real, tested, signed desktop app. Every panel that used to show mock data now reads live state from `git` and `claude` on your machine.

---

## Why

Running several Claude Code agents in parallel today means juggling terminal tabs, `tmux`, Warp, and the `claude` CLI. You can't see at a glance:

- which agent is **working** vs **waiting for input**,
- which files are being **edited in two worktrees at once** (collisions),
- how much **quota/time** each session has burned,
- the real **branch topology** across your worktrees.

Apex puts all of it in one place — and lets you launch, attach to, and stop agents without leaving the window.

## Features

| Area | What it does |
|---|---|
| **Live sessions** | Reads `claude agents --json` (interactive + background). Attach to background sessions in an embedded terminal, stop any session, resume past sessions from transcript history. |
| **Real terminals** | PTY-backed (`portable-pty` + xterm.js). One persistent tab per session — survives tab switches. Auto-runs `claude attach <id>` for background agents. |
| **New agent** | Launch a fresh agent into an isolated `git worktree` (auto-created, `.env` copied) running `claude --dangerously-skip-permissions`, with optional title / prompt / file refs. |
| **Editor + diff** | Monaco editor with a HEAD-vs-working-tree diff view, loaded locally (no CDN). |
| **File tree** | Lazy, real file tree over the workspaces you add; live-refreshes on filesystem changes. |
| **Push / Merge queue** | Per-project git status (ahead/behind/dirty), trial-merge conflict checks (`git merge-tree`), and operator-confirmed local merge / remote push, with auto worktree cleanup after merge. |
| **Collision detection** | Hook-free: flags the same repo-relative file edited in two or more worktrees. |
| **Branch topology** | Real lineage DAG — each branch's parent computed from its closest divergence. |
| **Resource metrics** | The app's own CPU% and RAM (RSS) via `sysinfo`. |
| **Persistence** | Workspaces, worktrees, queue, and open tabs are restored on relaunch. |

## Tech stack

- **Frontend:** React 19, Vite, Tailwind CSS v4, lightweight view routing, `@xterm/xterm`, `@monaco-editor/react`, `lucide-react`.
- **Backend (Rust):** Tauri v2, `portable-pty`, `notify` (file watching), `sysinfo`, `tauri-plugin-dialog`. Stateless, compute-on-demand `git` plumbing — no background daemon, no machine-specific paths, **no Python runtime dependency**.

## Getting started

**Prerequisites:** macOS (Apple Silicon), [Node.js](https://nodejs.org) 20+, [Rust](https://rustup.rs), Xcode Command Line Tools, and the `claude` CLI on your `PATH`.

```bash
git clone <this-repo>
cd apex-mission-control
npm install
npm run tauri dev      # native window with hot reload
```

Build a distributable app/bundle:

```bash
npm run tauri build    # → src-tauri/target/release/bundle/macos/Apex Mission Control.app
```

> On Apple Silicon the app is automatically ad-hoc signed (required to run locally). For distribution to other Macs without a Gatekeeper prompt, sign with a **Developer ID Application** certificate and notarize — see Tauri's [code signing guide](https://v2.tauri.app/distribute/sign/macos/).

## Testing

```bash
# Backend — hermetic git tests (each spins up its own temp repo; machine-independent)
cd src-tauri && cargo test          # + cargo clippy --all-targets -- -D warnings

# Frontend — unit / component tests
npm run test                        # vitest
```

28 tests total (14 Rust, 14 frontend). CI runs both on macOS via GitHub Actions (`.github/workflows/ci.yml`).

## Project structure

```
src/                    React frontend
  components/           Terminal, FileTree, FileEditor, SessionsPage, QueuePage, …
  lib/                  pure, tested helpers (format, agent command builder)
src-tauri/src/          Rust backend
  agents.rs             claude agents --json reader + stop/kill
  pty.rs                PTY-backed terminals (portable-pty)
  fs.rs                 file tree, read/write, git worktree + branch topology
  pm.rs                 project status, trial-merge, push/merge, collisions
  watcher.rs            notify-based filesystem watching
  metrics.rs            app CPU/RAM via sysinfo
docs/                   SYSTEM.md, PRD, design notes, test plan
```

## Design notes

- **Tauri over Electron** — ~12 MB vs ~80-200 MB, far lower memory with 10 agents + 10 terminals + Monaco, and a capability-based security model that scopes filesystem access to your repos only.
- **App-managed PTY (no tmux dependency)** — agents run in the app's own PTYs, so it works on any machine without extra setup.
- **PM logic in Rust, not Python** — zero runtime dependency; portable everywhere the app runs.

## Status

Actively built phase by phase (see `docs/prd-apex-mission-control.progress.md`). macOS / Apple Silicon is the supported target today.

## License

MIT — see [LICENSE](LICENSE).

---

🤖 Built with [Claude Code](https://claude.com/claude-code).
