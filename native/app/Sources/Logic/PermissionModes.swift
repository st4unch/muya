// Permission modes of a Claude session as today's Muya shows and switches them (src/redesign/Composer.tsx MODE_LABEL,
// src/App.tsx MODE_ITEMS + setModeTo): the chip text, the picker items, and the Shift+Tab stepping rule. Claude Code only
// cycles modes with Shift+Tab (ESC [ Z), so "switch to X" presses it up to 4 times, 0.7 s apart, until the screen shows X or stops changing.

import Foundation

enum PermissionModes {
    /// The picker: Manual, Accept edits, Plan, Auto (bypass is fixed at launch and outside the cycle).
    static let items: [(mode: String, label: String)] = [("default", "Manual"), ("acceptEdits", "Accept edits"), ("plan", "Plan"), ("auto", "Auto")]
    static let cycleKeys = "\u{1B}[Z"          // Shift+Tab
    static let maxPresses = 4
    static let settleSeconds = 0.7             // 300 ms screen-parse throttle + Claude's repaint (App.tsx setModeTo)

    static func isBypass(_ mode: String) -> Bool { mode.lowercased().contains("bypass") }

    /// Chip text after "Mode: " (MODE_LABEL): manual / accept edits / plan / auto / bypass.
    static func chipLabel(_ mode: String) -> String {
        switch mode {
        case "default": return "manual"
        case "acceptEdits": return "accept edits"
        case "plan": return "plan"
        case "auto": return "auto"
        default: return isBypass(mode) ? "bypass" : mode
        }
    }

    /// Whether the stepping loop presses Shift+Tab again: not there yet and presses left.
    static func shouldPress(current: String, target: String, pressed: Int) -> Bool { current != target && pressed < maxPresses }
    /// After a press: keep going only while the mode changed (an unchanged screen means Claude is not cycling — stop, like the web).
    static func shouldContinue(before: String, after: String) -> Bool { before != after }
}
