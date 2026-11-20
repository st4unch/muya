// Session exit diagnostics (docs/prd-session-exit-diag.md): the launch preflight (probes in the login shell a session
// uses, warnings only), the exit bookkeeping of a Claude tab, and the exit panel that replaces a dead terminal.

import AppKit

/// What a tab was started with, so it can be classified when it ends and relaunched from the panel.
struct ClaudeLaunch {
    let command: String
    let cwd: String
    let name: String
    let startedAt: Date
    var resumed: Bool { ExitDiag.isResume(command) }
}

enum LoginShell {
    /// The user's login shell from the account database (the GUI process environment has no reliable SHELL).
    static var path: String {
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell { let s = String(cString: sh); if !s.isEmpty { return s } }
        return "/bin/zsh"
    }
}

enum PreflightProbe {
    /// Runs `script` in the login shell with a hard time limit; never blocks the caller (completion arrives on the main queue).
    static func run(script: String, limit: TimeInterval = 2, completion: @escaping @Sendable (ProbeOutcome) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let argv = ExitDiag.probeArgv(shell: LoginShell.path, script: script)
            let p = Process(), out = Pipe(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: argv[0]); p.arguments = Array(argv.dropFirst())
            var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDE") }
            env["TERM"] = "dumb"
            p.environment = env
            p.standardInput = FileHandle.nullDevice; p.standardOutput = out; p.standardError = err
            do { try p.run() } catch {
                let o = ProbeOutcome(status: nil, stderr: "\(error.localizedDescription)")
                DispatchQueue.main.async { completion(o) }; return
            }
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            var timedOut = false
            if done.wait(timeout: .now() + limit) == .timedOut {
                timedOut = true
                p.terminate()
                if done.wait(timeout: .now() + 0.5) == .timedOut { kill(p.processIdentifier, SIGKILL) }
            }
            let so = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
            let se = String(decoding: err.fileHandleForReading.availableData, as: UTF8.self)
            let o = ProbeOutcome(status: timedOut ? nil : p.terminationStatus, timedOut: timedOut, stdout: so, stderr: se)
            DispatchQueue.main.async { completion(o) }
        }
    }
}

extension Store {
    /// Launches a Claude command in a new tab. The tab runs the command under the login shell (see ExitDiag.launchArgv)
    /// so its exit status reaches the app; the preflight runs beside it and only ever warns.
    @discardableResult
    func launchClaude(cwd: String, name: String, command: String) -> SessionModel? {
        let launch = ClaudeLaunch(command: command, cwd: cwd, name: name, startedAt: Date())
        guard let s = spawn(cwd: cwd, name: name, argv: ExitDiag.launchArgv(shell: LoginShell.path, command: command)) else { return nil }
        s.claudeLaunch = launch
        preflight()
        return s
    }

    /// The panel's Resume: the same command in the same folder, in a fresh tab; the dead one goes away.
    func relaunch(_ dead: SessionModel) {
        guard let l = dead.claudeLaunch else { return }
        close(dead)
        launchClaude(cwd: l.cwd, name: l.name, command: l.command)
    }

    func preflight(deliver: @escaping (PreflightReport) -> Void = { r in MainActor.assumeIsolated { Store.showPreflight(r) } }) {
        if mockMode { return }
        if let r = preflightCache.fresh() { if !r.isClean { deliver(r) }; return }
        final class Pair: @unchecked Sendable { var claude: ProbeOutcome?; var node: ProbeOutcome? }
        let pair = Pair()
        let finish: @Sendable () -> Void = { [weak self] in   // runs on the main queue
            guard let c = pair.claude, let n = pair.node else { return }
            let r = Preflight.map(claude: c, node: n)
            MainActor.assumeIsolated { self?.preflightCache.store(r) }
            if !r.isClean { deliver(r) }
        }
        PreflightProbe.run(script: ExitDiag.claudeProbeScript) { o in pair.claude = o; finish() }
        PreflightProbe.run(script: ExitDiag.nodeProbeScript) { o in pair.node = o; finish() }
    }

    @MainActor static func showPreflight(_ r: PreflightReport) {
        let lines = [r.claudeError, r.nodeWarning].compactMap { $0 }
        guard !lines.isEmpty, let c = Toasts.center else { return }
        c.show(title: r.claudeError != nil ? "Claude may not start" : "Heads-up before Claude starts", message: lines.joined(separator: "\n"), seconds: 20)
    }

    /// A session ended: a Claude tab that ended unexpectedly gets its verdict and the last lines it printed.
    func noteExit(_ s: SessionModel, status: Int32) {
        guard let l = s.claudeLaunch,
              let v = ExitDiag.classify(status: status, isClaudeLaunch: true, resumed: l.resumed, ranFor: Date().timeIntervalSince(l.startedAt)) else { return }
        s.exitVerdict = v
        delegate?.store(self, didUpdate: s)
        call("sessions.tail", ["id": s.id, "lines": 20]) { [weak self] r in
            guard let self else { return }
            if case let .success(any) = r, let lines = (any as? [String: Any])?["lines"] as? [String] { s.exitTail = lines }
            else { s.exitTail = ["(the last output is not available)"] }
            self.delegate?.store(self, didUpdate: s)
        }
    }
}

/// Over the dead terminal: what happened, the last lines, and what to do about it.
final class ExitPanel: NSView {
    var onResume: (() -> Void)?, onClose: (() -> Void)?
    private let card = ThemedBox(.popover)
    private let title = ThemedText.title("")
    private let detail = ThemedText.helper("")
    private let tail = NSTextField(wrappingLabelWithString: "")
    private let tailBox = ThemedBox(.rows)
    private let resume = ThemedButton("Resume", style: .primary)
    private let close = ThemedButton("Close", style: .ghost)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.font = ThemeFont.sans(15, .semibold)
        tail.font = ThemeFont.mono(12); tail.textColor = Theme.dynamic(.textTerminal)
        tail.lineBreakMode = .byTruncatingTail; tail.maximumNumberOfLines = 20; tail.isSelectable = true
        tail.translatesAutoresizingMaskIntoConstraints = false
        tailBox.translatesAutoresizingMaskIntoConstraints = false
        tailBox.addSubview(tail)
        resume.onClick = { [weak self] in self?.onResume?() }; close.onClick = { [weak self] in self?.onClose?() }
        let buttons = Kit.hstack([NSView(), close, resume], spacing: 8)
        let col = Kit.vstack([title, detail, tailBox, buttons], spacing: 10)
        col.translatesAutoresizingMaskIntoConstraints = false; card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(col); addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 620), card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            col.topAnchor.constraint(equalTo: card.topAnchor, constant: 16), col.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            col.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18), col.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            tail.topAnchor.constraint(equalTo: tailBox.topAnchor, constant: 8), tail.bottomAnchor.constraint(equalTo: tailBox.bottomAnchor, constant: -8),
            tail.leadingAnchor.constraint(equalTo: tailBox.leadingAnchor, constant: 10), tail.trailingAnchor.constraint(equalTo: tailBox.trailingAnchor, constant: -10),
        ])
        let wide = card.widthAnchor.constraint(equalToConstant: 620); wide.priority = .defaultHigh; wide.isActive = true
        for v in [detail, tailBox, buttons] { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        isHidden = true
        setAccessibilityRole(.group); setAccessibilityLabel("Session ended")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { Theme.dynamic(.bgTerminal).setFill(); bounds.fill() }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true; tail.textColor = Theme.dynamic(.textTerminal) }

    func show(_ s: SessionModel) {
        guard let v = s.exitVerdict else { isHidden = true; return }
        title.stringValue = v.title
        detail.stringValue = "\(v.detail) · \(s.name)"
        tail.stringValue = s.exitTail.isEmpty ? "…" : s.exitTail.joined(separator: "\n")
        resume.isHidden = s.claudeLaunch == nil
        isHidden = false
        needsDisplay = true
        setAccessibilityLabel(v.title)
    }
}
