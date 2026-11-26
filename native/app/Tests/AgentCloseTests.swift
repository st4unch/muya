// Unit tests of the `muya://close-agent-session` payload (Sources/Logic/AgentCloseRequest.swift).

import Foundation

func runAgentCloseTests() {
    test("close-agent-session: the tab is named by terminalId") {
        let r = AgentCloseRequest(payload: "{\"sessionId\":\"4f6c1d2e-aaaa-bbbb-cccc-0123456789ab\",\"terminalId\":31}")
        check(r?.terminalId == 31, "terminalId read")
        check(r?.sessionId == "4f6c1d2e-aaaa-bbbb-cccc-0123456789ab", "session id kept")
        check(AgentCloseRequest(payload: "{\"sessionId\":\"shell:7\",\"terminalId\":7}")?.terminalId == 7, "a shell")
    }
    test("close-agent-session: a payload with no terminal id closes nothing") {
        // The old daemon sent only the Claude session id; the app must not guess a tab from it (nor trap on a string id).
        check(AgentCloseRequest(payload: "{\"sessionId\":\"sess-1\"}") == nil, "no terminalId")
        check(AgentCloseRequest(payload: "{\"sessionId\":\"12\",\"terminalId\":\"12\"}")?.terminalId == nil, "string terminalId")
        check(AgentCloseRequest(payload: "{\"terminalId\":-3}") == nil, "negative")
        check(AgentCloseRequest(payload: "not json") == nil, "garbage")
    }
}
