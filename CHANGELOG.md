# Changelog

All notable changes to Muya are documented here, newest first.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.22] - 2026-08-06

### Added
- **`ssh_run` / `ssh_scp` now return `stderr`.** They used to return only an exit code,
  so a failed transfer was undiagnosable. The real error message is now included — so a
  server-side block (e.g. a CyberArk PSMP policy that permits uploads but blocks
  downloads) can be told apart from a genuine transfer error. (The `-O` legacy-protocol
  fix in 0.2.21 made PSMP *uploads* work; a still-failing download now shows why.)

## [0.2.21] - 2026-08-06

### Fixed
- **`ssh_scp` through CyberArk PSMP forces the legacy transfer protocol.** File
  transfers to a PSMP-fronted server failed (exit 255 / timeout / exit 1) while
  `ssh_run` worked. The cause was the transfer protocol, not auth: modern OpenSSH's
  `scp` uses the SFTP subsystem by default, which CyberArk PSMP doesn't proxy (it
  proxies the classic scp channel — the same one `ssh_run` uses). Muya now runs `scp`
  with the original protocol (`-O`) for PSMP servers. Direct (non-PSMP) transfers are
  unchanged. (End-to-end confirmation against a live PSMP is pending an operator re-test.)

## [0.2.20] - 2026-08-06

### Fixed
- **CPU spikes / stutter while editing are gone.** Two background checks (branch list
  and cross-worktree collisions) were re-running their `git` subprocesses on every file
  change and every 5 seconds — a subprocess storm that pushed CPU to ~20% and made the
  UI stutter during active work. They now refresh at most every 20s (not on every file
  change) and run off the shared worker pool, so file edits stay smooth.
- **The Kanban shows PRDs created by agents.** Agents run in git worktrees and drop
  their PRDs there, but the board only scanned your manually-added workspace folders —
  so an agent-created PRD was invisible. The board now scans every known project root
  (workspaces + worktrees + live agent working dirs) and de-duplicates, so every PRD
  shows up once.

## [0.2.19] - 2026-08-05

### Changed
- **SSH password handling is now deterministic (fixes PSMP `ssh_scp` + flaky `ssh_run`).**
  Muya used to type the password into the terminal when it spotted a "password:" prompt —
  a timing race that made `ssh_scp` fail against CyberArk PSMP (hang/timeout or "Permission
  denied") and made `ssh_run` fail intermittently (~1 in 3). Muya now hands the password to
  ssh/scp through OpenSSH's own askpass channel, so there's no prompt-timing guesswork — it
  either has the password ready or it doesn't. A PSMP 2FA/OTP challenge is still refused
  (the password is never sent to a one-time-code field). The password is streamed over a
  private in-memory pipe — never written to disk, never in the process's arguments,
  environment, or logs. (End-to-end confirmation against a live PSMP is still pending an
  operator re-test; verified 15/15 deterministic against a test SSH server.)

## [0.2.18] - 2026-08-05

### Fixed
- **`ssh_scp` now authenticates against CyberArk PSMP.** File transfers to a PSMP-fronted
  server were failing with "Permission denied (publickey,keyboard-interactive)" (exit 255):
  scp tried public-key auth first and the PSMP proxy closed the connection before the
  "Vault Password:" prompt appeared, so Muya never got to inject the password. scp now
  disables public-key auth whenever Muya will inject a stored/CyberArk credential (matching
  what `ssh_run` already did), so it reaches the password prompt. (End-to-end confirmation
  against a live PSMP is pending an operator re-test.)

## [0.2.17] - 2026-08-05

### Added
- **Agents can transfer files over SCP (`ssh_scp`).** A Claude agent can now upload or
  download a file to/from any SSH server you've allowed it to use (including PSMP), by
  server alias — Muya injects the credential, the agent never sees it. Guardrails: the
  local file path is confined to your **workspace folders** (the agent can't read
  `~/.ssh` or write outside a workspace), the agent can't pass risky scp flags (`-o`,
  `-i`, …), and a PSMP 2FA/OTP challenge is refused rather than guessed. PSMP profiles
  gain an optional **SCP options** field for any `-o` your environment requires.

### Note
- Verified end-to-end against a live SSH server (upload + download); confirmation against
  a real CyberArk PSMP transfer is still pending an operator test.

## [0.2.16] - 2026-08-04

### Fixed
- **Opening a terminal, connecting SSH, and the chat view are responsive again.** A
  previous change mounted every side panel (Sessions, Resources, Queue, PRD, SSH, Chat)
  at startup, so they all fetched at once and competed for the UI thread — slowing
  terminal open / SSH connect and making the chat load late. Panels now load the first
  time you open them and stay put afterward, so startup is light again.
- **Session tabs keep their own name.** Tabs no longer get relabeled with Claude's
  auto-generated "<project>-N" session name (which looked like just the project name);
  a tab keeps the name it was opened with.

## [0.2.15] - 2026-08-04

### Fixed
- **File tree and file opening are fast again.** Listing a folder or opening a file
  could take ~10 seconds: background polls (git status, and the Claude-session probes)
  were spawning subprocesses that tied up the shared worker pool, so the quick file
  reads had to wait their turn. Those polls now run off that pool and refresh less
  aggressively — listings and file opens are near-instant again.

### Changed
- **Password Store unlock shows an "Unlocking…" state.** The unlock runs a deliberately
  heavy key-derivation (Argon2id) that can take a second or two; the button now shows a
  spinner + "Unlocking…" and a short "deriving the key…" note so it's clearly working,
  not stuck. Security is unchanged — only the wait is now visible.

## [0.2.14] - 2026-08-04

### Changed
- **Agents can run commands through CyberArk PSM for SSH (PSMP) more safely.** When an
  agent uses `ssh_run` on a PSMP-fronted server and PSMP asks for a 2FA/OTP/passcode
  (RADIUS) code, Muya no longer submits the stored password into that prompt — it stops
  and tells the agent to use the interactive `ssh_open` instead. This prevents wasted
  logins and possible account lockouts. A PSMP connection that just times out with no
  prompt now returns a clearer "this may be a RADIUS push — use ssh_open" hint. Ordinary
  (non-PSMP) SSH command runs are unchanged.

### Note
- The PSMP command-run path is verified by unit tests; end-to-end confirmation against a
  live PSMP server is still pending an operator test.

## [0.2.13] - 2026-08-04

### Fixed
- **SSH: you can now open multiple terminals at once.** Clicking **Connect** always
  opens a new, independent terminal — so you can run several sessions to the *same*
  host side by side, and to different hosts at the same time. Previously a second
  Connect to a host replaced the first tab instead of adding one.

## [0.2.12] - 2026-08-03

### Added
- **Claude-to-Claude chat is back in the UI.** The bridge that lets two Claude agents
  talk to each other over a paired connection is re-wired into the Chat view, so you
  can open it, pair with a peer, and exchange messages again.

### Changed
- **Sessions / Kanban / Resources / Queue no longer refresh on every click.** Each page
  now loads once when first opened, has a manual refresh, and auto-refreshes at most
  once an hour — and never all at the same time (one finishes before the next starts).
  This cuts constant background CPU use, especially the Sessions poll, without you
  losing freshness.

### Performance
- **Faster Sessions refresh.** The list no longer re-probes for the `claude` binary on
  every refresh and no longer runs a separate git lookup for each session in the same
  folder, trimming the per-refresh cost. The displayed data is unchanged.

## [0.2.11] - 2026-08-02

### Added
- **Password Store: view, copy, and edit a stored credential.** Each credential now
  has an eye toggle to reveal its value inline, a copy button, and an edit button
  that loads it back into the form to change the value or details. Revealing requires
  the store to be unlocked and is a local UI action only — it is never exposed to
  agents. (Agents already have the separate, opted-in `update_secret` MCP tool.)
- **Green "DONE" pulse when a Claude session finishes a job.** Complementing the
  orange "NEEDS YOU" blink (waiting for your input), a terminal's row now pulses green
  when its Claude session finishes working, so you can tell at a glance which agents
  are done. Opening the tab clears it; a pending decision (orange) takes priority.

### Fixed
- Turkish characters (ı/ş/ğ/ç…) are no longer flagged as "confusable with ASCII" in
  the editor.

## [0.2.10] - 2026-08-01

### Added
- **Settings** in the Muya menu (⌘,): a **Debug logging** toggle + a log-file path.
  When on, every CyberArk and SSH step (auth method, URL, HTTP status, RADIUS push
  wait, account fetch, connect command) is written to the log — secret VALUES are
  never logged. Use it to diagnose connection issues.
- **Agents can register SSH servers** — a new `ssh_add_server` MCP tool completes the
  agentic SSH loop: an agent adds a server (optionally attaching a stored credential
  by name) and then uses `ssh_open` / `ssh_run` on it. Guardrails: the agent cannot
  set raw ssh options or a jump host, host/username are validated, and it can never
  overwrite a server you configured (agent-added servers are badged in the UI).

### Fixed
- **CyberArk RADIUS "Test connection" no longer 403s after you approve the push.**
  The test previously logged on twice (which fired a second 2FA push that failed);
  it now logs on once and verifies the token with a single read.

## [0.2.9] - 2026-07-31

### Added
- **Open files refresh when they change on disk.** When an agent (or you, externally)
  edits a file that's open in Muya, the view updates automatically — only the tab
  you're looking at reloads (background tabs stay untouched and refresh when you
  switch to them), so it stays light on CPU. If a file changes in the editor while
  you have unsaved edits, your work is never overwritten — a "changed on disk —
  reload" prompt lets you refresh on demand.

## [0.2.8] - 2026-07-29

### Added
- **Claude agents can now read and rotate stored secrets** (not just use them):
  `get_secret` returns a secret's value when you need to place it into a system
  you're configuring, and `update_secret` rotates an existing one — both only while
  the Password Store is unlocked. Storing your systems' passwords here stays safer
  than a plaintext file (encrypted at rest, human-unlock gated).
- **Markdown files open as a clean rendered view on single-click** (nice for reading
  docs); right-click **"Open in Muya"** (or the reader's **Edit** button) still opens
  the editable editor. Rendered content is sanitized before display.

### Fixed
- **The muya-ssh MCP tools now resolve a secret by the name you gave it** (in
  `muya-agent-ops.json`), not only its internal id — fixes "stored credential not
  found" when an operation referenced a secret by name.
- **CyberArk "Test connection" now actually sends a password** — it uses the typed
  password or, if empty, the stored credential you selected (the login-credential
  picker was previously ignored), and gives a clear error instead of CyberArk's
  cryptic "Missing mandatory parameter [Password]".
- **A hung agent operation can no longer freeze the Claude session that called it** —
  `run_operation` now times out (60s) and reports it, instead of waiting forever.
- **The file-tree right-click menu no longer flickers / needs several clicks.**

## [0.2.7] - 2026-07-26

### Fixed
- **The muya-ssh MCP plugin now actually appears in Claude.** It was being registered
  in a file Claude Code doesn't read (`~/.claude/.mcp.json`), so the tools never showed
  up in `claude mcp list`. It's now written to the config Claude actually reads
  (`~/.claude.json`), safely: your existing configuration is preserved, an unreadable
  config is left untouched rather than overwritten, and the write is atomic. The same
  fix applies to any MCP server installed from the Resources page. (Start a new
  terminal session to pick up the newly-registered plugin.)

## [0.2.6] - 2026-07-26

### Added
- **Muya can now lend secrets to Claude agents without ever revealing them.** A new
  `muya-ssh` MCP plugin (registered automatically for agents running in Muya's
  terminals) exposes tools so an agent can:
  - **List and connect to SSH servers by alias** — Muya types the password for the
    agent; it is never shown to the model. Opt in per server with the new
    "Agent may use this server" toggle.
  - **Run a command on a server** and get back its output, again without seeing the
    password.
  - **Use stored secrets to run operator-defined operations** (e.g. an `aws`/`git`
    command): the secret is placed in the program's environment and only the output
    comes back. Operations are defined by you in `~/.claude/muya-agent-ops.json`, and
    a fail-closed argument policy blocks the escape hatches that would leak a secret.
  - **Store a newly generated secret** by name for later reuse (write-only — it is
    never read back).
- **Password Store** now supports **API key** and **token** secret types and a
  per-secret **description** (so an agent can pick the right one by name).
- **Right-click a terminal** in the Sessions panel for **Duplicate** (re-opens it,
  reconnecting SSH / re-resuming Claude) and **Reveal in Finder**.

### Fixed
- The app failed to launch in development after a second bundled binary was added;
  the correct default binary is now declared.

### Security
- Every secret stays inside the app process: resolved in Rust, injected into the
  SSH prompt or the child process's environment, and never sent to the agent, the
  command line, logs, or disk in plaintext. Agent access additionally requires the
  encrypted store to be unlocked by you, and the broker socket is owner-only
  (rejects any other user).

## [0.2.5] - 2026-07-25

### Added
- **CyberArk actually connects now** — a real "Test connection & browse accounts"
  panel in the CyberArk tab: enter the PVWA URL, vault username and password, test
  the login (CyberArk / LDAP / RADIUS with push, plus older-PVWA fallback), then
  search and browse your vault accounts. A tested account can be assigned to a
  server as its credential.
- **Passwords are now sent to the server for you** — when a server's credential is
  a stored password or a CyberArk account, connecting logs in automatically instead
  of leaving you at the server's own password prompt. The secret is handled entirely
  inside the app and never exposed to the interface.
- **Extra SSH options per server** — a field to pass raw `ssh` flags such as
  `-X`, `-L 8080:localhost:80` or `-J jump@host` on connect.
- **Pick a stored/CyberArk credential when adding a server** — the server form now
  uses the same credential picker as the CyberArk tab.

### Fixed
- **Editing a server no longer resets when you switch tabs** — the SSH page keeps
  your in-progress add/edit form (and CyberArk session) while you move to Control,
  Sessions, Queue and back.
- **Reconnecting after a failed SSH works** — each Connect opens a fresh terminal
  that actually re-runs `ssh`, instead of reusing a dead tab where nothing happened.
- **CyberArk settings now confirm they saved** — a "Saved" indicator appears after
  saving.
- **PSMP jump-server profiles are editable** — not just add and delete.

## [0.2.4] - 2026-07-25

### Added
- **SSH Configuration** — a new "SSH" tab in the main area to manage remote SSH
  connections:
  - **Servers** — add / edit / remove SSH targets, with duplicate protection on
    host + port + user. One-click **Connect** opens the session in a terminal tab.
  - **PSMP jump-server** profiles for CyberArk Privileged Session Manager for SSH.
  - **CyberArk PAM** connection settings (URL, auth method, TLS, internal CA path).
  - **Password Store** — your own AES-256-GCM encrypted credential store, unlocked
    by an Argon2id master password. Show/hide the master password, export the master
    password or an encrypted backup, and import / export SSH keys.
  - **Reuse credentials** — pick a stored credential (or save a new one) wherever a
    password is needed, e.g. the CyberArk login.
- **"Open Claude Here"** in a folder's right-click menu (below "Open in Terminal
  Here"): opens a terminal in that folder and launches Claude straight away.
- **Error logging to a file** — the app now writes logs to its App log directory and
  captures panics and uncaught frontend errors, so problems can be diagnosed after
  the fact (useful when continuing on another machine).

### Fixed
- **Option+Arrow no longer prints `;3C` / `;3D` noise.** Option+Left/Right now move
  by word (readline meta-b/meta-f) and Option+Up/Down act as plain history arrows,
  like Terminal.app / iTerm2.

### Notes
- SSH is a work in progress. Server management, the encrypted store, credential
  reuse, and Connect are done and verified live. Still to come: Touch-ID
  auto-unlock, direct-SSH password injection / ssh-agent key auth, and the live
  CyberArk logon + connection test.

## [0.2.3] - 2026-07-24

### Added
- **Sessions that need your decision now blink.** When a Claude session pauses on
  a permission/confirmation prompt, its row in the Sessions page and its tab in
  the TERMINALS panel pulse amber with a "NEEDS YOU" marker. A tab stops blinking
  the moment you open it (opening it counts as "I'm answering"); a later prompt
  blinks again. Honours reduced-motion.
- **Edit a scheduled prompt.** The pencil on a pending prompt loads it back into
  the form; the button becomes "Save changes".

### Changed
- **Terminal tabs show their live directory** and adopt their Claude session's own
  name; the icon reflects whether Claude is running (Claude mark) or the tab is a
  plain shell (terminal glyph), switching back when Claude exits.
- **First ⌘Q shows a "press ⌘Q again to quit" hint** instead of doing nothing, so
  a real quit is a deliberate double-press.

### Fixed
- **Closing files no longer jumps focus onto a terminal.** Closing a file tab now
  moves focus to a neighbouring file, so a rapid string of ⌘W closes can't land on
  a terminal and accidentally kill a running Claude session.
- **Esc at an open dialog closes the dialog, not the terminal.** A modal (New
  Terminal, Scheduled Prompt, …) now swallows keystrokes so Esc can no longer slip
  into the focused terminal and interrupt Claude.

## [0.2.2] - 2026-07-23

### Fixed
- **UI stutter introduced in 0.2.1.** The terminal-directory and Claude-session
  probes ran as synchronous Tauri commands, so every poll executed on the main
  thread and froze the interface. Both now run off the main thread.
- **Update never installed.** Releases shipped a `.zip`, but the macOS updater
  always unpacks the downloaded artifact with gzip + tar ("invalid gzip header").
  Releases now publish `Muya-<version>-<arch>.app.tar.gz` (the `.zip` remains for
  manual download), built without macOS AppleDouble sidecars — those appear as a
  stray top-level `._Muya.app` entry that the updater cannot unpack.
- **Every file reported as a conflict.** The "Lock/Edit File Telemetry" panel
  flagged each changed file as edited in two worktrees when a repository *and* a
  folder inside it were both added as workspaces. Worktree identity now comes
  from the real worktree root, so the same tree added twice counts once. Genuine
  cross-worktree conflicts still report.

### Changed
- The Claude-session probe (which shells out to the Claude CLI) now runs every
  ~15 s instead of every 3 s; the cheap directory probe keeps its 3 s cadence.
- A terminal tab adopts its Claude session's own name, so the tab label matches
  what Claude calls itself. A manual rename is preserved.

## [0.2.1] - 2026-07-23

### Added
- **Live working directory per terminal.** The terminal list shows where each
  shell *currently* is instead of where it was opened.
- **Tabs remember their own Claude session.** After a restart, clicking a
  restored tab resumes that tab's own conversation
  (`claude --resume <id> --dangerously-skip-permissions`) rather than opening an
  empty shell.
- Claude sessions and plain terminals are distinguished by icon.
- Session resume ids are shown in full and copy on click; the previous 8-character
  truncation could not be used with `claude --resume`.

### Changed
- Live sessions are listed newest-first.
- Markdown files open **editable** in the centre editor like any other file.
- Update failures stay on screen and are logged instead of disappearing after
  five seconds.

### Removed
- The Chat view, the Vault Context panel, and the read-only Markdown side panel.

### Fixed
- **Remote pairing failed with an opaque TLS error.** The pairing listener read
  the PIN before it was generated, so every incoming connection was rejected. The
  PIN is now read when the connection arrives.
- **Stopping the listener left its port bound**, so restarting reported "already
  active". Stopping now actually releases the port.
- The listen address is validated before binding, and only an address that this
  machine can actually bind is suggested.
- Vault search no longer depends on one hardcoded Python path; setup is
  reproducible via `scripts/setup-vault.sh` (see `docs/vault-setup.md`).

[0.2.2]: https://github.com/st4unch/muya/releases/tag/v0.2.2
[0.2.1]: https://github.com/st4unch/muya/releases/tag/v0.2.1
