// The open-files list: stays inside its frame and scrolls, a long name never reaches the ×, only the × closes.

import Foundation

func runOpenFilesLayoutTests() {
    typealias L = OpenFilesLayout
    test("open files: 22 cards do not fit a 400 px list; the viewport ends at the frame and the list scrolls") {
        let l = L(width: 264, height: 400, count: 22)
        check(l.scrolls, "scrolls")
        check(l.viewport.maxY == 400, "viewport ends at the frame's bottom edge")
        check(l.maxOffset == 22 * 44 + 8 - (400 - 52), "max offset: \(l.maxOffset)")
        for off in [0, 100, l.maxOffset] {
            for i in l.visible(offset: off) {
                let c = l.card(i, offset: off)
                check(c.maxY > l.viewport.minY && c.minY < l.viewport.maxY, "card \(i) at offset \(off) touches the viewport")
            }
        }
        check(l.visible(offset: 0).count <= 9, "only about a screenful is drawn: \(l.visible(offset: 0))")
        check(l.visible(offset: l.maxOffset).upperBound == 22, "scrolled to the end shows the last card")
    }
    test("open files: few cards fit, nothing scrolls; offsets clamp") {
        let l = L(width: 264, height: 400, count: 3)
        check(!l.scrolls && l.maxOffset == 0, "no scrolling")
        check(l.clamp(-50) == 0 && l.clamp(500) == 0, "clamped to zero")
        let m = L(width: 264, height: 300, count: 22)
        check(m.clamp(-5) == 0 && m.clamp(1e6) == m.maxOffset, "clamped both ways")
    }
    test("open files: revealing a card moves the least") {
        let l = L(width: 264, height: 300, count: 22)
        check(l.offsetRevealing(0, from: 0) == 0, "already visible")
        check(l.card(21, offset: l.offsetRevealing(21, from: 0)).maxY <= l.viewport.maxY, "last card scrolls fully into view")
        let o = l.offsetRevealing(10, from: 0)
        let c = l.card(10, offset: o)
        check(c.minY >= l.viewport.minY && c.maxY <= l.viewport.maxY + 4, "revealed card sits inside the viewport")
        check(l.offsetRevealing(2, from: o) < o, "scrolls back up for an earlier card")
    }
    test("open files: the row is icon, name, dot, × — and the name only gets what is left") {
        let c = L(width: 264, height: 400, count: 1).card(0, offset: 0)
        let icon = L.iconRect(card: c), close = L.closeRect(card: c), dot = L.dotRect(card: c)
        check(icon.minX == c.minX + L.nameLead && icon.width == L.iconSize, "the icon leads the row: \(icon)")
        check(L.textLead(card: c) == icon.maxX + L.iconGap, "the name starts after the icon")
        check(dot.maxX <= close.minX && dot.minX > L.textLead(card: c), "the unsaved dot sits just before the ×: \(dot) vs \(close)")
        let plain = L.nameWidth(card: c, dirty: false), dirty = L.nameWidth(card: c, dirty: true)
        check(L.textLead(card: c) + plain <= close.minX, "name ends before the ×")
        check(dirty < plain && dirty == plain - (L.dotSize + L.dotGap), "an unsaved file gives the dot its room")
        check(L.nameWidth(card: CGRect(x: 0, y: 0, width: 20, height: 40), dirty: true) == 0, "never negative")
    }
    test("open files: the icon follows the file's extension, as classic maps its viewer kind") {
        check(L.icon(for: "/a/b/notes.md") == .markdown, "markdown")
        check(L.icon(for: "/a/b/shot.PNG") == .image, "image, any case")
        check(L.icon(for: "/a/b/paper.pdf") == .pdf, "pdf")
        check(L.icon(for: "/a/b/main.swift") == .code && L.icon(for: "/a/b/Makefile") == .code, "everything else is code")
    }
    test("open files: a click on the right part of a long name OPENS, only the × closes") {
        let l = L(width: 264, height: 400, count: 22)
        let c = l.card(0, offset: 0), x = L.closeRect(card: c)
        check(l.hit(CGPoint(x: x.minX - 3, y: c.midY), offset: 0) == .open(0), "just left of the ×: opens (the old 30 px zone closed here)")
        check(l.hit(CGPoint(x: c.maxX - 31, y: c.midY), offset: 0) == .open(0), "31 px from the edge: opens")
        check(l.hit(CGPoint(x: x.midX, y: x.midY), offset: 0) == .close(0), "the × closes")
        check(l.hit(CGPoint(x: c.minX + 30, y: c.midY), offset: 0) == .open(0), "the name opens")
        check(l.hit(CGPoint(x: x.midX, y: c.minY + 1), offset: 0) == .open(0), "above the × button, same column: opens")
    }
    test("open files: hits follow the scroll offset and ignore what is clipped away") {
        let l = L(width: 264, height: 300, count: 22)
        let off: CGFloat = 5 * 44
        let c = l.card(5, offset: off)
        check(l.hit(CGPoint(x: c.minX + 20, y: c.midY), offset: off) == .open(5), "card 5 at the top of the viewport")
        check(l.hit(CGPoint(x: 20, y: 10), offset: off) == .none, "the title row is not a card")
        check(l.hit(CGPoint(x: 20, y: 400), offset: off) == .none, "below the frame is nothing")
    }
    test("open files: the list always keeps its title row above the cards") {
        check(L.wantedHeight(count: 2) == 52 + 88 + 8, "title row + two cards + the bottom pad")
        check(L(width: 264, height: 100, count: 2).viewport.minY == 52, "the cards start under the title")
    }
}
