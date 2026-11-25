// FILES click decisions (5.0.2): a click on a row never collapses the section, a folder toggles itself, a file opens.

import Foundation

func runFileClickTests() {
    test("FILES row clicks: file opens, folder toggles, nothing closes the section") {
    typealias L = FileClickLogic
    check(L.action(isDirectory: false, onDisclosure: false, clickCount: 1, extend: false) == .openFile, "single click on a file opens it")
    check(L.action(isDirectory: true, onDisclosure: false, clickCount: 1, extend: false) == .toggleFolder, "single click on a folder (or a workspace root) toggles that folder")
    check(L.action(isDirectory: true, onDisclosure: true, clickCount: 1, extend: false) == .none, "the triangle is AppKit's: no second toggle")
    check(L.action(isDirectory: true, onDisclosure: false, clickCount: 2, extend: false) == .none, "second click of a double-click does not undo the toggle")
    check(L.action(isDirectory: false, onDisclosure: false, clickCount: 2, extend: false) == .none, "double-click on a file does not open it twice")
    check(L.action(isDirectory: false, onDisclosure: false, clickCount: 1, extend: true) == .none, "shift/command/control click only selects")
    check(L.action(isDirectory: true, onDisclosure: false, clickCount: 1, extend: true) == .none, "modified click on a folder does not toggle")
    }
}
