// Created by Claude — Classification: INTERNAL

/** Muya's own modals: a `role="dialog"` box, or the app-wide full-screen backdrop
 *  convention (`fixed inset-0 z-50`). */
export const MODAL_SELECTOR = '[role="dialog"], .fixed.inset-0.z-50';

/**
 * Is one of Muya's modals open on screen — so the keyboard belongs to it, not to a
 * terminal?
 *
 * A bare `document.querySelector(MODAL_SELECTOR)` is not enough: other code puts
 * `role="dialog"` in the page too. Monaco's find box is one (created on the first ⌘F
 * in a file and kept until the editor closes). While that file sat open in the
 * Files rail, every terminal ignored every key — the operator had to close the file
 * to type again, and clicking the terminal did not help.
 *
 * So a match only counts when it is not inside a terminal / file-viewer host (those
 * hold widgets, never app modals) and is actually rendered (not under a hidden page).
 */
export function appModalOpen(root: ParentNode = document): boolean {
  for (const el of root.querySelectorAll<HTMLElement>(MODAL_SELECTOR)) {
    if (el.closest("[data-terminal-host]")) continue;
    if (el.closest("[hidden], .hidden")) continue;
    if (typeof el.checkVisibility === "function" && !el.checkVisibility()) continue;
    return true;
  }
  return false;
}
