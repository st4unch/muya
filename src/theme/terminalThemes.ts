import type { ITheme } from "@xterm/xterm";

/**
 * xterm.js color themes for the two app themes (docs/design/redesign-v0.4/PROMPT.md
 * §1.2). Terminal content is real PTY output — only the xterm `theme` object, font
 * and padding change with the app theme; nothing about the terminal is redrawn in
 * HTML. This file (and src/styles/tokens.css) are the ONLY places allowed to
 * contain hex color literals.
 */

const DARK_TERMINAL_THEME: ITheme = {
  background: "#0B0D11",
  foreground: "#D4D9E1",
  cursor: "#E6E8EC",
  selectionBackground: "#2A3A5C",

  black: "#1A1E25",
  brightBlack: "#7C8595",
  red: "#F07167",
  brightRed: "#FFA8A0",
  green: "#4FD1A5",
  brightGreen: "#7BE3BF",
  yellow: "#F2B34B",
  brightYellow: "#F7CC7F",
  blue: "#8FB3FF",
  brightBlue: "#B8CEFF",
  magenta: "#C9A0FF",
  brightMagenta: "#DCC2FF",
  cyan: "#6FD6E8",
  brightCyan: "#A3E6F2",
  white: "#D4D9E1",
  brightWhite: "#FFFFFF",
};

const LIGHT_TERMINAL_THEME: ITheme = {
  background: "#FFFFFF",
  foreground: "#2A2F38",
  cursor: "#1A1D23",
  selectionBackground: "#CFDDFB",

  black: "#2A2F38",
  brightBlack: "#5E6675",
  red: "#C4302B",
  brightRed: "#B42318",
  green: "#127A56",
  brightGreen: "#1E9E72",
  yellow: "#8A5A00",
  brightYellow: "#9A6400",
  blue: "#2F5BD3",
  brightBlue: "#1E45B0",
  magenta: "#7A3FC4",
  brightMagenta: "#6330A8",
  cyan: "#0F7C8C",
  brightCyan: "#0B6573",
  white: "#4A5261",
  brightWhite: "#0B0D11",
};

/** Resolve the xterm theme object for the app's resolved (non-"system") theme. */
export function terminalTheme(resolved: "dark" | "light"): ITheme {
  return resolved === "dark" ? DARK_TERMINAL_THEME : LIGHT_TERMINAL_THEME;
}
