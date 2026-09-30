// Created by Claude — Classification: INTERNAL
//
// Body region for the pages that keep their Tailwind styling (Queue, Kanban, Resources,
// SSH, Chat, Sessions, Branches). Deliberately NOT inside an `.rd-root` element: that
// scope forces `white-space: nowrap` and button colors on every descendant, which would
// break those pages' own layout. Supplies the text size/font/color the old app root did.

import type { ReactNode } from "react";

export function AppFrameBody({ children }: { children: ReactNode }) {
  return (
    <div
      className="font-sans text-xs text-neutral-800 dark:text-neutral-200"
      style={{ flexGrow: 1, minWidth: 0, minHeight: 0, display: "flex", background: "var(--bg-app)", color: "var(--text)" }}
    >
      {children}
    </div>
  );
}
