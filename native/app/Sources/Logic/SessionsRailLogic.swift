// Sessions rail: when the Agents column is closed, the narrow left rail has two pages, "Sessions" (one compact item per session)
// and "Menu" (Control, Files, Sessions, Queue ...). Pure data here (page state, row geometry, monograms, session stepping, the
// ⌃⌥ arrow chords) so it is unit-tested (Tests/SessionsRailTests.swift); Sources/App/SessionsRail.swift only draws and routes.

import Foundation

public enum RailPage: Equatable, Sendable { case sessions, menu }

/// Which page the rail shows. Closing the column starts on Sessions, opening it goes back to Menu.
public struct RailPages: Equatable, Sendable {
    public private(set) var collapsed = false
    public private(set) var page: RailPage = .menu
    public init() {}
    public init(collapsed: Bool) { setCollapsed(collapsed) }
    public var showsSessions: Bool { collapsed && page == .sessions }
    public mutating func setCollapsed(_ c: Bool) {
        guard c != collapsed else { return }
        collapsed = c; page = c ? .sessions : .menu
    }
    /// False (nothing changed) while the column is open: the rail only has the Menu page then.
    @discardableResult public mutating func flip(to p: RailPage) -> Bool {
        guard collapsed else { return false }
        page = p; return true
    }
}

public enum RailGeometry {
    public static let itemHeight: CGFloat = 56, itemGap: CGFloat = 2, groupGap: CGFloat = 10
    public struct Row: Equatable, Sendable { public var index: Int; public var y: CGFloat; public var group: String? }
    /// One row per session in list order; a bigger gap where the split group changes. `groups[i]` = the split group id of session i (nil = none).
    public static func rows(groups: [String?]) -> (rows: [Row], height: CGFloat) {
        var out: [Row] = [], y: CGFloat = 0
        for (i, g) in groups.enumerated() {
            if i > 0 { y += groups[i - 1] == g && g != nil ? itemGap : (groups[i - 1] == nil && g == nil ? itemGap : groupGap) }
            out.append(Row(index: i, y: y, group: g)); y += itemHeight
        }
        return (out, y)
    }
    /// The scroll offset that keeps `row` visible inside a viewport of `viewport` points, starting from `offset`.
    public static func reveal(rowY: CGFloat, offset: CGFloat, viewport: CGFloat) -> CGFloat {
        if rowY < offset { return rowY }
        if rowY + itemHeight > offset + viewport { return rowY + itemHeight - viewport }
        return offset
    }
    public static func clamp(offset: CGFloat, content: CGFloat, viewport: CGFloat) -> CGFloat { max(0, min(offset, max(0, content - viewport))) }
}

public enum RailMonogram {
    /// 2-3 letters: initials of the name's words ("muya-all" -> "MA", "claude control plane" -> "CCP"), else the first two letters.
    public static func make(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { !$0.isEmpty }
        if words.count >= 2 { return String(words.prefix(3).compactMap(\.first)).uppercased() }
        return String((words.first ?? Substring(name)).prefix(2)).uppercased()
    }
}

public enum SessionStep {
    /// The id before/after `current` in `ids`, wrapping around; nothing selected -> first (forward) or last (back).
    public static func neighbor(of current: UInt64?, in ids: [UInt64], delta: Int) -> UInt64? {
        guard !ids.isEmpty else { return nil }
        guard let c = current, let i = ids.firstIndex(of: c) else { return delta >= 0 ? ids.first : ids.last }
        return ids[((i + delta) % ids.count + ids.count) % ids.count]
    }
}

public enum RailKeyAction: Equatable, Sendable { case flip(RailPage), step(Int) }

public enum RailKeys {
    /// Exactly ⌃⌥ + an arrow (no ⌘, no ⇧): ← Sessions page, → Menu page, ↑ previous session, ↓ next session.
    /// ⌥-arrows alone stay readline word moves in the terminal (TerminalKeys.altArrow needs !ctrl); ⌃←/→ is macOS Spaces.
    public static func action(_ k: KeyChord) -> RailKeyAction? {
        guard k.ctrl, k.alt, !k.cmd, !k.shift else { return nil }
        switch k.keyCode {
        case VK.left: return .flip(.sessions)
        case VK.right: return .flip(.menu)
        case VK.up: return .step(-1)
        case VK.down: return .step(1)
        default: return nil
        }
    }
}
