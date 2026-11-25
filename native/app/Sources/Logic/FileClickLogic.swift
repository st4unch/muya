// What one mouse click on a row of the Files tree does (src/components/FileTree.tsx `toggle`, 5.0.2 FILES fix): a folder row (a
// workspace root too) opens or closes THAT folder, a file row opens the file. Nothing a click on a row does can close the FILES
// section itself: only its own header does that. Pure so it is unit-tested (Tests/FileClickTests.swift); FileOutline only applies it.

import Foundation

public enum FileClickAction: Equatable, Sendable {
    case none
    case toggleFolder
    case openFile
}

public enum FileClickLogic {
    /// `onDisclosure`: the press landed on the row's own triangle (AppKit already toggles it). `clickCount`: 1 for the first click of a
    /// series; later clicks of a double-click do nothing more (they would undo the toggle). `extend`: shift / command / control is
    /// held (a multi-selection or a context menu, not an "open").
    public static func action(isDirectory: Bool, onDisclosure: Bool, clickCount: Int, extend: Bool) -> FileClickAction {
        if onDisclosure || clickCount != 1 || extend { return .none }
        return isDirectory ? .toggleFolder : .openFile
    }
}
