// Named colour tokens (project rule: colours only through tokens, both appearances). Chrome uses
// the system's semantic colours; the terminal has its own dark and light palettes.

import AppKit
import CGhostty

struct RGB {
    var r: UInt8, g: UInt8, b: UInt8
    init(_ hex: UInt32) { r = UInt8((hex >> 16) & 255); g = UInt8((hex >> 8) & 255); b = UInt8(hex & 255) }
    var hexValue: UInt32 { UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }
    var color: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    var ghostty: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }
}

struct TerminalTheme {
    var foreground: RGB
    var background: RGB
    var cursor: RGB
    var selection: RGB
    /// ANSI colours 0-15.
    var ansi: [RGB]

    /// The xterm.js palette of today's Muya (src/theme/terminalThemes.ts) via the generated TerminalHex table.
    private static func from(_ t: [String: UInt32]) -> TerminalTheme {
        let names = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
                     "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"]
        return TerminalTheme(foreground: RGB(t["foreground"]!), background: RGB(t["background"]!), cursor: RGB(t["cursor"]!),
                             selection: RGB(t["selectionBackground"]!), ansi: names.map { RGB(t[$0]!) })
    }
    static let dark = from(TerminalHex.dark)
    static let light = from(TerminalHex.light)

    /// The 8 fixed schemes of the appearance popover (TerminalSchemes), by id.
    static func fixed(_ id: String) -> TerminalTheme? { TerminalSchemes.hex[id].map(from) }

    static func current(for appearance: NSAppearance, scheme: String? = nil) -> TerminalTheme {
        if let t = fixed(scheme ?? TerminalSchemeState.id) { return t }
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

/// The colour scheme every terminal wears (today's muya.terminalPrefs.scheme): "muya" follows the app theme, the others are fixed.
enum TerminalSchemeState {   // read and written on the main thread only
    static let didChange = Notification.Name("MuyaTerminalSchemeDidChange")
    nonisolated(unsafe) private(set) static var id = "muya"
    static func isValid(_ s: String) -> Bool { TerminalSchemes.all.contains { $0.id == s } }
    static func set(_ s: String) {
        let v = isValid(s) ? s : "muya"
        guard v != id else { return }
        id = v
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    /// The area around the grid: a fixed scheme paints its own background there (Terminal.tsx, padding), "muya" uses --bg-terminal.
    static let padFill = NSColor(name: nil) { a in
        if let t = TerminalTheme.fixed(id) { return t.background.color }
        return Theme.dynamic(.bgTerminal).resolved(a)
    }
}

extension NSColor {
    /// This (dynamic) colour as it looks under `appearance`.
    func resolved(_ appearance: NSAppearance) -> NSColor {
        var out = self
        appearance.performAsCurrentDrawingAppearance { out = NSColor(cgColor: self.cgColor) ?? self }
        return out
    }
}

enum Token {
    static func dynamic(_ name: String, dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? RGB(dark).color : RGB(light).color
        }
    }
    static let stateBusy = dynamic("stateBusy", dark: 0x7FC27A, light: 0x2E7D32)
    static let statePermission = dynamic("statePermission", dark: 0xF0A04B, light: 0xB35C00)
    static let stateIdle = dynamic("stateIdle", dark: 0x7D8590, light: 0x8C959F)
    static let stateExited = dynamic("stateExited", dark: 0xE0626B, light: 0xC62828)
    static let stateClaude = dynamic("stateClaude", dark: 0x82C0F5, light: 0x1F5FBF)
    static let terminalBackground = Theme.dynamic(.bgTerminal) // --bg-terminal (src/styles/tokens.css:39,113)
    // Text colours of today's Muya (src/styles/tokens.css): every legacy page that uses Token.* follows them.
    static let text = Theme.dynamic(.text)
    static let textSecondary = Theme.dynamic(.textMuted)
    static let textTertiary = Theme.dynamic(.textFaint)
}
