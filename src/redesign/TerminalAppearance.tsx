// Created by Claude — Classification: INTERNAL
//
// Footer popover for the terminal's look: font size (−/+/reset, also ⌘+ ⌘− ⌘0
// inside a terminal), line and letter spacing, and a color scheme. Applies to every terminal at once and is
// remembered (src/lib/terminalPrefs.ts). Swatches are drawn from the scheme's own
// palette — the one place this UI shows non-token colors, because they ARE the content.

import type { CSSProperties } from "react";
import { MenuHeading, MenuPopover, MenuSeparator, type Anchor } from "./Menus";
import {
  FONT_DEFAULT,
  FONT_MAX,
  FONT_MIN,
  LETTER_DEFAULT,
  LETTER_MAX,
  LETTER_MIN,
  LINE_DEFAULT,
  LINE_MAX,
  LINE_MIN,
  setTerminalPrefs,
  stepTerminalFont,
  stepTerminalLetter,
  stepTerminalLine,
  useTerminalPrefs,
} from "../lib/terminalPrefs";
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

/** One −  value  +  Reset row. `what` names the buttons ("Smaller text", "Less line spacing"). */
function Stepper({
  what,
  label,
  value,
  atMin,
  atMax,
  atDefault,
  step,
  hints,
}: {
  what: string;
  label: string;
  value: string;
  atMin: boolean;
  atMax: boolean;
  atDefault: boolean;
  step: (delta: -1 | 0 | 1) => void;
  hints?: [string, string, string];
}) {
  const [less, more] = what === "text" ? ["Smaller text", "Larger text"] : [`Less ${what}`, `More ${what}`];
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 6, padding: "0 10px 6px" }}>
      <button type="button" aria-label={less} title={hints?.[0] ?? less} disabled={atMin} onClick={() => step(-1)} className="rd-btn2" style={stepBtn}>
        −
      </button>
      <span aria-live="polite" aria-label={label} style={{ minWidth: 44, textAlign: "center", fontFamily: "var(--font-mono)", fontSize: 13 }}>
        {value}
      </span>
      <button type="button" aria-label={more} title={hints?.[1] ?? more} disabled={atMax} onClick={() => step(1)} className="rd-btn2" style={stepBtn}>
        +
      </button>
      <button
        type="button"
        aria-label={`Reset ${label.toLowerCase()}`}
        title={hints?.[2] ?? "Default"}
        disabled={atDefault}
        onClick={() => step(0)}
        className="rd-btn2"
        style={{ ...stepBtn, width: "auto", padding: "0 10px", fontSize: 12, marginLeft: "auto" }}
      >
        Reset
      </button>
    </div>
  );
}

const SWATCH_KEYS = ["red", "green", "yellow", "blue", "magenta", "cyan"] as const;

export function TerminalAppearanceMenu({ anchor, appTheme, onClose }: { anchor: Anchor; appTheme: "dark" | "light"; onClose: () => void }) {
  const prefs = useTerminalPrefs();
  return (
    <MenuPopover anchor={anchor} width={300} onClose={onClose} label="Terminal appearance">
      <MenuHeading>FONT SIZE</MenuHeading>
      <Stepper
        what="text"
        label="Font size"
        value={`${prefs.fontSize} px`}
        atMin={prefs.fontSize <= FONT_MIN}
        atMax={prefs.fontSize >= FONT_MAX}
        atDefault={prefs.fontSize === FONT_DEFAULT}
        step={stepTerminalFont}
        hints={["Smaller (⌘−)", "Larger (⌘+)", "Default size (⌘0)"]}
      />
      <div style={{ padding: "0 10px 4px", fontSize: 11, color: "var(--text-muted)" }}>In a terminal: ⌘+ larger · ⌘− smaller · ⌘0 default</div>
      <MenuHeading>LINE SPACING</MenuHeading>
      <Stepper
        what="line spacing"
        label="Line spacing"
        value={prefs.lineHeight.toFixed(1)}
        atMin={prefs.lineHeight <= LINE_MIN}
        atMax={prefs.lineHeight >= LINE_MAX}
        atDefault={prefs.lineHeight === LINE_DEFAULT}
        step={stepTerminalLine}
      />
      <MenuHeading>LETTER SPACING</MenuHeading>
      <Stepper
        what="letter spacing"
        label="Letter spacing"
        value={`${prefs.letterSpacing} px`}
        atMin={prefs.letterSpacing <= LETTER_MIN}
        atMax={prefs.letterSpacing >= LETTER_MAX}
        atDefault={prefs.letterSpacing === LETTER_DEFAULT}
        step={stepTerminalLetter}
      />
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
