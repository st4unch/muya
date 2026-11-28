// Settings > Beta wording and the `muya://switchover` event shape (Sources/Logic/BetaLogic.swift).

import Foundation

func runBetaTests() {
    test("an update launch starts hidden and takes over only when the old copy is gone") {
        check(SwitchTakeover.startsHidden(args: ["--switched-from=update"]), "an update launch starts without a Dock tile")
        check(SwitchTakeover.startsHidden(args: ["--switched-from=native"]), "so does a switch launch")
        check(!SwitchTakeover.startsHidden(args: []) && !SwitchTakeover.startsHidden(args: ["--open", "/tmp/x"]), "an ordinary launch is unchanged")
        check(!SwitchTakeover.shouldTakeOver(otherInstances: 1, waited: 0), "the old copy is still there: stay invisible")
        check(!SwitchTakeover.shouldTakeOver(otherInstances: 2, waited: 5), "two old copies: still waits")
        check(SwitchTakeover.shouldTakeOver(otherInstances: 0, waited: 0.25), "the old copy quit: become the visible Muya")
        check(!SwitchTakeover.shouldTakeOver(otherInstances: 1, waited: 19.9), "waits up to the limit")
        check(SwitchTakeover.shouldTakeOver(otherInstances: 1, waited: SwitchTakeover.waitLimit), "a copy that will not quit never leaves the user without a window")
        check(SwitchTakeover.stepAsideAfter > 0 && SwitchTakeover.stepAsideAfter < 1.5, "the old copy steps aside faster than 5.0.6's 1.5 s")
    }
    test("switchover event: download progress, result and rejects") {
        let d = SwitchoverEvent(payload: "{\"kind\":\"switch_back\",\"phase\":\"downloading\",\"downloaded\":5242880,\"total\":10485760,\"version\":\"4.1.20\"}")
        check(d?.kind == .switchBack && d?.phase == "downloading" && d?.downloaded == 5_242_880 && d?.total == 10_485_760, "fields")
        check(d?.text == "Downloading classic Muya… 5.0 MB of 10.0 MB", "progress text, got \(d?.text ?? "nil")")
        check(SwitchoverEvent(payload: "{\"kind\":\"update\",\"phase\":\"downloading\"}")?.text == "Downloading the update…", "no bytes yet")
        let e = SwitchoverEvent(payload: "{\"kind\":\"update\",\"phase\":\"error\",\"message\":\"the download is damaged (checksum mismatch)\"}")
        check(e?.isError == true && e?.isFinished == true && e?.text == "the download is damaged (checksum mismatch)", "error carries muyad's message")
        check(SwitchoverEvent(payload: "{\"kind\":\"update\",\"phase\":\"done\"}")?.isError == false, "done is not an error")
        let doneEv = SwitchoverEvent(payload: "{\"kind\":\"update\",\"phase\":\"done\"}")
        check(doneEv?.stepsAside(initiatedHere: true) == true, "the app that asked for the update steps aside when it is done")
        check(doneEv?.stepsAside(initiatedHere: false) == false, "the freshly launched app sees the same event and stays")
        check(SwitchoverEvent(payload: "{\"kind\":\"update\",\"phase\":\"healthy\"}")?.stepsAside(initiatedHere: true) == false, "not before done")
        for bad in ["nope", "{}", "{\"kind\":\"other\",\"phase\":\"done\"}", "{\"kind\":\"update\"}"] { check(SwitchoverEvent(payload: bad) == nil, "rejects \(bad)") }
    }
    test("switch back dialog names the sessions that will close") {
        check(!BetaWording.switchBackMessage(live: 0, agents: 0).contains("running"), "nothing running, nothing said")
        check(BetaWording.switchBackMessage(live: 1, agents: 0).contains("1 session is running and will be closed."), "one")
        let m = BetaWording.switchBackMessage(live: 3, agents: 2)
        check(m.contains("3 sessions are running") && m.contains("2 Claude conversations can be resumed"), "counts, got \(m)")
        check(BetaWording.switchBackMessage(live: 0, agents: 0).contains("Trash"), "recoverable")
        check(BetaWording.switchBackMessage(live: 0, agents: 0).contains("macOS permissions stay"), "rights are kept, said plainly")
    }
    test("version line") {
        check(BetaWording.versionLine(installed: "0.1.0", available: nil) == "Version 0.1.0", "plain")
        check(BetaWording.versionLine(installed: "0.1.0", available: "0.2.0") == "Version 0.1.0 · 0.2.0 is available", "available")
        check(BetaWording.versionLine(installed: "0.1.0", available: nil, none: true).contains("no update published"), "none published")
    }
    test("switch launch writes the handshake file without muyad") {
        let home = NSTemporaryDirectory() + "muya-handshake-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        check(!LaunchHandshake.acknowledge(args: ["--other"], home: home), "plain launch writes nothing")
        check(!FileManager.default.fileExists(atPath: LaunchHandshake.markerPath(home: home)), "no marker for a plain launch")
        check(LaunchHandshake.acknowledge(args: ["--switched-from=classic"], home: home), "switch launch writes")
        let body = try? String(contentsOfFile: LaunchHandshake.markerPath(home: home), encoding: .utf8)
        check(body?.contains("\"app\":\"native\"") == true, "marker body, got \(body ?? "nil")")
    }
}
