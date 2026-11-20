// Text rules of the small dialogs (Broadcast, Rename) — kept apart from the AppKit code so the unit tests can reach them.

import Foundation

enum DialogsLogic {
    /// What a rename / broadcast field submits: trimmed, nil when empty.
    static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    /// "Send to 3 panels" / "Send to 1 panel".
    static func broadcastTitle(panels n: Int) -> String { "Send to \(n) panel\(n == 1 ? "" : "s")" }
}
