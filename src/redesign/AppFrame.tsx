// Created by Claude — Classification: INTERNAL
//
// The outermost shell shared by Control and Grid (PROMPT.md §2): header slot,
// rail, body and footer stacked in a column. Purely structural — every piece is
// a slot the screen fills in, no state or callbacks live here.

import type { ReactNode } from "react";

export interface AppFrameProps {
  header: ReactNode;
  rail: ReactNode;
  footer: ReactNode;
  children: ReactNode;
}

export function AppFrame({ header, rail, footer, children }: AppFrameProps) {
  return (
    <div
      className="rd-root"
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        flexDirection: "column",
        background: "var(--bg-app)",
        color: "var(--text)",
        overflow: "hidden",
      }}
    >
      {header}
      <div style={{ flexGrow: 1, minHeight: 0, display: "flex" }}>
        {rail}
        {children}
      </div>
      {footer}
    </div>
  );
}
