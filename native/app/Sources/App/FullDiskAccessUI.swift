// Optional Full Disk Access (docs/prd-full-disk-access.md): the shared status model, the Settings row and the
// first-run step. The step reuses the onboarding card (ModalOverlay); the row is built with ModalLayout like every
// other Settings group. Nothing here ever asks macOS for the permission: it only opens the right System Settings pane.

import AppKit

/// What macOS says right now, re-read when the app becomes active (the user comes back from System Settings).
@MainActor
final class FDAModel {
    static let shared = FDAModel()
    static let changedNotification = Notification.Name("muya.fda.changed")

    private(set) var status: FDAStatus
    var opener: FullDiskAccess.Opener = FullDiskAccess.systemOpener
    /// Called instead of opening System Settings / Finder (tests and the debug socket count the calls).
    var openPane: () -> Void = {
        if let u = URL(string: FullDiskAccess.settingsURL) { NSWorkspace.shared.open(u) }
    }
    var revealHelpers: () -> Void = { FDAModel.revealHelperApps() }
    private(set) var openCalls = 0
    private(set) var revealCalls = 0
    private var token: NSObjectProtocol?

    private init() {
        status = FullDiskAccess.status()
        token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refresh() }
        }
    }

    /// Re-reads the status; posts a notification when it changed.
    @discardableResult
    func refresh() -> FDAStatus {
        let s = FullDiskAccess.status(opener: opener)
        if s != status { status = s; NotificationCenter.default.post(name: Self.changedNotification, object: self) }
        return s
    }

    func open() { openCalls += 1; openPane() }
    func reveal() { revealCalls += 1; revealHelpers() }

    /// Selects the helper programs in Finder (the user may have to add them to the list as well); the app itself when
    /// this copy has none (a dev build).
    static func revealHelperApps() {
        let dir = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS")
        let helpers = FullDiskAccess.helperNames.map { dir.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        NSWorkspace.shared.activateFileViewerSelecting(helpers.isEmpty ? [Bundle.main.bundleURL] : helpers)
    }

    #if MUYA_TEST_HOOKS
    /// Tests: `granted` / `denied` / `unknown` decide what the probe finds instead of the real TCC database.
    func simulate(_ what: String) {
        switch what {
        case "granted": opener = { _ in nil }
        case "denied": opener = { _ in EPERM }
        default: opener = { _ in ENOENT }
        }
        refresh()
    }
    #endif
}

/// "Granted" / "Not granted" pill in the Settings colours.
@MainActor
func fdaPill(_ pill: ThemedPill, for s: FDAStatus) {
    pill.text = s.label
    switch s {
    case .granted:
        pill.fg = Theme.dynamic(.successText); pill.bg = Theme.dynamic(.successBg); pill.border = Theme.dynamic(.successCardBorder); pill.dot = Theme.dynamic(.success)
    case .notGranted:
        pill.fg = Theme.dynamic(.warningText); pill.bg = Theme.dynamic(.warningBg); pill.border = Theme.dynamic(.warningBorder); pill.dot = Theme.dynamic(.warning)
    case .unknown:
        pill.fg = Theme.dynamic(.textMuted); pill.bg = Theme.dynamic(.bgControl); pill.border = Theme.dynamic(.borderControl); pill.dot = Theme.dynamic(.textMuted)
    }
}

/// Settings > Privacy: the always-reachable row.
@MainActor
final class FDASection: NSObject {
    private let model = FDAModel.shared
    private let pill = ThemedPill("", fg: Theme.dynamic(.textMuted), bg: Theme.dynamic(.bgControl), border: Theme.dynamic(.borderControl), dot: Theme.dynamic(.textMuted))
    private let openButton = ThemedButton(FullDiskAccess.openButton)
    private let revealButton = ThemedButton(FullDiskAccess.revealButton)

    override init() {
        super.init()
        openButton.onClick = { [weak self] in MainActor.assumeIsolated { self?.model.open() } }
        openButton.setAccessibilityLabel("Open the Full Disk Access pane in System Settings")
        revealButton.onClick = { [weak self] in MainActor.assumeIsolated { self?.model.reveal() } }
        revealButton.setAccessibilityLabel("Show the Muya helper apps in Finder")
        pill.setAccessibilityLabel("Full Disk Access status")
        NotificationCenter.default.addObserver(self, selector: #selector(changed), name: FDAModel.changedNotification, object: nil)
        changed()
    }

    @objc private func changed() { fdaPill(pill, for: model.status); pill.setAccessibilityValue(model.status.label) }

    func blocks() -> [NSView] {
        let top = Kit.hstack([pill, openButton], spacing: 8)
        let row = ModalLayout.settingRow(title: FullDiskAccess.title, helper: FullDiskAccess.rowHelper, control: top, controlBelow: true)
        let helpers = ModalLayout.settingRow(title: "Helper apps", helper: FullDiskAccess.helpersHelper, control: revealButton, controlBelow: true)
        return [ThemedText.label("Privacy"), ModalLayout.rowsBox([row, helpers])]
    }

    func reload() { model.refresh(); changed() }
}

/// The first-run step: one card, "Not now" or "Open Settings".
final class FDAStepView: ModalOverlay {
    private let pill = ThemedPill("", fg: Theme.dynamic(.textMuted), bg: Theme.dynamic(.bgControl), border: Theme.dynamic(.borderControl), dot: Theme.dynamic(.textMuted))
    let openButton = ThemedButton(FullDiskAccess.openButton, style: .primary)
    let revealButton = ThemedButton(FullDiskAccess.revealButton)
    let notNowButton = ThemedButton(FullDiskAccess.notNowButton)
    var onOpen: (() -> Void)?
    var onReveal: (() -> Void)?
    var onNotNow: (() -> Void)?

    init() {
        super.init(width: 480)
        setAccessibilityLabel(FullDiskAccess.stepTitle)
        openButton.onClick = { [weak self] in self?.onOpen?() }
        revealButton.onClick = { [weak self] in self?.onReveal?() }
        notNowButton.onClick = { [weak self] in self?.onNotNow?() }
        let steps = ThemedBox(.rows)
        let stepsText = Self.paragraph(FullDiskAccess.stepHow)
        stepsText.translatesAutoresizingMaskIntoConstraints = false
        steps.addSubview(stepsText)
        NSLayoutConstraint.activate([
            stepsText.leadingAnchor.constraint(equalTo: steps.leadingAnchor, constant: 14), stepsText.trailingAnchor.constraint(equalTo: steps.trailingAnchor, constant: -14),
            stepsText.topAnchor.constraint(equalTo: steps.topAnchor, constant: 12), stepsText.bottomAnchor.constraint(equalTo: steps.bottomAnchor, constant: -12),
        ])
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = Kit.hstack([pill, spacer, revealButton, notNowButton, openButton], spacing: 8)
        fill([
            Self.header(icon: .settingsRail, color: .accent, title: FullDiskAccess.stepTitle),
            Self.paragraph(FullDiskAccess.stepWhat),
            Self.paragraph(FullDiskAccess.stepRisk),
            steps,
            footer,
        ])
        onReturn = { [weak self] in self?.onOpen?() }
        onEscape = { [weak self] in self?.onNotNow?() }
        setStatus(FDAModel.shared.status)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ s: FDAStatus) {
        fdaPill(pill, for: s)
        notNowButton.title = s == .granted ? FullDiskAccess.doneButton : FullDiskAccess.notNowButton
    }
}
