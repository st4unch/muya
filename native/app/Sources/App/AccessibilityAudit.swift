// Accessibility audit through the NSAccessibility protocol: walks the hierarchy of the given windows (and the
// sheets attached to them) the way the AX server serialises it for VoiceOver and AXUIElement clients, and lists
// every interactive control that has no label or title (help text alone is a hint, not a name). Used by the debug socket (`ax-tree`) and by
// tools/ssh-shots.swift; the in-app stand-in for tools/ax-audit.swift when the session cannot use the external
// Accessibility API (a locked screen makes the AX server answer with a flat application element).

import AppKit

private let auditInteractiveRoles: Set<NSAccessibility.Role> = [
    .button, .checkBox, .radioButton, .popUpButton, .comboBox, .textField, .textArea, .slider, .table, .outline,
    .list, .menuButton, .incrementor, .colorWell, .disclosureTriangle, .radioGroup,
]
private let auditSystemSubroles: Set<NSAccessibility.Subrole> = [
    .closeButton, .minimizeButton, .zoomButton, .fullScreenButton, .incrementArrow, .decrementArrow, .incrementPage, .decrementPage,
]

/// Audit of the given windows: `windows=… elements=… interactive=… unlabelled=…` and one line per unlabelled control.
func accessibilityAudit(windows wins: [NSWindow], dump: Bool = false) -> String {
    var seen = Set<ObjectIdentifier>()
    var elements = 0, interactive = 0
    var bad: [String] = [], lines: [String] = [], roles: [String: Int] = [:]

    func text(_ s: String?) -> String { (s ?? "").trimmingCharacters(in: .whitespaces) }

    func walk(_ e: Any, depth: Int, path: String) {
        guard depth < 40, let p = e as? NSAccessibilityProtocol else { return }
        if let o = e as AnyObject?, !seen.insert(ObjectIdentifier(o)).inserted { return }
        elements += 1
        let role = p.accessibilityRole() ?? .unknown
        let sub = p.accessibilitySubrole()
        let label = text(p.accessibilityLabel())
        let title = text(p.accessibilityTitle())
        let value = (p.accessibilityValue() as? String).map(text) ?? ""
        // What the AX server itself reads: the legacy attribute path, which for a control's cell forwards the
        // description / title the control carries (called by selector: the typed Swift method is deprecated).
        func legacy(_ a: NSAccessibility.Attribute) -> String {
            guard let o = e as? NSObject, o.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return "" }
            return text(o.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: a.rawValue)?.takeUnretainedValue() as? String)
        }
        let name = [label, title, legacy(.description), legacy(.title)].first { !$0.isEmpty } ?? ""
        if dump { lines.append(String(repeating: "  ", count: depth) + "[\(type(of: e))] \(role.rawValue)\(sub.map { "/\($0.rawValue)" } ?? "") '\(name)' \(value.isEmpty ? "" : "= '\(value.prefix(24))'")") }
        // The stepper arrows of a date picker (AXDateTimeArea) are part of the picker and spoken through it.
        let pickerPart = role == .incrementor && path.contains("AXDateTimeArea")
        if auditInteractiveRoles.contains(role), !pickerPart, !(sub.map { auditSystemSubroles.contains($0) } ?? false) {
            // A radio button inside a segmented/radio group, and a check box inside a table cell, speak through
            // their own title or the row they sit in; a field that only shows its current text does not count.
            interactive += 1
            roles[role.rawValue, default: 0] += 1
            let inCell = path.contains("AXCell") || path.contains("AXRow")
            if name.isEmpty && !(inCell && (role == .checkBox || role == .button)) {
                bad.append("[\(type(of: e))] \(role.rawValue)\(sub.map { "/\($0.rawValue)" } ?? "") value='\(value.prefix(20))' at \(path)")
            }
        }
        for c in p.accessibilityChildren() ?? [] { walk(c, depth: depth + 1, path: path + "/\(role.rawValue)") }
    }

    for w in wins { walk(w, depth: 0, path: "window[\(w.title)]"); for sh in w.sheets { walk(sh, depth: 0, path: "sheet[\(w.title)]") } }
    var out = "windows=\(wins.count) elements=\(elements) interactive=\(interactive) unlabelled=\(bad.count) roles=\(roles.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))"
    if !bad.isEmpty { out += "\n" + bad.map { "  UNLABELLED " + $0 }.joined(separator: "\n") }
    if dump { out += "\n" + lines.joined(separator: "\n") }
    return out
}
