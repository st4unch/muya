// `muya://close-agent-session` (the MCP `close_session`): muyad asks the app to close the tab an agent opened.
// The daemon sends `{"sessionId": <Claude session id, or "shell:N" for a plain shell>, "terminalId": N}`. The store knows tabs by their
// PTY id, so `terminalId` is the only part the app can act on; the session id is a Claude id (a UUID) that no tab carries.

import Foundation

public struct AgentCloseRequest: Equatable, Sendable {
    public var terminalId: UInt64
    public var sessionId: String?

    public init?(payload: String) {
        guard let d = payload.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let n = o["terminalId"] as? NSNumber, n.int64Value >= 0 else { return nil }
        terminalId = n.uint64Value
        sessionId = o["sessionId"] as? String
    }
}
