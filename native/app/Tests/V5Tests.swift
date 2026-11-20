// Muya 5 (Sources/Logic/V5Logic.swift): start-up re-launch decision, old-app cleanup, legacy preferences, wording.

import Foundation

func runV5Tests() {
    func facts(pid: Int32 = 500, ppid: Int32, parent: String? = nil, resp: Int32?, again: Bool = false, release: Bool = true) -> StartupRelaunch.Facts {
        .init(pid: pid, ppid: ppid, parentName: parent, responsible: resp, alreadyRelaunched: again, installedRelease: release)
    }
    test("v5: app name follows the bundle") {
        check(AppInfo.displayName(["CFBundleDisplayName": "Muya", "CFBundleName": "Muya Native"]) == "Muya", "display name wins")
        check(AppInfo.displayName(["CFBundleName": "Muya Native"]) == "Muya Native", "bundle name")
        check(AppInfo.displayName([:]) == "Muya" && AppInfo.displayName(nil) == "Muya", "fallback")
    }
    test("v5: started by LaunchServices (responsible for itself) proceeds") {
        check(StartupRelaunch.decide(facts(ppid: 1, resp: 500)) == .proceed, "Finder / open / login item")
    }
    test("v5: the classic updater's relaunch waits for the parent, then starts itself through LaunchServices") {
        check(StartupRelaunch.decide(facts(ppid: 4242, parent: "muya", resp: 4242)) == .waitForParent, "parent still alive")
        check(StartupRelaunch.decide(facts(ppid: 1, parent: nil, resp: 4242)) == .relaunch, "parent gone: an orphan attributed to classic - muyad would refuse it")
        check(StartupRelaunch.decide(facts(ppid: 1, parent: nil, resp: nil)) == .relaunch, "unknown responsibility, orphan: fail closed like muyad")
    }
    test("v5: a shell, Terminal, a dev build or a repeated launch is left alone") {
        check(StartupRelaunch.decide(facts(ppid: 900, parent: "zsh", resp: 800)) == .proceed, "run from a shell that stays alive")
        check(StartupRelaunch.decide(facts(ppid: 1, resp: 4242, release: false)) == .proceed, "dev build")
        check(StartupRelaunch.decide(facts(ppid: 1, resp: 4242, again: true)) == .proceed, "never loop")
    }
    test("v5: open arguments carry the flag and, only on request, the test environment") {
        let plain = StartupRelaunch.openArguments(bundlePath: "/Applications/Muya.app", passEnv: nil, args: [])
        check(plain == ["-n", "/Applications/Muya.app", "--args", "--relaunched-by-launchservices"], "plain, got \(plain)")
        let env = StartupRelaunch.openArguments(bundlePath: "/A/Muya.app", passEnv: ["PATH": "/usr/bin", "HOME": "/h"], args: ["--x"])
        check(env == ["-n", "--env", "HOME=/h", "--env", "PATH=/usr/bin", "/A/Muya.app", "--args", "--relaunched-by-launchservices", "--x"], "env, got \(env)")
    }
    test("v5: launchctl print is read for the job's parent bundle") {
        let text = "gui/501/com.staunch.muya.muyad = {\n\tactive count = 1\n\tprogram identifier = Contents/MacOS/muyad (mode: 2)\n\tparent bundle identifier = com.staunch.muya.native\n\tparent bundle version = 696\n}"
        check(LaunchctlPrint.parentBundleID(text) == "com.staunch.muya.native", "parent")
        check(LaunchctlPrint.parentBundleID("nothing here") == nil, "absent")
    }
    test("v5: classic's scheduler job is booted out only when it is loaded and this app does not ship it") {
        check(LegacyJobs.shouldBootoutScheduler(loaded: true, bundleShipsPlist: false), "orphan of classic")
        check(!LegacyJobs.shouldBootoutScheduler(loaded: false, bundleShipsPlist: false), "nothing loaded")
        check(!LegacyJobs.shouldBootoutScheduler(loaded: true, bundleShipsPlist: true), "a bundle that ships it owns it")
    }
    test("v5: foreign service jobs are told apart from our own") {
        let parents: [String: String?] = ["com.staunch.muya.muyad": "com.staunch.muya.native", "com.staunch.muya.ptyd": "com.staunch.muya"]
        check(LegacyJobs.foreignServiceLabels(parents: parents, ourBundleID: "com.staunch.muya") == ["com.staunch.muya.muyad"], "the .native muyad is foreign")
        check(LegacyJobs.foreignServiceLabels(parents: [:], ourBundleID: "com.staunch.muya").isEmpty, "none loaded")
        check(LegacyJobs.foreignServiceLabels(parents: ["com.staunch.muya.muyad": nil], ourBundleID: "com.staunch.muya") == ["com.staunch.muya.muyad"], "unknown parent counts as foreign")
        check(LegacyJobs.plan(foreign: [], switchLaunch: true) == .nothing, "nothing to do")
        check(LegacyJobs.plan(foreign: ["x"], switchLaunch: true) == .waitThenRegister, "managed hand-over")
        check(LegacyJobs.plan(foreign: ["x"], switchLaunch: false) == .leaveToRestartDialog, "never a silent kill of live sessions")
    }
    test("v5: the .native preferences fill only keys the new domain does not have") {
        check(LegacyDomain.legacyName(for: "com.staunch.muya") == "com.staunch.muya.native", "legacy domain")
        check(LegacyDomain.legacyName(for: "com.staunch.muya.e2e") == "com.staunch.muya.e2e.native", "e2e domain")
        check(LegacyDomain.legacyName(for: "com.staunch.muya.native") == nil, "a legacy app has no legacy domain")
        let add = LegacyDomain.keysToCopy(legacy: ["NSWindow Frame main": "1 2 3 4", "a": 1, "mine": "old"], current: ["mine": "new"])
        check(Set(add.keys) == ["NSWindow Frame main", "a"] && add["mine"] == nil, "never over an existing key, got \(add)")
        check(LegacyDomain.keysToCopy(legacy: [LegacyDomain.doneKey: true], current: [:]).isEmpty, "the marker is not copied")
    }
    test("v5: the real UserDefaults of the .native domain are carried over once, never over an existing key") {
        let own = "com.staunch.muya.e2e.v5unit", legacy = own + ".native"
        let std = UserDefaults.standard
        defer { std.removePersistentDomain(forName: own); std.removePersistentDomain(forName: legacy) }
        std.removePersistentDomain(forName: own); std.removePersistentDomain(forName: legacy)
        std.setPersistentDomain(["NSWindow Frame main": "10 20 800 600", "mine": "legacy-value", "onlyOld": 7], forName: legacy)
        let w = UserDefaults(suiteName: own)!
        w.set("kept", forKey: "mine")
        check(LegacyDomain.migrate(ownDomain: own, writer: w) == 2, "two missing keys copied")
        let after = std.persistentDomain(forName: own) ?? [:]
        check(after["NSWindow Frame main"] as? String == "10 20 800 600" && after["onlyOld"] as? Int == 7, "copied, got \(after)")
        check(after["mine"] as? String == "kept", "an existing key wins")
        check(std.persistentDomain(forName: legacy)?["mine"] as? String == "legacy-value", "the legacy domain is untouched")
        w.set("later", forKey: "onlyOld")
        check(LegacyDomain.migrate(ownDomain: own, writer: w) == 0 && (std.persistentDomain(forName: own)?["onlyOld"] as? String) == "later", "second run does nothing")
        check(LegacyDomain.migrate(ownDomain: "com.staunch.muya.native", writer: w) == 0, "a legacy app has nothing to migrate")
    }
    test("v5: Return to Muya Classic wording") {
        check(ReturnWording.rowTitle == "Return to Muya Classic (4.1.22)" && ReturnWording.menuTitle.hasSuffix("…"), "titles")
        check(ReturnWording.rowHelper.contains("macOS permissions stay"), "rights kept")
        check(ReturnWording.confirmTitle() == "Return to Muya Classic 4.1.22?", "confirm title")
        check(ReturnWording.moveConfirmTitle == "Move to Muya 5?", "move title")
        check(!ReturnWording.moveConfirmMessage(live: 0, agents: 0).contains("running"), "nothing running, nothing said")
        let mv = ReturnWording.moveConfirmMessage(live: 3, agents: 2)
        check(mv.contains("3 sessions are running and will be closed.") && mv.contains("2 Claude conversations can be resumed in Muya.") && mv.contains("macOS permissions stay"), "move counts, got \(mv)")
        let m = ReturnWording.confirmMessage(live: 2, agents: 1)
        check(m.contains("2 sessions are running and will be closed.") && m.contains("1 Claude conversation can be resumed in Muya Classic."), "counts, got \(m)")
    }
}

func runUpdateStatusTests() {
    test("updates: status line and button words") {
        check(UpdateStatusText.line(installed: "5.0.0", available: nil, upToDate: false) == "Version 5.0.0", "nothing checked yet")
        check(UpdateStatusText.line(installed: "5.0.0", available: nil, upToDate: true) == "Version 5.0.0 · up to date", "up to date")
        check(UpdateStatusText.line(installed: "5.0.0", available: "5.1.0", upToDate: false) == "Version 5.0.0 · 5.1.0 is available", "available")
        check(UpdateStatusText.line(installed: "5.0.0", available: nil, upToDate: true, none: true).contains("no update published yet"), "no feed")
        check(UpdateStatusText.line(installed: "", available: nil, upToDate: false) == "Version unknown", "unknown")
        check(UpdateStatusText.checkTitle == "Check for Updates" && UpdateStatusText.menuTitle == "Check for Updates…", "titles")
        check(UpdateStatusText.installTitle(legacy: false) == "Install & Restart" && UpdateStatusText.installTitle(legacy: true) == "Move now", "install title")
        let up = UpdateStatusText.toast(name: "Muya", installed: "5.0.0", available: nil, error: nil)
        check(up.0 == "Muya is up to date" && up.1.contains("5.0.0"), "toast up to date")
        check(UpdateStatusText.toast(name: "Muya", installed: "5.0.0", available: "5.1.0", error: nil).0 == "Muya 5.1.0 is available", "toast available")
        check(UpdateStatusText.toast(name: "Muya", installed: "5.0.0", available: nil, error: "network error").0 == "Could not check for updates", "toast error")
    }
    test("updates: the update centre notifies only on a change") {
        nonisolated(unsafe) var n = 0
        let o = NotificationCenter.default.addObserver(forName: UpdateCenter.changed, object: nil, queue: nil) { _ in n += 1 }
        defer { NotificationCenter.default.removeObserver(o); UpdateCenter.available = nil }
        UpdateCenter.set("5.1.0"); UpdateCenter.set("5.1.0"); UpdateCenter.set(nil)
        check(n == 2 && UpdateCenter.available == nil, "two changes, got \(n)")
    }
}
