// Faz 0 S3 (PRD docs/prd-native-rewrite.md): input method + accessibility on a minimal terminal
// view and on the editor baseline (TextKit 2 NSTextView).
//
// The terminal view is an NSTextInputClient that turns committed text into bytes for a real PTY
// (`/bin/cat`, IUTF8 set) and exposes the transcript to VoiceOver as an AXTextArea.
// `--selftest` types a ≥200-character script through the real keyboard layout: each character is
// mapped to (key code, modifiers) with UCKeyTranslate on the current input source, turned into a
// CGEvent (which the system translates with that layout) and fed through the window, so
// NSTextInputContext and the input methods see the same events a keyboard produces.

import AppKit
import Carbon.HIToolbox
import Darwin

// MARK: - PTY running /bin/cat

final class Pty {
    let master: Int32
    let pid: pid_t
    private var onOutput: (String) -> Void
    private var source: DispatchSourceRead?

    init?(onOutput: @escaping (String) -> Void) {
        self.onOutput = onOutput
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0, let name = ptsname(m) else { return nil }
        let slavePath = String(cString: name)
        // The first open of the slave resets the tty settings, so open it here, set echo off
        // (the PTY then returns only what cat prints) and IUTF8 (erase removes a whole UTF-8
        // character: ş is two bytes), and hand this descriptor to the child.
        let slave = open(slavePath, O_RDWR | O_NOCTTY)
        guard slave >= 0 else { close(m); return nil }
        defer { close(slave) }
        var t = termios()
        tcgetattr(slave, &t)
        t.c_lflag &= ~tcflag_t(ECHO)
        t.c_iflag |= tcflag_t(IUTF8)
        tcsetattr(slave, TCSANOW, &t)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd in 0...2 { posix_spawn_file_actions_adddup2(&actions, slave, Int32(fd)) }
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/cat"), nil]
        let rc = posix_spawn(&pid, "/bin/cat", &actions, &attr, argv, environ)
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        argv.forEach { free($0) }
        guard rc == 0 else { close(m); return nil }
        master = m
        self.pid = pid
        let src = DispatchSource.makeReadSource(fileDescriptor: m, queue: .main)
        src.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(m, &buf, buf.count)
            if n > 0 { self?.onOutput(String(decoding: buf[0..<n], as: UTF8.self)) }
        }
        src.resume()
        source = src
    }

    func send(_ bytes: [UInt8]) {
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBufferPointer { write(master, $0.baseAddress, $0.count) }
            if n <= 0 { return }
            off += n
        }
    }

    deinit { kill(pid, SIGKILL); close(master) }
}

// MARK: - Terminal input view

/// Input side of a terminal: committed text goes to the PTY as UTF-8; marked text (IME preedit,
/// dead keys) is shown but never sent. Text the PTY already received can still be replaced by an
/// input method (press-and-hold accents): the replaced characters are erased with DEL first.
final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    var pty: Pty?
    /// Characters sent since the last line break, so a replacementRange can be honoured.
    private var line: [Character] = []
    private var marked = NSAttributedString()
    private(set) var transcript = ""
    /// Every input-client call, for diagnosing input methods.
    var calls: [String: Int] = [:]
    var stats = (inserts: 0, markedUpdates: 0, replacements: 0, commands: [String](), firstRectCalls: 0)

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// Switching to an input method (e.g. Japanese) from the menu bar while this view is focused
    /// does not attach it until the context is activated again (S3: Kotoeri saw no key events
    /// until focus moved away and back). NSTextView handles this; a custom view must re-activate.
    private var keyboardObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if keyboardObserver == nil, ProcessInfo.processInfo.environment["NO_REACTIVATE"] == nil {
            keyboardObserver = NotificationCenter.default.addObserver(
                forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.firstResponder === self, let ctx = self.inputContext else { return }
                    self.calls["reactivate", default: 0] += 1
                    // Not inside the notification: the input source switch is still in progress and
                    // re-activating synchronously deadlocked with the TSM UI server.
                    DispatchQueue.main.async {
                        guard self.window?.firstResponder === self else { return }
                        ctx.deactivate()
                        ctx.activate()
                    }
                }
            }
        }
    }

    func appendOutput(_ s: String) {
        transcript += s
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    private func send(_ s: String) { pty?.send(Array(s.utf8)) }

    override func keyDown(with event: NSEvent) {
        calls[#function, default: 0] += 1
        // Control combinations map straight to C0 codes; everything else goes through the input
        // context so layouts, dead keys, press-and-hold and IMEs all work.
        if event.modifierFlags.contains(.control), let c = event.charactersIgnoringModifiers?.unicodeScalars.first,
           c.isASCII, let ascii = UInt8(exactly: c.value), (0x40...0x7f).contains(ascii | 0x20) || ascii == 0x20 {
            pty?.send([ascii & 0x1f])
            return
        }
        if ProcessInfo.processInfo.environment["KEY_PATH"] == "interpret" {
            interpretKeyEvents([event])
        } else {
            let handled = inputContext?.handleEvent(event) ?? false
            calls["handleEvent=\(handled)", default: 0] += 1
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        calls[#function, default: 0] += 1
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        stats.inserts += 1
        // Committed text replaces the marked text, or (press-and-hold) characters already sent.
        if marked.length == 0, replacementRange.location != NSNotFound, replacementRange.length > 0,
           replacementRange.location + replacementRange.length == line.count {
            stats.replacements += 1
            pty?.send(Array(repeating: 0x7f, count: replacementRange.length))
            line.removeLast(replacementRange.length)
        }
        marked = NSAttributedString()
        line.append(contentsOf: text)
        send(text)
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        calls[#function, default: 0] += 1
        stats.commands.append(NSStringFromSelector(selector))
        switch selector {
        case #selector(insertNewline(_:)):
            line.removeAll()
            send("\r")
        case #selector(deleteBackward(_:)):
            if !line.isEmpty { line.removeLast() }
            pty?.send([0x7f])
        case #selector(insertTab(_:)): send("\t")
        case #selector(cancelOperation(_:)): send("\u{1b}")
        case #selector(moveLeft(_:)): send("\u{1b}[D")
        case #selector(moveRight(_:)): send("\u{1b}[C")
        case #selector(moveUp(_:)): send("\u{1b}[A")
        case #selector(moveDown(_:)): send("\u{1b}[B")
        default: break
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        calls[#function, default: 0] += 1
        stats.markedUpdates += 1
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        needsDisplay = true
    }

    func unmarkText() {
        calls[#function, default: 0] += 1
        let text = marked.string
        marked = NSAttributedString()
        if !text.isEmpty { insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    func selectedRange() -> NSRange { NSRange(location: line.count + marked.length, length: 0) }
    func markedRange() -> NSRange {
        calls[#function, default: 0] += 1
        return marked.length > 0 ? NSRange(location: line.count, length: marked.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { marked.length > 0 }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        calls[#function, default: 0] += 1
        let all = String(line) + marked.string
        let ns = all as NSString
        let r = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        actualRange?.pointee = r
        return NSAttributedString(string: ns.substring(with: r))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        switch ProcessInfo.processInfo.environment["IME_ATTRS"] {
        case "none": return []
        case "clause": return [.markedClauseSegment, .underlineStyle, .underlineColor]
        default: return [.underlineStyle]
        }
    }

    /// Where the input method puts its candidate window: just after the caret.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        calls[#function, default: 0] += 1
        stats.firstRectCalls += 1
        let caret = NSRect(x: 8 + CGFloat(range.location) * 8, y: bounds.height - 24, width: 1, height: 18)
        return window?.convertToScreen(convert(caret, to: nil)) ?? .zero
    }

    // Optional NSTextInputClient methods NSTextView provides; input methods may query them.
    func attributedString() -> NSAttributedString {
        calls[#function, default: 0] += 1
        return NSAttributedString(string: String(line) + marked.string)
    }

    func windowLevel() -> Int {
        calls[#function, default: 0] += 1
        return window?.level.rawValue ?? 0
    }

    func documentVisibleRect() -> NSRect {
        calls[#function, default: 0] += 1
        return window?.convertToScreen(convert(bounds, to: nil)) ?? .zero
    }

    func unionRectInVisibleSelectedRange() -> NSRect {
        calls[#function, default: 0] += 1
        return firstRect(forCharacterRange: selectedRange(), actualRange: nil)
    }

    func baselineDeltaForCharacter(at anIndex: Int) -> CGFloat {
        calls[#function, default: 0] += 1
        return 4
    }

    func characterIndex(for point: NSPoint) -> Int { line.count }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).suffix(12)
        (lines.joined(separator: "\n") as NSString).draw(at: NSPoint(x: 8, y: 8), withAttributes: [.font: font, .foregroundColor: NSColor.textColor])
        let input = NSMutableAttributedString(string: "> " + String(line), attributes: [.font: font, .foregroundColor: NSColor.textColor])
        input.append(NSAttributedString(string: marked.string, attributes: [.font: font, .foregroundColor: NSColor.systemBlue, .underlineStyle: NSUnderlineStyle.single.rawValue]))
        input.draw(at: NSPoint(x: 8, y: bounds.height - 24))
    }

    // MARK: Accessibility: VoiceOver reads the transcript as a text area

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityValue() -> Any? { transcript }
    override func accessibilityNumberOfCharacters() -> Int { (transcript as NSString).length }
    override func accessibilitySelectedTextRange() -> NSRange { NSRange(location: (transcript as NSString).length, length: 0) }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: (transcript as NSString).length) }
    override func accessibilityString(for range: NSRange) -> String? {
        let ns = transcript as NSString
        return ns.substring(with: NSIntersectionRange(range, NSRange(location: 0, length: ns.length)))
    }
    override func accessibilityLine(for index: Int) -> Int {
        let ns = transcript as NSString
        let upto = ns.substring(to: min(index, ns.length))
        return upto.filter { $0 == "\n" }.count
    }
    override func accessibilityRange(forLine lineNumber: Int) -> NSRange {
        let ns = transcript as NSString
        var start = 0, current = 0
        while current < lineNumber {
            let r = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            if r.location == NSNotFound { return NSRange(location: ns.length, length: 0) }
            start = r.location + 1
            current += 1
        }
        let end = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start)).location
        return NSRange(location: start, length: (end == NSNotFound ? ns.length : end) - start)
    }
}

// MARK: - File tree (VoiceOver navigation check)

final class Tree: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let root: [String: [String]] = ["src": ["App.tsx", "main.tsx", "Terminal.tsx"], "docs": ["SYSTEM.md", "prd.md"]]
    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? root.count : (root[item as! String]?.count ?? 0)
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        item == nil ? root.keys.sorted()[index] : root[item as! String]![index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { root[item as! String] != nil }
    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: item as! String)
        cell.addSubview(text)
        cell.textField = text
        text.frame = NSRect(x: 2, y: 0, width: 200, height: 17)
        return cell
    }
}

// MARK: - Self test

/// Reverse keyboard map for the current layout: character -> (key code, modifier flags).
struct Keymap {
    struct Stroke { let keyCode: CGKeyCode; let flags: CGEventFlags }
    var strokes: [Character: Stroke] = [:]
    var deadKeys: [(Stroke, String)] = []
    let layoutName: String
    private let layoutData: Data

    /// What the layout produces for dead key `dead` followed by the key for `base`.
    func compose(_ dead: Stroke, _ base: Character) -> String? {
        guard let b = strokes[base] else { return nil }
        func mod(_ f: CGEventFlags) -> UInt32 {
            (f.contains(.maskShift) ? UInt32(shiftKey >> 8) : 0) | (f.contains(.maskAlternate) ? UInt32(optionKey >> 8) : 0)
        }
        return layoutData.withUnsafeBytes { raw -> String? in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            var state: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            UCKeyTranslate(layout, dead.keyCode, UInt16(kUCKeyActionDown), mod(dead.flags), UInt32(LMGetKbdType()), 0, &state, 4, &len, &chars)
            UCKeyTranslate(layout, b.keyCode, UInt16(kUCKeyActionDown), mod(b.flags), UInt32(LMGetKbdType()), 0, &state, 4, &len, &chars)
            return len > 0 ? String(utf16CodeUnits: chars, count: len) : nil
        }
    }

    init() {
        let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        layoutName = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(source, kTISPropertyLocalizedName)).takeUnretainedValue() as String
        let data = Unmanaged<CFData>.fromOpaque(TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)).takeUnretainedValue() as Data
        layoutData = data
        let mods: [(UInt32, CGEventFlags)] = [
            (0, []), (UInt32(shiftKey >> 8), .maskShift), (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]
        data.withUnsafeBytes { raw in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            for (mod, flags) in mods {
                for code in 0..<UInt16(128) {
                    var dead: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var len = 0
                    UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mod, UInt32(LMGetKbdType()), 0, &dead, 4, &len, &chars)
                    let stroke = Stroke(keyCode: CGKeyCode(code), flags: flags)
                    if dead != 0 {
                        // Dead key: translate it once more with no key to see what it would show.
                        var s2 = dead
                        UCKeyTranslate(layout, 49, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()), 0, &s2, 4, &len, &chars)
                        deadKeys.append((stroke, String(utf16CodeUnits: chars, count: len)))
                    } else if len == 1, let c = String(utf16CodeUnits: chars, count: 1).first, strokes[c] == nil, !c.isWhitespace || c == " " {
                        strokes[c] = stroke
                    }
                }
            }
        }
    }
}

@MainActor
final class SelfTest {
    let window: NSWindow
    let terminal: TerminalView
    let editor: NSTextView
    let keymap = Keymap()
    var report: [String] = []
    var failures = 0

    init(window: NSWindow, terminal: TerminalView, editor: NSTextView) {
        self.window = window
        self.terminal = terminal
        self.editor = editor
    }

    func check(_ name: String, _ ok: Bool, _ detail: String) {
        if !ok { failures += 1 }
        report.append("\(ok ? "PASS" : "FAIL") \(name): \(detail)")
    }

    /// Feeds one key through the window like the keyboard would.
    func post(_ code: CGKeyCode, _ flags: CGEventFlags, repeatDown: Bool = false, down: Bool = true, up: Bool = true) {
        let src = CGEventSource(stateID: .hidSystemState)
        if down, let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true) {
            e.flags = flags
            if repeatDown { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            if let ns = NSEvent(cgEvent: e) { deliver(ns) }
        }
        if up, let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
            e.flags = flags
            if let ns = NSEvent(cgEvent: e) { deliver(ns) }
        }
    }

    /// The window is key only when the app is active (`--activate`); otherwise hand the event to
    /// the first responder with its input context activated, the same chain AppKit uses.
    func deliver(_ event: NSEvent) {
        if window.isKeyWindow { window.sendEvent(event); return }
        guard let responder = window.firstResponder else { return }
        if let view = responder as? NSView, let ctx = view.inputContext, NSTextInputContext.current !== ctx { ctx.activate() }
        if event.type == .keyDown { responder.keyDown(with: event) } else { responder.keyUp(with: event) }
    }

    /// Per-keystroke processing time (key down + up through the input chain), in microseconds.
    var keyUs: [Double] = []

    func type(_ text: String, capsLock: Bool = false) -> [Character] {
        var missing: [Character] = []
        for c in text {
            let target: Character = capsLock ? Character(String(c).lowercased(with: Locale(identifier: "tr_TR"))) : c
            guard let s = keymap.strokes[target] else { missing.append(c); continue }
            let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            post(s.keyCode, capsLock ? s.flags.union(.maskAlphaShift) : s.flags)
            keyUs.append(Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t) / 1000)
        }
        return missing
    }

    /// Holds a key with autorepeat for ~0.6 s like a finger would, then presses "1".
    func holdAndPick(_ c: Character) async {
        guard let k = keymap.strokes[c], let one = keymap.strokes["1"] else { return }
        post(k.keyCode, k.flags, down: true, up: false)
        for _ in 0..<12 {
            await pump(0.05)
            post(k.keyCode, k.flags, repeatDown: true, down: true, up: false)
        }
        post(k.keyCode, k.flags, down: false, up: true)
        await pump(0.4)
        post(one.keyCode, one.flags)
        await pump(0.3)
    }

    func pump(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    /// The last complete line cat printed. Split on "\r\n" as a string: Swift treats "\r\n"
    /// as one Character, so splitting on "\n" never matches.
    func lastLine() -> String {
        let lines = terminal.transcript.components(separatedBy: "\r\n")
        return lines.count >= 2 ? lines[lines.count - 2] : ""
    }

    func run() async {
        report.append("app active \(NSApp.isActive), window key \(window.isKeyWindow), bundle \(Bundle.main.bundleIdentifier ?? "none")")
        report.append("layout: \(keymap.layoutName), \(keymap.strokes.count) direct characters, \(keymap.deadKeys.count) dead keys")
        let script = "Pijamalı hasta yağız şoföre çabucak güvendi. PİJAMALI HASTA YAĞIZ ŞOFÖRE ÇABUCAK GÜVENDİ. "
            + "Iğdır'da ılık süt içtik; İzmir'e gittik! 0123456789 @€{}[]\\|~#$%^&*()_+-=<>?/,.:\"' "
            + "Öğrenciler çığlık attı: ŞİMDİ! ğüşıöç ĞÜŞİÖÇ"
        report.append("script: \(script.count) characters")

        // 1. Terminal: the whole script, then Return; cat echoes the line back.
        window.makeFirstResponder(terminal)
        keyUs = []
        let missing = type(script)
        report.append(latency("terminal per key"))
        post(CGKeyCode(kVK_Return), [])
        await pump(0.5)
        let typed = String(script.filter { !missing.contains($0) })
        let got = lastLine()
        check("terminal 200-char script", got == typed, got == typed ? "\(got.count) chars, 0 dropped / duplicated" : diff(typed, got))
        if !missing.isEmpty { report.append("  not on this layout (skipped): \(String(missing))") }

        // 2. Caps Lock: i -> İ and ı -> I on Turkish layouts.
        _ = type("iıiı", capsLock: true)
        post(CGKeyCode(kVK_Return), [])
        await pump(0.3)
        check("terminal caps lock İ/I", lastLine() == "İIİI", "got \"\(lastLine())\"")

        // 3. Backspace over a two-byte character: the PTY must erase the whole ş (IUTF8).
        _ = type("aş")
        post(CGKeyCode(kVK_Delete), [])
        post(CGKeyCode(kVK_Return), [])
        await pump(0.3)
        check("terminal backspace over ş", lastLine() == "a", "got \"\(lastLine())\"")

        // 4. Dead keys go through marked text; the expected result comes from the layout.
        for (dead, accent) in keymap.deadKeys {
            guard let expected = keymap.compose(dead, "e") else { continue }
            let before = terminal.stats.markedUpdates
            post(dead.keyCode, dead.flags)
            _ = type("e")
            post(CGKeyCode(kVK_Return), [])
            await pump(0.3)
            check("terminal dead key \(accent) + e", terminal.stats.markedUpdates > before && lastLine() == expected,
                  "marked updates \(terminal.stats.markedUpdates - before), want \"\(expected)\" got \"\(lastLine())\"")
        }

        // 5. Press-and-hold accent menu: hold u, pick the first accent with "1".
        let before = terminal.stats.replacements
        await holdAndPick("u")
        post(CGKeyCode(kVK_Return), [])
        await pump(0.3)
        let held = lastLine()
        check("terminal press-and-hold u -> accent", held.count == 1 && held != "u" && terminal.stats.replacements > before,
              "got \"\(held)\", replacements \(terminal.stats.replacements - before)")

        // 6. Editor baseline (TextKit 2 NSTextView): same script, same events.
        window.makeFirstResponder(editor)
        editor.string = ""
        keyUs = []
        _ = type(script)
        report.append(latency("editor per key"))
        await pump(0.3)
        check("editor 200-char script", editor.string == typed, editor.string == typed ? "\(typed.count) chars" : diff(typed, editor.string))
        editor.string = ""
        _ = type("iıiı", capsLock: true)
        check("editor caps lock İ/I", editor.string == "İIİI", "got \"\(editor.string)\"")

        editor.string = ""
        await holdAndPick("u")
        check("editor press-and-hold u -> accent", editor.string.count == 1 && editor.string != "u", "got \"\(editor.string)\"")

        if CommandLine.arguments.contains("--ime-ja") { await runJapanese() }

        // 7. Accessibility tree as VoiceOver sees it.
        check("a11y terminal", terminal.accessibilityRole() == .textArea && (terminal.accessibilityValue() as? String)?.contains("PİJAMALI") == true,
              "role \(terminal.accessibilityRole()?.rawValue ?? "-"), \(terminal.accessibilityNumberOfCharacters()) chars, line 0 = \"\(terminal.accessibilityString(for: terminal.accessibilityRange(forLine: 0)) ?? "")\"")
        report.append("transcript tail: " + String(terminal.transcript.suffix(160)).debugDescription)
        report.append("stats terminal: inserts \(terminal.stats.inserts), marked \(terminal.stats.markedUpdates), replacements \(terminal.stats.replacements)")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        report.append("peak RSS \(usage.ru_maxrss / 1_048_576) MB, CPU user \(usage.ru_utime.tv_sec).\(String(format: "%06d", usage.ru_utime.tv_usec)) s")
        report.append(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures))")
    }

    /// Japanese IME (Romaji): "nihongo" -> marked かな -> Space converts -> Return commits 日本語.
    /// Enables the input method for the run and restores its previous state afterwards.
    func runJapanese() async {
        let imID = "com.apple.inputmethod.Kotoeri.RomajiTyping", modeID = imID + ".Japanese"
        func source(_ id: String) -> TISInputSource? {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            return (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first
        }
        func enabled(_ s: TISInputSource) -> Bool {
            Unmanaged<CFBoolean>.fromOpaque(TISGetInputSourceProperty(s, kTISPropertyInputSourceIsEnabled)).takeUnretainedValue() == kCFBooleanTrue
        }
        guard let im = source(imID) else { report.append("SKIP Japanese: input method not installed"); return }
        let wasEnabled = enabled(im)
        if !wasEnabled { TISEnableInputSource(im) }
        // Select Japanese the way a user does (menu bar, system-wide) and put the operator's
        // input source back afterwards.
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        defer {
            TISSelectInputSource(previous)
            if !wasEnabled { TISDisableInputSource(im) }
            let now = Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID)).takeUnretainedValue() as String
            report.append("input source restored: \(now)")
            report.append("Japanese input method restored to \(wasEnabled ? "enabled" : "disabled"): now \(enabled(im) ? "enabled" : "disabled")")
        }
        await pump(2.0) // the input method process starts on first use
        for (name, view) in (ProcessInfo.processInfo.environment["JA_ORDER"] == "editor-first" ? [("editor", editor as NSView), ("terminal", terminal as NSView)] : [("terminal", terminal as NSView), ("editor", editor as NSView)]) {
            window.makeFirstResponder(view)
            if view === editor { editor.string = "" }
            if let mode = source(modeID) { TISSelectInputSource(mode) }
            await pump(1.0)
            let ctx = view.inputContext
            report.append("\(name) context: current=\(NSTextInputContext.current === ctx) allowed=\(ctx?.allowedInputSourceLocales ?? []) sources=\(ctx?.keyboardInputSources?.count ?? -1) japaneseAllowed=\(ctx?.keyboardInputSources?.contains(modeID) ?? false) client=\(Swift.type(of: ctx?.client))")
            report.append("\(name) input source: \(view.inputContext?.selectedKeyboardInputSource ?? "nil")")
            let before = (terminal.stats.markedUpdates, terminal.stats.firstRectCalls)
            terminal.calls = [:]
            // Kotoeri reads key codes through its ASCII layout (ABC), not Turkish Q: "i" is
            // where Turkish Q has a quote, so use the ANSI positions.
            for code in [kVK_ANSI_N, kVK_ANSI_I, kVK_ANSI_H, kVK_ANSI_O, kVK_ANSI_N, kVK_ANSI_G, kVK_ANSI_O] {
                post(CGKeyCode(code), [])
                await pump(0.08)
            }
            await pump(0.3)
            report.append("\(name) marked before Space: \"\(view === terminal ? (terminal.attributedSubstring(forProposedRange: terminal.markedRange(), actualRange: nil)?.string ?? "") : (editor.attributedSubstring(forProposedRange: editor.markedRange(), actualRange: nil)?.string ?? ""))\"")
            let shown = view === terminal ? (terminal.attributedSubstring(forProposedRange: terminal.markedRange(), actualRange: nil)?.string ?? "") : (editor.attributedSubstring(forProposedRange: editor.markedRange(), actualRange: nil)?.string ?? "")
            post(CGKeyCode(kVK_Return), [])
            await pump(0.3)
            if view === terminal {
                post(CGKeyCode(kVK_Return), [])
                await pump(0.4)
                report.append("terminal client calls: " + terminal.calls.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                check("terminal Japanese IME nihongo -> 日本語", lastLine() == "日本語" && lastLine() == shown && terminal.stats.markedUpdates > before.0,
                      "got \"\(lastLine())\", marked updates \(terminal.stats.markedUpdates - before.0), firstRect calls \(terminal.stats.firstRectCalls - before.1)")
            } else {
                check("editor Japanese IME nihongo -> 日本語", editor.string == "日本語" && editor.string == shown, "got \"\(editor.string)\"")
            }
        }
    }

    func latency(_ name: String) -> String {
        let v = keyUs.sorted()
        func q(_ p: Double) -> String { String(format: "%.0f", v[min(v.count - 1, Int(Double(v.count) * p))]) }
        return "\(name): n=\(v.count) us p50=\(q(0.5)) p95=\(q(0.95)) p99=\(q(0.99)) max=\(q(1))"
    }

    func diff(_ want: String, _ got: String) -> String {
        let w = Array(want), g = Array(got)
        let i = (0..<min(w.count, g.count)).first { w[$0] != g[$0] } ?? min(w.count, g.count)
        return "want \(w.count) got \(g.count) chars; first difference at \(i): want \"\(String(w[i..<min(w.count, i + 12)]))\" got \"\(String(g[i..<min(g.count, i + 12)]))\""
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let terminal = TerminalView()
    let tree = Tree()
    var editor: NSTextView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 520),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "IME Lab"
        terminal.pty = Pty { [weak terminal] s in terminal?.appendOutput(s) }
        terminal.frame = NSRect(x: 0, y: 0, width: 420, height: 520)

        editor = NSTextView(usingTextLayoutManager: true)
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setAccessibilityLabel("Editor")
        let editorScroll = NSScrollView()
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editor.autoresizingMask = [.width]

        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = tree
        outline.delegate = tree
        outline.setAccessibilityLabel("Files")
        let treeScroll = NSScrollView()
        treeScroll.documentView = outline

        let split = NSSplitView()
        split.isVertical = true
        [treeScroll, terminal, editorScroll].forEach(split.addArrangedSubview)
        window.contentView = split
        split.setPosition(180, ofDividerAt: 0)
        split.setPosition(560, ofDividerAt: 1)
        outline.expandItem(nil, expandChildren: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(terminal)
        if let seed = CommandLine.arguments.drop(while: { $0 != "--seed" }).dropFirst().first {
            terminal.appendOutput(seed.replacingOccurrences(of: "\\n", with: "\r\n"))
        }

        if CommandLine.arguments.contains("--selftest") {
            // Only with --activate: bringing the window forward would catch the operator's typing.
            if CommandLine.arguments.contains("--activate") { NSApp.activate() }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                let test = SelfTest(window: window, terminal: terminal, editor: editor)
                let start = Date()
                await test.run()
                test.report.append(String(format: "elapsed %.2f s", Date().timeIntervalSince(start)))
                let out = test.report.joined(separator: "\n")
                print(out)
                if let path = CommandLine.arguments.drop(while: { $0 != "--out" }).dropFirst().first {
                    try? out.write(toFile: path, atomically: true, encoding: .utf8)
                }
                if !CommandLine.arguments.contains("--keep-open") { NSApp.terminate(nil) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
