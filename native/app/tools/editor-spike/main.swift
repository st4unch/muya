// ENGINE SPIKE (docs/prd-native-editor.md ADR): editable NSTextView, TextKit 1 vs 2, + the windowed highlighter. Its typing numbers
// do not model checkpoint shifting or the real view; the numbers that gate the product are verify-editor.sh AC9. Run: measure-editor.sh
// Engine spike: an EDITABLE NSTextView (TextKit 1 manual stack, or TextKit 2 default) + windowed highlighter.
// usage: spike <file> <tk1|tk2> [hl]   prints: open_ms first_paint_ms cp_ms hl_ms type_ms rss_mb
import AppKit
import Foundation

func rssMB() -> Int {
    var info = mach_task_basic_info(); var cnt = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4)
    let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: 1) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &cnt) } }
    return r == KERN_SUCCESS ? Int(info.resident_size / 1_048_576) : -1
}
func now() -> Double { CFAbsoluteTimeGetCurrent() * 1000 }

let args = CommandLine.arguments
let path = args[1], mode = args[2], hl = args.count > 3
let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
scroll.hasVerticalScroller = true
var tv: NSTextView
var lm: NSLayoutManager? = nil
if mode == "tk1" {
    let storage = NSTextStorage(); let l = NSLayoutManager(); storage.addLayoutManager(l)
    l.allowsNonContiguousLayout = true
    let c = NSTextContainer(size: NSSize(width: 900, height: CGFloat.greatestFiniteMagnitude)); c.widthTracksTextView = true
    l.addTextContainer(c)
    tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), textContainer: c); lm = l
} else { tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 700)) }
tv.isEditable = true; tv.allowsUndo = true; tv.isRichText = false
tv.autoresizingMask = [.width]; tv.isVerticallyResizable = true
tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
tv.isAutomaticQuoteSubstitutionEnabled = false; tv.isAutomaticDashSubstitutionEnabled = false; tv.isAutomaticSpellingCorrectionEnabled = false
scroll.documentView = tv; win.contentView = scroll; win.makeKeyAndOrderFront(nil)
let lang = SyntaxLanguage.detect(path: path)

let t0 = now()
let data = FileManager.default.contents(atPath: path)!
let text = String(decoding: data, as: UTF8.self)
let tRead = now()
tv.textStorage!.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
tv.textStorage!.addAttribute(.font, value: tv.font!, range: NSRange(location: 0, length: tv.textStorage!.length))
tv.textStorage!.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: tv.textStorage!.length))
tv.setSelectedRange(NSRange(location: 0, length: 0))
let tSet = now()
scroll.layoutSubtreeIfNeeded(); tv.display(); win.displayIfNeeded()
let tPaint = now()

// whole-file checkpoint pass
var tCp = 0.0
var cp = Checkpoints()
func withBuf<T>(_ body: (UnsafeBufferPointer<UInt16>) -> T) -> T {
    let s = tv.textStorage!.string as NSString
    let n = s.length
    let p = UnsafeMutablePointer<UInt16>.allocate(capacity: n); defer { p.deallocate() }
    s.getCharacters(p, range: NSRange(location: 0, length: n))
    return body(UnsafeBufferPointer(start: p, count: n))
}
if hl {
    let c0 = now()
    cp = withBuf { Checkpoints.build($0, language: lang) }
    tCp = now() - c0
}
// highlight a window around the visible area (mid-document too)
func highlight(window: NSRange) -> Double {
    let h0 = now()
    let s = tv.textStorage!.string as NSString
    let r = s.lineRange(for: window)
    if hl && ProcessInfo.processInfo.environment["PROF"] != nil { FileHandle.standardError.write("lineRange \(now()-h0)\n".data(using: .utf8)!) }
    let n = r.length
    let p = UnsafeMutablePointer<UInt16>.allocate(capacity: n); defer { p.deallocate() }
    s.getCharacters(p, range: r)
    let startState = cp.nearest(before: r.location)
    // Start from the checkpoint when it is before the window: scan [checkpoint, window) state-only, then emit.
    var state = 0
    if startState.offset < r.location {
        let m = r.location - startState.offset
        let q = UnsafeMutablePointer<UInt16>.allocate(capacity: m); defer { q.deallocate() }
        s.getCharacters(q, range: NSRange(location: startState.offset, length: m))
        state = SyntaxScanner.scan(UnsafeBufferPointer(start: q, count: m), from: 0, to: m, language: lang, state: startState.state, emit: nil)
    }
    let hp = now()
    let fg = [NSColor.systemBlue, NSColor.systemGreen, NSColor.systemOrange, NSColor.systemPurple]
    let tr0 = now(); if false { lm?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: r) }; if ProcessInfo.processInfo.environment["PROF"] != nil { FileHandle.standardError.write("remove \(now()-tr0)\n".data(using: .utf8)!) }
    let ts = tv.textStorage!; if true { ts.beginEditing() }
    SyntaxScanner.scan(UnsafeBufferPointer(start: p, count: n), from: 0, to: n, language: lang, state: state) { loc, len, kind in
        if true { ts.addAttribute(.foregroundColor, value: fg[Int(kind.rawValue) % 4], range: NSRange(location: r.location + loc, length: len)) } else { lm?.addTemporaryAttribute(.foregroundColor, value: fg[Int(kind.rawValue) % 4], forCharacterRange: NSRange(location: r.location + loc, length: len)) }
    }
    if true { ts.endEditing() }
    if ProcessInfo.processInfo.environment["PROF"] != nil { FileHandle.standardError.write("scan+attr \(now()-hp)\n".data(using: .utf8)!) }
    return now() - h0
}
var tHl = 0.0
var tHlMid = 0.0
func visibleChars() -> NSRange {
    let v = tv.visibleRect
    let a = tv.characterIndexForInsertion(at: NSPoint(x: 5, y: v.minY + 2))
    let b = tv.characterIndexForInsertion(at: NSPoint(x: 5, y: v.maxY - 2))
    return NSRange(location: a, length: max(0, b - a))
}
if hl {
    let cr = visibleChars()
    tHl = highlight(window: NSRange(location: cr.location, length: min(cr.length * 3, (tv.textStorage!.length - cr.location))))
    let mid = tv.textStorage!.length / 2
    tHlMid = highlight(window: NSRange(location: mid, length: min(20000, tv.textStorage!.length - mid)))
}
// scrolling: jump to the end, to the middle, back to the top; time layout + paint + highlight of the new window
var tScroll: [Double] = []
for frac in [1.0, 0.5, 0.0, 0.73] {
    let a = now()
    let y = max(0, (tv.frame.height - scroll.contentView.bounds.height) * frac)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
    win.displayIfNeeded()
    if hl { let cr = visibleChars(); _ = highlight(window: NSRange(location: cr.location, length: min(cr.length * 3, tv.textStorage!.length - cr.location))) ; win.displayIfNeeded() }
    tScroll.append(now() - a)
}
// typing latency: insert a char in the middle visible line, force layout+display, re-highlight the edited line
var lat: [Double] = []
let mid = min(tv.textStorage!.length / 2, tv.textStorage!.length - 1)
if mode == "tk1" { tv.scrollRangeToVisible(NSRange(location: mid, length: 0)) } else { tv.scrollRangeToVisible(NSRange(location: mid, length: 0)) }
scroll.layoutSubtreeIfNeeded(); win.displayIfNeeded()
tv.setSelectedRange(NSRange(location: mid, length: 0))
for k in 0 ..< 40 {
    let a = now()
    tv.insertText("x", replacementRange: tv.selectedRange())
    if hl { _ = highlight(window: NSRange(location: max(0, tv.selectedRange().location - 200), length: 400)) }
    win.displayIfNeeded()
    lat.append(now() - a)
    _ = k
}
lat.sort()
let tType = lat[lat.count / 2], tTypeMax = lat.last!
print(String(format: "%@ %@ size=%.1fMB lang=%@ | read=%.0f set=%.0f paint=%.0f (open=%.0f) cp=%.0f hlVis=%.1f hlMid=%.1f | scroll end/mid/top/73%% = %.0f/%.0f/%.0f/%.0f | type med=%.1f max=%.1f | rss=%dMB",
             (path as NSString).lastPathComponent, mode, Double(data.count) / 1_048_576, lang.rawValue, tRead - t0, tSet - tRead, tPaint - tSet, tPaint - t0, tCp, tHl, tHlMid, tScroll[0], tScroll[1], tScroll[2], tScroll[3], tType, tTypeMax, rssMB()))
