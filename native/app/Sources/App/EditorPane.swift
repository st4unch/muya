// The editor view (src/components/FileEditor.tsx, natively): an NSTextView on an explicit TextKit 1 stack, a line-number
// ruler, a minimap, a windowed syntax highlighter, a unified diff against HEAD, find / replace through the system find
// bar, go-to-line, and the guards (dirty, changed on disk, conflict on save). Everything decidable lives in
// Logic/EditorLogic.swift and Logic/SyntaxHighlight.swift (unit-tested); this file only shows it.

import AppKit
import CoreServices

// MARK: Monaco palettes (classic runs Monaco's built-in "vs" / "vs-dark" themes)

enum MonacoPalette {
    private static func dyn(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light) }
    }
    static let background = dyn(0x1E1E1E, 0xFFFFFE)
    static let foreground = dyn(0xD4D4D4, 0x000000)
    static let selection = dyn(0x264F78, 0xADD6FF)
    static let gutter = dyn(0x858585, 0x237893)
    static let gutterBg = dyn(0x1E1E1E, 0xFFFFFE)
    static let added = NSColor(srgbRed: 0.61, green: 0.73, blue: 0.33, alpha: 0.22)
    static let removed = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.18)
    private static let table: [TokenKind: NSColor] = [
        .comment: dyn(0x6A9955, 0x008000), .string: dyn(0xCE9178, 0xA31515), .number: dyn(0xB5CEA8, 0x098658),
        .keyword: dyn(0x569CD6, 0x0000FF), .type: dyn(0x4EC9B0, 0x267F99), .key: dyn(0x9CDCFE, 0x0451A5),
        .tag: dyn(0x569CD6, 0x800000), .attribute: dyn(0x9CDCFE, 0xE50000), .heading: dyn(0x569CD6, 0x800000),
        .bracket1: dyn(0xFFD700, 0x0431FA), .bracket2: dyn(0xDA70D6, 0x319331), .bracket3: dyn(0x179FFF, 0x7B3814),
        .constant: dyn(0x569CD6, 0x0000FF), .variable: dyn(0x9CDCFE, 0x001080), .punctuation: dyn(0xD4D4D4, 0x000000),
    ]
    static func color(_ k: TokenKind) -> NSColor { table[k] ?? foreground }
}

// MARK: Text view

final class EditorTextView: NSTextView {
    var onSave: (() -> Void)?
    var onGoToLine: (() -> Void)?

    private func finder(_ a: NSTextFinder.Action) {
        let item = NSMenuItem(); item.tag = a.rawValue
        performTextFinderAction(item)
    }

    /// Menu key equivalents are offered to the window's views before the main menu: while the editor has the keyboard,
    /// ⌘S saves (View > Sessions owns ⌘S elsewhere) and ⌘F / ⌥⌘F / ⌘G drive the find bar (⌘G is Grid in the menu).
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: e) }
        let m = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if m == .command, key == "s" { onSave?(); return true }
        if m == .command, key == "f" { finder(.showFindInterface); return true }
        if m == [.command, .option], key == "f" || e.keyCode == 3 { finder(.showReplaceInterface); return true }
        if m == .command, key == "g" { finder(.nextMatch); return true }
        if m == [.command, .shift], key == "g" { finder(.previousMatch); return true }
        if m == .command, key == "e" { finder(.setSearchString); return true }
        if m == .control, key == "g" { onGoToLine?(); return true }
        if m == .command, key == "d" { session?.addNextOccurrence(); return true }                 // Monaco: add selection to next find match
        if m == .command, key == "a" { selectAll(nil); return true }
        if m == [.command, .option], key == "[" { session?.foldAtCaret(true); return true }       // Monaco: fold / unfold
        if m == [.command, .option], key == "]" { session?.foldAtCaret(false); return true }
        return super.performKeyEquivalent(with: e)
    }

    weak var session: EditorSession?

    // Multi-cursor editing. NSTextView keeps several selection ranges but types into the first only, so with more than one
    // range typing, Backspace and Return are applied to every range here.
    private var multi: Bool { selectedRanges.count > 1 || !(session?.extraCarets.isEmpty ?? true) }

    private func applyToAll(_ make: (NSRange) -> (NSRange, String)) {
        let extra = (session?.extraCarets ?? []).map { NSRange(location: $0, length: 0) }
        let edits = (selectedRanges.map(\.rangeValue) + extra).map(make).sorted { $0.0.location < $1.0.location }
        guard let st = textStorage else { return }
        // AppKit refuses a list that holds several empty ranges, so its answer only counts for non-empty ones.
        let allowed = shouldChangeText(inRanges: edits.map { NSValue(range: $0.0) }, replacementStrings: edits.map { $0.1 })
        if !allowed, edits.contains(where: { $0.0.length > 0 }) { return }
        var shift = 0
        var sel: [NSRange] = []
        session?.inMultiEdit = true
        st.beginEditing()
        for (r, s) in edits {
            let loc = r.location + shift
            st.replaceCharacters(in: NSRange(location: loc, length: r.length), with: s)
            let n = (s as NSString).length
            sel.append(NSRange(location: loc + n, length: 0))
            shift += n - r.length
        }
        st.endEditing()
        // NSTextView keeps only one insertion point: the first stays the real caret, the others are ours.
        if sel.allSatisfy({ $0.length == 0 }) { session?.extraCarets = sel.dropFirst().map(\.location); selectedRanges = [NSValue(range: sel[0])] }
        else { session?.extraCarets = []; selectedRanges = sel.map { NSValue(range: $0) } }
        didChangeText()
        session?.inMultiEdit = false
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if multi, replacementRange.location == NSNotFound, let s = (string as? String) ?? (string as? NSAttributedString)?.string {
            applyToAll { ($0, s) }
        } else { super.insertText(string, replacementRange: replacementRange) }
    }

    override func insertNewline(_ sender: Any?) { if multi { applyToAll { ($0, "\n") } } else { super.insertNewline(sender) } }

    override func deleteBackward(_ sender: Any?) {
        guard multi else { return super.deleteBackward(sender) }
        let ns = string as NSString
        applyToAll { r in
            if r.length > 0 { return (r, "") }
            guard r.location > 0 else { return (r, "") }
            return (ns.rangeOfComposedCharacterSequence(at: r.location - 1), "")
        }
    }

    /// ⌥-click adds a caret (Monaco's default multi-cursor gesture).
    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.option), !e.modifierFlags.contains(.shift) {
            window?.makeFirstResponder(self)
            let idx = characterIndexForInsertion(at: convert(e.locationInWindow, from: nil))
            session?.addCursor(at: idx)
            return
        }
        super.mouseDown(with: e)
    }

    /// NSTextView draws one insertion point; the extra carets of a multi-cursor selection and the "⋯" of folded blocks are ours.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        session?.drawExtras(in: self)
    }
}

// MARK: Line numbers

final class LineNumberRuler: NSRulerView {
    weak var session: EditorSession?
    private let font = ThemeFont.mono(11)

    private var digits: Int { max(3, String(max(session?.totalLinesEstimate ?? 1, 1)).count) }
    override var requiredThickness: CGFloat { CGFloat(digits) * 7.4 + 30 }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = clientView as? NSTextView, let lm = tv.layoutManager, let tc = tv.textContainer, let s = session, let st = tv.textStorage else { return }
        MonacoPalette.gutterBg.setFill(); bounds.fill()
        let ns = st.string as NSString
        guard ns.length > 0 else { draw(1, at: tv.textContainerOrigin.y, in: tv); return }
        let origin = tv.textContainerOrigin
        let g = lm.glyphRange(forBoundingRect: tv.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: tc)
        var line = -1, last = 0, prevStart = 0
        lm.enumerateLineFragments(forGlyphRange: g) { frag, _, _, glyphs, _ in
            let cr = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let isPara = cr.location == 0 || ns.character(at: cr.location - 1) == 0x0A
            guard isPara else { return }
            // A folded block merges several paragraphs into one fragment: count the newlines since the last numbered one.
            if line < 0 { line = s.line(ofOffset: cr.location) } else { line += EditorSession.countNewlines(ns, NSRange(location: prevStart, length: cr.location - prevStart)) }
            prevStart = cr.location
            self.draw(line, at: frag.minY + origin.y, in: tv); last = line
            let y = self.convert(NSPoint(x: 0, y: frag.minY + origin.y), from: tv).y
            if s.isFolded(headerLineStart: cr.location) { self.chevron(open: false, y: y) }
            else if self.hover, Folding.isFoldable(headerLineStart: cr.location, in: ns) { self.chevron(open: true, y: y) }
        }
        if ns.character(at: ns.length - 1) == 0x0A, lm.extraLineFragmentRect != .zero, last > 0 {
            draw(last + 1, at: lm.extraLineFragmentRect.minY + origin.y, in: tv)
        }
    }

    // Fold chevrons: collapsed ones always, expandable ones while the pointer is over the gutter (Monaco's "mouseover").
    var hover = false { didSet { if hover != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    private func chevron(open: Bool, y: CGFloat) {
        let cx = bounds.width - 5, cy = y + 8.5
        let p = NSBezierPath()
        if open { p.move(to: NSPoint(x: cx - 3, y: cy - 1.5)); p.line(to: NSPoint(x: cx, y: cy + 1.5)); p.line(to: NSPoint(x: cx + 3, y: cy - 1.5)) }
        else { p.move(to: NSPoint(x: cx - 1.5, y: cy - 3)); p.line(to: NSPoint(x: cx + 1.5, y: cy)); p.line(to: NSPoint(x: cx - 1.5, y: cy + 3)) }
        p.lineWidth = 1.3; MonacoPalette.gutter.setStroke(); p.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = clientView as? NSTextView, let s = session, let st = tv.textStorage else { return }
        let pt = tv.convert(event.locationInWindow, from: nil)
        let idx = tv.characterIndexForInsertion(at: NSPoint(x: 4, y: pt.y))
        let ns = st.string as NSString
        s.toggleFold(atLineStart: ns.lineRange(for: NSRange(location: min(idx, ns.length), length: 0)).location)
    }

    private func draw(_ n: Int, at y: CGFloat, in tv: NSTextView) {
        let p = convert(NSPoint(x: 0, y: y), from: tv)
        let str = "\(n)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: MonacoPalette.gutter]
        let w = str.size(withAttributes: attrs).width
        str.draw(at: NSPoint(x: bounds.width - w - 10, y: p.y + 1), withAttributes: attrs)
    }
}

// MARK: Minimap

final class MinimapView: NSView {
    weak var session: EditorSession?
    static let width: CGFloat = 76
    private let rowH: CGFloat = 2
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// First line drawn: the window follows the viewport the way Monaco's does (proportional while the file is taller than the map).
    private func geometry() -> (top: Int, rows: Int, total: Int, viewFirst: Int, viewLast: Int)? {
        guard let s = session else { return nil }
        let total = max(s.totalLinesEstimate, 1)
        let rows = max(1, Int(bounds.height / rowH))
        let (vf, vl) = s.visibleLines()
        let maxTop = max(0, total - rows)
        let frac = total > (vl - vf + 1) ? Double(vf - 1) / Double(max(1, total - (vl - vf + 1))) : 0
        return (min(maxTop, Int((Double(maxTop) * frac).rounded())) + 1, rows, total, vf, vl)
    }

    override func draw(_ dirty: NSRect) {
        MonacoPalette.background.setFill(); bounds.fill()
        guard let s = session, let g = geometry() else { return }
        s.drawMinimap(top: g.top, rows: g.rows, rowH: rowH, width: bounds.width)
        let y0 = CGFloat(g.viewFirst - g.top) * rowH, y1 = CGFloat(g.viewLast - g.top + 1) * rowH
        NSColor(white: 0.5, alpha: 0.22).setFill()
        NSRect(x: 0, y: max(0, y0), width: bounds.width, height: max(4, min(bounds.height, y1) - max(0, y0))).fill()
        NSColor(white: 0.5, alpha: 0.25).setFill(); NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
    }

    private func scrollTo(_ e: NSEvent) {
        guard let g = geometry(), let s = session else { return }
        let y = convert(e.locationInWindow, from: nil).y
        s.scrollToLine(g.top + Int(y / rowH), centered: true)
    }
    override func mouseDown(with e: NSEvent) { scrollTo(e) }
    override func mouseDragged(with e: NSEvent) { scrollTo(e) }
}

// MARK: Toolbar button (classic: Wrap / Map / Diff / Save pills)

final class PillButton: NSButton {
    enum Style { case plain, primary, warning }
    var style: Style = .plain { didSet { needsDisplay = true } }
    var on = false { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.4 } }
    override var intrinsicContentSize: NSSize { NSSize(width: max(40, (title as NSString).size(withAttributes: [.font: ThemeFont.mono(10, .semibold)]).width + 18), height: 20) }
    override var acceptsFirstResponder: Bool { false }

    convenience init(_ title: String, tip: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title; toolTip = tip; self.target = target; self.action = action
        isBordered = false; setButtonType(.momentaryChange)
        setAccessibilityLabel(tip)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        let filled = style == .primary || (on && style != .warning) , warn = style == .warning && on
        let fill: NSColor = filled ? Theme.dynamic(.primaryBg) : warn ? Theme.dynamic(.warningBg) : Theme.dynamic(.bgControl)
        let stroke: NSColor = filled ? Theme.dynamic(.primaryBg) : warn ? Theme.dynamic(.warningBorder) : Theme.dynamic(.borderControl)
        let fg: NSColor = filled ? Theme.dynamic(.primaryFg) : warn ? Theme.dynamic(.warningText) : Theme.dynamic(.textSecondary)
        fill.setFill(); path.fill(); stroke.setStroke(); path.lineWidth = 1; path.stroke()
        let a: [NSAttributedString.Key: Any] = [.font: ThemeFont.mono(10, filled || warn ? .bold : .regular), .foregroundColor: fg]
        let sz = (title as NSString).size(withAttributes: a)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2), withAttributes: a)
    }
}

// MARK: Container

final class EditorContainer: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearanceChange?() }
}

// MARK: Guard dialogs

enum EditorGuard {
    #if MUYA_TEST_HOOKS
    /// Set by the debug socket so a scripted run can answer without a click: "save", "discard" or "cancel".
    nonisolated(unsafe) static var testAnswer: String?
    #endif

    enum Answer { case save, discard, cancel }

    static func ask(_ name: String, window: NSWindow?, _ done: @escaping (Answer) -> Void) {
        #if MUYA_TEST_HOOKS
        if let a = testAnswer { testAnswer = nil; done(a == "save" ? .save : a == "discard" ? .discard : .cancel); return }
        #endif
        let a = NSAlert()
        a.messageText = "Do you want to save the changes to “\(name)”?"
        a.informativeText = "Your changes will be lost if you don’t save them."
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Don’t Save"); a.addButton(withTitle: "Cancel")
        let map: (NSApplication.ModalResponse) -> Answer = { $0 == .alertFirstButtonReturn ? .save : $0 == .alertSecondButtonReturn ? .discard : .cancel }
        if let window { a.beginSheetModal(for: window) { done(map($0)) } } else { done(map(a.runModal())) }
    }
}

// MARK: Session

final class EditorSession: NSObject, NSTextStorageDelegate, NSTextViewDelegate, NSLayoutManagerDelegate {
    let doc: EditorDocument
    let url: URL
    let container = EditorContainer()
    let language: SyntaxLanguage
    private let storage = NSTextStorage()
    private let layout = NSLayoutManager()
    private let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private(set) var textView: EditorTextView!
    private let scroll = NSScrollView()
    private var ruler: LineNumberRuler!
    private let minimap = MinimapView()
    private let diffScroll = NSScrollView()
    private let diffText = NSTextView()
    private let sideBySide = DiffPane()
    private(set) var diffSideBySide = false
    private let pathLabel = NSTextField(labelWithString: "")
    private let dirtyLabel = NSTextField(labelWithString: "● unsaved")
    private let readOnlyLabel = NSTextField(labelWithString: "read-only")
    private var badge: NSButton!
    private var wrapButton: PillButton!, mapButton: PillButton!, diffButton: PillButton!, saveButton: PillButton!
    private var minimapWidth: NSLayoutConstraint!

    private var checkpoints = Checkpoints()
    private var editGeneration = 0
    private var isLoading = true
    private var highlightOn: Bool
    private var highlighted: NSRange?
    private var rehighlightScheduled = false
    private var buildToken = 0
    private var watcher: DirectoryWatcher?
    private var autoSaveTimer: Timer?
    private var wrap = false
    private var showMap = false
    private(set) var inDiff = false
    private var scrollObserver: NSObjectProtocol?

    /// Told when dirty / badge / read-only state changed (the open-files list repaints).
    var onChange: (() -> Void)?
    var autoSaveEnabled: () -> Bool = { false }
    var note: String

    init(doc: EditorDocument, text: String, displayNote: String?) {
        self.doc = doc
        url = URL(fileURLWithPath: doc.path)
        language = SyntaxLanguage.detect(path: doc.path)
        highlightOn = doc.features.highlight && language != .plain
        note = [language.displayName, doc.encoding.label + (doc.bom ? " BOM" : ""), doc.eol.label]
            .joined(separator: " · ") + (displayNote.map { " · " + $0 } ?? "")
        super.init()
        #if MUYA_TEST_HOOKS
        EditorSession.live += 1
        #endif
        buildViews()
        load(text)
        startWatching()
        container.onAppearanceChange = { [weak self] in self?.recolorWindow(); self?.minimap.needsDisplay = true }
    }

    #if MUYA_TEST_HOOKS
    nonisolated(unsafe) static var live = 0
    #endif

    deinit {
        #if MUYA_TEST_HOOKS
        EditorSession.live -= 1
        #endif
        watcher?.stop(); autoSaveTimer?.invalidate()
        if let o = scrollObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Views

    private func buildViews() {
        storage.addLayoutManager(layout)
        layout.allowsNonContiguousLayout = true   // lazy layout: 50 MB opens in tens of ms (docs/prd-native-editor.md ADR)
        textContainer.widthTracksTextView = false
        textContainer.size = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        layout.addTextContainer(textContainer)
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: textContainer)
        textView = tv
        tv.delegate = self
        storage.delegate = self
        tv.isEditable = doc.features.editable
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.isRichText = false
        tv.importsGraphics = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.usesFontPanel = false
        for f in [\NSTextView.isAutomaticQuoteSubstitutionEnabled, \.isAutomaticDashSubstitutionEnabled, \.isAutomaticSpellingCorrectionEnabled,
                  \.isAutomaticTextReplacementEnabled, \.isAutomaticLinkDetectionEnabled, \.isAutomaticDataDetectionEnabled, \.isGrammarCheckingEnabled,
                  \.isContinuousSpellCheckingEnabled, \.smartInsertDeleteEnabled] { tv[keyPath: f] = false }
        tv.font = ThemeFont.mono(12)
        tv.textColor = MonacoPalette.foreground
        tv.backgroundColor = MonacoPalette.background
        tv.insertionPointColor = MonacoPalette.foreground
        tv.selectedTextAttributes = [.backgroundColor: MonacoPalette.selection]
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isHorizontallyResizable = true; tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.autoresizingMask = []
        tv.session = self
        layout.delegate = self
        tv.onSave = { [weak self] in self?.save() }
        tv.onGoToLine = { [weak self] in self?.goToLineSheet() }
        tv.setAccessibilityLabel("Editor, \(url.lastPathComponent)")

        scroll.documentView = tv
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true; scroll.backgroundColor = MonacoPalette.background
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.findBarPosition = .aboveContent
        ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.session = self; ruler.clientView = tv
        scroll.verticalRulerView = ruler; scroll.hasVerticalRuler = true; scroll.rulersVisible = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.viewportMoved()
        }

        diffText.isEditable = false; diffText.isSelectable = true; diffText.isRichText = true
        diffText.backgroundColor = MonacoPalette.background; diffText.drawsBackground = true
        diffText.textContainerInset = NSSize(width: 4, height: 4)
        diffText.isHorizontallyResizable = true; diffText.isVerticallyResizable = true
        diffText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        diffText.textContainer?.widthTracksTextView = false
        diffText.textContainer?.size = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        diffText.setAccessibilityLabel("Diff against HEAD, \(url.lastPathComponent)")
        diffScroll.documentView = diffText
        diffScroll.hasVerticalScroller = true; diffScroll.hasHorizontalScroller = true
        diffScroll.drawsBackground = true; diffScroll.backgroundColor = MonacoPalette.background
        diffScroll.isHidden = true; sideBySide.isHidden = true

        minimap.session = self
        minimap.setAccessibilityElement(false)

        // Toolbar: path on the left, state + pills on the right (classic's strip).
        pathLabel.stringValue = doc.path.abbreviatingHome(NSHomeDirectory())
        pathLabel.font = ThemeFont.mono(10); pathLabel.textColor = Theme.dynamic(.textMuted)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dirtyLabel.font = ThemeFont.mono(10); dirtyLabel.textColor = Theme.dynamic(.warningText)
        readOnlyLabel.font = ThemeFont.mono(10); readOnlyLabel.textColor = Theme.dynamic(.textMuted)
        badge = NSButton(title: "", target: self, action: #selector(badgeTapped))
        badge.isBordered = false; badge.font = ThemeFont.mono(10); badge.contentTintColor = Theme.dynamic(.dangerText)
        badge.toolTip = "This file changed on disk while you had unsaved edits. Reload discards your edits."
        wrapButton = PillButton("Wrap", tip: "Toggle word wrap", target: self, action: #selector(toggleWrap))
        mapButton = PillButton("Map", tip: "Toggle minimap", target: self, action: #selector(toggleMap))
        diffButton = PillButton("Diff", tip: "Show diff against HEAD", target: self, action: #selector(toggleDiff))
        diffButton.style = .warning
        saveButton = PillButton("Save", tip: "Save (⌘S)", target: self, action: #selector(saveTapped))
        saveButton.style = .primary
        let bar = NSStackView(views: [pathLabel, badge, dirtyLabel, readOnlyLabel, wrapButton, mapButton, diffButton, saveButton])
        bar.orientation = .horizontal; bar.spacing = 8; bar.alignment = .centerY
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let sep = NSBox(); sep.boxType = .separator

        for v in [bar, sep, scroll, minimap, diffScroll, sideBySide] { v.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(v) }
        minimapWidth = minimap.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor), bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 30),
            sep.topAnchor.constraint(equalTo: bar.bottomAnchor), sep.leadingAnchor.constraint(equalTo: container.leadingAnchor), sep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sep.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: minimap.leadingAnchor),
            minimap.topAnchor.constraint(equalTo: sep.bottomAnchor), minimap.bottomAnchor.constraint(equalTo: container.bottomAnchor), minimap.trailingAnchor.constraint(equalTo: container.trailingAnchor), minimapWidth,
            sideBySide.topAnchor.constraint(equalTo: sep.bottomAnchor), sideBySide.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sideBySide.trailingAnchor.constraint(equalTo: container.trailingAnchor), sideBySide.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            diffScroll.topAnchor.constraint(equalTo: sep.bottomAnchor), diffScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            diffScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor), diffScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        mapButton.isEnabled = doc.features.minimap
        diffButton.isEnabled = doc.features.diff
        refreshChrome()
    }

    func refreshChrome() {
        dirtyLabel.isHidden = !doc.isDirty
        badge.isHidden = !(doc.diskChanged || doc.diskDeleted)
        badge.title = doc.diskDeleted ? "⟳ deleted on disk — keep buffer" : "⟳ changed on disk — reload"
        badge.isEnabled = !doc.diskDeleted
        readOnlyLabel.isHidden = doc.features.editable
        readOnlyLabel.stringValue = doc.features.readOnly == .notWritable ? "read-only (no write permission)" : "read-only"
        saveButton.isEnabled = doc.isDirty && doc.features.editable
        wrapButton.on = wrap; mapButton.on = showMap; diffButton.on = inDiff
        onChange?()
    }

    func focus() { container.window?.makeFirstResponder(inDiff ? diffText : textView) }

    // MARK: Loading

    private func load(_ text: String) {
        isLoading = true
        folds = []; matchRanges = []
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        resetAttributes()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.undoManager?.removeAllActions()
        highlighted = nil
        isLoading = false
        rebuildCheckpoints()
        highlightWindowSoon()
    }

    private func resetAttributes() {
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: ThemeFont.mono(12), .foregroundColor: MonacoPalette.foreground], range: all)
        storage.endEditing()
        textView.typingAttributes = [.font: ThemeFont.mono(12), .foregroundColor: MonacoPalette.foreground]
    }

    // MARK: Checkpoints (line anchors + highlighter states)

    private func utf16Snapshot() -> [UInt16] {
        let ns = storage.string as NSString
        var a = [UInt16](repeating: 0, count: ns.length)
        a.withUnsafeMutableBufferPointer { ns.getCharacters($0.baseAddress!, range: NSRange(location: 0, length: ns.length)) }
        return a
    }

    private func rebuildCheckpoints() {
        buildToken += 1
        let token = buildToken, gen = editGeneration, lang = highlightOn ? language : .plain
        var cp = Checkpoints()   // a full fresh pass: the shifted entries serve until it lands
        let snap = utf16Snapshot()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            snap.withUnsafeBufferPointer { b in
                cp.extend(b, language: lang, isCancelled: { self?.buildToken != token })
            }
            DispatchQueue.main.async {
                guard let self, token == self.buildToken, gen == self.editGeneration else { return }
                self.checkpoints = cp
                self.ruler.needsDisplay = true; self.minimap.needsDisplay = true
                self.ruler.ruleThickness = self.ruler.requiredThickness
                self.recolorWindow()
            }
        }
    }

    var totalLinesEstimate: Int { max(checkpoints.totalLines, line(ofOffset: storage.length)) }

    /// 1-based line of a UTF-16 offset, counted from the nearest checkpoint.
    func line(ofOffset off: Int) -> Int {
        let ns = storage.string as NSString
        let o = min(max(off, 0), ns.length)
        let i = checkpoints.nearestIndex(before: o)
        let start = checkpoints.entries[i].offset
        return checkpoints.entries[i].line + EditorSession.countNewlines(ns, NSRange(location: start, length: o - start))
    }

    func offset(ofLine line: Int) -> Int {
        let ns = storage.string as NSString
        let target = max(1, line) - 1
        let i = checkpoints.nearestIndex(beforeLine: target + 1)
        var off = checkpoints.entries[i].offset
        var remaining = target + 1 - checkpoints.entries[i].line
        while remaining > 0 {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: off, length: ns.length - off))
            if r.location == NSNotFound { return ns.length > 0 && ns.character(at: ns.length - 1) == 0x0A ? ns.length : ns.lineRange(for: NSRange(location: ns.length, length: 0)).location }
            off = r.location + 1; remaining -= 1
        }
        return off
    }

    static func countNewlines(_ ns: NSString, _ r: NSRange) -> Int {
        var count = 0, pos = r.location
        let end = r.location + r.length
        var buf = [unichar](repeating: 0, count: 8192)
        while pos < end {
            let n = min(buf.count, end - pos)
            ns.getCharacters(&buf, range: NSRange(location: pos, length: n))
            for k in 0 ..< n where buf[k] == 0x0A { count += 1 }
            pos += n
        }
        return count
    }

    func visibleCharRange() -> NSRange {
        let origin = textView.textContainerOrigin
        let g = layout.glyphRange(forBoundingRect: textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: textContainer)
        return layout.characterRange(forGlyphRange: g, actualGlyphRange: nil)
    }

    func visibleLines() -> (Int, Int) {
        let v = visibleCharRange()
        return (line(ofOffset: v.location), line(ofOffset: v.location + v.length))
    }

    // MARK: Highlighting (a window around the viewport, real attributes)

    private func viewportMoved() {
        ruler.needsDisplay = true; minimap.needsDisplay = true
        highlightWindowSoon()
    }

    private func highlightWindowSoon() {
        guard !rehighlightScheduled else { return }
        rehighlightScheduled = true
        DispatchQueue.main.async { [weak self] in self?.rehighlightScheduled = false; self?.highlightWindow() }
    }

    /// Scans `r` (line aligned) and returns tokens as (location, length, kind), starting from the nearest checkpoint.
    private func tokens(in r: NSRange) -> [(Int, Int, TokenKind)] {
        let ns = storage.string as NSString
        var out: [(Int, Int, TokenKind)] = []
        guard r.length > 0 else { return out }
        let c = checkpoints.nearest(before: r.location)
        var state = c.state
        if c.offset < r.location {
            let m = r.location - c.offset
            var pre = [UInt16](repeating: 0, count: m)
            pre.withUnsafeMutableBufferPointer { ns.getCharacters($0.baseAddress!, range: NSRange(location: c.offset, length: m)) }
            state = pre.withUnsafeBufferPointer { SyntaxScanner.scan($0, from: 0, to: m, language: language, state: state, emit: nil) }
        }
        var buf = [UInt16](repeating: 0, count: r.length)
        buf.withUnsafeMutableBufferPointer { ns.getCharacters($0.baseAddress!, range: r) }
        buf.withUnsafeBufferPointer { b in
            _ = SyntaxScanner.scan(b, from: 0, to: b.count, language: language, state: state) { l, n, k in out.append((r.location + l, n, k)) }
        }
        return out
    }

    /// `a` minus `b`: up to two pieces.
    private static func subtract(_ a: NSRange, _ b: NSRange) -> [NSRange] {
        guard let i = a.intersection(b), i.length > 0 else { return [a] }
        var out: [NSRange] = []
        if i.location > a.location { out.append(NSRange(location: a.location, length: i.location - a.location)) }
        if NSMaxRange(i) < NSMaxRange(a) { out.append(NSRange(location: NSMaxRange(i), length: NSMaxRange(a) - NSMaxRange(i))) }
        return out
    }

    /// Colours `r` (line aligned): default first, then the tokens. TextKit 1 re-lays-out whatever an attribute change touches
    /// (about 6 us per character here), so callers hand it only what is NEW: a scroll step, an edited line.
    private func applyColors(_ r: NSRange) {
        let len = storage.length
        guard r.length > 0, NSMaxRange(r) <= len else { return }
        let toks = tokens(in: r)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: MonacoPalette.foreground, range: r)
        for (l, n, k) in toks where k != .plain && l + n <= len { storage.addAttribute(.foregroundColor, value: MonacoPalette.color(k), range: NSRange(location: l, length: n)) }
        storage.endEditing()
    }

    private func resetColors(_ r: NSRange) {
        guard r.length > 0, NSMaxRange(r) <= storage.length else { return }
        storage.beginEditing(); storage.addAttribute(.foregroundColor, value: MonacoPalette.foreground, range: r); storage.endEditing()
    }

    /// The coloured window follows the viewport (one screen of padding each side). Moving it colours only the newly covered
    /// part and clears the part that left, so a long scroll through a big file keeps the attribute runs bounded.
    private func highlightWindow() {
        guard highlightOn, !isLoading, storage.length > 0, !inDiff else { return }
        let t0 = CFAbsoluteTimeGetCurrent()
        let len = storage.length
        let vis = visibleCharRange()
        let pad = max(vis.length, 3000)
        let lo = max(0, vis.location - pad), hi = min(len, vis.location + vis.length + pad)
        let w = (storage.string as NSString).lineRange(for: NSRange(location: lo, length: max(0, hi - lo)))
        if let h = highlighted, NSEqualRanges(h, w) { return }
        let old = highlighted
        for piece in old.map({ EditorSession.subtract(w, $0) }) ?? [w] { applyColors(piece) }
        if let old { for piece in EditorSession.subtract(old, w) { resetColors(piece) } }
        highlighted = w
        #if MUYA_TEST_HOOKS
        profile = String(format: "window %d chars, %.1f ms", w.length, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        #endif
    }

    /// After an edit: only the touched lines are re-coloured (the states after them are fixed by the background pass).
    private func rehighlightEdited(_ edited: NSRange) {
        guard highlightOn, !inDiff, let h = highlighted, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let loc = min(edited.location, ns.length), end = min(NSMaxRange(edited), ns.length)
        let r = ns.lineRange(for: NSRange(location: loc, length: max(0, end - loc)))
        guard let inside = r.intersection(h) else { return }
        applyColors(inside)
        #if MUYA_TEST_HOOKS
        profile = "edited \(inside.length) chars"
        #endif
    }

    /// Re-colour the whole window (appearance change, the background pass landed, wrap toggled).
    private func recolorWindow() { if let h = highlighted { applyColors(h) } else { highlightWindowSoon() } }
    #if MUYA_TEST_HOOKS
    var profile = ""
    #endif

    // MARK: Code folding (hidden glyphs) and its "⋯" marker

    /// Folded blocks: the hidden range runs from the end of the header line to the end of the block's last line.
    private(set) var folds: [NSRange] = []

    func isFolded(headerLineStart start: Int) -> Bool {
        let ns = storage.string as NSString
        guard start < ns.length else { return false }
        let end = Folding.lineEnd(ns, start)
        return folds.contains { $0.location == end }
    }

    func toggleFold(atLineStart start: Int) {
        let ns = storage.string as NSString
        guard start < ns.length else { return }
        let end = Folding.lineEnd(ns, start)
        if let i = folds.firstIndex(where: { $0.location == end }) { unfold(i); return }
        guard doc.features.highlight || true, let r = Folding.range(headerLineStart: start, in: ns) else { return }
        folds.append(r); folds.sort { $0.location < $1.location }
        relayoutFold(r)
        placeCaretOutsideFolds()
    }

    /// ⌥⌘[ / ⌥⌘]: fold / unfold the block the caret's line starts (or the innermost block around the caret when folding).
    func foldAtCaret(_ fold: Bool) {
        let ns = storage.string as NSString
        let caret = min(textView.selectedRange().location, ns.length)
        var ls = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        if fold {
            while ls >= 0 {
                if isFolded(headerLineStart: ls) { break }
                if Folding.range(headerLineStart: ls, in: ns).map({ NSMaxRange($0) >= caret }) == true { toggleFold(atLineStart: ls); return }
                if ls == 0 { break }
                ls = ns.lineRange(for: NSRange(location: ls - 1, length: 0)).location
            }
        } else if isFolded(headerLineStart: ls) { toggleFold(atLineStart: ls) }
    }

    private func unfold(_ i: Int) { let r = folds.remove(at: i); relayoutFold(r) }

    private func relayoutFold(_ r: NSRange) {
        let a = NSRange(location: max(0, r.location - 1), length: min(storage.length - max(0, r.location - 1), r.length + 2))
        layout.invalidateGlyphs(forCharacterRange: a, changeInLength: 0, actualCharacterRange: nil)
        layout.invalidateLayout(forCharacterRange: a, actualCharacterRange: nil)
        textView.needsDisplay = true; ruler.needsDisplay = true; minimap.needsDisplay = true
    }

    private func placeCaretOutsideFolds() {
        var sel = textView.selectedRanges.map(\.rangeValue)
        for i in sel.indices { for f in folds where sel[i].location > f.location && sel[i].location <= NSMaxRange(f) { sel[i] = NSRange(location: f.location, length: 0) } }
        textView.selectedRanges = sel.map { NSValue(range: $0) }
    }

    func layoutManager(_ lm: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>, properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard !folds.isEmpty else { return 0 }
        let n = glyphRange.length
        var hidden = false
        let out = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: n)
        defer { out.deallocate() }
        for i in 0 ..< n {
            var p = props[i]
            let c = charIndexes[i]
            if folds.contains(where: { c >= $0.location && c < NSMaxRange($0) }) { p = .null; hidden = true }
            out[i] = p
        }
        guard hidden else { return 0 }
        lm.setGlyphs(glyphs, properties: out, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return n
    }

    // MARK: Multi-cursor, bracket match, drawing of both

    /// Extra insertion points (NSTextView only keeps one empty caret; empty carets are drawn and edited by us).
    var extraCarets: [Int] = []
    var inMultiEdit = false

    func addCursor(at idx: Int) {
        let i = min(idx, storage.length)
        let primary = textView.selectedRange()
        if primary.length == 0, primary.location == i {
            if let e = extraCarets.first { extraCarets.removeFirst(); inMultiEdit = true; textView.setSelectedRange(NSRange(location: e, length: 0)); inMultiEdit = false }
            textView.needsDisplay = true; return
        }
        if let k = extraCarets.firstIndex(of: i) { extraCarets.remove(at: k) } else { extraCarets.append(i); extraCarets.sort() }
        textView.needsDisplay = true
    }

    /// ⌘D: select the word at the caret, then add the next occurrence of the selection as a further selection.
    func addNextOccurrence() {
        let ns = storage.string as NSString
        var rs = textView.selectedRanges.map(\.rangeValue)
        let r = MultiCursor.nextOccurrence(ranges: rs, in: ns)
        if let w = r.selectWord { rs[rs.count - 1] = w }
        else if let a = r.add { rs.append(a); textView.scrollRangeToVisible(a) }
        else { return }
        textView.selectedRanges = rs.map { NSValue(range: $0) }
    }

    var cursorCount: Int { textView.selectedRanges.count + extraCarets.count }

    /// Extra carets (zero-length ranges after the first) and the folded-block markers.
    func drawExtras(in tv: NSTextView) {
        let origin = tv.textContainerOrigin
        for r in extraCarets.map({ NSRange(location: $0, length: 0) }) where r.location <= storage.length {
            let g = layout.glyphIndexForCharacter(at: min(r.location, max(0, storage.length - 1)))
            var rect = layout.lineFragmentUsedRect(forGlyphAt: min(g, max(0, layout.numberOfGlyphs - 1)), effectiveRange: nil)
            let loc = layout.location(forGlyphAt: min(g, max(0, layout.numberOfGlyphs - 1)))
            rect.origin.x += loc.x + (r.location >= storage.length ? 0 : 0)
            MonacoPalette.foreground.setFill()
            NSRect(x: rect.minX + origin.x, y: rect.minY + origin.y, width: 1.5, height: rect.height).fill()
        }
        for f in folds where f.location > 0 && f.location <= storage.length {
            let g = layout.glyphIndexForCharacter(at: f.location - 1)
            let used = layout.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
            let box = NSRect(x: used.maxX + origin.x + 6, y: used.minY + origin.y + 2, width: 22, height: max(10, used.height - 4))
            Theme.dynamic(.bgControl).setFill(); NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            ("⋯" as NSString).draw(at: NSPoint(x: box.minX + 5, y: box.minY - 1), withAttributes: [.font: ThemeFont.mono(11), .foregroundColor: Theme.dynamic(.textMuted)])
        }
    }

    private var matchRanges: [NSRange] = []
    private var lastPrimary = NSRange(location: 0, length: 0)

    func textViewDidChangeSelection(_ n: Notification) {
        guard !isLoading else { return }
        if !inMultiEdit, !extraCarets.isEmpty, textView.selectedRange() != lastPrimary { extraCarets = [] }
        lastPrimary = textView.selectedRange()
        // A caret that lands inside a folded block unfolds it (Monaco does the same on find / go to).
        let sel = textView.selectedRange()
        if let i = folds.firstIndex(where: { sel.location > $0.location && sel.location < NSMaxRange($0) }) { unfold(i) }
        updateBracketMatch()
    }

    /// Bracket matching: the pair next to a lone caret gets a faint box (real attribute on two characters).
    private func updateBracketMatch() {
        let len = storage.length
        if !matchRanges.isEmpty {
            storage.beginEditing()
            for r in matchRanges where NSMaxRange(r) <= len { storage.removeAttribute(.backgroundColor, range: r) }
            storage.endEditing(); matchRanges = []
        }
        let sels = textView.selectedRanges.map(\.rangeValue)
        guard sels.count == 1, sels[0].length == 0, len > 0, len < 80 << 20, let p = BracketMatch.pair(at: sels[0].location, in: storage.string as NSString) else { return }
        let c = NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.22) : NSColor(srgbRed: 0, green: 0.4, blue: 0, alpha: 0.18) }
        let rs = [NSRange(location: p.0, length: 1), NSRange(location: p.1, length: 1)]
        storage.beginEditing()
        for r in rs { storage.addAttribute(.backgroundColor, value: c, range: r) }
        storage.endEditing()
        matchRanges = rs
    }

    // MARK: Minimap drawing

    func drawMinimap(top: Int, rows: Int, rowH: CGFloat, width: CGFloat) {
        guard storage.length > 0 else { return }
        let ns = storage.string as NSString
        let start = offset(ofLine: top)
        var end = start, linesLeft = rows
        while linesLeft > 0, end < ns.length {
            let r = ns.range(of: "\n", options: .literal, range: NSRange(location: end, length: ns.length - end))
            end = r.location == NSNotFound ? ns.length : r.location + 1; linesLeft -= 1
        }
        let r = NSRange(location: start, length: end - start)
        guard r.length > 0 else { return }
        var lineIdx = 0, lineStart = start
        var buf = [UInt16](repeating: 0, count: r.length)
        buf.withUnsafeMutableBufferPointer { ns.getCharacters($0.baseAddress!, range: r) }
        let cw: CGFloat = 1
        // plain text first: one faint bar per run of non-space characters
        let faint = MonacoPalette.foreground.withAlphaComponent(0.28)
        faint.setFill()
        var col = 0, runStart = -1
        for (i, c) in buf.enumerated() {
            if c == 0x0A { if runStart >= 0 { NSRect(x: 8 + CGFloat(runStart) * cw, y: CGFloat(lineIdx) * rowH, width: CGFloat(col - runStart) * cw, height: rowH - 0.6).fill() }; lineIdx += 1; col = 0; runStart = -1; lineStart = r.location + i + 1; continue }
            if c == 0x20 || c == 0x09 { if runStart >= 0 { NSRect(x: 8 + CGFloat(runStart) * cw, y: CGFloat(lineIdx) * rowH, width: CGFloat(col - runStart) * cw, height: rowH - 0.6).fill(); runStart = -1 }; col += c == 0x09 ? 4 : 1; continue }
            if runStart < 0 { runStart = col }
            col += 1
            if col > Int((width - 10) / cw) { continue }
        }
        _ = lineStart
        guard highlightOn else { return }
        for (l, n, k) in tokens(in: r) where k != .plain {
            // recompute row/col of the token start from the buffer
            let rel = l - r.location
            var row = 0, c0 = 0, q = 0
            while q < rel { if buf[q] == 0x0A { row += 1; c0 = 0 } else { c0 += buf[q] == 0x09 ? 4 : 1 }; q += 1 }
            let x = 8 + CGFloat(c0) * cw
            if x > width - 2 { continue }
            MonacoPalette.color(k).withAlphaComponent(0.9).setFill()
            NSRect(x: x, y: CGFloat(row) * rowH, width: min(CGFloat(n) * cw, width - 2 - x), height: rowH - 0.6).fill()
        }
    }

    func scrollToLine(_ line: Int, centered: Bool) {
        let off = offset(ofLine: line)
        let r = NSRange(location: off, length: 0)
        if centered {
            let g = layout.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: g.location, length: max(1, g.length)), in: textContainer)
            let y = max(0, rect.midY - scroll.contentView.bounds.height / 2)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        } else { textView.scrollRangeToVisible(r) }
    }

    // MARK: Editing callbacks

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isLoading else { return }
        doc.markEdited()
        editGeneration += 1
        checkpoints.shift(after: editedRange.location, by: delta, lines: pendingLineDelta)
        pendingLineDelta = 0
        matchRanges = []
        if !inMultiEdit { extraCarets = [] }
        if !folds.isEmpty {   // folds move with the text; an edit that touches a folded block unfolds it
            let oldEnd = editedRange.location + editedRange.length - delta
            folds = folds.compactMap { f in
                if editedRange.location < NSMaxRange(f), oldEnd > f.location { return nil }
                return editedRange.location <= f.location ? NSRange(location: f.location + delta, length: f.length) : f
            }
            layout.invalidateGlyphs(forCharacterRange: NSRange(location: 0, length: storage.length), changeInLength: 0, actualCharacterRange: nil)
        }
        if var h = highlighted {   // the coloured window moves with the text
            if editedRange.location < h.location { h.location = max(0, h.location + delta) }
            else if editedRange.location <= NSMaxRange(h) { h.length = max(0, h.length + delta) }
            highlighted = h
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshChrome()
            self.rehighlightEdited(editedRange)
            self.ruler.needsDisplay = true; self.minimap.needsDisplay = true
            self.scheduleCheckpointRebuild(); self.scheduleAutoSave()
        }
    }

    private var pendingLineDelta = 0
    func textView(_ tv: NSTextView, shouldChangeTextIn r: NSRange, replacementString s: String?) -> Bool {
        let ns = storage.string as NSString
        if !matchRanges.isEmpty {   // the bracket box must not be inherited by typed text
            storage.beginEditing(); for m in matchRanges where NSMaxRange(m) <= ns.length { storage.removeAttribute(.backgroundColor, range: m) }; storage.endEditing(); matchRanges = []
        }
        pendingLineDelta = (s.map { EditorSession.countNewlines($0 as NSString, NSRange(location: 0, length: ($0 as NSString).length)) } ?? 0) - EditorSession.countNewlines(ns, r)
        return true
    }

    private var rebuildTimer: Timer?
    private func scheduleCheckpointRebuild() {
        rebuildTimer?.invalidate()
        rebuildTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in self?.rebuildCheckpoints() }
    }

    private func scheduleAutoSave() {
        autoSaveTimer?.invalidate()
        guard autoSaveEnabled(), doc.features.editable else { return }
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            guard let self, self.doc.isDirty else { return }
            do { try self.doc.save(text: self.storage.string) } catch { /* conflict / failure: the badge or the next manual save tells */ }
            self.refreshChrome()
        }
    }

    // MARK: Save

    @objc private func saveTapped() { save() }

    @discardableResult
    func save(force: Bool = false, then: ((Bool) -> Void)? = nil) -> Bool {
        guard doc.features.editable else { then?(false); return false }
        if !doc.isDirty && !force { then?(true); return true }
        do {
            try doc.save(text: storage.string, force: force)
            refreshChrome(); then?(true); return true
        } catch SaveError.conflict {
            refreshChrome()
            conflictSheet(then)
        } catch {
            let a = NSAlert(); a.messageText = "Could not save “\(url.lastPathComponent)”"; a.informativeText = "\(error)"; a.alertStyle = .warning
            if let w = container.window { a.beginSheetModal(for: w) { _ in then?(false) } } else { a.runModal(); then?(false) }
        }
        return false
    }

    private func conflictSheet(_ then: ((Bool) -> Void)?) {
        #if MUYA_TEST_HOOKS
        if let a = EditorGuard.testAnswer { EditorGuard.testAnswer = nil; handleConflict(a == "overwrite" ? .alertFirstButtonReturn : a == "reload" ? .alertSecondButtonReturn : .alertThirdButtonReturn, then); return }
        #endif
        let a = NSAlert()
        a.messageText = "“\(url.lastPathComponent)” changed on disk"
        a.informativeText = "Something else wrote to this file after you opened it. Overwrite it with your version, or reload the version on disk and lose your edits?"
        a.addButton(withTitle: "Overwrite"); a.addButton(withTitle: "Reload from Disk"); a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        if let w = container.window { a.beginSheetModal(for: w) { self.handleConflict($0, then) } } else { handleConflict(a.runModal(), then) }
    }

    private func handleConflict(_ r: NSApplication.ModalResponse, _ then: ((Bool) -> Void)?) {
        switch r {
        case .alertFirstButtonReturn: save(force: true, then: then)
        case .alertSecondButtonReturn: reloadFromDisk(); then?(true)
        default: then?(false)
        }
    }

    /// Close guard: calls `done(true)` when the file may be closed (clean, saved, or discarded).
    func confirmClose(window: NSWindow?, _ done: @escaping (Bool) -> Void) {
        guard doc.isDirty else { done(true); return }
        EditorGuard.ask(url.lastPathComponent, window: window) { [weak self] answer in
            guard let self else { done(true); return }
            switch answer {
            case .save: self.save(then: done)
            case .discard: done(true)
            case .cancel: done(false)
            }
        }
    }

    // MARK: Disk changes

    private func startWatching() {
        let dir = url.deletingLastPathComponent().path
        watcher = DirectoryWatcher(path: dir, latency: 0.2) { [weak self] _ in self?.reconcile() }
    }

    /// FSEvents / app activation: one stat decides. Clean + changed = reload now; dirty + changed = the badge.
    func reconcile() {
        guard !isLoading else { return }
        switch doc.checkDisk() {
        case .unchanged: break
        case .modified: if !doc.isDirty { reloadFromDisk() }
        case .deleted: break
        }
        refreshChrome()
    }

    @objc private func badgeTapped() { reloadFromDisk() }

    /// Replaces the buffer with the file on disk, keeping scroll and caret where they were. Discards unsaved edits.
    func reloadFromDisk() {
        let path = doc.path, anyway = doc.features.readOnly == .truncated
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = EditorOpen.open(path: path, openAnyway: anyway)
            DispatchQueue.main.async {
                guard let self, case .document(let fresh, let text, let note) = r else { return }
                let sel = self.textView.selectedRange(), origin = self.scroll.contentView.bounds.origin
                self.doc.didReload(decoded: DecodedText(text: text, eol: fresh.eol, bom: fresh.bom, encoding: fresh.encoding, mixedEndings: fresh.mixedEndings), features: fresh.features, size: fresh.size)
                self.highlightOn = fresh.features.highlight && self.language != .plain
                self.textView.isEditable = fresh.features.editable
                if let note { self.note += " · " + note }
                self.editGeneration += 1
                self.checkpoints = Checkpoints()
                self.load(text)
                let len = self.storage.length
                self.textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
                self.scroll.contentView.scroll(to: origin); self.scroll.reflectScrolledClipView(self.scroll.contentView)
                self.refreshChrome()
            }
        }
    }

    // MARK: Toolbar actions

    @objc private func toggleWrap() {
        wrap.toggle()
        if wrap {
            textContainer.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.frame.size.width = scroll.contentSize.width
            textContainer.containerSize = NSSize(width: scroll.contentSize.width - 8, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textContainer.widthTracksTextView = false
            textView.autoresizingMask = []
            textView.isHorizontallyResizable = true
            textContainer.containerSize = NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude)
        }
        refreshChrome(); ruler.needsDisplay = true
    }

    @objc private func toggleMap() {
        showMap.toggle()
        minimapWidth.constant = showMap && !inDiff ? MinimapView.width : 0
        minimap.needsDisplay = true; refreshChrome()
    }

    @objc private func toggleDiff() {
        if inDiff { leaveDiff(); return }
        guard doc.features.diff else { return }
        inDiff = true
        diffScroll.isHidden = false; scroll.isHidden = true
        minimapWidth.constant = 0
        setDiffMessage("diff…")
        let text = storage.string, path = doc.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let head = GitHead.content(of: path)
            let rows = head.flatMap { LineDiff.diff(old: $0, new: text) }
            let out = EditorSession.render(rows)
            DispatchQueue.main.async {
                guard let self, self.inDiff else { return }
                if head == nil { self.setDiffMessage("Git is not available here, or this file is not in a git repository, so there is no HEAD to compare with.") }
                else if rows == nil { self.setDiffMessage("This file is too large to diff (over \(LineDiff.maxLines) lines).") }
                else if rows!.allSatisfy({ $0.kind == .same || $0.kind == .fold }) { self.setDiffMessage("No changes against HEAD.") }
                else if self.container.bounds.width >= DiffPane.minWidth, let rows {
                    self.diffSideBySide = true; self.diffScroll.isHidden = true; self.sideBySide.isHidden = false
                    self.sideBySide.show(rows: rows)
                } else { self.diffText.textStorage?.setAttributedString(out) }
            }
        }
        refreshChrome()
    }

    private func leaveDiff() {
        inDiff = false
        diffScroll.isHidden = true; sideBySide.isHidden = true; diffSideBySide = false; scroll.isHidden = false
        minimapWidth.constant = showMap ? MinimapView.width : 0
        highlightWindowSoon(); refreshChrome(); focus()
    }

    private func setDiffMessage(_ s: String) {
        sideBySide.isHidden = true; diffSideBySide = false; if inDiff { diffScroll.isHidden = false }
        diffText.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: [.font: ThemeFont.sans(12), .foregroundColor: Theme.dynamic(.textMuted)]))
    }

    static func render(_ rows: [DiffRow]?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        guard let rows else { return out }
        let font = ThemeFont.mono(12), faint = ThemeFont.mono(11)
        func pad(_ n: Int?) -> String { n.map { String($0).leftPad(5) } ?? "     " }
        for r in rows {
            switch r.kind {
            case .fold:
                out.append(NSAttributedString(string: "      ⋯ \(r.text)\n", attributes: [.font: faint, .foregroundColor: Theme.dynamic(.textMuted), .backgroundColor: Theme.dynamic(.bgControl)]))
            default:
                let sign = r.kind == .added ? "+" : r.kind == .removed ? "-" : " "
                let bg: NSColor? = r.kind == .added ? MonacoPalette.added : r.kind == .removed ? MonacoPalette.removed : nil
                var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: MonacoPalette.foreground]
                if let bg { a[.backgroundColor] = bg }
                var g = a; g[.foregroundColor] = MonacoPalette.gutter
                out.append(NSAttributedString(string: pad(r.oldLine) + pad(r.newLine) + " " + sign + " ", attributes: g))
                out.append(NSAttributedString(string: r.text + "\n", attributes: a))
            }
        }
        return out
    }

    // MARK: Go to line

    func goToLineSheet() {
        let a = NSAlert()
        a.messageText = "Go to Line"
        a.informativeText = "Line number, or line:column. This file has \(totalLinesEstimate) lines."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24)); f.placeholderString = "12 or 12:5"
        a.accessoryView = f
        a.addButton(withTitle: "Go"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        let go: (NSApplication.ModalResponse) -> Void = { [weak self] r in
            guard r == .alertFirstButtonReturn, let self, let p = LineIndex.parse(f.stringValue) else { return }
            self.goTo(line: p.line, column: p.column)
        }
        if let w = container.window { a.beginSheetModal(for: w, completionHandler: go) } else { go(a.runModal()) }
    }

    func goTo(line: Int, column: Int?) {
        let ns = storage.string as NSString
        let off = offset(ofLine: line)
        let lr = ns.lineRange(for: NSRange(location: min(off, ns.length), length: 0))
        let lineLen = max(0, lr.length - (lr.length > 0 && ns.character(at: lr.location + lr.length - 1) == 0x0A ? 1 : 0))
        let col = min((column ?? 1) - 1, lineLen)
        textView.setSelectedRange(NSRange(location: lr.location + col, length: 0))
        scrollToLine(line, centered: true)
        container.window?.makeFirstResponder(textView)
    }

    var currentText: String { storage.string }

    #if MUYA_TEST_HOOKS
    // Debug-socket hooks (verify-editor.sh).
    func debugType(_ s: String) { container.window?.makeFirstResponder(textView); textView.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    func debugFold(_ line: Int) { toggleFold(atLineStart: offset(ofLine: line)) }
    func debugAddCursor(_ off: Int) { addCursor(at: off) }
    func debugAddNext() { addNextOccurrence() }
    var debugSelections: String { textView.selectedRanges.map { "\($0.rangeValue.location),\($0.rangeValue.length)" }.joined(separator: " ") + (extraCarets.isEmpty ? "" : " | extra " + extraCarets.map(String.init).joined(separator: " ")) }
    var debugDiffFrames: String { sideBySide.debugFrames }
    var debugDiffStrings: (String, String) { sideBySide.isHidden ? ("", "") : (sideBySide.leftString, sideBySide.rightString) }
    func debugSetCaret(_ loc: Int) { textView.setSelectedRange(NSRange(location: min(loc, storage.length), length: 0)) }
    func debugToggle(_ what: String) { switch what { case "wrap": toggleWrap(); case "map": toggleMap(); case "diff": toggleDiff(); default: break } }
    func debugUndo() { textView.undoManager?.undo() }
    func debugFind() { _ = textView.performKeyEquivalent(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: container.window?.windowNumber ?? 0, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!) }
    /// Key-to-paint latency: n inserts at the middle of the file, each followed by the window re-highlight and a repaint.
    func debugBench(_ n: Int) -> String {
        let mid = storage.length / 2
        container.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: mid, length: 0)); textView.scrollRangeToVisible(NSRange(location: mid, length: 0))
        scroll.displayIfNeeded()
        var lat: [Double] = [], ins: [Double] = [], hl: [Double] = [], disp: [Double] = []
        for _ in 0 ..< n {
            let a = CFAbsoluteTimeGetCurrent()
            textView.insertText("x", replacementRange: textView.selectedRange())
            let b = CFAbsoluteTimeGetCurrent()
            rehighlightEdited(textView.selectedRange()); highlightWindow()
            let c = CFAbsoluteTimeGetCurrent()
            scroll.displayIfNeeded()
            let d = CFAbsoluteTimeGetCurrent()
            lat.append((d - a) * 1000); ins.append((b - a) * 1000); hl.append((c - b) * 1000); disp.append((d - c) * 1000)
        }
        func med(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }
        // scrolling: 40 steps of 3 lines through the file, each followed by the window move and a repaint
        var sc: [Double] = []
        var y = scroll.contentView.bounds.origin.y
        for _ in 0 ..< 40 {
            let a = CFAbsoluteTimeGetCurrent()
            y += 50
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            highlightWindow(); scroll.displayIfNeeded()
            sc.append((CFAbsoluteTimeGetCurrent() - a) * 1000)
        }
        return String(format: "median=%.1f max=%.1f n=%d (insert %.1f, highlight %.1f, paint %.1f) scroll median=%.1f max=%.1f", med(lat), lat.max() ?? 0, n, med(ins), med(hl), med(disp), med(sc), sc.max() ?? 0)
    }
    var debugState: String {
        "path=\((doc.path as NSString).lastPathComponent) dirty=\(doc.isDirty) diskChanged=\(doc.diskChanged) deleted=\(doc.diskDeleted) lang=\(language.rawValue) highlight=\(highlightOn) minimap=\(doc.features.minimap) diff=\(doc.features.diff) readOnly=\(String(describing: doc.features.readOnly)) len=\(storage.length) lines=\(totalLinesEstimate) wrap=\(wrap) map=\(showMap) inDiff=\(inDiff) sideBySide=\(diffSideBySide) folds=\(folds.count) cursors=\(cursorCount) eol=\(doc.eol.label) save=\(saveButton.isEnabled)"
    }
    #endif
}

private extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
