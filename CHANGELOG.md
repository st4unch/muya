# Changelog

All notable changes to Muya are documented here, newest first.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.2] - 2026-07-23

### Fixed
- **UI stutter introduced in 0.2.1.** The terminal-directory and Claude-session
  probes ran as synchronous Tauri commands, so every poll executed on the main
  thread and froze the interface. Both now run off the main thread.
- **Update never installed — "invalid gzip header".** Releases shipped a `.zip`,
  but the macOS updater always unpacks the downloaded artifact with gzip + tar.
  Releases now publish `Muya-<version>-<arch>.app.tar.gz` (the `.zip` remains for
  manual download).
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
