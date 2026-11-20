// File tree panel: an NSOutlineView over the selected session's working directory. Children load
// lazily on first expand; an FSEvents stream (one per opened root) keeps the rows in step with the
// disk; the context menu offers Open, Copy Path, Reveal in Finder, Open in Terminal Here, Rename and
// Move to Trash. Everything pure (model, debounce, path rules) lives in Logic/FileLogic.swift.

import AppKit
import CoreServices
import UniformTypeIdentifiers

/// FSEvents stream over one directory tree. Callbacks arrive on the main queue after `latency`.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(path: String, latency: TimeInterval = 0.1, handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.handler(Array(list.prefix(count)))
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        guard FSEventStreamStart(s) else { FSEventStreamInvalidate(s); FSEventStreamRelease(s); return nil }
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

/// Names in `dir` that git ignores. Only asked when a `.git` exists above `dir` (so machines without
/// git tooling never run the /usr/bin/git shim).
enum GitIgnore {
    static func hasRepository(above dir: URL) -> Bool {
        var d = dir
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: d.appendingPathComponent(".git").path) { return true }
            let up = d.deletingLastPathComponent()
            if up.path == d.path { return false }
            d = up
        }
    }

    /// Runs `git check-ignore` with a 2 s ceiling. The main thread waits on a semaphore, not on
    /// `Process.waitUntilExit()`, which spins the run loop and would let other events (debug commands, timers)
    /// run in the middle of a tree update.
    static func ignored(_ names: [String], in dir: URL) -> Set<String> {
        guard !names.isEmpty, names.count <= 3000, hasRepository(above: dir) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = GitArgs.hardened(["-C", dir.path, "check-ignore", "--stdin", "-z"])
        p.environment = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        nonisolated(unsafe) var result = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            inp.fileHandleForWriting.write(Data((names.joined(separator: "\0") + "\0").utf8))
            try? inp.fileHandleForWriting.close()
            result = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut { p.terminate(); return [] }
        return Set(String(decoding: result, as: UTF8.self).split(separator: "\0").map(String.init))
    }
}

final class FileRowView: NSTableCellView {
    /// The active workspace root (the selected agent's folder): indigo border and fill (`border-indigo-500` of the tree's root header).
    var emphasis = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard emphasis else { return }
        let r = NSRect(x: -14, y: bounds.minY, width: bounds.width + 14, height: bounds.height).insetBy(dx: 1, dy: 0.5), p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ThemeRaw.indigo950.withAlphaComponent(0.5) : ThemeRaw.indigo50 }.setFill(); p.fill()
        NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ThemeRaw.indigo500 : ThemeRaw.indigo500 }.setStroke(); p.lineWidth = 1; p.stroke()
    }
    let icon = NSImageView()
    var iconLeading: NSLayoutConstraint!
    let label = NSTextField(labelWithString: "")
    /// The agent that works in a workspace root (FileTree.tsx: 8 px mono, indigo, at most 80 px).
    let chip = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = false
        label.font = ThemeFont.mono(12)
        chip.font = ThemeFont.mono(8, .semibold); chip.lineBreakMode = .byTruncatingTail; chip.isHidden = true
        chip.textColor = NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ThemeRaw.indigo300 : ThemeRaw.indigo700 }
        chip.drawsBackground = true   // border-indigo-200 bg-indigo-50 / dark: indigo-950 at 40 % of the web chip (the border is left out)
        chip.backgroundColor = NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ThemeRaw.indigo950.withAlphaComponent(0.55) : ThemeRaw.indigo50 }
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.translatesAutoresizingMaskIntoConstraints = false; addSubview(chip)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        icon.imageScaling = .scaleProportionallyDown
        for v in [icon, label] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            chip.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 80),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
            }

    required init?(coder: NSCoder) { fatalError() }
}

final class FileOutline: NSOutlineView {
    var isHeaderRow: ((Int) -> Bool)?
    /// The triangle of a root row is shown too: a workspace folder collapses and expands like any other folder.
    func disclosureFrame(row: Int) -> NSRect { super.frameOfOutlineCell(atRow: row) }
    var onKey: ((NSEvent) -> Bool)?
    /// A single click on a workspace root row (outside its triangle): the panel collapses / expands it.
    var onHeaderClick: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil), row = self.row(at: p)
        let onHeader = row >= 0 && isHeaderRow?(row) == true && !disclosureFrame(row: row).contains(p)
        super.mouseDown(with: event)   // selection, the triangle, double-click; returns after the release
        if onHeader, event.clickCount == 1 { onHeaderClick?(row) }
    }
    /// The first click works even when the window was not key (coming back from another app), like the sidebar's own rows.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }
}

final class FileTreePanel: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let view = NSView()
    let outline = FileOutline()
    private let title = NSTextField(labelWithString: "Files")
    private let pathLabel = NSTextField(labelWithString: "")
    private let hiddenButton = NSButton()
    private let empty = NSTextField(labelWithString: "")

    private(set) var root: FileNode?
    /// Multi-root mode (today's tree: one root per workspace folder, each with the agent working in it); `root` is then the first one.
    private(set) var roots: [FileNode] = []
    private(set) var multiMode = false
    /// The workspace of the selected agent: its root row is marked.
    var activeRoot: String? { didSet { if activeRoot != oldValue { outline.reloadData(); expandRoots(); restoreAll() } } }
    private var chips: [String: String] = [:]
    private(set) var collapsedRoots = CollapsedRoots()
    /// Expands every workspace root except the ones the operator collapsed.
    private func expandRoots() { for r in roots where collapsedRoots.isExpanded(r.path) { outline.expandItem(r) } }
    private var watchers: [DirectoryWatcher] = []
    private var headStack: NSStackView!
    private var scroll: NSScrollView!
    private var scrollTop: NSLayoutConstraint!
    private(set) var showHidden = false
    private var watcher: DirectoryWatcher?
    private var coalescer = EventCoalescer(interval: 0.15)
    private var flushTimer: Timer?
    private var iconCache: [String: NSImage] = [:]
    weak var window: NSWindow?
    var home = NSHomeDirectory()
    /// Test hook: report errors in the return value instead of a sheet.
    var silent = false

    var onOpen: ((URL, FileKind) -> Void)?
    var onTerminalHere: ((String) -> Void)?

    /// Counters for the debug hook / AC14: how many reloads ran and when the last change reached the rows.
    private(set) var reloads = 0
    private(set) var lastReloadAt: TimeInterval = 0
    private(set) var eventsSeen = 0
    /// Where the last Move to Trash put the item (the test hook prints it).
    private(set) var lastTrashed: URL?

    override init() {
        super.init()
        build()
    }

    // MARK: Layout

    private func build() {
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = Token.textSecondary
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = Token.textSecondary
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.maximumNumberOfLines = 1
        hiddenButton.setButtonType(.pushOnPushOff)
        hiddenButton.bezelStyle = .texturedRounded
        hiddenButton.isBordered = false
        hiddenButton.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Show hidden files")
        hiddenButton.alternateImage = NSImage(systemSymbolName: "eye", accessibilityDescription: "Hide hidden files")
        hiddenButton.contentTintColor = Token.textSecondary
        hiddenButton.toolTip = "Show hidden files"
        hiddenButton.target = self
        hiddenButton.action = #selector(toggleHiddenAction)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.setAccessibilityLabel("File tree")
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowHeight = 21; outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 15
        outline.isHeaderRow = { [weak self] r in guard let self, let it = self.outline.item(atRow: r) else { return false }; return self.isRootNode(it) }
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.onHeaderClick = { [weak self] row in if let self, let n = self.outline.item(atRow: row) as? FileNode { self.toggleRoot(n) } }
        outline.menu = { let m = NSMenu(); m.delegate = self; return m }()
        outline.onKey = { [weak self] e in self?.key(e) ?? false }
        scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        empty.font = .systemFont(ofSize: 12)
        empty.textColor = Token.textSecondary
        empty.alignment = .center

        let top = NSStackView(views: [title, NSView(), hiddenButton])
        top.orientation = .horizontal
        let head = NSStackView(views: [top, pathLabel])
        headStack = head
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 2
        top.translatesAutoresizingMaskIntoConstraints = false
        for v in [head, scroll as NSView, empty] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            head.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            head.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            top.widthAnchor.constraint(equalTo: head.widthAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        scrollTop = scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 4)
        scrollTop.isActive = true
    }

    /// One root per workspace folder, all expanded; `chip` is the name of the agent working there. Same folders in the same order: nothing reloads.
    func setRoots(_ entries: [(path: String, chip: String?)]) {
        let valid = entries.filter { FileManager.default.fileExists(atPath: $0.0) }
        var seen = Set<String>(); let unique = valid.filter { seen.insert($0.path).inserted }
        let newChips = Dictionary(uniqueKeysWithValues: unique.compactMap { e in e.chip.map { (e.path, $0) } })
        if multiMode, unique.map(\.path) == roots.map(\.path) {
            if newChips != chips { chips = newChips; outline.reloadData(); expandRoots(); restoreAll() }
            return
        }
        watcher?.stop(); watcher = nil; watchers.forEach { $0.stop() }; watchers = []
        flushTimer?.invalidate(); flushTimer = nil
        coalescer = EventCoalescer(interval: 0.15)
        if !multiMode {   // the header of the single-root panel makes room for the section header of the sidebar
            headStack.isHidden = true
            scrollTop.isActive = false
            scrollTop = scroll.topAnchor.constraint(equalTo: view.topAnchor, constant: 5); scrollTop.isActive = true
        }
        multiMode = true
        chips = newChips
        roots = unique.map { FileNode(url: URL(fileURLWithPath: $0.path), isDirectory: true) }
        for r in roots { load(r) }
        root = roots.first
        pathLabel.stringValue = root?.path.abbreviatingHome(home) ?? ""
        empty.stringValue = roots.isEmpty ? "No workspace yet." : ""
        outline.reloadData()
        expandRoots()
        restoreAll()
        watchers = roots.compactMap { r in DirectoryWatcher(path: r.path) { [weak self] paths in self?.changed(paths) } }
    }
    private func restoreAll() { for r in roots { restoreExpansion(r) } }
    /// The root node a path is inside (multi-root), or the single root.
    private func owner(of path: String) -> FileNode? {
        (multiMode ? roots : root.map { [$0] } ?? []).filter { path == $0.path || path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
    }
    private func findNode(_ dir: String) -> FileNode? {
        guard let r = owner(of: dir) else { return nil }
        return dir == r.path ? r : FileTreeModel.find(dir, in: r)
    }

    // MARK: Root

    func setRoot(_ path: String?) {
        if path == root?.path { return }
        watcher?.stop(); watcher = nil
        flushTimer?.invalidate(); flushTimer = nil
        coalescer = EventCoalescer(interval: 0.15)
        guard let path, FileManager.default.fileExists(atPath: path) else {
            root = nil
            pathLabel.stringValue = ""
            empty.stringValue = path == nil ? "No session" : "Folder not found"
            outline.reloadData()
            return
        }
        let node = FileNode(url: URL(fileURLWithPath: path), isDirectory: true)
        load(node)
        root = node
        pathLabel.stringValue = path.abbreviatingHome(home)
        pathLabel.toolTip = path
        outline.reloadData()
        updateEmpty()
        watcher = DirectoryWatcher(path: path) { [weak self] paths in self?.changed(paths) }
    }

    private func updateEmpty() {
        if multiMode { empty.stringValue = roots.isEmpty ? "No workspace yet." : ""; return }
        empty.stringValue = (root?.children?.isEmpty ?? true) && root != nil ? "Empty folder" : ""
    }

    private func load(_ node: FileNode) {
        var nodes = FileTreeModel.list(node.url, showHidden: showHidden)
        // The listing is instant; git's answer is not (up to its 2 s ceiling), so the main thread never waits for it:
        // rows start with the last known answer for this folder and are corrected when git replies.
        let known = ignoredCache[node.path] ?? []
        for n in nodes where known.contains(n.name) { n.ignored = true }
        nodes = FileTreeModel.sorted(nodes)
        node.setChildren(nodes)
        scheduleIgnoreCheck(node)
    }

    /// Last answer of `git check-ignore` per folder path.
    private var ignoredCache: [String: Set<String>] = [:]
    private let ignoreQueue = DispatchQueue(label: "filetree.ignore", qos: .utility)
    private var ignoreInflight = Set<String>()
    private var ignoreAgain = Set<String>()

    /// Asks git (off the main thread) which children of `node` are ignored, then dims / undims the rows that changed.
    /// One check per folder at a time; a request that arrives meanwhile runs once more afterwards.
    private func scheduleIgnoreCheck(_ node: FileNode) {
        let path = node.path
        if ignoreInflight.contains(path) { ignoreAgain.insert(path); return }
        ignoreInflight.insert(path)
        let names = (node.children ?? []).map(\.name)
        let url = node.url
        ignoreQueue.async { [weak self] in
            let ig = GitIgnore.ignored(names, in: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyIgnored(ig, forPath: path) }
            }
        }
    }

    private func applyIgnored(_ ig: Set<String>, forPath path: String) {
        ignoreInflight.remove(path)
        ignoredCache[path] = ig
        if let node = findNode(path), node.isLoaded {
            var rows = IndexSet()
            for k in node.children ?? [] where k.ignored != ig.contains(k.name) {
                k.ignored = ig.contains(k.name)
                let r = outline.row(forItem: k)
                if r >= 0 { rows.insert(r) }
            }
            if !rows.isEmpty { outline.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0)) }
            if ignoreAgain.remove(path) != nil { scheduleIgnoreCheck(node) }
        } else {
            ignoreAgain.remove(path)
        }
    }

    @objc private func toggleHiddenAction() { setShowHidden(hiddenButton.state == .on) }

    func setShowHidden(_ on: Bool) {
        showHidden = on
        hiddenButton.state = on ? .on : .off
        hiddenButton.toolTip = on ? "Hide hidden files" : "Show hidden files"
        for r in (multiMode ? roots : root.map { [$0] } ?? []) { reloadLoaded(r) }
        outline.reloadData()
        if multiMode { expandRoots(); restoreAll() } else if let root { restoreExpansion(root) }
        updateEmpty()
    }

    /// Re-lists every loaded directory (after the hidden toggle).
    private func reloadLoaded(_ node: FileNode) {
        guard node.isDirectory, node.isLoaded else { return }
        FileTreeModel.refresh(node, showHidden: showHidden, ignored: ignoredCache[node.path] ?? [])
        scheduleIgnoreCheck(node)
        for k in node.children ?? [] { reloadLoaded(k) }
    }

    private var expandedPaths = Set<String>()
    private func restoreExpansion(_ node: FileNode) {
        for k in node.children ?? [] where k.isDirectory && expandedPaths.contains(k.path) {
            outline.expandItem(k)
            restoreExpansion(k)
        }
    }

    // MARK: Watcher

    private func changed(_ paths: [String]) {
        eventsSeen += paths.count
        coalescer.add(paths, now: CACurrentMediaTime())
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTimer?.invalidate()
        guard let d = coalescer.due(now: CACurrentMediaTime()) else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: d, repeats: false) { [weak self] _ in self?.flush() }
    }

    private func flush() {
        guard let batch = coalescer.flush(now: CACurrentMediaTime()), root != nil else { scheduleFlush(); return }
        // Reload each affected directory once. A changed directory entry itself also refreshes its parent.
        var dirs = Set<String>()
        for p in batch {
            let parent = (p as NSString).deletingLastPathComponent
            dirs.insert(parent)
            if FileManager.default.fileExists(atPath: p), (try? URL(fileURLWithPath: p).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { dirs.insert(p) }
        }
        for d in dirs.sorted(by: { $0.count < $1.count }) {
            guard let node = findNode(d), node.isLoaded else { continue }
            reloadDirectory(node)
        }
        scheduleFlush()
    }

    func reloadDirectory(_ node: FileNode) {
        let (added, removed) = FileTreeModel.refresh(node, showHidden: showHidden, ignored: ignoredCache[node.path] ?? [])
        scheduleIgnoreCheck(node)   // a changed .gitignore or new files: git answers later and the rows are corrected
        reloads += 1
        guard !added.isEmpty || !removed.isEmpty else { return }
        lastReloadAt = CACurrentMediaTime()
        outline.reloadItem(node === root && !multiMode ? nil : node, reloadChildren: true)
        restoreExpansion(node)
        updateEmpty()
    }

    /// Reloads one directory by path right now (tests, and after our own rename / trash).
    func reload(path: String) {
        guard let n = findNode(path), n.isLoaded else { return }
        reloadDirectory(n)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil, multiMode { return roots.count }
        guard let node = (item as? FileNode) ?? root else { return 0 }
        if !node.isLoaded { load(node) }
        return node.children?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil, multiMode { return roots[index] }
        let node = (item as? FileNode) ?? root!
        return node.children![index]
    }

    private func isRootNode(_ item: Any) -> Bool { multiMode && roots.contains(where: { $0 === (item as AnyObject) }) }
    /// Today's workspace header is a taller row than the file rows below it.
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { isRootNode(item) ? 23 : 21 }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.isDirectory ?? false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileRow")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? FileRowView) ?? { let c = FileRowView(frame: .zero); c.identifier = id; return c }()
        cell.label.stringValue = node.name
        cell.label.textColor = node.ignored ? Token.textSecondary.withAlphaComponent(0.6) : Token.text
        cell.icon.image = icon(for: node, open: node.isDirectory && outlineView.isItemExpanded(node))
        let chipText = multiMode ? chips[node.path] : nil
        cell.chip.stringValue = chipText.map { " \($0) " } ?? ""; cell.chip.isHidden = chipText == nil
        let isRoot = multiMode && roots.contains(where: { $0 === node })
        cell.emphasis = isRoot && node.path == activeRoot
        cell.label.font = ThemeFont.mono(12, isRoot ? .semibold : .regular)
        cell.iconLeading.constant = isRoot ? -2 : 2
        cell.toolTip = multiMode && roots.contains(where: { $0 === node }) ? node.path.abbreviatingHome(home) : nil
        cell.icon.alphaValue = node.ignored ? 0.5 : 1
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? FileNode { expandedPaths.insert(n.path); refreshIcon(of: n); if isRootNode(n) { collapsedRoots.set(n.path, expanded: true) } }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let n = notification.userInfo?["NSObject"] as? FileNode { expandedPaths.remove(n.path); refreshIcon(of: n); if isRootNode(n) { collapsedRoots.set(n.path, expanded: false) } }
    }
    /// A folder shows the open or the closed folder (lucide Folder / FolderOpen).
    private func refreshIcon(of n: FileNode) {
        let row = outline.row(forItem: n)
        guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileRowView else { return }
        cell.icon.image = icon(for: n, open: outline.isItemExpanded(n))
    }

    /// lucide Folder / FolderOpen (indigo) and FileText (neutral), like today's tree rows (14 px).
    private func icon(for node: FileNode, open: Bool = false) -> NSImage {
        let key = node.isDirectory ? (open ? "\u{0}open" : "\u{0}dir") : "\u{0}file"
        if let i = iconCache[key] { return i }
        let paths: [String]
        if node.isDirectory { paths = open ? GlyphIcon.folderOpenPaths : ["M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"] }
        else { paths = ["M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z", "M14 2v4a2 2 0 0 0 2 2h4", "M10 9H8", "M16 13H8", "M16 17H8"] }
        let color = NSColor(name: nil) { a in
            let dark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return node.isDirectory ? (dark ? ThemeRaw.indigo400 : ThemeRaw.indigo500) : Theme.dynamic(.textMuted)
        }
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: 1, y: 1)
            GlyphIcon.paths(paths).draw(in: ctx, size: 14, color: color, stroke: 2)
            return true
        }
        iconCache[key] = img
        return img
    }

    // MARK: Actions

    private func clickedNode() -> FileNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        return row >= 0 ? outline.item(atRow: row) as? FileNode : nil
    }

    /// One click on a workspace root row collapses/expands it (its triangle does the same by itself); other rows open on double-click.
    func toggleRoot(_ n: FileNode) { if outline.isItemExpanded(n) { outline.collapseItem(n) } else { outline.expandItem(n) } }
    @objc private func doubleClicked() { if let n = clickedNode(), !isRootNode(n) { open(n) } }

    private func key(_ e: NSEvent) -> Bool {
        guard let n = clickedNode() ?? (outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? FileNode : nil) else { return false }
        switch e.keyCode {
        case 36, 76: open(n); return true // return / enter
        case 51 where e.modifierFlags.contains(.command): trash(n); return true // ⌘⌫
        default: return false
        }
    }

    func open(_ node: FileNode) {
        if node.isDirectory {
            if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
        } else {
            onOpen?(node.url, FileKind.detect(node.url))
        }
    }

    @objc func menuOpen() { if let n = clickedNode() { open(n) } }
    @objc func menuCopyPath() { if let n = clickedNode() { copyPath(n.url) } }
    @objc func menuReveal() { if let n = clickedNode() { NSWorkspace.shared.activateFileViewerSelecting([n.url]) } }
    @objc func menuTerminal() {
        if let n = clickedNode() { onTerminalHere?(PathActions.terminalDirectory(for: n.url, isDirectory: n.isDirectory)) }
    }
    @objc func menuRename() { if let n = clickedNode() { promptRename(n) } }
    @objc func menuTrash() { if let n = clickedNode() { trash(n) } }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func promptRename(_ node: FileNode) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename “\(node.name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = node.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            self?.rename(node, to: field.stringValue)
        }
    }

    @discardableResult
    func rename(_ node: FileNode, to name: String) -> String? {
        do {
            _ = try PathActions.rename(node.url, to: name)
            reload(path: (node.path as NSString).deletingLastPathComponent)
            return nil
        } catch {
            show(error: "\(error)", title: "Could not rename")
            return "\(error)"
        }
    }

    /// `confirm: false` is for the test hook only; the menu and ⌘⌫ always ask first.
    func trash(_ node: FileNode, confirm: Bool = true) {
        let go = { [weak self] in
            do {
                self?.lastTrashed = try PathActions.trash(node.url)
                self?.reload(path: (node.path as NSString).deletingLastPathComponent)
            } catch { self?.show(error: "\(error)", title: "Could not move to Trash") }
        }
        guard confirm, let window else { go(); return }
        let alert = NSAlert()
        alert.messageText = "Move “\(node.name)” to the Trash?"
        alert.informativeText = node.isDirectory ? "The folder and everything in it moves to the Trash. You can put it back from there." : "You can put it back from the Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { go() } }
    }

    private func show(error: String, title: String) {
        guard let window, !silent else { NSLog("file tree: \(title): \(error)"); return }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = error
        a.beginSheetModal(for: window)
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let n = clickedNode() else { return }
        func add(_ t: String, _ a: Selector) { menu.addItem(withTitle: t, action: a, keyEquivalent: "").target = self }
        add(n.isDirectory ? (outline.isItemExpanded(n) ? "Collapse" : "Expand") : "Open", #selector(menuOpen))
        menu.addItem(.separator())
        add("Copy Path", #selector(menuCopyPath))
        add("Reveal in Finder", #selector(menuReveal))
        add("Open in Terminal Here", #selector(menuTerminal))
        menu.addItem(.separator())
        add("Rename…", #selector(menuRename))
        add("Move to Trash…", #selector(menuTrash))
    }

    // MARK: Test hook helpers

    /// Visible rows as "depth<TAB>name[/]" lines, for the debug socket.
    /// "path<TAB>chip" per root (debug socket): the multi-root tree's top level.
    func rootSummary() -> String { roots.map { "\($0.path)\t\(chips[$0.path] ?? "")" }.joined(separator: "\n") }

    func visibleRows() -> [String] {
        (0 ..< outline.numberOfRows).compactMap { r in
            guard let n = outline.item(atRow: r) as? FileNode else { return nil }
            return "\(outline.level(forRow: r))\t\(n.name)\(n.isDirectory ? "/" : "")\(n.ignored ? "\tignored" : "")"
        }
    }

    func expand(path: String) -> Bool {
        guard let root = owner(of: path) else { return false }
        if path == root.path { return true }
        // Expand every directory from the root down to `path`.
        var node = root
        let rel = path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        for part in rel {
            if !node.isLoaded { load(node) }
            guard let next = node.children?.first(where: { $0.name == part && $0.isDirectory }) else { return false }
            outline.expandItem(next)
            node = next
        }
        return true
    }

    /// Selects the row of `path` (expanding parents) so menu actions act on it; false if it is not visible/known.
    @discardableResult
    func select(path: String) -> Bool {
        guard expand(path: (path as NSString).deletingLastPathComponent), let n = node(path: path) else { return false }
        let row = outline.row(forItem: n)
        guard row >= 0 else { return false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        return true
    }

    func menuTitles() -> [String] {
        guard let m = outline.menu else { return [] }
        menuNeedsUpdate(m)
        return m.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    func node(path: String) -> FileNode? {
        guard let root = owner(of: path) else { return nil }
        if path == root.path { return root }
        return FileTreeModel.find((path as NSString).deletingLastPathComponent, in: root)?.children?.first { $0.path == path }
    }
}
