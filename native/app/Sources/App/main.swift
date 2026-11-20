import AppKit
import Foundation

signal(SIGPIPE, SIG_IGN)

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MainController!
    #if MUYA_TEST_HOOKS
    var debug: DebugServer?
    #endif
    var shortcuts: ShortcutRouter!
    var panelPrefs: PanelPrefs?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeFonts.register() // bundled IBM Plex Sans + JetBrains Mono, process-scoped; before any view or the renderer asks for them
        let env = ProcessInfo.processInfo.environment
        let home = env["HOME"] ?? NSHomeDirectory()
        LaunchHandshake.acknowledge(args: Array(CommandLine.arguments.dropFirst()), home: home) // classic waits for this file after a switch
        let fixedSocket = home + "/Library/Application Support/Muya/muyad.sock"
        #if MUYA_TEST_HOOKS
        let socket = env["MUYA_SOCKET"] ?? fixedSocket // tests only: the shipping app always uses the fixed path (an env var must not redirect it)
        #else
        let socket = fixedSocket
        #endif
        let store = Store(socketPath: socket, home: home)
        V5Startup.cleanUpClassicScheduler(home: home) // a leftover classic scheduler job would retry a missing program for ever
        V5Startup.migrateLegacyDomain(home: home) // the .native beta id's preferences
        ServiceApproval.ensureRegistered(home: home) // first launch: the system must know the two background agents before anything can connect
        controller = MainController(store: store)
        shortcuts = ShortcutRouter(controller: controller)
        shortcuts.install()
        buildMenu()
        #if MUYA_TEST_HOOKS
        if let p = env["MUYA_DEBUG_SOCKET"] {
            debug = DebugServer(path: p, controller: controller)
            debug?.start()
        }
        if env["MUYA_MOCK"] == "1", env["MUYA_DEBUG_SOCKET"] != nil { MockData.install(store: store); controller.queuePage.source = MockQueueSource(inner: controller.queuePage.source, home: store.home) } else { store.connect() }
        #else
        store.connect()
        #endif
        NSApp.activate()
        shortcuts.windowReady()
        panelPrefs = PanelPrefs(controller: controller)
        installSignalFlush()
    }

    /// A kill (SIGTERM/SIGINT/SIGHUP) must not lose the last second of preference changes: flush on a private queue (the main
    /// thread may be busy), then exit with the conventional 128+signal status.
    private func installSignalFlush() {
        let q = DispatchQueue(label: "muya.signal-flush")
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: q)
            src.setEventHandler { [weak self] in
                self?.controller?.store.flushPrefs()
                exit(128 + sig)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationDidResignActive(_ notification: Notification) { controller?.store.flushPrefs() }
    func applicationDidHide(_ notification: Notification) { controller?.store.flushPrefs() }

    /// Finder: Open With, double-click, drop on the Dock icon (lib.rs get_startup_files / apex://open-file).
    func application(_ application: NSApplication, open urls: [URL]) {
        shortcuts?.receive(paths: urls.filter(\.isFileURL).map(\.path))
        // A clicked permission banner posted by the notifier helper: muya://session/<id>.
        for id in urls.compactMap(PromptNotice.sessionId(from:)) { controller?.store.notifier.focusWhenListed(session: id) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { (controller?.confirmQuit() ?? true) ? .terminateNow : .terminateCancel }

    func applicationDidBecomeActive(_ notification: Notification) { controller?.viewer.reconcileAll() }

    func applicationWillTerminate(_ notification: Notification) { controller?.resume.rememberAtQuit(); controller?.store.flushPrefs() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); main.addItem(item)
            let m = NSMenu(title: title); item.submenu = m
            return m
        }
        let appName = AppInfo.name
        let app = submenu(appName)
        app.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(withTitle: UpdateStatusText.menuTitle, action: #selector(MainController.checkForUpdates), keyEquivalent: "").target = controller
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(MainController.openSettings), keyEquivalent: ",").target = controller
        app.addItem(withTitle: ReturnWording.menuTitle, action: #selector(MainController.returnToClassic), keyEquivalent: "").target = controller
        app.addItem(.separator())
        let services = app.addItem(withTitle: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services"); services.submenu = servicesMenu; NSApp.servicesMenu = servicesMenu
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(ShortcutRouter.quitPressed), keyEquivalent: "q").target = shortcuts
        let file = submenu("File")
        file.addItem(withTitle: "New File…", action: #selector(ShortcutRouter.newFile), keyEquivalent: "n").target = shortcuts
        file.addItem(withTitle: "Open…", action: #selector(ShortcutRouter.openFiles), keyEquivalent: "o").target = shortcuts
        file.addItem(withTitle: "New Terminal", action: #selector(ShortcutRouter.newTerminal), keyEquivalent: "t").target = shortcuts
        file.addItem(withTitle: "New Session…", action: #selector(MainController.newSession), keyEquivalent: "").target = controller
        file.addItem(.separator())
        file.addItem(withTitle: "Close Tab", action: #selector(ShortcutRouter.closeTab), keyEquivalent: "w").target = shortcuts
        let reopen = file.addItem(withTitle: "Reopen Closed Tab", action: #selector(ShortcutRouter.reopenClosedTab), keyEquivalent: "t")
        reopen.keyEquivalentModifierMask = [.command, .shift]; reopen.target = shortcuts
        file.addItem(.separator())
        file.addItem(withTitle: "Save", action: #selector(MainController.saveFile), keyEquivalent: "").target = controller // ⌘S is Sessions in the menu; the editor takes ⌘S itself while it has focus
        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(TerminalView.selectAll(_:)), keyEquivalent: "") // ⌘A is Ctrl+A in a terminal
        edit.addItem(.separator())
        let find = edit.addItem(withTitle: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f"); find.tag = NSTextFinder.Action.showFindInterface.rawValue
        let repl = edit.addItem(withTitle: "Find and Replace…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f"); repl.tag = NSTextFinder.Action.showReplaceInterface.rawValue; repl.keyEquivalentModifierMask = [.command, .option]
        let goto = edit.addItem(withTitle: "Go to Line…", action: #selector(MainController.goToLine), keyEquivalent: "g"); goto.keyEquivalentModifierMask = [.control]; goto.target = controller
        let view = submenu("View")
        view.addItem(withTitle: "Next Session", action: #selector(MainController.nextSession), keyEquivalent: "]").target = controller
        view.addItem(withTitle: "Previous Session", action: #selector(MainController.previousSession), keyEquivalent: "[").target = controller
        view.addItem(.separator())
        view.addItem(withTitle: "Command Palette", action: #selector(MainController.togglePalette), keyEquivalent: "k").target = controller
        view.addItem(withTitle: "Agents Panel", action: #selector(MainController.toggleAgentsPanel), keyEquivalent: "b").target = controller
        let insp = view.addItem(withTitle: "Inspector", action: #selector(MainController.toggleInspector), keyEquivalent: "b")
        insp.keyEquivalentModifierMask = [.command, .option]; insp.target = controller
        view.addItem(withTitle: "Terminals", action: #selector(MainController.showControl), keyEquivalent: "") // ⌘0 is the font reset.target = controller
        let sess = view.addItem(withTitle: "Sessions", action: #selector(MainController.showSessions), keyEquivalent: "s")
        sess.keyEquivalentModifierMask = [.command, .shift]; sess.target = controller
        let sched = view.addItem(withTitle: "Schedules", action: #selector(MainController.showSchedules), keyEquivalent: "e")
        sched.keyEquivalentModifierMask = [.command, .shift]; sched.target = controller
        let ssh = view.addItem(withTitle: "SSH & Passwords", action: #selector(MainController.showSSH), keyEquivalent: "h")
        ssh.keyEquivalentModifierMask = [.command, .shift]; ssh.target = controller
        let res = view.addItem(withTitle: "Resources", action: #selector(MainController.showResources), keyEquivalent: "r")
        res.keyEquivalentModifierMask = [.command, .shift]; res.target = controller
        let cmdItem = view.addItem(withTitle: "Send Command…", action: #selector(MainController.commandDialog), keyEquivalent: "k")
        cmdItem.keyEquivalentModifierMask = [.command, .shift]; cmdItem.target = controller
        let slash = view.addItem(withTitle: "Slash Commands…", action: #selector(MainController.toggleSlash), keyEquivalent: "/")
        slash.keyEquivalentModifierMask = [.command]; slash.target = controller
        view.addItem(.separator())
        let grid = view.addItem(withTitle: "Grid View", action: #selector(MainController.toggleGrid), keyEquivalent: "g")
        grid.keyEquivalentModifierMask = [.command, .option]
        grid.target = controller
        let window = submenu("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        NSApp.mainMenu = main
    }
}

V5Startup.relaunchThroughLaunchServicesIfNeeded() // classic's updater starts Muya 5 directly; muyad only accepts a LaunchServices start
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
