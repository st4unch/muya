// Created by Claude — Classification: INTERNAL
//
// Control styles for the SSH page and its credential picker, in the v0.4 design: the
// same tokens and metrics as SettingsModal (32px controls, 7px radius, neutral
// primary button, uppercase field labels). Tailwind classes with `var(--token)`
// values only — no palette colors, so light/dark follow the theme on their own.

/** A section card. */
export const CARD = "rounded-[10px] border border-[var(--border)] bg-[var(--bg-panel)] p-4";

/** Text input / select / textarea. */
export const INPUT =
  "w-full px-2.5 py-1.5 rounded-[7px] border border-[var(--border-control)] bg-[var(--bg-input)] text-[13px] text-[var(--text)] " +
  "placeholder:text-[var(--text-faint)] outline-none focus:border-[var(--accent)]";

/** The one primary action of a form or card. */
export const BTN =
  "px-3 py-1.5 rounded-[7px] text-[13px] font-medium bg-[var(--primary-bg)] text-[var(--primary-fg)] " +
  "hover:opacity-90 disabled:opacity-50 disabled:cursor-default cursor-pointer whitespace-nowrap";

/** Secondary action with a label (Cancel, Export, Lock…). */
export const BTN_GHOST =
  "px-3 py-1.5 rounded-[7px] text-[13px] border border-[var(--border-control)] bg-[var(--bg-control)] text-[var(--text)] " +
  "hover:bg-[var(--bg-segment)] disabled:opacity-50 disabled:cursor-default cursor-pointer whitespace-nowrap";

/** Icon-only row action (edit, delete, reveal, copy). */
export const ICON_BTN =
  "inline-flex items-center justify-center w-7 h-7 rounded-[7px] text-[var(--text-muted)] " +
  "hover:bg-[var(--bg-segment)] hover:text-[var(--text)] disabled:opacity-50 cursor-pointer";

/** Destructive icon action. */
export const ICON_BTN_DANGER = `${ICON_BTN} hover:!text-[var(--danger-text)]`;

/** Field label above an input, like SettingsModal's labelStyle. */
export const LABEL = "block text-[11px] font-semibold uppercase tracking-[.06em] text-[var(--text-muted)]";
