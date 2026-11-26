// WP9 — the "New agent" dialog of today's Muya (src/components/NewAgentModal.tsx): tabs Claude Code / opencode / Terminal,
// WORKSPACE (editable + known folders + Browse), NAME, PERMISSION MODE (Claude), the agents-manager checkbox, BRANCH
// (a git worktree through `claude --worktree`), INITIAL PROMPT and FILES; Cancel / Launch agent. Launch opens a terminal in
// the folder and types the generated command into it, exactly the command the web dialog builds
// (src/lib/agent.ts buildAgentCommand). Rows with nothing behind them in the native app are left out (see the WP9 summary).

import AppKit

final class NewAgentSheet: NSObject {
    unowned let store: Store
    let panel = EditorPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
    var onClose: (() -> Void)?
    private weak var parent: NSWindow?
    private var scrim: ModalScrim?
    private var frameParts: ModalFrame!

    private let tabs = IconSegmented(options: ["Claude Code", "opencode", "Terminal"])
    private let workspace = NSComboBox()
    private let name = Kit.field("Tab name", label: "Agent name")
    private let mode = ThemedSelect(NewAgentCommand.modes.map(\.label), selected: 0)
    private let modeHint = ThemedText.helper("")
    private let manager = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let channels = NSButton(checkboxWithTitle: "Load Muya channel", target: nil, action: nil)
    private let channelsHint = ThemedText.helper("")
    /// nil while the daemon is asked, then whether the installed Claude takes the channel flag (agents.channels_supported).
    private var channelsOk: Bool? { didSet { updateChannels() } }
    /// Absolute paths of the CLIs muyad found AND probed (agents.bins); nil = not answered yet. A Finder-launched app and
    /// the daemon's sessions have a minimal PATH, so a bare `claude` would not be found there.
    private var bins: (claude: String?, opencode: String?)?
    private let branch = Kit.field("feature/my-task", label: "Branch")
    private let prompt = DialogTextView()
    private let filesLabel = ThemedText.helper("")
    private let error = NSTextField(wrappingLabelWithString: "")
    private var files: [String] = []
    private var groups: [String: NSView] = [:]
    private var channelsRow: NSStackView!
    private let launch = ModalButton("Launch agent", style: .primary, height: 32)

    init(store: Store, workspaces: [String], initial: String) {
        self.store = store
        super.init()
        build(workspaces: workspaces, initial: initial)
    }

    private func build(workspaces: [String], initial: String) {
        panel.title = "New agent"
        panel.onSubmit = { [weak self] in self?.launchTapped() }
        panel.onCancel = { [weak self] in self?.cancelTapped() }
        tabs.target = self; tabs.action = #selector(kindChanged); tabs.selected = 0
        tabs.setSpokenLabel("Agent type")
        workspace.addItems(withObjectValues: workspaces); workspace.stringValue = initial; workspace.completes = false   // the inline-completion popup swallowed the first click on Launch after typing a path
        workspace.placeholderString = "/path/to/project"; workspace.setSpokenLabel("Workspace folder")
        workspace.font = ThemeFont.mono(13)
        // Opens on Settings > Default permission mode; a different pick here is for this session only and is never written back.
        mode.plain = true; mode.selected = mode.titles.firstIndex(of: NewAgentCommand.mode(for: store.permissionMode).label) ?? 0
        mode.onChange = { [weak self] _ in self?.kindChanged() }; mode.setSpokenLabel("Permission mode")
        manager.target = self; manager.action = #selector(kindChanged); manager.setSpokenLabel("Open the agents manager instead")
        branch.font = ThemeFont.mono(12); name.delegate = nil
        prompt.isRichText = false; prompt.font = ThemeFont.mono(12); prompt.textColor = Theme.dynamic(.text); prompt.drawsBackground = false
        prompt.insertionPointColor = Theme.dynamic(.text)
        prompt.isAutomaticQuoteSubstitutionEnabled = false; prompt.isAutomaticDashSubstitutionEnabled = false
        prompt.textContainerInset = NSSize(width: 6, height: 8); prompt.isVerticallyResizable = true; prompt.autoresizingMask = [.width]
        prompt.setAccessibilityLabel("Initial prompt")
        let promptScroll = NSScrollView(); promptScroll.documentView = prompt; promptScroll.hasVerticalScroller = true
        promptScroll.drawsBackground = false; promptScroll.borderType = .noBorder; promptScroll.scrollerStyle = .overlay
        let promptFrame = InputFrame(); promptFrame.translatesAutoresizingMaskIntoConstraints = false
        Kit.pin(promptScroll, in: promptFrame, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        promptFrame.heightAnchor.constraint(equalToConstant: 96).isActive = true
        error.font = ThemeFont.sans(12); error.textColor = Theme.dynamic(.dangerText); error.maximumNumberOfLines = 0; error.isHidden = true

        let browse = ModalButton("Browse", icon: .folderOpen, height: 32, label: "Choose the workspace folder"); browse.onClick = { [weak self] in self?.browse() }
        let addFiles = ModalButton("Add files…", icon: .plus, height: 32, label: "Add files to mention in the prompt"); addFiles.onClick = { [weak self] in self?.addFiles() }
        let cancel = ModalButton("Cancel", height: 32); cancel.onClick = { [weak self] in self?.cancelTapped() }
        launch.onClick = { [weak self] in self?.launchTapped() }
        let hint = ThemedText.helper("⌘ Enter to launch"); hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        let f = ModalFrame.make(title: "New agent", footerLeft: hint, footerRight: [cancel, launch], width: 520, height: 620)
        frameParts = f

        let wsRow = Kit.hstack([FieldBox(workspace), browse], spacing: 8); wsRow.distribution = .fill
        let managerRow = Kit.hstack([manager, { let t = NSTextField(labelWithString: ""); t.attributedStringValue = NSAttributedString(string: "Open the agents manager instead  ", attributes: [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.text)]); return t }(), { let t = NSTextField(labelWithString: "claude agents"); t.font = ThemeFont.mono(12); t.textColor = Theme.dynamic(.textMuted); return t }()], spacing: 4)
        channels.target = self; channels.action = #selector(kindChanged); channels.setSpokenLabel("Load Muya channel")
        channels.attributedTitle = NSAttributedString(string: "Load Muya channel", attributes: [.font: ThemeFont.sans(13), .foregroundColor: Theme.dynamic(.text)])
        channelsRow = Kit.vstack([channels, channelsHint], spacing: 8)
        let modeBlock = Kit.vstack([FieldBox(mode), modeHint, managerRow, channelsRow], spacing: 8)
        for v in modeBlock.arrangedSubviews { v.translatesAutoresizingMaskIntoConstraints = false }
        FieldBoxFill.fill(modeBlock)
        let filesRow = Kit.hstack([addFiles, filesLabel], spacing: 10)

        f.body.spacing = 16   // NewAgentModal.tsx: body gap 16, group gap 6 + the label's line (modalKit's Group uses 20 / 8)
        func grp(_ label: String, _ control: NSView, helper: NSView? = nil) -> NSView { let g = f.group(label, control, helper: helper); (g as? NSStackView)?.spacing = 9; return g }
        f.add(tabs)
        let g1 = grp("Workspace", wsRow); f.add(g1)
        f.add(grp("Name (optional)", FieldBox(name)))
        let g3 = grp("Permission mode", modeBlock); groups["mode"] = g3; f.add(g3)
        let g4 = grp("Branch (optional)", FieldBox(branch), helper: ThemedText.helper("Creates an isolated git worktree")); groups["branch"] = g4; f.add(g4)
        let g5 = grp("Initial prompt (optional)", promptFrame); groups["prompt"] = g5; f.add(g5)
        let g6 = grp("Files", filesRow); groups["files"] = g6; f.add(g6)
        f.add(error)
        panel.contentView = f.root
        panel.setAccessibilityLabel("New agent")
        updateChannels()
        kindChanged()
        store.call("agents.bins") { [weak self] r in
            if case let .success(v) = r, let d = v as? [String: Any] { self?.bins = (d["claude"] as? String, d["opencode"] as? String) }
        }
        store.call("agents.channels_supported") { [weak self] r in
            if case let .success(v) = r, (v as? Bool) == true { self?.channelsOk = true } else { self?.channelsOk = false }
        }
    }

    private func updateChannels() {
        channels.isEnabled = channelsOk == true
        if channelsOk != true { channels.state = .off }
        channelsHint.stringValue = channelsOk == false ? "Your Claude Code version does not support channels" : "Messages from other sessions and paired Macs arrive inside the chat instead of being typed into the terminal"
        channelsHint.maximumNumberOfLines = 0
        kindChanged()
    }

    private var kind: Int { tabs.selected }
    private var pickedMode: NewAgentCommand.Mode { NewAgentCommand.modes.first { $0.label == mode.titleOfSelectedItem } ?? NewAgentCommand.mode(for: store.permissionMode) }

    @objc private func kindChanged() {
        error.isHidden = true
        let claude = kind == 0, terminal = kind == 2
        groups["mode"]?.isHidden = !claude
        channelsRow?.isHidden = manager.state == .on
        let m = pickedMode
        modeHint.stringValue = manager.state == .on ? "Not used by the agents manager" : m.hint
        groups["branch"]?.isHidden = !claude
        groups["prompt"]?.isHidden = terminal || (claude && manager.state == .on)
        groups["files"]?.isHidden = terminal || (claude && manager.state == .on)
        launch.title = "Launch agent"
    }

    private func browse() {
        let p = NSOpenPanel(); p.title = "Select workspace folder"; p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.beginSheetModal(for: panel) { [weak self] r in if r == .OK, let u = p.url { self?.workspace.stringValue = u.path } }
    }

    private func addFiles() {
        let p = NSOpenPanel(); p.title = "Select file(s)"; p.canChooseFiles = true; p.canChooseDirectories = false; p.allowsMultipleSelection = true
        p.beginSheetModal(for: panel) { [weak self] r in
            guard r == .OK, let self else { return }
            self.files += p.urls.map(\.path)
            self.filesLabel.stringValue = self.files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
    }

    /// The command Launch would type (empty for Terminal) — shown by the test hook.
    var command: String {
        let m = pickedMode
        return NewAgentCommand.build(kind: kind, mode: m.value, agentsManager: manager.state == .on, branch: branch.stringValue, prompt: prompt.string, files: files, channels: channels.state == .on && channelsOk == true, claudePath: bins?.claude, opencodePath: bins?.opencode)
    }

    func present(on window: NSWindow) {
        parent = window
        panel.contentView?.layoutSubtreeIfNeeded()
        if let hc = frameParts.root.constraints.first(where: { $0.firstAttribute == .height }) {
            let natural = 56 + frameParts.body.fittingSize.height + 32 + 61
            hc.constant = min(natural, ((window.contentView?.bounds.height ?? 732) * 0.85).rounded())
            panel.setContentSize(NSSize(width: 520, height: hc.constant))
        }
        scrim = ModalScrim(over: window, alpha: 0.38) {}   // beginSheet dims the window once more (~20 %): together they come to today's 50 %
        window.beginSheet(panel) { _ in }
        // toasts stay under the dialog (they used to be lifted above it and covered its tabs)
        panel.makeFirstResponder(workspace)
        workspace.currentEditor()?.selectedRange = NSRange(location: workspace.stringValue.count, length: 0)   // focused, not select-all
    }

    @objc func cancelTapped() { close() }

    func close() {
        scrim?.remove(); scrim = nil
        if let p = parent { p.endSheet(panel) } else { panel.close() }
        onClose?()
    }

    /// The message sits at the end of the form, which a small window clips: scroll it into view.
    private func showError(_ message: String) {
        error.stringValue = message; error.isHidden = false
        panel.contentView?.layoutSubtreeIfNeeded()
        error.scrollToVisible(error.bounds)
    }

    func launchTapped() {
        let ws = (workspace.stringValue.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard !ws.isEmpty, FileManager.default.fileExists(atPath: ws, isDirectory: &isDir), isDir.boolValue else {
            showError("That folder doesn't exist.")
            panel.makeFirstResponder(workspace); return
        }
        if let b = bins {
            if kind == 0 && b.claude == nil { showError("Claude Code was not found on this Mac (or it is too old). Install it from claude.com/claude-code, then try again."); return }
            if kind == 1 && b.opencode == nil { showError("opencode was not found on this Mac. Install it, then try again."); return }
        }
        error.isHidden = true
        let cmd = command
        let title = name.stringValue.trimmingCharacters(in: .whitespaces)
        store.spawn(cwd: ws, name: title.isEmpty ? nil : title)
        if !cmd.isEmpty { store.sendText(cmd + "\n") }
        close()
    }

    /// Test hook: sets a field the way typing would.
    func debugSet(_ field: String, _ value: String) -> Bool {
        switch field {
        case "kind": guard let i = ["claude", "opencode", "terminal"].firstIndex(of: value) else { return false }; tabs.selected = i
        case "workspace": workspace.stringValue = value
        case "name": name.stringValue = value
        case "mode": guard let i = mode.titles.firstIndex(of: value) else { return false }; mode.selected = i
        case "manager": manager.state = value == "on" ? .on : .off
        case "channels": channels.state = value == "on" && channelsOk == true ? .on : .off
        case "branch": branch.stringValue = value
        case "prompt": prompt.string = value
        default: return false
        }
        kindChanged(); return true
    }

    func debugState() -> String { "channelsOk=\(channelsOk.map(String.init(describing:)) ?? "nil") kind=\(kind) workspace=\(workspace.stringValue) command=\(command) error=\(error.isHidden ? "" : error.stringValue)" }
}

/// Makes every arranged subview of a vertical stack span its width.
enum FieldBoxFill {
    static func fill(_ s: NSStackView) { for v in s.arrangedSubviews { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true } }
}
