// Unit tests of the `muya://terminal-opened` payload (Sources/Logic/StartedTerminal.swift).

import Foundation

func runStartedTerminalTests() {
    test("terminal-opened: payload with id, pid, name and size") {
        let t = StartedTerminal(payload: "{\"id\":7,\"pid\":4242,\"name\":\"logs\",\"cwd\":\"/tmp\",\"cols\":120,\"rows\":30}")
        check(t == StartedTerminal(payload: "{\"id\":7,\"pid\":4242,\"name\":\"logs\",\"cols\":120,\"rows\":30}"), "cwd is not part of it")
        check(t?.id == 7 && t?.pid == 4242 && t?.name == "logs" && t?.cols == 120 && t?.rows == 30, "fields")
        check(StartedTerminal(payload: "{\"id\":7,\"pid\":1,\"name\":\"x\"}")?.cols == nil, "size is optional")
    }
    test("terminal-opened: a payload without id, pid or a name is ignored") {
        for bad in ["nope", "{}", "{\"id\":1,\"pid\":2}", "{\"id\":1,\"pid\":2,\"name\":\"  \"}", "{\"pid\":2,\"name\":\"x\"}"] {
            check(StartedTerminal(payload: bad) == nil, "rejects \(bad)")
        }
    }
}
