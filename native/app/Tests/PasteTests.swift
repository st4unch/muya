// Unit tests of what ⌘V sends (Sources/Logic/PasteLogic.swift).

import Foundation

func runPasteTests() {
    test("paste: plain text pastes as text") {
        check(PasteLogic.decide(filePaths: [], string: "hello world", hasImage: false) == .text("hello world"), "text")
    }
    test("paste: an image and no text becomes an empty bracketed paste (Claude Code then reads the image)") {
        check(PasteLogic.decide(filePaths: [], string: nil, hasImage: true) == .emptyPasteForImage, "nil string")
        check(PasteLogic.decide(filePaths: [], string: "", hasImage: true) == .emptyPasteForImage, "empty string")
    }
    test("paste: text wins over an image that came along with it (xterm.js pastes the text)") {
        check(PasteLogic.decide(filePaths: [], string: "alt text", hasImage: true) == .text("alt text"), "text first")
    }
    test("paste: Finder copy pastes the escaped paths, even though the pasteboard also carries the file name and an icon image") {
        let a = PasteLogic.decide(filePaths: ["/tmp/my shot.png", "/tmp/b.png"], string: "my shot.png", hasImage: true)
        check(a == .text("/tmp/my\\ shot.png /tmp/b.png"), "paths: \(a)")
    }
    test("paste: nothing on the pasteboard sends nothing") {
        check(PasteLogic.decide(filePaths: [], string: nil, hasImage: false) == .nothing, "empty")
        check(PasteLogic.decide(filePaths: [], string: "", hasImage: false) == .nothing, "empty string")
    }
    test("paste: image type identifiers (screenshot clipboard = png + tiff)") {
        check(PasteLogic.hasImage(types: ["public.png", "public.tiff"]), "png")
        check(PasteLogic.hasImage(types: ["public.jpeg"]), "jpeg")
        check(!PasteLogic.hasImage(types: ["public.utf8-plain-text", "public.file-url"]), "text and url only")
    }
}
