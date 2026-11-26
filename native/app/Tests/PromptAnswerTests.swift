// Unit tests of the verified prompt answer (Sources/Logic/PromptAnswer.swift). No sleeping: the decision is pure.

import Foundation

func runPromptAnswerTests() {
    test("prompt answer: first attempt sends the key, or Esc for deny") {
        check(PromptAnswer.next(attempt: 0, choice: .key("1", index: 0), stillPresent: true) == .write([.init(delay: 0, bytes: [0x31])]), "digit")
        check(PromptAnswer.next(attempt: 0, choice: .escape(denyIndex: 2), stillPresent: true) == .write([.init(delay: 0, bytes: [0x1b])]), "esc")
    }
    test("prompt answer: a prompt that went away after the key is done") {
        check(PromptAnswer.next(attempt: 1, choice: .key("1", index: 0), stillPresent: false) == .done, "done")
        check(PromptAnswer.next(attempt: 1, choice: .escape(denyIndex: 2), stillPresent: false) == .done, "done deny")
    }
    test("prompt answer: still there falls back to arrows then Enter as its own write") {
        let s = PromptAnswer.next(attempt: 1, choice: .key("3", index: 2), stillPresent: true)
        guard case let .write(w) = s else { check(false, "write"); return }
        check(w.map(\.bytes) == [PromptAnswer.down, PromptAnswer.down, PromptAnswer.enter], "down down enter")
        check(w.last?.delay == PromptAnswer.enterGap && w.last?.bytes == [0x0d], "Enter separate, with a gap")
        let first = PromptAnswer.next(attempt: 1, choice: .key("1", index: 0), stillPresent: true)
        check(first == .write([.init(delay: 0, bytes: [0x0d])]), "first option: Enter only")
        guard case let .write(d) = PromptAnswer.next(attempt: 1, choice: .escape(denyIndex: 1), stillPresent: true) else { check(false, "deny write"); return }
        check(d.map(\.bytes) == [PromptAnswer.down, PromptAnswer.enter], "deny moves to the last option")
    }
    test("prompt answer: the fallback moves by the delta from the live marker, both directions") {
        func bytes(_ c: PromptAnswer.Choice, _ sel: Int) -> [[UInt8]]? {
            guard case let .write(w) = PromptAnswer.next(attempt: 1, choice: c, stillPresent: true, selected: sel) else { return nil }
            return w.map(\.bytes)
        }
        check(bytes(.key("3", index: 2), 0) == [PromptAnswer.down, PromptAnswer.down, PromptAnswer.enter], "below: down x2")
        check(bytes(.key("1", index: 0), 2) == [PromptAnswer.up, PromptAnswer.up, PromptAnswer.enter], "above: up x2")
        check(PromptAnswer.up == [0x1b, 0x5b, 0x41], "up bytes")
        check(bytes(.key("2", index: 1), 1) == [PromptAnswer.enter], "already there: Enter only")
        check(bytes(.escape(denyIndex: 2), 1) == [PromptAnswer.down, PromptAnswer.enter], "deny from the middle")
    }
    test("prompt answer: still there after the fallback stops, never loops") {
        check(PromptAnswer.next(attempt: 2, choice: .key("1", index: 0), stillPresent: true) == .giveUp, "give up")
        check(PromptAnswer.next(attempt: 2, choice: .key("1", index: 0), stillPresent: false) == .done, "done")
        check(PromptAnswer.next(attempt: 9, choice: .escape(denyIndex: 2), stillPresent: true) == .giveUp, "later attempts too")
    }
    test("prompt answer: timing values are short and ordered") {
        check(PromptAnswer.verifyDelay > PromptAnswer.enterGap && PromptAnswer.enterGap > 0, "timing")
    }
}
