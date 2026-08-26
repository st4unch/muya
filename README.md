# Muya

A native macOS desktop control plane for running, watching, and steering **multiple parallel [Claude Code](https://claude.com/claude-code) agents** from a single window — with an encrypted credential vault, SSH/CyberArk access, and an MCP server that lets those agents drive Muya itself.

Built with **Tauri v2** (Rust core) + **React 19** — ~12 MB, starts instantly, signed & notarized.

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

Muya puts all of it in one place — and lets you launch, attach to, message, and stop agents without leaving the window.

---

## Getting started

### 1. Add a workspace

Muya works against folders you choose. Open the **Control** screen and use **+ Workspace** to add a
project directory. The file tree, git status, branch topology and collision detection all follow the
workspaces you add — nothing is scanned without you asking.

### 2. Open a Claude terminal

Press **+** in the tab bar (or **+ New Agent**) and pick a workspace. Muya opens a real terminal and
starts Claude Code in it with `--dangerously-skip-permissions`, so the agent can work without
stopping to ask about every file.

Two things worth knowing straight away:

- **Optionally give the agent its own branch.** In the New Agent dialog, filling in a branch name
  makes Muya create a real `git worktree` for it — a separate checkout of the same repository. Two
  agents on two worktrees can work at the same time without touching each other's files.
- **The tab is the session.** Each tab keeps its own Claude conversation. Tabs marked with the
  Claude glyph are live agents; a plain `>_` is an ordinary shell.

### 3. Work with several agents at once

| You want to… | Do this |
|---|---|
| See four agents at once | **⊞ Grid** — up to 4 terminals in a 2×2 grid, drag to rearrange |
| Rename a tab | Double-click its title |
| Find which agent said something | **Sessions** → search — it greps the actual conversation text, not just names |
| Resume a session after restarting Muya | Click its tab — Muya reconnects it to the same conversation |
| Send the same prompt to several agents later | **Scheduled Prompt** — pick the terminals, pick a time |
| Check nobody is editing the same file twice | **Queue** — collisions are flagged automatically |
| Push or merge an agent's work | **Queue** — shows ahead/behind, trial-merges first, cleans up the worktree after |

### 4. Keep an eye on the whole fleet

**Sessions** lists every Claude session on the machine — live and past — with what each one is doing
and whether it's *working* or *waiting for input*. From there you can attach, stop, resume, or export
a conversation to Markdown.

---

## Features

Muya is organised as seven screens.

### Control — terminals, files, branches

| | |
|---|---|
| **Real terminals** | PTY-backed (`portable-pty` + xterm.js). One persistent tab per session — survives tab switches and grid/tab mode changes. Shift+Enter inserts a literal newline without submitting. |
| **Grid view** | Up to 4 terminals in a resizable 2×2 grid; drag & drop to reorder. Side panels auto-hide for focus. |
| **Tab bar** | Scrolls when tabs overflow, drag to reorder, double-click to rename. Claude tabs are marked and resume their *own* conversation when clicked. |
| **New agent** | Launch a fresh agent into an isolated `git worktree` (auto-created, `.env` copied). |
| **Scheduled prompts** | Send a prompt to one or more terminals at a chosen date/time; pending and fired prompts are tracked. |
| **Editor + diff** | Monaco with HEAD-vs-working-tree diff, bundled locally (no CDN). Unsaved tabs show a dot; closing asks first. |
| **Viewers** | Images and PDFs open in their own tabs; other binaries offer "Open in default app". |
| **File tree** | Lazy real tree over the workspaces you add; live-refreshes on filesystem changes; right-click actions. |
| **Branch topology** | Real lineage DAG — parent computed from the closest divergence point. Branches checked out in a worktree count as active work. |

### Sessions — every Claude session, live and past

Reads `claude agents --json`. Attach, stop, or resume any session. Full-text search across live sessions **and transcript history** (it greps the actual conversations, not just names). Export a conversation to Markdown.

### Queue — ship the work

Per-project git status (ahead/behind/dirty), trial-merge conflict checks, operator-confirmed push/merge with automatic worktree cleanup, and **collision detection** that flags the same file being edited in two worktrees at once.

### Kanban — plans on a board

PRDs written as `docs/prd-<name>.md` show up as cards with their status. Agents can publish and update their own plans here through the `track_plan` MCP tool.

### Resources — skills, agents, hooks, MCPs

Browse what's installed locally, discover community skills in the marketplace, and install Muya's own Claude Code plugin in one click. "Create with Claude" scaffolds a new resource in a terminal.

### SSH — servers and secrets

| | |
|---|---|
| **Credential vault** | AES-256-GCM + Argon2id, on disk encrypted. Unlock with **Touch ID** (or your Mac password) instead of typing the master password. Locks itself after 15 idle minutes; secrets are wiped from memory on lock, not just dropped. |
| **Direct + CyberArk PSMP** | Muya assembles the connection and injects the password **inside Rust** — it never reaches the frontend or an agent. Handles PSMP's one-session-per-connection model. |
| **File transfer** | `scp` to/from a server, confined to your workspace roots. |
| **Groups, search, import/export** | Organise credentials, search by label/host/tag, import a password, token, API key or SSH key from a file. |

### Chat — Claude ↔ Claude

A local bridge lets a terminal Claude talk to Muya's own Claude. Pairing with another machine uses SPAKE2 + certificate (SPKI) pinning with a short verification code.

---

## For agents — the `muya-mcp` server

Muya ships an MCP server so a Claude Code agent can drive it: **21 tools** across five groups.

| Group | Tools |
|---|---|
| **Remote exec** | `ssh_list_servers`, `ssh_run`, `ssh_open`, `ssh_send`, `ssh_session_open/exec/close`, `ssh_scp`, `ssh_add_server` |
| **Sessions** | `list_sessions`, `read_session`, `send_to_session`, `open_session`, `close_session` |
| **Secrets** | `list_secrets`, `add_secret`, `get_secret`, `update_secret` |
| **Operations** | `list_operations`, `run_operation` — operator-pinned commands that use a secret the agent never sees |
| **Planning** | `track_plan` |

An agent can open a parallel session, hand it a task, read what another session is doing, answer a permission prompt it's stuck on, and close it when done. Credentials are resolved and injected in Rust; agents reference secrets **by name only**.

**Transport:** a stdio sidecar binary the MCP client spawns, talking to the app over a Unix socket that is owner-only (`0600`) and checks the peer's uid. No network port is opened.

### Setting it up

**The server itself needs no installation.** Muya registers `muya-mcp` in your Claude Code MCP
config the first time it runs, and ships the sidecar binary inside the app bundle. Any Claude Code
session you start afterwards can call the tools.

If an agent doesn't see the tools, it's almost always one of these two:

| Symptom | Cause | Fix |
|---|---|---|
| Tools missing in a session that was already open | An MCP client reads the tool list **once, when it connects** | Restart that Claude Code session |
| `Muya app not running` | The sidecar talks to the app over a socket; without the app there's nothing to talk to | Launch Muya |

Verify the server is answering — this asks the sidecar directly and should list the tools:

```bash
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | /Applications/Muya.app/Contents/MacOS/muya-ssh-mcp
```

(Adjust the path if you keep Muya somewhere other than `/Applications`.)

### Install the companion skill (recommended)

The tools work without it, but agents use them far better with it — it explains which tool suits
which job, and the gotchas that aren't obvious from the tool descriptions alone.

Easiest way: open **Resources → Marketplace** in Muya and press **Install** on the *Muya plugin*
card at the top. Or do the same by hand:

```
/plugin marketplace add st4unch/muya
/plugin install muya-mcp
```

| Plugin | What it ships | Always-on cost |
|---|---|---|
| `muya-mcp` | 1 skill: which tool for which job, the PSMP/CyberArk connection-cost model, message-delivery modes, session ownership rules | ~250 tok |

### Letting an agent use your servers and secrets

Nothing is exposed by default — this is opt-in per item, from Muya's **SSH** screen:

1. **Unlock the vault.** Agents can't reach a locked store; SSH tools refuse rather than guess.
2. **Tick "Agent may use this server"** on each server you're willing to expose. Servers without it
   stay invisible to `ssh_list_servers`.
3. Secrets are referenced **by name**. `ssh_run` and `run_operation` inject the value inside Rust —
   the agent never receives it. Only an explicit `get_secret` returns a value.

### What this actually enables

```
You:  "Spin up a session on the API repo and have it fix the failing tests,
       then tell me when it's done."

Agent: open_session(name: "api-tests", initial_message: "…")
       → a new terminal tab appears in Muya, already working
       list_sessions()      → sees it running, and every other session
       read_session(...)    → checks progress without interrupting it
       send_to_session(...) → answers a prompt it got stuck on
       close_session(...)   → tidies up when finished
```

An agent may only close sessions **it** opened — your own session and any tab you opened by hand are
off limits.

---

## Download

Get the latest signed & notarized build from [Releases](https://github.com/st4unch/muya/releases/latest). Requires macOS on Apple Silicon — unzip and run, no installer. The app updates itself from signed releases.

---

## Tech stack

- **Frontend:** React 19, Vite, Tailwind CSS v4, `@xterm/xterm`, `@monaco-editor/react`, `lucide-react`.
- **Backend (Rust):** Tauri v2, `portable-pty`, `notify` (file watching), `sysinfo`, `aes-gcm` + `argon2` + `zeroize` (vault), `security-framework` (Keychain/Touch ID), `rustls` + `rcgen` (paired bridge), `reqwest` (CyberArk REST).
- Stateless, compute-on-demand `git` plumbing — no daemon, no Python.

---

## Build from source

**Prerequisites:** macOS (Apple Silicon), [Node.js](https://nodejs.org) 20+, [Rust](https://rustup.rs), Xcode Command Line Tools, `claude` CLI on `PATH`.

```bash
git clone https://github.com/st4unch/muya.git
cd muya
npm install
npm run tauri dev      # native window with hot reload
```

Distributable build:

```bash
npm run tauri build    # → src-tauri/target/release/bundle/macos/Muya.app
```

---

## Testing

```bash
cd src-tauri && cargo test --lib       # 263 tests
cd .. && npx tsc --noEmit              # types
npm test -- --run                      # 116 tests
npm run build                          # production bundle
```

Tests that need a real sshd are `#[ignore]`d by default:

```bash
docker run -d --name muya-ssh-test -e PASSWORD_ACCESS=true \
  -e USER_NAME=testuser -e USER_PASSWORD='Sup3rSecret!' \
  -p 2222:2222 lscr.io/linuxserver/openssh-server
cd src-tauri && cargo test --lib -- --ignored
```

---

## Project structure

```
src/                     React frontend (32 components)
  components/            Terminal, TerminalGrid, FileTree, FileEditor, SshPage,
                         SessionsPage, QueuePage, ResourcesPage, BranchDAG, …
  lib/                   pure, unit-tested helpers (tabs, format, agent command)
src-tauri/src/
  pty.rs                 PTY-backed terminals + password injection
  agents.rs              `claude agents --json` reader, CLI resolution
  sessions.rs            transcript reading, search, export
  fs.rs                  file tree, git worktrees, branch topology
  pm.rs                  project status, trial-merge, push/merge, collisions
  broker.rs              MCP broker (Unix socket, peer-uid gated)
  bin/muya_ssh_mcp.rs    MCP stdio sidecar the client spawns
  agent_ssh.rs           persistent headless SSH sessions
  ssh.rs / askpass.rs    connection assembly, credential injection
  cyberark.rs            CyberArk PVWA REST (password retrieval)
  credstore.rs           encrypted vault, Keychain / Touch ID
  bridge*.rs             Claude↔Claude chat, paired remote bridge
  watcher.rs             filesystem watching (notify)
claude-plugin/           the muya-mcp Claude Code plugin shipped from this repo
docs/                    SYSTEM.md, PRDs, research, screenshots
```

---

## Design notes

- **Tauri over Electron** — far lower memory with 10 agents + terminals + Monaco, and a fraction of the binary size.
- **App-managed PTY** — agents run in the app's own PTYs, no tmux dependency.
- **Secrets never cross into JS** — the vault decrypts and injects inside Rust; the frontend and any agent only ever see names.
- **No network listener for MCP** — a Unix socket with a peer-uid check, not a local HTTP server.
- **Fail closed** — agent-facing surfaces (SSH servers, operation arguments, file paths) use allow-lists; anything unlisted is refused rather than passed through.

---

## Status

v0.2.44 — actively developed. macOS / Apple Silicon only.

## License

MIT — see [LICENSE](LICENSE).
