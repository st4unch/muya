# MuyaNative (Faz 2 test app)

Native macOS app that talks to `muyad` (PRD docs/prd-native-rewrite.md §8). AppKit + Metal + libghostty-vt, no packages.

| Command | What it does |
|---|---|
| `./build.sh` | builds `build/MuyaNative.app` (bundle id `com.staunch.muya.dev`, ad-hoc signed) |
| `./build.sh test` | client unit tests (frame codec, partial reads, fuzz, wire shape; `MUYA_TEST_SOCKET=<muyad socket>` adds a live test) |
| `./run-dev.sh` | starts ptyd + muyad (debug builds, or `MUYA_BIN_DIR=<dir>`) in a temp HOME with temp sockets, and the app; `status`, `app` (relaunch only the app), `stop` (kills exactly the recorded PIDs) |
| `./verify.sh` | spawns 3 sessions, types through the app, screenshots dark + light, `kill -9`s the app, relaunches, compares sessions and screen |
| `./verify-terminal.sh` | selection / copy / paste, mouse reporting vs Shift, scrollback, IME preedit (API calls only), 6-tile grid: asserts and screenshots dark + light |
| `./verify-files.sh` | Faz 3a: file tree (lazy, hidden toggle, git-ignored dimmed, context menu actions, rename / trash), the five viewers, AC15; screenshots dark + light |
| `./measure-ac14.py` | AC14: external create / rename / delete / mkdir / 200-file burst -> time until the tree shows it |
| `./measure-ac24.py` | AC24: 25 streaming sessions, window minimized -> app CPU; simulated sleep / wake -> sessions kept, statuses, output flowing (`AC24_FAST=65536 AC24_KEY=ac24_light_stream` for the light stream) |
| `./probe-appkit-webkit.py` | AC15 evidence: WebKit regions of an empty AppKit window vs the app |
| `./measure-ac7.py` | AC7: 25 streaming sessions, 6 in the grid; fps, frame p95, echo, switch, RSS -> `measurements.json` (`ac7`) |
| `./verify-pages.sh` | Faz 4a: Sessions (grouped history, cancellable content search, resume, Markdown export), Schedules (muyad owns the timers; validation messages, run now, history), Settings (persisted + read back after an app relaunch), command palette; keyboard navigation, in-app and AXUIElement (`tools/ax-audit.swift`) accessibility audits; screenshots dark + light (`screenshots/pages-*.png`). Synthetic transcripts + a fake `claude` in a throwaway HOME (`make-pages-fixtures.py`) |
| `./measure-faz4a.py` | Faz 4a: CPU / RSS idle and during a full-scan search over 500 synthetic transcripts (~95 MB), cancel latency -> `measurements.json` (`faz4a`) |
| `./measure.py` | CPU / footprint / GPU, idle and during `yes \| head -c 50000000`; last run in `measurements.json` |

Test hook: with `MUYA_DEBUG_SOCKET` set the app also listens on that Unix socket (one command per line: `sessions`, `new <cwd>`, `select <id>`, `click <row>`, `type "<json>"`, `nsevent "<json>"`, `nskey <code> [mods]`, `text`, `appearance dark|light`, `metrics`, `windowid` ...). `run-dev.sh` sets it; a normal launch has no such socket.

Faz 2b debug commands: `grid on|off|toggle`, `tiles`, `mouse down|drag|up <col> <row> [clicks=N] [tile=N] [shift|opt]`, `selection`, `copy`, `paste`, `clipboard "<json>"`, `clear-selection`, `preedit "<json>"`, `commit "<json>"`, `unmark`, `firstrect`, `wheel <lines>`, `scrollstate`, `bytes`, `probe-echo <char>`, `probe-switch <id>`.

Keys: ⌘C copies the selection, ⌘V pastes (bracketed paste is muyad's job), ⌘A selects everything, ⌥⌘G toggles the grid. Shift-drag selects even while the program tracks the mouse; ⌥-drag selects a block. New output and typing return the view to the bottom.

Faz 3a debug commands: `files`, `files-root`, `files-expand <path>`, `files-hidden on|off`, `files-stats`, `files-select|files-menu|files-open|files-terminal|files-copypath|files-trash <path>`, `files-rename <path> <name>`, `viewer-open <path>`, `viewer`, `viewer-close`, `minimize`, `restore`, `visibility`, `occlude yes|no`, `sleep`, `wake`.
The text viewer is an interim read-only NSTextView until the editor component decision.

Faz 4a debug commands: `page sessions|schedules|none`, `sessions-view|-reload|-search <q>|-cancel|-select <id>|-resume <id>|-export <id> <dest>`, `sched-view|-new|-edit <name>|-set <field> <value>|-save|-editor|-cancel|-run <name>|-toggle <name> on|off|-delete <name>|-history <name>|-history-view|-history-close`, `settings-open|-get <id>|-set <id> <value>|-rows|-visible|-close`, `palette-open|-query <q>|-state|-run [id]|-close|-shortcut`, `menu-item <title>`, `press <tab|shift-tab|return|esc|down|up|space|cmd-k|cmd-comma>`, `focus`, `ax-audit [settings]`, `appearance-name`.
The views talk to muyad through protocol minor 2 (`Rpc` / `RpcReply` / `RpcCancel`): `sessions.history|search|export`, `schedules.list|save|validate|set_enabled|delete|runs|run_now`, `prefs.get|set`, `debug_log.get|set`.
