// Native file viewers, all system frameworks (no WebKit linked): images in NSImageView, PDF in PDFKit,
// Markdown rendered into an NSAttributedString, other text read-only in a plain NSTextView
// (INTERIM: the real code editor component is still awaiting an operator decision on a package),
// and a hex preview with "Open with Default App" for everything else.

import AppKit
import PDFKit

final class ViewerPane: NSView {
    private let header = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let separator = NSBox()
    private var content: NSView?
    private(set) var url: URL?
    private(set) var kind: FileKind = .other
    var onClose: (() -> Void)?
    /// "Open anyway" was chosen for this file: show its head although it is over the prompt size.
    private var openAnyway: URL?
    /// Editor documents by path: they live while the file is in the open-files list (unsaved edits survive a switch).
    private(set) var sessions: [String: EditorSession] = [:]
    /// Markdown files shown in the editor instead of rendered.
    private var markdownEditing = Set<String>()
    private let editButton = NSButton()
    var onDirtyChange: (() -> Void)?
    var autoSaveEnabled: () -> Bool = { false }

    var dirtyPaths: [String] { sessions.values.filter { $0.doc.isDirty }.map(\.doc.path).sorted() }
    func isDirty(_ path: String) -> Bool { sessions[path]?.doc.isDirty ?? false }

    /// Close guard for one open file: `done(true)` when it may go (clean, saved or discarded). A closed file's document is dropped.
    func confirmClose(_ path: String, window: NSWindow?, _ done: @escaping (Bool) -> Void) {
        guard let s = sessions[path] else { done(true); return }
        s.confirmClose(window: window) { [weak self] ok in
            if ok { self?.sessions[path] = nil; self?.markdownEditing.remove(path); self?.onDirtyChange?() }
            done(ok)
        }
    }

    func discardSession(_ path: String) { sessions[path] = nil; markdownEditing.remove(path); onDirtyChange?() }

    /// Saves every dirty document (quit: "Save All"). Returns false when one could not be written.
    func saveAll() -> Bool { sessions.values.filter { $0.doc.isDirty }.allSatisfy { $0.save() } }
    func reconcileAll() { for s in sessions.values { s.reconcile() } }

    @objc private func toggleMarkdownEdit() {
        guard let url, kind == .markdown else { return }
        if markdownEditing.contains(url.path) { markdownEditing.remove(url.path) } else { markdownEditing.insert(url.path) }
        show(url, kind: kind)
    }

    private func updateEditButton() {
        editButton.isHidden = kind != .markdown
        editButton.title = url.map { markdownEditing.contains($0.path) } == true ? "Preview" : "Edit"
    }

    #if MUYA_TEST_HOOKS
    var currentSession: EditorSession? { url.flatMap { sessions[$0.path] } }
    private(set) var lastOpenMs = -1
    func debugToggleMarkdownEdit() { toggleMarkdownEdit() }
    func debugOpenAnyway() { openAnywayTapped() }
    #endif


    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        kindLabel.font = .systemFont(ofSize: 11)
        kindLabel.textColor = Token.textSecondary
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close viewer")
        closeButton.isBordered = false
        closeButton.bezelStyle = .texturedRounded
        closeButton.contentTintColor = Token.textSecondary
        closeButton.target = self
        closeButton.action = #selector(close)
        closeButton.toolTip = "Close and return to the terminal"
        separator.boxType = .separator
        editButton.isBordered = false; editButton.font = .systemFont(ofSize: 11, weight: .medium); editButton.contentTintColor = Token.textSecondary
        editButton.target = self; editButton.action = #selector(toggleMarkdownEdit); editButton.isHidden = true
        editButton.toolTip = "Edit this Markdown file as text, or go back to the rendered view"
        header.addSubview(editButton)
        for v in [nameLabel, kindLabel, closeButton, separator, header, editButton] { v.translatesAutoresizingMaskIntoConstraints = false }
        header.addSubview(nameLabel); header.addSubview(kindLabel); header.addSubview(closeButton)
        addSubview(header); addSubview(separator)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 34),
            nameLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            kindLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            kindLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            kindLabel.trailingAnchor.constraint(lessThanOrEqualTo: editButton.leadingAnchor, constant: -8),
            editButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10), editButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor), separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Opaque, so the terminal underneath never shows through the header.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    @objc private func close() { onClose?() }

    /// Bumped by every `show`: a slow read that finishes after the user opened another file is dropped.
    private var loadGeneration = 0

    /// What the background read found out about the file (nil probe = not a regular file, or unreadable).
    private struct Loaded {
        var probe: FileProbe.Result?
        var text: String?
        var truncated = false
        var editor: EditorOpen.Result?
    }

    func show(_ url: URL, kind: FileKind) {
        if openAnyway != url { openAnyway = nil }
        self.url = url
        self.kind = kind
        nameLabel.stringValue = url.lastPathComponent
        updateEditButton()
        loadGeneration += 1
        let gen = loadGeneration
        // An open document keeps its text, caret, scroll and unsaved edits while another file is in view.
        if let s = sessions[url.path], kind == .text || (kind == .markdown && markdownEditing.contains(url.path)) {
            install(s.container, note: s.note, name: url.lastPathComponent)
            s.reconcile(); s.refreshChrome()
            DispatchQueue.main.async { s.focus() }
            return
        }
        install(loadingView(), note: "Loading…", name: url.lastPathComponent)
        let anyway = openAnyway == url
        #if MUYA_TEST_HOOKS
        let t0 = CFAbsoluteTimeGetCurrent()
        lastOpenMs = -1
        #endif
        let editing = markdownEditing.contains(url.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let loaded = ViewerPane.load(url, kind: kind, openAnyway: anyway, editing: editing)
            DispatchQueue.main.async {
                guard let self, gen == self.loadGeneration else { return }
                let (v, note) = self.build(url, kind: kind, loaded: loaded)
                self.install(v, note: note, name: url.lastPathComponent)
                #if MUYA_TEST_HOOKS
                self.lastOpenMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                #endif
            }
        }
    }

    /// Off the main thread: the file is opened non-blocking and only read when it is a regular file (never a FIFO / device).
    private static func load(_ url: URL, kind: FileKind, openAnyway: Bool, editing: Bool) -> Loaded {
        guard let p = FileProbe.probe(url) else { return Loaded(probe: nil) }
        var l = Loaded(probe: p)
        guard kind == .text || kind == .markdown, !p.binary else { return l }
        let mode = LargeFile.decide(size: p.size, binary: p.binary, markdown: kind == .markdown)
        if kind == .text || mode != .normal || editing { l.editor = EditorOpen.open(path: url.path, openAnyway: openAnyway); return l }
        guard mode != .prompt || openAnyway else { return l }
        let limit = p.size > LargeFile.promptBytes ? LargeFile.headBytes : LargeFile.promptBytes
        guard let data = FileProbe.readHead(url, limit: limit) else { return Loaded(probe: nil) }
        l.truncated = data.count > limit
        let slice = l.truncated ? data.prefix(limit) : data
        l.text = String(data: slice, encoding: .utf8) ?? String(decoding: slice, as: UTF8.self)
        return l
    }

    private func build(_ url: URL, kind: FileKind, loaded: Loaded) -> (NSView, String) {
        guard let p = loaded.probe else { return message("This is not a regular file (or it could not be read), so it is not opened.") }
        switch kind {
        case .image: return imageView(url)
        case .pdf: return pdfView(url)
        case .markdown: return markdownView(url, probe: p, loaded: loaded)
        case .text: return editorView(url, probe: p, loaded: loaded)
        case .other: return otherView(url, probe: p)
        }
    }

    private func loadingView() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        let l = NSTextField(labelWithString: "Loading…")
        l.textColor = Token.textSecondary
        let row = NSStackView(views: [spinner, l])
        row.orientation = .horizontal
        row.spacing = 8
        let box = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([row.centerXAnchor.constraint(equalTo: box.centerXAnchor), row.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
        return box
    }

    private func install(_ v: NSView, note: String, name: String) {
        content?.removeFromSuperview()
        kindLabel.stringValue = note
        // Spoken name of the content: a screen reader would otherwise meet an anonymous text area / image.
        let spoken = "\(note.isEmpty ? "File" : note), \(name)"
        func label(_ view: NSView) {
            if view is NSTextView { view.setAccessibilityLabel(spoken) }
            for sub in view.subviews { label(sub) }
        }
        label(v)
        if !(v is NSScrollView) { v.setAccessibilityLabel(spoken) }
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: separator.bottomAnchor), v.leadingAnchor.constraint(equalTo: leadingAnchor),
            v.trailingAnchor.constraint(equalTo: trailingAnchor), v.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        content = v
    }

    #if MUYA_TEST_HOOKS
    /// Measurement hook: scrolls the text to `fraction` (0 = top, 1 = end), forces layout + drawing, returns the ms it took.
    func scrollForTest(fraction: CGFloat) -> Int {
        guard let sv = content as? NSScrollView, let doc = sv.documentView else { return -1 }
        let t0 = CFAbsoluteTimeGetCurrent()
        let y = max(0, (doc.frame.height - sv.contentView.bounds.height) * fraction)
        sv.contentView.scroll(to: NSPoint(x: 0, y: y)); sv.reflectScrolledClipView(sv.contentView)
        sv.displayIfNeeded()
        return Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }
    #endif

    /// What the viewer currently shows, for the test hook.
    var contentDescription: String {
        guard let c = content else { return "none" }
        return "\(kind) \(type(of: c)) \(kindLabel.stringValue)"
    }

    // MARK: Image

    private func imageView(_ url: URL) -> (NSView, String) {
        guard let img = NSImage(contentsOf: url) else { return message("This image could not be read.") }
        let view = NSImageView(image: img)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = true
        let rep = img.representations.first
        let px = rep.map { "\($0.pixelsWide)×\($0.pixelsHigh)" } ?? "\(Int(img.size.width))×\(Int(img.size.height))"
        return (view, "Image · \(px)")
    }

    // MARK: PDF

    private func pdfView(_ url: URL) -> (NSView, String) {
        guard let doc = PDFDocument(url: url) else { return message("This PDF could not be read.") }
        let v = PDFView()
        v.document = doc
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .underPageBackgroundColor
        // PDFView is sized after it is added; fit the width once it has its real size.
        DispatchQueue.main.async { v.autoScales = false; v.scaleFactor = v.scaleFactorForSizeToFit; v.autoScales = true; v.go(to: doc.page(at: 0)!) }
        return (v, "PDF · \(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s")")
    }

    // MARK: Text, Markdown, other

    private func scrollText(_ attr: NSAttributedString, monospaced: Bool, inset: CGFloat) -> NSScrollView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: inset, height: inset)
        tv.isAutomaticLinkDetectionEnabled = false
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textStorage?.setAttributedString(attr)
        let s = NSScrollView()
        s.documentView = tv
        s.hasVerticalScroller = true
        s.drawsBackground = true
        s.backgroundColor = .textBackgroundColor
        return s
    }

    /// Text files open in the editor. A file over the prompt size asks first; binary falls to the hex view.
    private func editorView(_ url: URL, probe p: FileProbe.Result, loaded: Loaded) -> (NSView, String) {
        switch loaded.editor {
        case .prompt(let size): return promptView(url, size: size)
        case .binary: return otherView(url, probe: p)
        case .document(let doc, let text, let displayNote):
            let s = EditorSession(doc: doc, text: text, displayNote: displayNote)
            s.onChange = { [weak self] in self?.onDirtyChange?() }
            s.autoSaveEnabled = { [weak self] in self?.autoSaveEnabled() ?? false }
            sessions[url.path] = s
            var note = s.note
            if p.size >= LargeFile.largeBytes { note += " · large file (\(ByteCountFormatter.string(fromByteCount: Int64(p.size), countStyle: .file))): highlighting, map and diff are off" }
            if doc.features.readOnly == .truncated { note += " · first \(ByteCountFormatter.string(fromByteCount: Int64(LargeFile.headBytes), countStyle: .file)) only, read-only" }
            s.note = note
            DispatchQueue.main.async { s.focus() }
            return (s.container, note)
        case .unreadable, nil: return message("This file could not be read.")
        }
    }

    private func markdownView(_ url: URL, probe p: FileProbe.Result, loaded: Loaded) -> (NSView, String) {
        if loaded.editor != nil { return editorView(url, probe: p, loaded: loaded) }   // editing, or too big to render
        guard let text = loaded.text else { return message("This file could not be read.") }
        let attr = MarkdownRenderer.render(MarkdownParser.parse(sessions[url.path]?.currentText ?? text))
        return (scrollText(attr, monospaced: false, inset: 22), "Markdown")
    }

    private func promptView(_ url: URL, size: Int) -> (NSView, String) {
        let sz = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let label = NSTextField(wrappingLabelWithString: "This file is large (\(sz)). Open the first \(ByteCountFormatter.string(fromByteCount: Int64(LargeFile.headBytes), countStyle: .file)) read-only, or use another app.")
        label.font = .systemFont(ofSize: 13)
        label.textColor = Token.textSecondary
        let anyway = NSButton(title: "Open Anyway", target: self, action: #selector(openAnywayTapped))
        anyway.bezelStyle = .rounded
        anyway.keyEquivalent = "\r"
        let ext = NSButton(title: "Open with Default App", target: self, action: #selector(openExternally))
        ext.bezelStyle = .rounded
        let row = NSStackView(views: [anyway, ext])
        row.orientation = .horizontal
        row.spacing = 12
        let col = NSStackView(views: [label, row])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 12
        let box = NSView()
        col.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: box.topAnchor, constant: 18), col.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            col.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -18),
        ])
        return (box, "Large file · \(sz)")
    }

    @objc private func openAnywayTapped() { if let url { openAnyway = url; show(url, kind: kind) } }

    private func otherView(_ url: URL, probe p: FileProbe.Result) -> (NSView, String) {
        let size = p.size
        let hex = HexDump.format(p.head.prefix(256))
        let box = NSView()
        let label = NSTextField(wrappingLabelWithString: "No built-in viewer for this file type.")
        label.font = .systemFont(ofSize: 13)
        label.textColor = Token.textSecondary
        let btn = NSButton(title: "Open with Default App", target: self, action: #selector(openExternally))
        btn.bezelStyle = .rounded
        let mono = scrollText(NSAttributedString(string: hex, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.textColor]), monospaced: true, inset: 12)
        let top = NSStackView(views: [label, btn])
        top.orientation = .horizontal
        top.spacing = 12
        for v in [top, mono] { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: box.topAnchor, constant: 14), top.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            mono.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12), mono.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            mono.trailingAnchor.constraint(equalTo: box.trailingAnchor), mono.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return (box, "Binary · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) · hex of the first 256 bytes")
    }

    @objc private func openExternally() {
        guard let url else { return }
        guard ExecutableGuard.needsConfirmation(url) else { NSWorkspace.shared.open(url); return }
        // Something that can run code: the safe answer is the default button.
        let alert = NSAlert()
        alert.messageText = "Open “\(url.lastPathComponent)” with its default app?"
        alert.informativeText = "This kind of file can run code on your Mac. Reveal it in Finder to look at it first, or open it only if you trust where it came from."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([url])
        case .alertSecondButtonReturn: NSWorkspace.shared.open(url)
        default: break
        }
    }

    private func message(_ text: String) -> (NSView, String) {
        let l = NSTextField(wrappingLabelWithString: text)
        l.alignment = .center
        l.textColor = Token.textSecondary
        let box = NSView()
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([l.centerXAnchor.constraint(equalTo: box.centerXAnchor), l.centerYAnchor.constraint(equalTo: box.centerYAnchor)])
        return (box, "Error")
    }
}

enum HexDump {
    /// `00000000  48 65 6c 6c 6f ...  |Hello...|` lines of 16 bytes.
    static func format(_ d: Data) -> String {
        var lines: [String] = []
        let bytes = [UInt8](d)
        for off in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[off ..< min(off + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let pad = String(repeating: " ", count: (16 - chunk.count) * 3)
            let asc = String(chunk.map { $0 >= 0x20 && $0 < 0x7f ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  ", off) + hex + pad + "  |" + asc + "|")
        }
        return lines.joined(separator: "\n")
    }
}

enum MarkdownRenderer {
    private static let body = NSFont.systemFont(ofSize: 14)
    private static let mono = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    /// Inline Markdown (bold, italic, code, links) through AttributedString; falls back to plain text.
    static func inline(_ text: String, base: NSFont, color: NSColor = .textColor) -> NSAttributedString {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let a = try? AttributedString(markdown: text, options: opts) else {
            return NSAttributedString(string: text, attributes: [.font: base, .foregroundColor: color])
        }
        let out = NSMutableAttributedString()
        for run in a.runs {
            let piece = String(a[run.range].characters)
            var font = base
            if let i = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if i.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if i.contains(.emphasized) { traits.insert(.italic) }
                if i.contains(.code) { font = NSFont.monospacedSystemFont(ofSize: base.pointSize - 1, weight: .regular) }
                else if !traits.isEmpty { font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize) ?? base }
            }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if run.inlinePresentationIntent?.contains(.code) == true { attrs[.backgroundColor] = NSColor.quaternaryLabelColor }
            if let link = run.link { attrs[.link] = link; attrs[.foregroundColor] = NSColor.linkColor }
            if run.inlinePresentationIntent?.contains(.strikethrough) == true { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }

    static func render(_ blocks: [MarkdownBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func para(_ spacingAfter: CGFloat, indent: CGFloat = 0, first: CGFloat? = nil, before: CGFloat = 0) -> NSMutableParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = spacingAfter
            p.paragraphSpacingBefore = before
            p.headIndent = indent
            p.firstLineHeadIndent = first ?? indent
            p.lineSpacing = 2
            return p
        }
        func add(_ s: NSAttributedString, style: NSParagraphStyle) {
            let m = NSMutableAttributedString(attributedString: s)
            m.append(NSAttributedString(string: "\n"))
            m.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: m.length))
            out.append(m)
        }
        for b in blocks {
            switch b {
            case let .heading(level, text):
                let size: CGFloat = [26, 21, 17, 15, 14, 13][min(max(level, 1), 6) - 1]
                add(inline(text, base: .systemFont(ofSize: size, weight: level <= 2 ? .bold : .semibold)), style: para(8, before: level <= 2 ? 10 : 4))
            case let .paragraph(text):
                add(inline(text, base: body), style: para(10))
            case let .bullet(depth, text):
                let ind = CGFloat(18 + depth * 18)
                let s = NSMutableAttributedString(string: "•\t", attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor])
                s.append(inline(text, base: body))
                let p = para(3, indent: ind, first: ind - 14)
                p.tabStops = [NSTextTab(textAlignment: .left, location: ind)]
                add(s, style: p)
            case let .numbered(depth, n, text):
                let ind = CGFloat(24 + depth * 18)
                let s = NSMutableAttributedString(string: "\(n).\t", attributes: [.font: body, .foregroundColor: NSColor.secondaryLabelColor])
                s.append(inline(text, base: body))
                let p = para(3, indent: ind, first: ind - 22)
                p.tabStops = [NSTextTab(textAlignment: .left, location: ind)]
                add(s, style: p)
            case let .code(_, text):
                let s = NSAttributedString(string: text, attributes: [.font: mono, .foregroundColor: NSColor.textColor, .backgroundColor: NSColor.quaternaryLabelColor])
                add(s, style: para(12, indent: 12, first: 12, before: 2))
            case let .quote(text):
                add(inline(text, base: body, color: .secondaryLabelColor), style: para(10, indent: 16, first: 16))
            case .rule:
                add(NSAttributedString(string: String(repeating: "─", count: 40), attributes: [.font: body, .foregroundColor: NSColor.separatorColor]), style: para(10))
            }
        }
        return out
    }
}
