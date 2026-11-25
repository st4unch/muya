# Password Store (classic React) - visual spec for AppKit port

Sources: `src/components/SshPage.tsx` (SSH page, tab "Password Store", component starts ~L971, list render L1314-1475), `src/components/sshStyles.ts`, tokens `src/styles/tokens.css`. Tailwind v4: 1 spacing unit = 4px, `text-xs`=12px/16, `text-sm`=14px/20, `text-lg`=18px/28. Icons: lucide, `h-4 w-4` = 16x16, stroke 2 (default).

## 1. Page structure and toolbar
The store is a TAB of the SSH page, not a standalone page.
- Page: `flex-1 overflow-auto` > `w-full p-6 space-y-4` (24px padding, 16px between blocks, no max width) (SshPage L286-288).
- Header: ServerIcon 20x20 `--text-muted` + h1 "SSH Configuration" `text-lg font-semibold` (18px/600), gap 8 (L289-291).
- Tab strip (L294-317): `flex gap-1 border-b border-[var(--border)]`. Tabs "Servers", "CyberArk", "Password Store". Each `px-3 py-2 text-sm` (14px), `border-b-2 -mb-px`. Active: border + text `--text`, weight 600. Inactive: transparent border, `--text-muted`, hover `--text`.
- Error banner (L319): `text-sm rounded bg --danger-pill-bg, text --danger-text, px-3 py-2`, message left, X icon 16 right. Also used for export-success messages.

### Unlocked body (`space-y-3` = 12px between children, L1314)
Row 1 toolbar (L1315-1349): `flex justify-between items-center` (NO wrap, no responsive handling; just overflows when narrow).
- Left: status `text-sm` colour `--success-text`, flex gap 4: Unlock icon 16 + text `Unlocked · {n} item(s)` (n = ALL creds, not filtered).
- Right: `flex gap-2` (8px) buttons in order:
  1. `Add credential` BTN (primary) with Plus icon 16, `mr-1`.
  2. `Import SSH key` BTN_GHOST, Upload icon.
  3. `Import credential` BTN_GHOST, Upload icon.
  4. `Export backup` BTN_GHOST, no icon.
  5. `Enable Touch ID` / `Disable Touch ID` BTN_GHOST, Fingerprint icon. Tooltips: enable "Unlock with Touch ID next time, without the master password"; disable "Stop offering Touch ID unlock".
  6. `Lock` BTN_GHOST, Lock icon.
- BTN: `px-3 py-1.5` (12/6 padding), radius 7, 13px weight 500, bg `--primary-bg`, fg `--primary-fg`, hover opacity .9, disabled .5. BTN_GHOST: same metrics, 13px normal weight, 1px border `--border-control`, bg `--bg-control`, text `--text`, hover bg `--bg-segment`. (sshStyles.ts L18-27.) Height about 32. Icon-to-label gap 4.

Row 2 search (L1351-1359): full width input, `INPUT` + `pl-8`; SearchIcon 16 absolutely at left 10px, vertically centred, `--text-faint`. Placeholder: `Search credentials — label, username, group, note…`. INPUT: `w-full px-2.5 py-1.5` (10/6), radius 7, 1px `--border-control`, bg `--bg-input`, 13px `--text`, placeholder `--text-faint`, focus border `--accent`. Search matches label, username, description, group, secretKind (substring, case-insensitive). While searching, groups are force-expanded.

Row 3+: import forms (CARD, `space-y-2`), new-credential form (CARD), then group cards.
Search with no hit: `No credentials match "{query}".` centred, `text-xs` `--text-faint`, `py-4` (L1414).

## 2. Grouping (L115-201)
- `group` free text; trimmed; empty -> bucket named literally `Ungrouped`.
- Order: named groups alphabetical (`localeCompare`), `Ungrouped` ALWAYS last.
- Each group = a CARD (outer group card): `CARD space-y-3` (12px between header and grid). Collapse IS supported: header button toggles; persisted in localStorage `muya.vault.collapsed` (array of collapsed names; absence = open). Collapsed hides the grid.
- Header (`GroupCard`, L172-201): button `flex w-full items-center gap-1.5` (6px) left-aligned, pointer. Chevron (ChevronRight if collapsed, ChevronDown if open) 16x16 `--text-faint`; name `text-sm font-medium truncate` (14px/500, `--text`); count `(N)` `text-xs` 12px `--text-muted`, shrink-0.
- Spacing between group cards: parent `space-y-3` = 12px.
- Item grid: `grid gap-3 md:grid-cols-2 2xl:grid-cols-3` (L200): 12px gap; 1 column < 768px, 2 columns >= 768px, 3 columns >= 1536px (window/page width, not card width). Window content is full width minus p-6.

## 3. The credential card (L1433-1470)
Container: `CARD flex flex-col gap-2` -> radius 10, 1px `--border`, bg `--bg-panel`, padding 16 all sides, internal gap 8 between header row and revealed block. NOTE: card nested inside group card both use `--bg-panel` (same colour, border separates). No shadow, no hover state on the card.

Header row: `flex justify-between items-center gap-2`.
- Left text block `text-sm min-w-0` (14px):
  - Line 1 inline: label `font-medium` (14px/500, `--text`), a space, then `text-xs text-muted font-mono` (12px mono, `--text-muted`): `{username} · {kind}`. Kind names: password -> `password`, key -> `SSH key`, token -> `token`, api_key -> `API key`. NO badge/pill; kind is plain text after a middle dot. Line 1 wraps (no truncate; `min-w-0` lets it wrap).
  - Line 2 (only if description): `text-xs` 12px `--text-faint`, `mt-0.5` (2px) below. Wraps, no truncation.
- Right actions: `flex gap-1` (4px), shrink-0, ALWAYS visible (not hover-only). Each ICON_BTN: 28x28 (`w-7 h-7`), radius 7, icon 16, colour `--text-muted`, hover bg `--bg-segment` + colour `--text`. Order and tooltips (`title`):
  1. Eye / EyeOff (when revealed) - "View value" / "Hide value"
  2. Copy (becomes Check in `--success-text` for 1.5 s after copy) - "Copy value"
  3. Pencil - "Edit credential"
  4. Download - "Export {secretKind}" (e.g. "Export password", "Export key")
  5. Trash2 - NO title; ICON_BTN_DANGER: hover text `--danger-text`. Deletes immediately, no confirm.
- Copy: reveals via `credstore_reveal_cred` if not already revealed, copies to clipboard.
- Edit: reveals secret, replaces the card in place (same grid cell) with the CredForm card.

Revealed value (L1461): below header, `<pre>` `text-xs font-mono` (12px mono), bg `--bg-segment`, radius 4 (`rounded`), padding 8, `whitespace-pre-wrap break-all`, selectable, `max-h-40` (160px) then scroll. Text colour inherits `--text`. Revealed state is per-card and in-memory only; fetched on demand.

CredForm card (L1480+): `CARD space-y-2`; title `font-medium text-sm` "New credential" / "Edit credential"; `grid grid-cols-2 gap-2` fields: Label, Username, Secret kind select (Password / SSH private key / Token / API key), secret (password input, or textarea `h-24 font-mono` for key), Group (placeholder "Group (optional)", col-span-2), Description (placeholder "Description (optional — shown to agents by name)", col-span-2). Buttons right-aligned `flex gap-2 justify-end`: Cancel (ghost), Save (primary).

## 4. Empty / locked / uninitialised states
- Empty store (unlocked, 0 creds): NO dedicated empty text. Toolbar says `Unlocked · 0 item(s)`, search box shows, nothing below.
- Locked (L1253-): CARD `space-y-3`: row `flex items-center gap-2`: Lock icon 16 `--warning`, `Store locked` `font-medium text-sm`. If biometric available: primary BTN `Unlock with Touch ID` (Fingerprint icon; busy: spinner + `Waiting for Touch ID…`), divider row `text-[10px] --text-faint` "or use your master password" flanked by 1px lines `--bg-segment`. Password INPUT placeholder `Master password` with eye toggle (16px, absolute right 8, top 6, `--text-faint`, title Show/Hide); Enter unlocks. Primary BTN `Unlock` (Unlock icon; busy `Unlocking…` + spinner). Busy hint `text-xs --text-muted`: "Deriving the key (Argon2id) — this can take a second or two, hang tight."
- Not initialised (L1207-): CARD `space-y-3`: KeyRound icon 16 `--accent` + `Create password store` (font-medium text-sm); `text-xs --text-muted`: "Your credentials are stored encrypted with AES-256-GCM. Keep your master password safe — the app never stores it, so you can also export an encrypted backup once unlocked."; Master password input w/ eye; busy hint "Deriving the key (Argon2id) — this can take a second or two."; buttons `Create` (primary, busy `Creating…`) + ghost `Export master password` (Download icon); warning `text-[11px] --warning`: `⚠️ "Export master password" saves it to a plaintext file you pick. Prefer keeping it in a password manager — the app never stores it.`

## 5. Tokens (src/styles/tokens.css; dark L33+, light L107+)
| token | dark | light |
|---|---|---|
| --bg-panel (card) | #14171C | #F9FAFB |
| --bg-input | #171A20 | #FFFFFF |
| --bg-control | #1A1E25 | #FFFFFF |
| --bg-segment (reveal bg, hover, dividers) | #1B1F27 | #EEF0F3 |
| --border (card) | #262B35 | #E3E6EB |
| --border-control (input/ghost btn) | #2A2F3A | #D5DAE1 |
| --text | #E6E8EC | #1A1D23 |
| --text-muted | #9AA3B2 | #5E6675 |
| --text-faint | #7C8595 | #6B727E |
| --accent | #8FB3FF | #2F5BD3 |
| --primary-bg | #E6E8EC | #1A1D23 |
| --primary-fg | #0F1115 | #FFFFFF |
| --success-text | #7BE3BF | #127A56 |
| --warning | #F2B34B | #D9921A |
| --danger-text | #FFA8A0 | #B42318 |
| --danger-pill-bg | #3A1D1D | #FDECEA |

Notes: sans = `var(--font-sans)`, mono = `var(--font-mono)`. The Servers tab uses the same GroupCard and groupItems, so grouping look is shared.
