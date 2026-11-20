// Tests for Sources/Logic/EditorExtras.swift and the bracket-depth part of SyntaxHighlight.swift.

import Foundation

func runEditorExtraTests() {
    test("folding: indentation blocks, closing line stays visible, blank lines inside, not foldable") {
        let t = "a {\n  b\n\n  c {\n    d\n  }\n}\nz\n" as NSString
        let r = Folding.range(headerLineStart: 0, in: t)!
        check(t.substring(with: r) == "\n  b\n\n  c {\n    d\n  }", "outer block \(r)")
        let inner = Folding.range(headerLineStart: t.range(of: "  c {").location, in: t)!
        check(t.substring(with: inner) == "\n    d", "inner block")
        check(Folding.range(headerLineStart: t.range(of: "z").location, in: t) == nil, "last line")
        check(Folding.range(headerLineStart: t.range(of: "  b").location, in: t) == nil, "no deeper line below")
        check(Folding.range(headerLineStart: 0, in: "x\ny\n" as NSString) == nil, "same indent")
    }

    test("brackets: matching pair, nesting, caret on either side, none") {
        let t = "f(a[1], {b: (c)})" as NSString
        let p = BracketMatch.pair(at: 2, in: t)
        check(p?.0 == 1 && p?.1 == 16, "( at 1 pairs with ) at 16: \(String(describing: p))")
        let q = BracketMatch.pair(at: 17, in: t)
        check(q?.0 == 16 && q?.1 == 1, "caret after the closing bracket: \(String(describing: q))")
        let inner = BracketMatch.pair(at: 13, in: t)
        check(inner?.0 == 12 && inner?.1 == 14, "inner pair \(String(describing: inner))")
        check(BracketMatch.pair(at: 0, in: "( unclosed" as NSString) == nil, "unbalanced")
    }

    test("brackets are coloured by depth, skipped inside strings, depth carried in the state") {
        let u = Array("a(b[\"(\"], {c})".utf16)
        var br: [TokenKind] = []
        let st = u.withUnsafeBufferPointer { b in
            SyntaxScanner.scan(b, from: 0, to: b.count, language: .typescript, state: 0) { _, _, k in if k == .bracket1 || k == .bracket2 || k == .bracket3 { br.append(k) } }
        }
        check(br.count == 6, "six brackets (the one in the string is skipped): \(br.count)")
        check(br.first == .bracket1 && br[1] == .bracket2 && br.last == .bracket1, "depth colours")
        check(st >> 8 == 0, "balanced: depth 0")
        let u2 = Array("f(g[".utf16)
        let st2 = u2.withUnsafeBufferPointer { SyntaxScanner.scan($0, from: 0, to: $0.count, language: .typescript, state: 0, emit: nil) }
        check(st2 >> 8 == 2, "depth carries in the state")
    }

    test("multi-cursor: next occurrence, word selection, wrap, no duplicates") {
        let t = "foo bar foo baz foo" as NSString
        let w = MultiCursor.nextOccurrence(ranges: [NSRange(location: 1, length: 0)], in: t)
        check(w.selectWord == NSRange(location: 0, length: 3) && w.add == nil, "empty caret selects the word first")
        let n1 = MultiCursor.nextOccurrence(ranges: [NSRange(location: 0, length: 3)], in: t)
        check(n1.add == NSRange(location: 8, length: 3), "second foo")
        let n2 = MultiCursor.nextOccurrence(ranges: [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3)], in: t)
        check(n2.add == NSRange(location: 16, length: 3), "third foo")
        let all = MultiCursor.nextOccurrence(ranges: [NSRange(location: 0, length: 3), NSRange(location: 8, length: 3), NSRange(location: 16, length: 3)], in: t)
        check(all.add == nil, "all taken: nothing new")
        let wrap = MultiCursor.nextOccurrence(ranges: [NSRange(location: 16, length: 3)], in: t)
        check(wrap.add == NSRange(location: 0, length: 3), "wraps to the start")
    }
}
