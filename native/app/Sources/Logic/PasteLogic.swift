// What ⌘V does with the pasteboard (src/components/Terminal.tsx + xterm.js, the Tauri Muya's behaviour):
//   - Finder copy (file URLs): the paths, shell-escaped, space separated (Claude Code attaches image paths it is given).
//   - text: the text.
//   - an image and no text (a screenshot, "Copy Image"): an EMPTY bracketed paste, ESC[200~ESC[201~. xterm.js sends exactly that for
//     an empty clipboard text, and Claude Code answers an empty paste by reading the image off the system pasteboard itself and
//     attaching it ("[Image #1]"). Muya writes no temp file and sends no path: nothing else is needed.
//   - nothing usable: nothing.
// Pure so it is unit-tested (Tests/PasteTests.swift); TerminalView reads the pasteboard and hands the three facts in.

import Foundation

public enum PasteAction: Equatable, Sendable {
    case text(String)
    case emptyPasteForImage
    case nothing
}

public enum PasteLogic {
    /// Pasteboard type identifiers that mean "there is a picture on it".
    public static let imageTypeIdentifiers = ["public.png", "public.tiff", "public.jpeg", "public.heic", "com.compuserve.gif", "public.image"]

    public static func decide(filePaths: [String], string: String?, hasImage: Bool) -> PasteAction {
        let paths = filePaths.filter { !$0.isEmpty }
        if !paths.isEmpty { return .text(paths.map { TerminalFind.escapeForShell($0) }.joined(separator: " ")) }
        if let s = string, !s.isEmpty { return .text(s) }
        if hasImage { return .emptyPasteForImage }
        return .nothing
    }

    public static func hasImage(types: [String]) -> Bool { types.contains { imageTypeIdentifiers.contains($0) } }
}
