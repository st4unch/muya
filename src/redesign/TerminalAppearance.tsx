// Created by Claude — Classification: INTERNAL
//
// Session-header popover for the terminal's look: font size (−/+/reset, also ⌘+ ⌘− ⌘0
// inside a terminal) and a color scheme. Applies to every terminal at once and is
// remembered (src/lib/terminalPrefs.ts). Swatches are drawn from the scheme's own
// palette — the one place this UI shows non-token colors, because they ARE the content.

import type { CSSProperties } from "react";
import { MenuHeading, MenuPopover, MenuSeparator, type Anchor } from "./Menus";
import { FONT_DEFAULT, FONT_MAX, FONT_MIN, setTerminalPrefs, stepTerminalFont, useTerminalPrefs } from "../lib/terminalPrefs";
import { TERMINAL_SCHEMES, schemeTheme } from "../theme/terminalThemes";

const stepBtn: CSSProperties = {
  width: 30,
  height: 28,
  borderRadius: 7,
  border: "1px solid var(--border-control)",
  background: "var(--bg-control)",
  color: "var(--text)",
  fontSize: 15,
  display: "flex",
  alignItems: "center",
  justifyContent: "center",
  flexShrink: 0,
};

const SWATCH_KEYS = ["red", "green", "yellow", "blue", "magenta", "cyan"] as const;

export function TerminalAppearanceMenu({ anchor, appTheme, onClose }: { anchor: Anchor; appTheme: "dark" | "light"; onClose: () => void }) {
  const prefs = useTerminalPrefs();
  return (
    <MenuPopover anchor={anchor} width={300} onClose={onClose} label="Terminal appearance">
      <MenuHeading>FONT SIZE</MenuHeading>
      <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "0 10px 6px" }}>
        <button type="button" aria-label="Smaller text" title="Smaller (⌘−)" disabled={prefs.fontSize <= FONT_MIN} onClick={() => stepTerminalFont(-1)} className="rd-btn2" style={stepBtn}>
          −
        </button>
        <span aria-live="polite" aria-label="Font size" style={{ minWidth: 44, textAlign: "center", fontFamily: "var(--font-mono)", fontSize: 13 }}>
          {prefs.fontSize} px
        </span>
        <button type="button" aria-label="Larger text" title="Larger (⌘+)" disabled={prefs.fontSize >= FONT_MAX} onClick={() => stepTerminalFont(1)} className="rd-btn2" style={stepBtn}>
          +
        </button>
        <button
          type="button"
          title="Default size (⌘0)"
          disabled={prefs.fontSize === FONT_DEFAULT}
          onClick={() => stepTerminalFont(0)}
          className="rd-btn2"
          style={{ ...stepBtn, width: "auto", padding: "0 10px", fontSize: 12, marginLeft: "auto" }}
        >
          Reset
        </button>
      </div>
      <div style={{ padding: "0 10px 4px", fontSize: 11, color: "var(--text-muted)" }}>In a terminal: ⌘+ larger · ⌘− smaller · ⌘0 default</div>
      <MenuSeparator />
      <MenuHeading>COLORS</MenuHeading>
      <div role="radiogroup" aria-label="Terminal colors" style={{ display: "flex", flexDirection: "column", gap: 1, maxHeight: "min(50vh, 360px)", overflowY: "auto" }}>
        {TERMINAL_SCHEMES.map((s) => {
          const on = prefs.scheme === s.id;
          const t = schemeTheme(s.id, appTheme);
          return (
            <button
              key={s.id}
              type="button"
              role="radio"
              aria-checked={on}
              onClick={() => setTerminalPrefs({ scheme: s.id })}
              className="rd-btn2"
              style={{ display: "flex", alignItems: "center", gap: 8, width: "100%", height: 30, padding: "0 10px", borderRadius: 6, border: "none", background: "transparent", color: "var(--text)", fontSize: 13, textAlign: "left" }}
            >
              <span style={{ width: 12, flexShrink: 0, color: "var(--accent)" }}>{on ? "✓" : ""}</span>
              <span
                aria-hidden="true"
                style={{ display: "flex", alignItems: "center", gap: 2, height: 18, padding: "0 4px", borderRadius: 4, background: t.background, border: "1px solid var(--border)", flexShrink: 0 }}
              >
                <span style={{ fontFamily: "var(--font-mono)", fontSize: 10, color: t.foreground, marginRight: 2 }}>A</span>
                {SWATCH_KEYS.map((k) => (
                  <span key={k} style={{ width: 6, height: 6, borderRadius: 3, background: t[k] }} />
                ))}
              </span>
              <span className="rd-ellipsis">{s.label}</span>
            </button>
          );
        })}
      </div>
    </MenuPopover>
  );
}
