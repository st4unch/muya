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

/** Operator-picked terminal color schemes. "muya" follows the app theme; the others
 *  are fixed palettes (their published values) and look the same in either app theme. */
export const TERMINAL_SCHEMES = [
  { id: "muya", label: "Muya (follows app theme)" },
  { id: "dracula", label: "Dracula" },
  { id: "nord", label: "Nord" },
  { id: "one-dark", label: "One Dark" },
  { id: "tokyo-night", label: "Tokyo Night" },
  { id: "gruvbox-dark", label: "Gruvbox Dark" },
  { id: "solarized-dark", label: "Solarized Dark" },
  { id: "solarized-light", label: "Solarized Light" },
  { id: "github-light", label: "GitHub Light" },
] as const;

export type TerminalSchemeId = (typeof TERMINAL_SCHEMES)[number]["id"];

const FIXED_SCHEMES: Record<Exclude<TerminalSchemeId, "muya">, ITheme> = {
  dracula: {
    background: "#282A36", foreground: "#F8F8F2", cursor: "#F8F8F2", selectionBackground: "#44475A",
    black: "#21222C", brightBlack: "#6272A4", red: "#FF5555", brightRed: "#FF6E6E",
    green: "#50FA7B", brightGreen: "#69FF94", yellow: "#F1FA8C", brightYellow: "#FFFFA5",
    blue: "#BD93F9", brightBlue: "#D6ACFF", magenta: "#FF79C6", brightMagenta: "#FF92DF",
    cyan: "#8BE9FD", brightCyan: "#A4FFFF", white: "#F8F8F2", brightWhite: "#FFFFFF",
  },
  nord: {
    background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selectionBackground: "#434C5E",
    black: "#3B4252", brightBlack: "#4C566A", red: "#BF616A", brightRed: "#BF616A",
    green: "#A3BE8C", brightGreen: "#A3BE8C", yellow: "#EBCB8B", brightYellow: "#EBCB8B",
    blue: "#81A1C1", brightBlue: "#81A1C1", magenta: "#B48EAD", brightMagenta: "#B48EAD",
    cyan: "#88C0D0", brightCyan: "#8FBCBB", white: "#E5E9F0", brightWhite: "#ECEFF4",
  },
  "one-dark": {
    background: "#282C34", foreground: "#ABB2BF", cursor: "#528BFF", selectionBackground: "#3E4451",
    black: "#282C34", brightBlack: "#5C6370", red: "#E06C75", brightRed: "#E06C75",
    green: "#98C379", brightGreen: "#98C379", yellow: "#E5C07B", brightYellow: "#E5C07B",
    blue: "#61AFEF", brightBlue: "#61AFEF", magenta: "#C678DD", brightMagenta: "#C678DD",
    cyan: "#56B6C2", brightCyan: "#56B6C2", white: "#ABB2BF", brightWhite: "#FFFFFF",
  },
  "tokyo-night": {
    background: "#1A1B26", foreground: "#C0CAF5", cursor: "#C0CAF5", selectionBackground: "#33467C",
    black: "#15161E", brightBlack: "#414868", red: "#F7768E", brightRed: "#F7768E",
    green: "#9ECE6A", brightGreen: "#9ECE6A", yellow: "#E0AF68", brightYellow: "#E0AF68",
    blue: "#7AA2F7", brightBlue: "#7AA2F7", magenta: "#BB9AF7", brightMagenta: "#BB9AF7",
    cyan: "#7DCFFF", brightCyan: "#7DCFFF", white: "#A9B1D6", brightWhite: "#C0CAF5",
  },
  "gruvbox-dark": {
    background: "#282828", foreground: "#EBDBB2", cursor: "#EBDBB2", selectionBackground: "#504945",
    black: "#282828", brightBlack: "#928374", red: "#CC241D", brightRed: "#FB4934",
    green: "#98971A", brightGreen: "#B8BB26", yellow: "#D79921", brightYellow: "#FABD2F",
    blue: "#458588", brightBlue: "#83A598", magenta: "#B16286", brightMagenta: "#D3869B",
    cyan: "#689D6A", brightCyan: "#8EC07C", white: "#A89984", brightWhite: "#EBDBB2",
  },
  "solarized-dark": {
    background: "#002B36", foreground: "#839496", cursor: "#93A1A1", selectionBackground: "#073642",
    black: "#073642", brightBlack: "#586E75", red: "#DC322F", brightRed: "#CB4B16",
    green: "#859900", brightGreen: "#93A1A1", yellow: "#B58900", brightYellow: "#839496",
    blue: "#268BD2", brightBlue: "#839496", magenta: "#D33682", brightMagenta: "#6C71C4",
    cyan: "#2AA198", brightCyan: "#93A1A1", white: "#EEE8D5", brightWhite: "#FDF6E3",
  },
  "solarized-light": {
    background: "#FDF6E3", foreground: "#657B83", cursor: "#586E75", selectionBackground: "#EEE8D5",
    black: "#073642", brightBlack: "#586E75", red: "#DC322F", brightRed: "#CB4B16",
    green: "#859900", brightGreen: "#586E75", yellow: "#B58900", brightYellow: "#657B83",
    blue: "#268BD2", brightBlue: "#839496", magenta: "#D33682", brightMagenta: "#6C71C4",
    cyan: "#2AA198", brightCyan: "#93A1A1", white: "#EEE8D5", brightWhite: "#FDF6E3",
  },
  "github-light": {
    background: "#FFFFFF", foreground: "#24292F", cursor: "#0969DA", selectionBackground: "#B6D7FF",
    black: "#24292F", brightBlack: "#57606A", red: "#CF222E", brightRed: "#A40E26",
    green: "#116329", brightGreen: "#1A7F37", yellow: "#4D2D00", brightYellow: "#633C01",
    blue: "#0969DA", brightBlue: "#218BFF", magenta: "#8250DF", brightMagenta: "#A475F9",
    cyan: "#1B7C83", brightCyan: "#3192AA", white: "#6E7781", brightWhite: "#8C959F",
  },
};

/** The xterm theme for a picked scheme; "muya" (and any unknown id) follows the app theme. */
export function schemeTheme(scheme: string, resolved: "dark" | "light"): ITheme {
  return (FIXED_SCHEMES as Record<string, ITheme>)[scheme] ?? terminalTheme(resolved);
}
