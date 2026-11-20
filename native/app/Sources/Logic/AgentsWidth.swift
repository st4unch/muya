// The left "Agents" column's width: default, bounds and restore rules (usePanelLayout.ts: 296 wide, 264 at <= 1360, 220-480).
// On top of the classic bounds the column never takes more than `maxFraction` of the window, so a stale saved width or a
// window that grew after launch cannot squeeze the terminals.

import Foundation

public enum AgentsWidth {
    public static let min = 220.0
    public static let max = 480.0
    public static let maxFraction = 0.32

    /// Today's default for the window's size class.
    public static func defaultWidth(window: Double) -> Double { window <= 1360 ? 264 : 296 }

    /// Upper bound for a window of this width (never below `min`).
    public static func upperBound(window: Double) -> Double { Swift.max(min, Swift.min(max, (window * maxFraction).rounded(.down))) }

    public static func clamp(_ width: Double, window: Double) -> Double { Swift.min(Swift.max(width, min), upperBound(window: window)) }

    /// Width to show: the saved one clamped to the window, or the default when nothing valid is saved.
    public static func restore(saved: Double?, window: Double) -> Double {
        guard let s = saved, s.isFinite else { return clamp(defaultWidth(window: window), window: window) }
        return clamp(s, window: window)
    }
}
