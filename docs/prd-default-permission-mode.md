# Default permission mode — one setting every Claude session starts with

The operator asked for `--dangerously-skip-permissions` back, for new and restored sessions alike,
and for the choice to live in Settings rather than in one dialog.

Today the mode is a field of the New agent sheet only, and it resets to "Auto" every time it opens
(`NewAgentSheet.swift:54`). Every other way a session starts has the mode hard-coded:

| Where | Today |
|---|---|
| New agent sheet | picker, always reopens on "Auto" (`NewAgentSheet.swift:54`, `:124`, `:148`) |
| ⌘⇧C in a terminal | `claude --permission-mode auto` (`ShortcutLogic.swift:74`) |
| Resume after a restart / on launch | `claude --resume '<id>' --permission-mode auto` (`PageLogic.swift:116`) |
| Fork a session into a split | `claude --resume <id> --fork-session --permission-mode auto` (`SplitLogic.swift:143,151`) |
| A session an agent opens (MCP `open_session`) | `claude --permission-mode auto` (`SplitLogic.swift:191`) |
| Resources page "create" | no mode flag at all (`ResourcesLogic.swift:97`) |

So a session the operator had running in Bypass comes back after a restart in Auto, and nothing they
can set changes it.

## What is built

**One setting**, in Settings, stored like every other `store: "ui"` row (`SettingsSchema.rows`,
`PageLogic.swift:445`): **Default permission mode**, a popup with the five modes Muya already knows
(`NewAgentCommand.modes`): Manual, Accept edits, Plan, Auto, **Bypass permissions**. The helper line
says what it does and that Bypass means Claude never asks.

**Every start path above reads it.** One accessor, no second copy of the fallback:
`NewAgentCommand.flag(for:)` (or the equivalent) is the only place a mode becomes a flag, and every
site calls it with the stored value.

**The New agent sheet opens on the stored mode** instead of "Auto", and changing it there stays a
one-off for that session — it does not write the setting back.

**Restored sessions get it.** The resume command is rebuilt from scratch (`resumeCommand`), so a
restored session starts in the chosen mode. This is also the honest limit: a terminal that survived
because the daemon kept it running is re-attached, not restarted, so its mode only changes the next
time it actually starts. Say so in the helper text.

**Factory default stays `auto`.** Muya is published; a fresh install must not skip permission checks
because of us. The operator sets Bypass once and it persists.

**Out of scope, deliberately:** the scheduler's per-job "Skip permission prompts" (a job is not a
session and is chosen per job), and `autoApprove` (which answers prompts, a different thing).

## A bug found on the way

`Faz4eLogic.attachCommand` appends `--dangerously-skip-permissions` to `claude attach`, which takes
no options:

```
$ claude attach 'x' --dangerously-skip-permissions
warning: extra arguments ignored: --dangerously-skip-permissions
```

Attaching cannot change the mode of a session that is already running, so the flag is dropped from
that command (and from its test at `ThemeTests.swift:70`). Nothing else changes about attach.

## Acceptance criteria (binary)

1. Settings shows "Default permission mode" with the five modes; the value survives a restart.
2. Changing it changes what every one of the six start paths types. Proved per path, not assumed.
3. With the setting on Bypass, a session restored by the resume path starts with
   `--dangerously-skip-permissions`; with it on Manual, the same path starts with
   `--permission-mode manual`.
4. The New agent sheet opens pre-set to the stored mode; picking another mode there does not change
   the setting.
5. A session an agent opens through MCP `open_session` follows the setting.
6. A fresh profile (no prefs file) behaves exactly as today: `--permission-mode auto`.
7. `claude attach` is typed with no extra flag.
8. Proved live through the debug socket in `native/app/verify-permission-mode.sh`, which must pass.
