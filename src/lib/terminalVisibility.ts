// Created by Claude — Classification: INTERNAL

/** Everything that can hide a terminal in the Control page. */
export interface TerminalPlacement {
  /** The Control page is the page on screen — the others are kept mounted but
   *  `display:none`, so a terminal under them is invisible even when its tab is
   *  selected. */
  controlPageVisible: boolean;
  /** Grid mode, and this terminal holds one of the 2×2 slots. */
  inGrid: boolean;
  /** Tabs mode, and this terminal is the selected tab. */
  isActiveTab: boolean;
}

/**
 * Is this terminal actually on screen — and therefore the one that should own the
 * keyboard, a live GPU context and a PTY-sized viewport?
 *
 * Every layer that can hide a terminal has to appear in this expression. Leaving one
 * out fails *silently*: the terminal is painted on screen while React sees no prop
 * change, so `Terminal`'s show-effect (focus → renderer → refit) never runs and the
 * operator types into nothing. That is exactly what the page layer cost us — navigate
 * Control → Kanban → Control and the terminal was visible but deaf until clicked.
 *
 * When a new way to hide the pane is added (another page, a collapsible panel), it
 * belongs here too.
 */
export function terminalIsVisible(p: TerminalPlacement): boolean {
  return p.controlPageVisible && (p.inGrid || p.isActiveTab);
}
