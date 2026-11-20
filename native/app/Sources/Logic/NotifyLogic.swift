// Permission-prompt notifications (PRD AC12, native path): the words, the "once per prompt" rule and the "is the
// operator already looking at it" rule. Pure logic; Notifications.swift posts through UNUserNotificationCenter.
// The words are the daemon's (crates/muyad prompt_watch.rs) so the app and the no-app fallback read the same.

import Foundation

enum PromptNotice {
    static let title = "Muya: permission needed"

    /// "Claude is asking permission to use Bash: rm -rf build" — the tool and the first 80 characters of the target,
    /// nothing else from the screen (never the dialog's file content).
    static func body(tool: String, target: String) -> String {
        let what = tool.isEmpty || tool == "Tool use" ? "a tool" : tool
        var text = "Claude is asking permission to use \(what)"
        if !target.isEmpty { text += ": " + String(target.prefix(80)) }
        return text
    }

    /// The link a clicked banner opens (helper -> app): `muya://session/<id>`.
    static func sessionURL(_ id: UInt64) -> URL { URL(string: "muya://session/\(id)")! }

    static func sessionId(from url: URL) -> UInt64? {
        guard url.scheme == "muya", url.host == "session" else { return nil }
        return UInt64(url.pathComponents.dropFirst().first ?? "")
    }

    /// No banner while the operator is looking at that very session in the frontmost window.
    static func shouldPost(appActive: Bool, windowVisible: Bool, isSelected: Bool) -> Bool {
        !(appActive && windowVisible && isSelected)
    }
}

/// One notification per prompt: remembers which prompt each session showed last and forgets it when the prompt goes.
struct PromptNoticeTracker {
    private var seen: [UInt64: String] = [:]

    /// `prompting`: session id → prompt key ("tool|target|question") of every session that shows a permission dialog now.
    /// Returns the sessions whose prompt is new since the last call.
    mutating func fresh(prompting: [UInt64: String]) -> [UInt64] {
        seen = seen.filter { prompting[$0.key] != nil }
        var out: [UInt64] = []
        for (id, key) in prompting.sorted(by: { $0.key < $1.key }) where seen[id] != key {
            seen[id] = key
            out.append(id)
        }
        return out
    }
}
