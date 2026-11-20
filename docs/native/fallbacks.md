# Faz 0 written fallbacks (gate condition, 2026-11-03)

The Faz 0 gate (PRD §10) needs S6-S9 to PASS or to have a written fallback. S7 and S9 have
measurements (see `docs/prd-native-rewrite.progress.md`). S6 and S8 could not run yet: S6 needs the
operator's Touch ID, and S8 needs Sparkle fetched from GitHub, which requires the operator's approval.
This file is the fallback for each. It is binding until the spike runs.

## S6 — vault: who reads the biometry-protected Keychain item

| | Variant A: muyad reads it | Variant B: the UI reads it, hands the key to muyad |
|---|---|---|
| Prompt attribution | The Touch ID sheet names the agent, which users may not recognise | The prompt names Muya |
| Works with no window | Yes (schedules, MCP calls while the UI is closed) | No: unlock needs the app |
| Key in transit | None | One message over the client socket (peer gate: Muya.app identifier only) |

- **Plan:** run S6 first with A, because it keeps vault secrets in one process.
- **Fallback if A's prompt is not attributed to Muya, or fails at screen lock/unlock:** use B. The
  key crosses the client socket once per unlock and is zeroized in the UI right after it is sent.
  muyad keeps today's 15-minute idle lock and zeroize on lock (credstore.rs behaviour).
- **Fallback if neither prompt works under the agent layout:** keep the vault in the UI process
  (today's model). muyad asks the UI for one secret per use over the client socket. Requests made
  while no UI is attached get a typed "vault locked: open Muya" error, which is today's behaviour
  when the vault is locked.
- **Not affected:** the Faz 1 broker. Secret-returning broker paths (`get_secret`) stay behind the
  `VaultLocked` error until S6 decides. Faz 1 builds everything else.

## S8 — update: Sparkle replaces the bundle while ptyd keeps sessions

- **Protocol rule (Faz 1, independent of Sparkle):**
  - Every socket starts with a version handshake.
  - ptyd accepts a muyad or UI one protocol version older or newer.
  - Otherwise ptyd answers `incompatible` and keeps every session alive.
  - The app then shows the operator's chosen dialog: "Restart sessions now / later".
- **Plan:** Sparkle 2, non-sandboxed layout, no XPC services, EdDSA key (PRD Faz 5).
- **Fallback if Sparkle cannot replace a bundle whose nested LaunchAgent binaries are running:**
  1. The app downloads and verifies the update itself (EdDSA signature plus Developer ID check, same
     checks as today's Tauri updater).
  2. It stages the new bundle next to the old one.
  3. It asks ptyd to "prepare for update", which stops accepting new sessions.
  4. It swaps the bundle with `rename(2)`.
  5. It restarts muyad and the UI from the new bundle.
  6. ptyd is re-executed only when the protocol changed and the operator chose "now".
  Today's `publish-release.sh` feed stays the source.
- **Fallback if ptyd cannot survive any bundle swap:** sessions are re-created after the update
  with `claude --resume` from `sessions.json` (PRD §6 respawn path). The update dialog says so before
  it runs.
