# Apex Mission Control

A native macOS desktop control plane for running, watching, and steering **multiple parallel [Claude Code](https://claude.com/claude-code) agents** from a single window.

Built with **Tauri v2** (Rust core) + **React 19** — ~8 MB, starts instantly, signed & notarized.

---

## Screenshots

### Grid View — 4 terminals side by side
![Grid View](docs/screenshots/01-grid-view.png)

### Sessions — live + past Claude Code sessions
![Sessions](docs/screenshots/02-sessions.png)

### Queue — push/merge queue with git status
![Queue](docs/screenshots/03-queue.png)

### Resources — skills, agents, hooks, MCPs
![Resources](docs/screenshots/04-resources.png)

### Control — tab mode with file tree + branch DAG
![Control](docs/screenshots/05-control.png)

---

## Why

Running several Claude Code agents in parallel today means juggling terminal tabs, `tmux`, Warp, and the `claude` CLI. You can't see at a glance:

- which agent is **working** vs **waiting for input**,
- which files are being **edited in two worktrees at once** (collisions),
- how much **quota/time** each session has burned,
- the real **branch topology** across your worktrees.

Apex puts all of it in one place — and lets you launch, attach to, and stop agents without leaving the window.

---

## Features

| Area | What it does |
|---|---|
| **Grid view** | Show up to 4 terminals simultaneously in a resizable 2×2 grid. Drag & drop to reorder panels. Toggle with the ⊞ Grid button — sidepanels auto-hide for full focus. |
| **Tab bar** | Scroll left/right when tabs overflow. Drag & drop to reorder. Double-click to rename any tab. |
| **Live sessions** | Reads `claude agents --json` (interactive + background). Attach, stop, or resume any session directly from the app. Full-text search across live sessions and transcript history. |
| **Real terminals** | PTY-backed (`portable-pty` + xterm.js). One persistent tab per session — survives tab switches and grid/tab mode changes. Shift+Enter inserts a literal newline without submitting. |
| **New agent** | Launch a fresh agent into an isolated `git worktree` (auto-created, `.env` copied) running `claude --dangerously-skip-permissions`. |
| **Scheduled Prompt** | Schedule a prompt to be sent to one or more terminals at a specific date and time. Pending and recently fired prompts are tracked in the modal. |
| **Editor + diff** | Monaco editor with HEAD-vs-working-tree diff view, loaded locally (no CDN). Unsaved files show a dot indicator in the tab; closing blocks with a native confirmation dialog. |
| **File tree** | Lazy real file tree over workspaces you add; live-refreshes on filesystem changes. Right-click a folder to remove it from the workspace. |
| **Push / Merge queue** | Per-project git status (ahead/behind/dirty), trial-merge conflict checks, and operator-confirmed push/merge with auto worktree cleanup. |
| **Collision detection** | Flags the same repo-relative file edited in two or more worktrees simultaneously. |
| **Branch topology** | Real lineage DAG — parent computed from closest divergence point. Live branch summary with ahead/conflict counts. |
| **Claude Resources** | Browse local Skills, Agents, Hooks, and MCPs. One-click "Create with Claude" to scaffold new resources in a terminal. Marketplace tab for discovering community skills. |
| **File associations** | Set Apex as the default app for `.md`, `.json`, `.ts`, `.py`, `.rs`, and 15+ other text formats — files open directly in the Monaco editor. |
| **Resource metrics** | App CPU% and RAM (RSS) in the header bar via `sysinfo`. |
| **Persistence** | Workspaces, worktrees, queue, open tabs, and grid layout are restored on relaunch. |

---

## Download

Get the latest signed & notarized macOS build from [Releases](https://github.com/st4unch/apex-mission-control/releases/latest).

Requires macOS (Apple Silicon). Just unzip and run — no installer needed.

---

## Tech stack

- **Frontend:** React 19, Vite, Tailwind CSS v4, `@xterm/xterm`, `@monaco-editor/react`, `lucide-react`.
- **Backend (Rust):** Tauri v2, `portable-pty`, `notify` (file watching), `sysinfo`, `tauri-plugin-dialog`. Stateless, compute-on-demand `git` plumbing — no Python, no daemon.

---

## Build from source

**Prerequisites:** macOS (Apple Silicon), [Node.js](https://nodejs.org) 20+, [Rust](https://rustup.rs), Xcode Command Line Tools, `claude` CLI on `PATH`.

```bash
git clone https://github.com/st4unch/apex-mission-control.git
cd apex-mission-control
npm install
npm run tauri dev      # native window with hot reload
```

Distributable build:

```bash
npm run tauri build    # → src-tauri/target/release/bundle/macos/Apex Mission Control.app
```

---

## Testing

```bash
# Backend
cd src-tauri && cargo test

# Frontend
npm run test   # vitest — 29 tests
```

---

## Project structure

```
src/                    React frontend
  components/           Terminal, TerminalGrid, FileTree, FileEditor, SessionsPage, …
  lib/                  pure helpers (format, agent command builder)
src-tauri/src/          Rust backend
  agents.rs             claude agents --json reader
  pty.rs                PTY-backed terminals
  fs.rs                 file tree, read/write, git worktree + branch topology
  pm.rs                 project status, trial-merge, push/merge, collisions
  watcher.rs            filesystem watching (notify)
  metrics.rs            CPU/RAM via sysinfo
docs/                   SYSTEM.md, PRDs, screenshots
```

---

## Design notes

- **Tauri over Electron** — ~8 MB vs ~80-200 MB, far lower memory with 10 agents + terminals + Monaco.
- **App-managed PTY** — agents run in the app's own PTYs, no tmux dependency.
- **Rust backend** — zero Python runtime dependency; portable everywhere the app runs.

---

## Status

v0.1.1 — actively developed. macOS / Apple Silicon only.

## License

MIT — see [LICENSE](LICENSE).

---

🤖 Built with [Claude Code](https://claude.com/claude-code).
