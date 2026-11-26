// A verified answer to Claude's permission prompt. Typing the option digit once and assuming it worked left a
// prompt on screen (and the session stuck) whenever the TUI ignored the key. The decision is pure: given which
// attempt this is, which option is wanted and whether the same prompt is still showing, what to write next.

import Foundation

enum PromptAnswer {
    /// Wait after a write before looking at the screen again.
    static let verifyDelay: TimeInterval = 0.6
    /// Gap between the arrow presses and the Enter of the fallback; Enter is its own write (see Store.submitText).
    static let enterGap: TimeInterval = 0.15
    /// Gap between two arrow presses.
    static let arrowGap: TimeInterval = 0.05

    struct Write: Equatable {
        var delay: TimeInterval
        var bytes: [UInt8]
    }

    enum Step: Equatable {
        case write([Write])   // do these, wait `verifyDelay`, then ask again with attempt + 1
        case done
        case giveUp           // still there after the fallback: stop, surface it, do not loop
    }

    enum Choice: Equatable {
        case key(String, index: Int)   // the option's digit and its 0-based position in the list
        case escape(denyIndex: Int)    // Esc; the fallback selects the last (Deny) option
    }

    static let down: [UInt8] = [0x1b, 0x5b, 0x42]   // ESC [ B
    static let up: [UInt8] = [0x1b, 0x5b, 0x41]     // ESC [ A
    static let enter: [UInt8] = [0x0d]

    /// attempt 0 = the first answer (the prompt is on screen by definition); 1 = after the first write;
    /// 2 = after the fallback. `selected` is the row the `❯` marker is on in the live screen right now (the
    /// fallback moves by the distance from there to the wanted row, not from an assumed first row).
    static func next(attempt: Int, choice: Choice, stillPresent: Bool, selected: Int = 0) -> Step {
        switch attempt {
        case 0:
            switch choice {
            case let .key(k, _): return .write([Write(delay: 0, bytes: Array(k.utf8))])
            case .escape: return .write([Write(delay: 0, bytes: [0x1b])])
            }
        case 1:
            guard stillPresent else { return .done }
            let index: Int
            switch choice {
            case let .key(_, i): index = max(0, i)
            case let .escape(d): index = max(0, d)
            }
            let delta = index - max(0, selected)
            let arrow = delta > 0 ? down : up
            var writes: [Write] = []
            for n in 0..<abs(delta) { writes.append(Write(delay: n == 0 ? 0 : arrowGap, bytes: arrow)) }
            writes.append(Write(delay: delta == 0 ? 0 : enterGap, bytes: enter))
            return .write(writes)
        default:
            return stillPresent ? .giveUp : .done
        }
    }
}
