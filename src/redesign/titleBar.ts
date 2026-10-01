// Created by Claude — Classification: INTERNAL
//
// Muya draws its own title bar (the window uses an overlay title bar), so the header
// has to behave like one by hand: drag the window from any empty or text area, and on a
// double-click do what macOS is set to (zoom by default — the Rust side reads the
// preference). Controls in the bar (buttons, the search pill, tabs, inputs) keep their
// own clicks. Text in the bar is never selected by a double-click.
//
// Replaces `data-tauri-drag-region`, which only worked on the bare header element —
// a double-click on its logo, readouts or search text selected text instead.

import type { MouseEvent } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";

const INTERACTIVE = "button, a, input, select, textarea, [role='button'], [role='tab'], [contenteditable='true']";

export function isTitleBarBackground(target: EventTarget | null): boolean {
  return target instanceof Element && !target.closest(INTERACTIVE);
}

export function onTitleBarMouseDown(e: MouseEvent<HTMLElement>): void {
  if (e.button !== 0 || !isTitleBarBackground(e.target)) return;
  e.preventDefault(); // no text selection, no focus change
  if (e.detail === 2) {
    void invoke("title_bar_double_click").catch(() => {});
    return;
  }
  if (e.detail === 1) {
    try {
      void getCurrentWindow().startDragging().catch(() => {});
    } catch {
      /* not running inside Tauri (browser preview) */
    }
  }
}
