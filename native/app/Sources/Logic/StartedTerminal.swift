// `muya://terminal-opened` (the MCP `open_terminal`): muyad started a shell itself and tells the app which session to adopt and what to call it.

import Foundation

public struct StartedTerminal: Equatable, Sendable {
    public var id: UInt64, pid: Int32, name: String
    public var cols: UInt16?, rows: UInt16?

    public init?(payload: String) {
        guard let d = payload.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let id = (o["id"] as? NSNumber)?.uint64Value, let pid = (o["pid"] as? NSNumber)?.int32Value,
              let name = o["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        self.id = id; self.pid = pid; self.name = name
        cols = (o["cols"] as? NSNumber)?.uint16Value; rows = (o["rows"] as? NSNumber)?.uint16Value
    }
}
