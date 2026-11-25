// Muya 5 start-up work that touches the system (the decisions are in Sources/Logic/V5Logic.swift and unit-tested):
// start again through LaunchServices after classic's updater, clean up the old apps' launchd jobs, and carry the old
// `.native` preferences over. Everything that changes the user's launchd or login items is skipped for a fake HOME.

import AppKit
import Darwin
import Foundation

enum V5Startup {
    // MARK: re-launch after classic's updater

    private static func responsiblePid() -> Int32? {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil } // RTLD_DEFAULT
        let r = unsafeBitCast(sym, to: Fn.self)(getpid())
        return r > 0 ? r : nil
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    private static func facts(args: [String]) -> StartupRelaunch.Facts {
        let id = Bundle.main.bundleIdentifier ?? ""
        let ppid = getppid()
        return .init(pid: getpid(), ppid: ppid, parentName: ppid > 1 ? processName(ppid) : nil, responsible: responsiblePid(),
                     alreadyRelaunched: args.contains(StartupRelaunch.flag),
                     installedRelease: Bundle.main.bundlePath.hasSuffix(".app") && !id.isEmpty && !id.hasSuffix(".dev"))
    }

    /// First thing in the process. When the classic updater started this app directly, wait for it to exit, then start the
    /// app again through `open` (LaunchServices) and quit this copy: only that start is accepted by muyad.
    static func relaunchThroughLaunchServicesIfNeeded() {
        let args = Array(CommandLine.arguments.dropFirst())
        var action = StartupRelaunch.decide(facts(args: args))
        var waited = 0
        while action == .waitForParent && waited < 50 { // up to 5 s
            usleep(100_000); waited += 1
            action = StartupRelaunch.decide(facts(args: args))
        }
        guard action == .relaunch else { return }
        let env = ProcessInfo.processInfo.environment
        var pass: [String: String]? = nil
        if env["MUYA_SWITCHOVER_PASS_ENV"] != nil { // test runs only: `open` hands the app launchd's environment, not the synthetic user's
            pass = [:]
            for k in ["HOME", "PATH"] { if let v = env[k] { pass?[k] = v } }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = StartupRelaunch.openArguments(bundlePath: Bundle.main.bundlePath, passEnv: pass, args: args)
        do { try p.run(); p.waitUntilExit() } catch { return } // could not: carry on in this process rather than not start at all
        if p.terminationStatus == 0 { exit(0) }
    }

    // MARK: launchd jobs of the old apps

    private static func launchctl(_ args: [String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func jobPrint(_ label: String) -> String? {
        let r = launchctl(["print", "gui/\(getuid())/\(label)"])
        return r.status == 0 ? r.out : nil
    }

    @discardableResult
    static func bootout(_ label: String) -> Bool { launchctl(["bootout", "gui/\(getuid())/\(label)"]).status == 0 }

    /// Service jobs (muyad / ptyd) that belong to another bundle id than ours.
    static func foreignServices() -> [String] {
        let ours = Bundle.main.bundleIdentifier ?? ""
        var parents: [String: String?] = [:], programs: [String: String] = [:]
        for l in LegacyJobs.serviceLabels {
            guard let t = jobPrint(l) else { continue }
            parents[l] = .some(LaunchctlPrint.parentBundleID(t))
            if let prog = LaunchctlPrint.program(t) { programs[l] = prog }
        }
        let bundle = Bundle.main.bundleURL
        return LegacyJobs.foreignServiceLabels(parents: parents, ourBundleID: ours, programs: programs, ourBundlePath: bundle.pathExtension == "app" ? bundle.path : nil)
    }

    /// Classic's scheduler agent (`muya --scheduler`) cannot run in this app: its executable does not exist here and the
    /// plist is not shipped. Boot a leftover job out so launchd does not retry a missing program for ever.
    static func cleanUpClassicScheduler(home: String) {
        guard LoginItem.isRealHome(home) else { return }
        let ships = FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(LegacyJobs.schedulerPlist)").path)
        let loaded = jobPrint(LegacyJobs.schedulerLabel) != nil
        if LegacyJobs.shouldBootoutScheduler(loaded: loaded, bundleShipsPlist: ships) { bootout(LegacyJobs.schedulerLabel) }
    }

    /// Polls until none of `labels` is loaded any more (the old daemon boots them out after a managed hand-over).
    static func waitUntilGone(_ labels: [String], timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if labels.allSatisfy({ jobPrint($0) == nil }) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return labels.allSatisfy { jobPrint($0) == nil }
    }

    // MARK: the `.native` preferences domain

    /// Once: copy keys of `<id>.native` that the app's own domain does not have. Never touches the legacy domain.
    static func migrateLegacyDomain(home: String) {
        guard LoginItem.isRealHome(home), let id = Bundle.main.bundleIdentifier else { return }
        LegacyDomain.migrate(ownDomain: id, writer: .standard)
    }
}
