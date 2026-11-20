// P3: the app's keyboard shortcuts as pure data, so the key -> action / terminal-bytes map is unit-tested
// (Tests/P3Tests.swift) and the AppKit side (Sources/App/Shortcuts.swift) only routes. Every rule cites today's
// code: src/components/Terminal.tsx (xterm key handler), src/App.tsx (window capture-phase handler),
// src/lib/keys.ts, src/lib/workspaceScope.ts, src/redesign/usePanelLayout.ts, src/redesign/gridKeys.ts,
// src-tauri/src/lib.rs (menu accelerators, quit guard).

import Foundation

/// One key press, as AppKit reports it: the virtual key code, the character with modifiers ignored (layout aware,
/// so Turkish and other layouts keep working), and the modifier keys.
public struct KeyChord: Equatable, Sendable {
    public var keyCode: UInt16
    public var chars: String
    public var cmd: Bool, shift: Bool, alt: Bool, ctrl: Bool
    public init(keyCode: UInt16, chars: String, cmd: Bool = false, shift: Bool = false, alt: Bool = false, ctrl: Bool = false) {
        self.keyCode = keyCode; self.chars = chars.lowercased()
        self.cmd = cmd; self.shift = shift; self.alt = alt; self.ctrl = ctrl
    }
    public var noMods: Bool { !cmd && !shift && !alt && !ctrl }
}

/// macOS virtual key codes (Carbon `kVK_*`) the shortcuts use.
public enum VK {
    public static let enter: UInt16 = 36, keypadEnter: UInt16 = 76, escape: UInt16 = 53
    public static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
    public static let b: UInt16 = 11
    /// The number row, digit 0...9 (the codes are not consecutive).
    public static let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
    public static func digit(_ code: UInt16) -> Int? { digits.firstIndex(of: code) }
}

// MARK: - Terminal keys (Terminal.tsx attachCustomKeyEventHandler, in its order)

public enum TerminalKeyAction: Equatable, Sendable {
    /// Bytes written to the terminal exactly as given.
    case write(String)
    /// ⌘C: copy when text is selected, else Ctrl+C (SIGINT).
    case copyOrInterrupt
    /// ⌘⇧C: type the claude launch command into the shell.
    case launchClaude
    /// ⌘F: the in-terminal search.
    case search
    /// ⌘= / ⌘+ / ⌘- / ⌘0: terminal font bigger (+1), smaller (-1), default (0).
    case font(Int)
}

public enum TerminalKeys {
    /// ⌘ + letter -> the control byte (Terminal.tsx `cmdMap`). `w` is the menu's and `k` is the app's command palette
    /// (App.tsx's capture-phase handler takes it before xterm ever sees it), so both are absent.
    public static let cmdLetters: [String: String] = [
        "r": "\u{12}", "l": "\u{0C}", "a": "\u{01}", "e": "\u{05}", "d": "\u{04}", "u": "\u{15}",
    ]

    /// Option + arrow (keys.ts `altArrowSeq`): readline meta word-nav left/right, plain arrows up/down.
    public static func altArrow(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case VK.left: return "\u{1B}b"
        case VK.right: return "\u{1B}f"
        case VK.up: return "\u{1B}[A"
        case VK.down: return "\u{1B}[B"
        default: return nil
        }
    }

    /// What a key does in a focused terminal, or nil to leave it to the normal key path (named keys, text input, IME).
    public static func action(_ k: KeyChord) -> TerminalKeyAction? {
        // Shift+Enter -> "\n" (newline, not submit).
        if (k.keyCode == VK.enter || k.keyCode == VK.keypadEnter), k.shift, !k.ctrl, !k.alt, !k.cmd { return .write("\n") }
        // ⌘F -> search.
        if k.cmd, k.chars == "f", !k.shift, !k.ctrl, !k.alt { return .search }
        // ⌘= ⌘+ ⌘- ⌘0 -> font (shift allowed: "+" is shift+"=" on most layouts).
        if k.cmd, !k.ctrl, !k.alt, ["=", "+", "-", "0"].contains(k.chars) { return .font(k.chars == "-" ? -1 : k.chars == "0" ? 0 : 1) }
        // ⌘⇧C -> launch claude.
        if k.cmd, k.shift, !k.ctrl, !k.alt, k.chars == "c" { return .launchClaude }
        // ⌘ + r k l a e d c u -> control byte.
        if k.cmd, !k.shift, !k.ctrl, !k.alt {
            if k.chars == "c" { return .copyOrInterrupt }
            if let b = cmdLetters[k.chars] { return .write(b) }
        }
        // Option + arrows.
        if k.alt, !k.cmd, !k.ctrl, !k.shift, let s = altArrow(k.keyCode) { return .write(s) }
        return nil
    }

    /// Font size after a step (Terminal prefs: 9...28, default 13).
    public static let fontMin = 9, fontMax = 28, fontDefault = 13
    public static func steppedFont(_ current: Int, _ delta: Int) -> Int {
        delta == 0 ? fontDefault : min(fontMax, max(fontMin, current + delta))
    }
}

// MARK: - App shortcuts (App.tsx capture-phase handler, usePanelLayout.ts, ⌘T)

public enum AppShortcut: Equatable, Sendable {
    /// ⌘1-9: the Nth agent as listed (1-based).
    case selectAgent(Int)
    /// ⌥⌘1-9: the Nth workspace; ⌥⌘0 (`nil`): all workspaces.
    case selectWorkspace(Int?)
    case toggleAgentsPanel      // ⌘B
    case toggleInspector        // ⌥⌘B
    case newTerminal            // ⌘T
    case splitTerminalArea      // ⌘⇧D
    case maximizeGridPanel      // ⌘Enter
    case togglePalette          // ⌘K
    case reopenClosedTab        // ⌘⇧T (File menu in lib.rs; handled here so the ⌘T menu item can never catch it)
}

public enum AppShortcuts {
    /// ⌘S: classic has no app-level ⌘S (Monaco binds it while it is focused); Native's menu puts View > Sessions on it. The
    /// resolution: while a file with unsaved edits is on screen ⌘S saves it, wherever the keyboard focus is; otherwise it is Sessions.
    public static func commandSSaves(editorVisible: Bool, dirty: Bool) -> Bool { editorVisible && dirty }

    public static func action(_ k: KeyChord) -> AppShortcut? {
        guard k.cmd, !k.ctrl else { return nil }
        // ⌘⇧D (⌘D alone stays Ctrl+D for the terminal).
        if k.shift, !k.alt { return k.chars == "d" ? .splitTerminalArea : k.chars == "t" ? .reopenClosedTab : nil }
        if k.shift { return nil }
        // Panel toggles use the key code: ⌥B types "∫" on macOS.
        if k.keyCode == VK.b { return k.alt ? .toggleInspector : .toggleAgentsPanel }
        if k.alt { // ⌥⌘0-9 by key code, so the number row works on every layout
            guard let n = VK.digit(k.keyCode) else { return nil }
            return .selectWorkspace(n == 0 ? nil : n)
        }
        if k.chars == "t" { return .newTerminal }
        if k.chars == "k" { return .togglePalette }
        if k.keyCode == VK.enter || k.keyCode == VK.keypadEnter { return .maximizeGridPanel }
        if let n = Int(k.chars), (1 ... 9).contains(n) { return .selectAgent(n) }
        return nil
    }

    /// Esc leaves the grid (gridKeys.ts `shouldExitGridOnEscape`): not with any modifier, not while an overlay is
    /// open, not when the key belongs to a terminal, a text field or a dialog.
    public static func escapeLeavesGrid(_ k: KeyChord, overlayOpen: Bool, focusIsTerminalOrField: Bool) -> Bool {
        k.keyCode == VK.escape && k.noMods && !overlayOpen && !focusIsTerminalOrField
    }
}

// MARK: - ⌘Q double press (lib.rs: QUIT_DOUBLE_PRESS_MS)

public struct QuitGuard: Sendable {
    public static let windowMs: UInt64 = 700
    public enum Outcome: Equatable, Sendable { case showHint, quit }
    private var lastMs: UInt64 = 0
    public init() {}
    /// A ⌘Q press at `nowMs`: the first shows "press ⌘Q again", a second within 700 ms quits.
    public mutating func press(nowMs: UInt64) -> Outcome {
        if nowMs &- lastMs < Self.windowMs { lastMs = 0; return .quit }
        lastMs = nowMs
        return .showHint
    }
}

// MARK: - Files handed to the app (lib.rs get_startup_files + apex://open-file)

/// Paths from Finder ("Open With", double-click, drop on the Dock icon). Before the window can show them they wait
/// here (`get_startup_files` drains the list once); afterwards they are handed over at once (`apex://open-file`).
public struct StartupFiles: Sendable {
    private var pending: [String] = []
    private var ready = false
    public init() {}
    /// Returns the paths to open now (empty while the app is not ready yet: they are kept).
    public mutating func offer(_ paths: [String]) -> [String] {
        if ready { return paths }
        pending.append(contentsOf: paths)
        return []
    }
    /// The app is ready: hands over what arrived early, once.
    public mutating func drain() -> [String] {
        ready = true
        defer { pending = [] }
        return pending
    }
}

// MARK: - Closed tabs (⌘⇧T)

/// What ⌘⇧T brings back, newest first: a closed terminal session (its folder) or a closed file.
public enum ClosedTab: Equatable, Sendable {
    case terminal(cwd: String, name: String)
    case file(path: String)
}

public struct ClosedTabs: Sendable {
    public static let limit = 20
    private(set) var stack: [ClosedTab] = []
    public init() {}
    public var isEmpty: Bool { stack.isEmpty }
    public mutating func push(_ t: ClosedTab) {
        if case .file(let p) = t { stack.removeAll { $0 == .file(path: p) } }
        stack.append(t)
        if stack.count > Self.limit { stack.removeFirst(stack.count - Self.limit) }
    }
    public mutating func pop() -> ClosedTab? { stack.popLast() }
}

// MARK: - IME candidate window anchor

/// Where the input method's candidate window goes: the cursor cell, in view points (origin top-left). The cell size
/// follows the terminal font (⌘= / ⌘-), so it is always passed in, never assumed.
public enum IMEAnchor {
    public static func cellRect(col: Int, row: Int, cellW: Double, cellH: Double, padding: Double) -> (x: Double, y: Double, w: Double, h: Double) {
        (padding + Double(col) * cellW, padding + Double(row) * cellH, cellW, cellH)
    }
}
