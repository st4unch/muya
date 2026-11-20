#!/usr/bin/env python3
"""Generate native/app/Sources/Theme/Tokens.swift and native/ui-reference/tokens.json from today's
web UI sources, citing file:line for every value.

  python3 native/ui-reference/gen-tokens.py

Sources (read-only): src/styles/tokens.css (colours, fonts), src/theme/terminalThemes.ts (terminal
palette), native/ui-reference/metrics.json (sizes/radii measured in the running mock UI by measure.mjs).
Re-run after any change to those files; the Swift file is generated — do not edit by hand.
"""
import json, os, re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CSS = "src/styles/tokens.css"
TERM = "src/theme/terminalThemes.ts"


def read(rel):
    with open(os.path.join(ROOT, rel)) as fh:
        return fh.read().splitlines()


def parse_css():
    themes, cur = {"dark": {}, "light": {}}, None
    for i, line in enumerate(read(CSS), 1):
        m = re.match(r':root\[data-theme="(dark|light)"\]', line)
        if m:
            cur = m.group(1)
            continue
        if line.startswith("}"):
            cur = None
        m = re.match(r"\s*--([\w-]+):\s*(.+?);", line)
        if cur and m:
            themes[cur][m.group(1)] = {"value": m.group(2).strip(), "src": f"{CSS}:{i}"}
    return themes


def parse_raw():
    """Theme-independent accent scale (`:root { --raw-indigo-* }`), shared by both themes."""
    out, inside = {}, False
    for i, line in enumerate(read(CSS), 1):
        if line.startswith(":root {"): inside = True; continue
        if inside and line.startswith("}"): break
        m = re.match(r"\s*--raw-([\w-]+):\s*(#[0-9A-Fa-f]{6});", line)
        if inside and m: out[m.group(1)] = (m.group(2), f"{CSS}:{i}")
    return out


def parse_terminal():
    out, cur = {}, None
    for i, line in enumerate(read(TERM), 1):
        m = re.match(r"const (DARK|LIGHT)_TERMINAL_THEME", line)
        if m:
            cur = m.group(1).lower()
            out[cur] = {}
            continue
        if cur and line.startswith("};"):
            cur = None
        m = re.match(r'\s*(\w+):\s*"(#[0-9A-Fa-f]{6})"', line)
        if cur and m:
            out[cur][m.group(1)] = {"value": m.group(2), "src": f"{TERM}:{i}"}
    return out


def parse_schemes():
    """TERMINAL_SCHEMES ids/labels and FIXED_SCHEMES colours of src/theme/terminalThemes.ts (the 8 fixed schemes; "muya" follows the app theme)."""
    lines = read(TERM)
    labels, fixed, cur = [], {}, None
    in_list = in_fixed = False
    for i, line in enumerate(lines, 1):
        if line.startswith("export const TERMINAL_SCHEMES"):
            in_list = True
            continue
        if in_list:
            m = re.match(r'\s*\{ id: "([\w-]+)", label: "(.*)" \}', line)
            if m:
                labels.append((m.group(1), m.group(2), f"{TERM}:{i}"))
            if line.startswith("]"):
                in_list = False
        if line.startswith("const FIXED_SCHEMES"):
            in_fixed = True
            continue
        if in_fixed:
            m = re.match(r'\s*"?([\w-]+)"?: \{$', line)
            if m:
                cur = m.group(1)
                fixed[cur] = {}
                continue
            if cur:
                for k, v in re.findall(r'(\w+): "(#[0-9A-Fa-f]{6})"', line):
                    fixed[cur][k] = v
            if line.startswith("};"):
                in_fixed = False
    return labels, fixed


def swift_name(css_name):
    parts = css_name.split("-")
    return parts[0] + "".join(p.capitalize() for p in parts[1:])


def color_expr(v):
    v = v.strip()
    m = re.fullmatch(r"#([0-9A-Fa-f]{6})", v)
    if m:
        return f'NSColor(hex: 0x{m.group(1).upper()})'
    m = re.fullmatch(r"rgba?\(([\d.\s,]+)\)", v)
    if m:
        p = [float(x) for x in m.group(1).split(",")]
        a = p[3] if len(p) > 3 else 1.0
        return f"NSColor(srgbRed: {p[0]/255:.4f}, green: {p[1]/255:.4f}, blue: {p[2]/255:.4f}, alpha: {a})"
    return None


# Layout constants, each verified against the cited line (re-check when those files change).
REGIONS = {
    "rail.width": {"value": 64, "src": "src/redesign/Rail.tsx:41"},
    "rail.item": {"value": 48, "src": "src/redesign/Rail.tsx:63"},
    "header.height": {"value": 48, "src": "src/redesign/ControlHeader.tsx:116"},
    "header.button": {"value": 32, "src": "src/redesign/ControlHeader.tsx:74"},
    "header.search.width": {"value": 440, "src": "src/redesign/ControlHeader.tsx:167"},
    "footer.height": {"value": 28, "src": "src/redesign/Footer.tsx:124"},
    "agents.width": {"value": 296, "src": "src/redesign/usePanelLayout.ts:12"},
    "agents.width.min": {"value": 220, "src": "src/redesign/usePanelLayout.ts:12"},
    "agents.width.max": {"value": 480, "src": "src/redesign/usePanelLayout.ts:12"},
    "inspector.width": {"value": 320, "src": "src/redesign/usePanelLayout.ts:13"},
    "inspector.width.min": {"value": 260, "src": "src/redesign/usePanelLayout.ts:13"},
    "inspector.width.max": {"value": 520, "src": "src/redesign/usePanelLayout.ts:13"},
}


def count_inline(prop):
    """How often `prop: N` appears in inline styles under src/redesign + src/components (frequency table)."""
    c = {}
    for d in ("src/redesign", "src/components"):
        for f in os.listdir(os.path.join(ROOT, d)):
            if f.endswith(".tsx") and ".test." not in f:
                for m in re.finditer(prop + r":\s*([0-9.]+)\b", open(os.path.join(ROOT, d, f)).read()):
                    c[m.group(1)] = c.get(m.group(1), 0) + 1
    return dict(sorted(c.items(), key=lambda kv: -kv[1]))


def main():
    themes = parse_css()
    term = parse_terminal()
    metrics = {"regions": REGIONS, "fontSizes": count_inline("fontSize"), "radii": count_inline("borderRadius"),
               "fontWeights": count_inline("fontWeight")}

    # Colour tokens present in both themes (the dark file lists a few more; keep dark's set, fall back to dark).
    names = [n for n in themes["dark"] if color_expr(themes["dark"][n]["value"])]
    names += [n for n in themes["light"] if n not in names and color_expr(themes["light"][n]["value"])]

    with open(os.path.join(ROOT, "native/ui-reference/tokens.json"), "w") as fh:
        json.dump({"colors": {t: themes[t] for t in themes}, "terminal": term, "metrics": metrics,
                   "fonts": {"sans": "IBM Plex Sans", "mono": "JetBrains Mono",
                             "src": f"{CSS}:103-104"}}, fh, indent=2)

    L = []
    w = L.append
    w("// GENERATED by native/ui-reference/gen-tokens.py from today's web UI — do not edit by hand.")
    w("// Every value cites its source (file:line) in the trailing comment. Dark + light, same names as the CSS")
    w("// custom properties (--bg-app → Theme.bgApp).")
    w("import AppKit")
    w("")
    w("public extension NSColor {")
    w("    convenience init(hex: UInt32, alpha: CGFloat = 1) {")
    w("        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,")
    w("                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)")
    w("    }")
    w("}")
    w("")
    w("public enum ThemeVariant { case dark, light }")
    w("")
    w("/// Colour tokens of the running Muya UI. `Theme.color(.bgApp, .dark)` or the dynamic `Theme.dynamic(.bgApp)`")
    w("/// (follows NSApp.effectiveAppearance).")
    w("public enum Theme {")
    w("    public enum Token: String, CaseIterable {")
    for n in names:
        w(f"        case {swift_name(n)} = \"{n}\"")
    w("    }")
    w("")
    w("    public static func color(_ t: Token, _ v: ThemeVariant) -> NSColor { v == .dark ? dark[t]! : light[t] ?? dark[t]! }")
    w("")
    w("    /// Appearance-aware colour: resolves at draw time, so views repaint on theme change without extra code.")
    w("    public static func dynamic(_ t: Token) -> NSColor {")
    w("        NSColor(name: nil) { ap in")
    w("            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(t, .dark) : color(t, .light)")
    w("        }")
    w("    }")
    w("")
    for tname in ("dark", "light"):
        w(f"    static let {tname}: [Token: NSColor] = [")
        for n in names:
            e = themes[tname].get(n)
            if not e:
                continue
            c = color_expr(e["value"])
            if c:
                w(f"        .{swift_name(n)}: {c}, // {e['src']}")
        w("    ]")
        w("")
    w("    /// Shadows that are not plain colours (CSS box-shadow strings, kept verbatim for reference).")
    for tname in ("dark", "light"):
        for n in ("shadow-popover", "shadow-segment-active", "pdf-page-shadow"):
            e = themes[tname].get(n)
            if e:
                w(f"    // {tname} --{n}: {e['value']}  ({e['src']})")
    w("}")
    w("")
    w("/// Theme-independent accent scale (violet-ish indigo: primary buttons on pages, \"Add to queue\", Create with Claude).")
    w("public enum ThemeRaw {")
    for k, (v, src) in parse_raw().items():
        w(f"    public static let {swift_name(k)} = NSColor(hex: 0x{v[1:].upper()}) // {src}")
    w("}")
    w("")
    w("/// xterm.js palette of the two themes (the native terminal must paint the same ANSI colours).")
    w("public enum TerminalPalette {")
    for tname in ("dark", "light"):
        w(f"    public static let {tname}: [String: NSColor] = [")
        for k, e in term.get(tname, {}).items():
            w(f"        \"{k}\": NSColor(hex: 0x{e['value'][1:].upper()}), // {e['src']}")
        w("    ]")
    w("}")
    w("")
    w("/// The same palette as 0xRRGGBB values (for the terminal renderer, which takes plain RGB).")
    w("public enum TerminalHex {")
    for tname in ("dark", "light"):
        w(f"    public static let {tname}: [String: UInt32] = [")
        for k, e in term.get(tname, {}).items():
            w(f"        \"{k}\": 0x{e['value'][1:].upper()},")
        w("    ]")
    w("}")
    w("")
    labels, fixed = parse_schemes()
    w("/// The terminal colour schemes of the appearance popover (src/theme/terminalThemes.ts TERMINAL_SCHEMES + FIXED_SCHEMES).")
    w("/// \"muya\" has no table: it follows the app theme (TerminalHex.dark / .light).")
    w("public enum TerminalSchemes {")
    w("    public static let all: [(id: String, label: String)] = [")
    for sid, lab, src in labels:
        w(f"        (\"{sid}\", \"{lab}\"), // {src}")
    w("    ]")
    w("    public static let hex: [String: [String: UInt32]] = [")
    for sid, cols in fixed.items():
        w(f"        \"{sid}\": [")
        for k, v in cols.items():
            w(f"            \"{k}\": 0x{v[1:].upper()},")
        w("        ],")
    w("    ]")
    w("}")
    w("")
    w("/// Typography of the running UI. Fonts: IBM Plex Sans (UI) and JetBrains Mono (terminal/code), both SIL OFL 1.1 —")
    w("/// bundle the .ttf/.otf files (node_modules/@fontsource/*) and register them; fall back to the system font.")
    w("public enum ThemeFont {")
    w(f"    public static let sansName = \"IBM Plex Sans\"      // {CSS}:103")
    w(f"    public static let monoName = \"JetBrains Mono\"     // {CSS}:104")
    w("    public static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {")
    w("        let ps = weight >= .bold ? \"IBMPlexSans-Bold\" : weight >= .semibold ? \"IBMPlexSans-SemiBold\" : weight >= .medium ? \"IBMPlexSans-Medium\" : \"IBMPlexSans-Regular\"")
    w("        return NSFont(name: ps, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight) // falls back until ThemeFonts.register() ran")
    w("    }")
    w("    public static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {")
    w("        NSFont(name: weight >= .bold ? \"JetBrainsMono-Bold\" : \"JetBrainsMono-Regular\", size: size)")
    w("            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)")
    w("    }")
    w("    /// Sizes in use (count of occurrences across src/redesign + src/components inline styles).")
    fs = metrics.get("fontSizes", {})
    for k, v in fs.items():
        w(f"    //   {k}px × {v}")
    w("}")
    w("")
    w("/// Geometry measured in the running mock UI at 1440×900 (native/ui-reference/measure.mjs).")
    w("public enum ThemeMetric {")
    for k, e in metrics.get("regions", {}).items():
        w(f"    public static let {swift_name(k.replace('.', '-'))}: CGFloat = {e['value']} // {e['src']}")
    w("    /// Inline borderRadius values by frequency (src/redesign + src/components): " + ", ".join(f"{k}×{v}" for k, v in list(metrics["radii"].items())[:8]))
    w("    public static let radii: [CGFloat] = [" + ", ".join(list(metrics["radii"])[:8]) + "]")
    w("}")
    out = os.path.join(ROOT, "native/app/Sources/Theme/Tokens.swift")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as fh:
        fh.write("\n".join(L) + "\n")
    print("wrote", out, "with", len(names), "colour tokens")


if __name__ == "__main__":
    main()
