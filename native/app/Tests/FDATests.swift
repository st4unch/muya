// Full Disk Access status logic (Sources/Logic/FullDiskAccess.swift).

import Foundation

/// A tiny thread-safe cell for the @Sendable opener in tests.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T
    init(_ v: T) { self.v = v }
    func set(_ x: T) { lock.lock(); v = x; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
}

func runFDATests() {
    test("fda: probe result maps to a status") {
        check(FullDiskAccess.classify(openErrno: nil) == .granted, "opened = granted")
        check(FullDiskAccess.classify(openErrno: EPERM) == .notGranted, "EPERM = not granted")
        check(FullDiskAccess.classify(openErrno: EACCES) == .notGranted, "EACCES = not granted")
        check(FullDiskAccess.classify(openErrno: ENOENT) == .unknown, "missing file is unknown, never a red verdict")
        check(FullDiskAccess.classify(openErrno: EIO) == .unknown, "odd error is unknown")
    }
    test("fda: status probes the TCC database under the real home through the opener") {
        let seen = LockedBox<String>("")
        let s = FullDiskAccess.status(home: "/home/x", opener: { seen.set($0); return EPERM })
        check(s == .notGranted && seen.get() == "/home/x/Library/Application Support/com.apple.TCC/TCC.db", "path \(seen.get())")
        check(FullDiskAccess.status(home: "/home/x", opener: { _ in nil }) == .granted, "granted")
        check(FullDiskAccess.status(home: nil, opener: { _ in nil }) == .unknown, "no home is unknown")
    }
    test("fda: the real probe never throws and answers with one of the three states") {
        let s = FullDiskAccess.status()
        check(s == .granted || s == .notGranted || s == .unknown, "real probe")
        check(FullDiskAccess.status(home: "/nonexistent-\(UUID().uuidString)") == .unknown, "missing path is unknown")
    }
    test("fda: the first-run step is offered only when it should be") {
        func offer(_ s: FDAStatus, dismissed: Bool = false, other: Bool = false, real: Bool = true) -> Bool {
            FullDiskAccess.shouldOffer(status: s, dismissed: dismissed, otherScreenUp: other, realInstall: real)
        }
        check(offer(.notGranted), "not granted, first run")
        check(!offer(.granted), "already granted")
        check(!offer(.unknown), "cannot tell")
        check(!offer(.notGranted, dismissed: true), "Not now is remembered")
        check(!offer(.notGranted, other: true), "waits while the Login Items / restart screen is up")
        check(!offer(.notGranted, real: false), "a dev stack never asks")
    }
    test("fda: labels, deep link and wording") {
        check(FDAStatus.granted.label == "Granted" && FDAStatus.notGranted.label == "Not granted", "labels")
        check(FullDiskAccess.settingsURL == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles", "deep link")
        check(FullDiskAccess.rowHelper.contains("Optional") && FullDiskAccess.rowHelper.contains("all your files"), "opt-in and what it grants")
        check(FullDiskAccess.helperNames == ["muya-ptyd", "muyad"], "helpers")
    }
}
