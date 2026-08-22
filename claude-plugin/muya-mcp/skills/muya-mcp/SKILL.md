---
name: muya-mcp
description: How to use the `muya-mcp` MCP server's tools well — SSH (ssh_open/ssh_run/ssh_scp/ssh_session_*/ssh_add_server), cross-session messaging (list_sessions/read_session/send_to_session), opening/closing local sessions (open_session/close_session), secrets (add_secret/get_secret/update_secret/list_secrets), operator-pinned operations (list_operations/run_operation), and Kanban tracking (track_plan). Use whenever the muya-mcp server is connected and the task involves SSH, another running Claude session, spinning up a parallel session, a stored credential, or an operator-approved operation — or when unsure which muya-mcp tool fits.
---

# muya-mcp — Muya's agent tool surface

Muya is a desktop control plane for parallel Claude Code agents. When its `muya-mcp` MCP
server is connected, you get 21 tools across five groups. This skill is the "which tool,
and how" reference — the tools' own JSON-schema descriptions are accurate but terse;
this fills in the workflow-level gotchas that span more than one tool.

**Always run `list_sessions` (and `ssh_list_servers` for SSH work) before anything else in
a group** — you need real names/aliases, and guessing is never allowed (see below).

## Decision table

| I want to... | Tool |
|---|---|
| See what SSH servers I'm allowed to use | `ssh_list_servers` |
| Run ONE remote command, get stdout back | `ssh_run(alias, command)` |
| Run several INDEPENDENT remote commands (fast, one login) | `ssh_run(alias, commands: [...])` |
| Run commands that must share shell state (cd/env/sudo), or many commands on a PSMP server | `ssh_session_open` → `ssh_session_exec` (repeat) → `ssh_session_close` |
| Do interactive remote work a human should watch (login, 2FA/OTP/RADIUS, a TUI) | `ssh_open` (opens a visible tab) + `ssh_send` for follow-up keystrokes |
| Register a new SSH server | `ssh_add_server` |
| Copy a file to/from a server | `ssh_scp` |
| See what other Claude sessions are running | `list_sessions` |
| Check what another session is doing, without messaging it | `read_session` |
| Tell another session something / hand off a finding | `send_to_session(deliver: "auto")` |
| Answer a permission/trust prompt another session is stuck on | `send_to_session(deliver: "keys")` |
| Spin up a NEW parallel session and message it, without asking the operator | `open_session` |
| Close a session I opened with `open_session` | `close_session` |
| Store/read/rotate a credential | `add_secret` / `get_secret` / `update_secret` / `list_secrets` |
| Run an operator-pinned command (aws/kubectl/git...) that uses a secret I never see | `list_operations` → `run_operation` |
| Put a plan/PRD on the operator's Kanban board | `track_plan` |

## SSH group

- **Default remote-exec is `ssh_run`**, not `ssh_session_open`. Only reach for a persistent
  session when you genuinely need shared shell state or many round-trips against a
  **PSMP** (CyberArk-proxied) server — PSMP binds one audited session per connection, so
  a fresh `ssh_run` call each time means a fresh login/OTP each time. `ssh_run(commands:
  [...])` already amortizes that for independent commands over one connection; only use
  `ssh_session_open/exec/close` when commands must share state or the back-and-forth is
  long. **Always `ssh_session_close` when done** — it's not automatic.
- **PSMP + 2FA**: `ssh_run`/`ssh_scp` refuse (never guess) if PSMP shows a 2FA/OTP/RADIUS
  challenge — switch to `ssh_open` so a human completes it. A timeout with no prompt at
  all on a PSMP server usually means an out-of-band RADIUS push is pending approval.
- `ssh_open` is for a human-watched interactive tab (you get no output back — use
  `ssh_send` for keystrokes, `ssh_run` if you need to read the result yourself).
- Credentials are never exposed to you at any point in this group — Muya resolves and
  injects them server-side.

## Session-messaging group (list_sessions / read_session / send_to_session)

- `list_sessions` returns Muya's own **authoritative names** (what the operator actually
  calls each session) plus `status` and, when a session is blocked, `waitingFor` (e.g.
  `"permission prompt"`).
- `send_to_session`/`read_session`/`close_session` resolve `target` the same way: exact id
  → exact name → unique substring. **On an ambiguous match you get candidates back — ask
  the operator which one, never guess.**
- `send_to_session` has **three delivery modes and picking the wrong one breaks things**:
  | `deliver` | What it does | Use for |
  |---|---|---|
  | `"auto"` (default) | Hands you the canonical name; YOU then call the native `SendMessage` tool yourself | Normal messages — doesn't interrupt the target's running work |
  | `"muya"` | Muya types `[message from X via Muya] <text>` into the target's terminal | Fallback when `SendMessage` isn't available to you |
  | `"keys"` | Muya types `text` into the terminal **verbatim, no wrapping** | Answering a prompt/menu the target is stuck on (`waitingFor` is set) |

  **Never use `"muya"` to answer a prompt** — the wrapping text gets typed into the menu
  itself and breaks it. For `"keys"`, pass exactly what a human would type, e.g. `"1\n"`
  or `"y\n"`.
- `read_session` is read-only and has no native equivalent — use it to check on a session
  before deciding whether messaging it is even necessary.

## open_session / close_session

- `open_session(name, cwd?, initial_message?)` opens a brand-new local Claude session as a
  Muya terminal tab — the local analog of `ssh_open`, but no server/credentials involved.
  It runs `claude --dangerously-skip-permissions --name <name>`, same trust level as
  Muya's own "+ New Agent" button.
- **Give it `initial_message` instead of opening-then-`send_to_session`-immediately** — a
  freshly opened session isn't reliably discoverable by name for a few seconds, but
  `initial_message` is handed to it directly on launch and always lands.
- **For any FOLLOW-UP message, use `send_to_session(target: name, deliver: "muya")`** —
  not `"auto"`. The new session runs bypassing permission prompts, and Claude Code's own
  `SendMessage` holds a message to a bypass-mode session for the operator's approval
  unless the sender also self-identifies as bypassing — `deliver:"muya"` sidesteps that
  gate entirely and is the only way to guarantee unattended delivery here.
- `close_session(target)` — **you may only close a session you yourself opened with
  `open_session`.** Closing the operator's own main session, or one they opened by hand
  ("+ New Agent"), is refused. Always close a session you opened once you're done with it.
- A first-time-seen `cwd` would normally show claude's own "is this folder trusted?"
  prompt — `open_session` auto-accepts it (Muya's workspaces are the operator's own
  trusted directories), so you don't need to do anything about that.

## Secrets & operations group

- `list_secrets`/`add_secret`/`get_secret`/`update_secret` — secret **values** are only
  ever returned by `get_secret`, and only once the operator has unlocked the Password
  Store. Everywhere else (naming a secret for `ssh_add_server`, `run_operation`, etc.)
  you reference it **by name only**.
- Prefer `run_operation` over `get_secret` when you just need to *use* a credential (e.g.
  an operator-pinned `aws`/`kubectl`/`git` command) — it injects the secret without ever
  exposing the value to you. Reach for `get_secret` only when you must place the actual
  value somewhere yourself (a config file, an env var).
- `run_operation` arguments are policed by a fail-closed allow-list — pass flag values as
  `--flag=value`; unlisted flags/operands are rejected before the fixed program ever runs.

## track_plan

Publishes/updates a PRD card on Muya's Kanban board (writes `docs/prd-<slug>.md` +
progress file in **your current project directory**). Call once with `status: "active"`
when you start a plan, again with the same `title` and `status: "done"` when finished.

## General principles across all of this

- **Never guess an ambiguous target** — every fuzzy-resolution tool here (`send_to_session`,
  `read_session`, `close_session`) returns candidates instead of picking one; ask the
  operator.
- **Secrets are never exposed to you** unless you explicitly call `get_secret` — every
  other tool in this surface (SSH, operations) injects credentials without revealing them.
- **Ownership is checked, not assumed** — you can `ssh_send`/`close_session` only sessions
  you yourself opened; the operator's own sessions and manually-opened tabs are off-limits.
