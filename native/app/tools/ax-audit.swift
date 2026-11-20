// Accessibility API audit of a running app (AC26 subset): walks the AXUIElement tree of <pid> and lists every
// interactive element (button, check box, text field, pop-up, segmented control, table, outline, text area,
// switch, slider, radio button) that has no title, description, label or value a screen reader could speak.
//
//   ax-audit <pid> [--dump]    exit 1 when unlabelled controls exist; 2 when this process may not use the
//                              Accessibility API (grant it to the terminal under System Settings > Privacy);
//                              4 on a 120 s timeout; 5 when the app answered with (almost) no elements.
import ApplicationServices
import Foundation

guard CommandLine.arguments.count >= 2, let pid = pid_t(CommandLine.arguments[1]) else { print("usage: ax-audit <pid> [--dump]"); exit(64) }
let dump = CommandLine.arguments.contains("--dump")
guard AXIsProcessTrusted() else { print("NOT-TRUSTED: this process may not use the Accessibility API"); exit(2) }

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v as AnyObject? : nil
}
func str(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }

let interactive: Set<String> = ["AXButton", "AXCheckBox", "AXTextField", "AXPopUpButton", "AXRadioButton", "AXSegmentedControl", "AXTable", "AXOutline",
                                "AXTextArea", "AXSwitch", "AXSlider", "AXComboBox", "AXSearchField", "AXMenuButton"]
let system: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton", "AXIncrementArrow", "AXDecrementArrow", "AXIncrementPage", "AXDecrementPage"]
var total = 0
var bad: [String] = []
var rolesSeen: [String: Int] = [:]

func walk(_ e: AXUIElement, depth: Int, path: String) {
    let role = str(e, "AXRole")
    let label = [str(e, "AXTitle"), str(e, "AXDescription"), str(e, "AXLabel"), str(e, "AXHelp")].first { !$0.isEmpty } ?? ""
    var value = ""
    if let v = attr(e, "AXValue") { value = (v as? String) ?? "" }
    if dump { print(String(repeating: "  ", count: depth) + "\(role) '\(label)' \(value.isEmpty ? "" : "= '\(value.prefix(30))'")") }
    if interactive.contains(role) {
        total += 1
        rolesSeen[role, default: 0] += 1
        let subrole = str(e, "AXSubrole")
        // Window and scroll-bar parts are supplied by AppKit and spoken through their role description.
        if system.contains(subrole) { total -= 1; rolesSeen[role, default: 1] -= 1; return }
        // Checkboxes inside table cells and fields that show their own value are spoken through the value / the cell.
        let speaks = !label.isEmpty || (role == "AXTextField" && !value.isEmpty) || (role == "AXButton" && !str(e, "AXTitle").isEmpty)
        if !speaks { bad.append("\(role)/\(subrole) at \(path)") }
    }
    guard depth < 30, let kids = attr(e, "AXChildren") as? [AXUIElement] else { return }
    for (i, k) in kids.enumerated() { walk(k, depth: depth + 1, path: path + "/\(role)[\(i)]") }
}

let app = AXUIElementCreateApplication(pid)
// An app that is busy must not hang the audit: every AX call gives up after 20 s (the first answer of a freshly started app can be slow), the whole walk after 120 s.
AXUIElementSetMessagingTimeout(app, 20)
DispatchQueue.global().asyncAfter(deadline: .now() + 120) { print("TIMEOUT: the Accessibility walk took more than 120 s"); exit(4) }
guard let windows = attr(app, "AXWindows") as? [AXUIElement], !windows.isEmpty else { print("no windows visible to the Accessibility API"); exit(3) }
for w in windows { walk(w, depth: 0, path: "window '\(str(w, "AXTitle"))'") }
if total < 3 { print("TOO-FEW: only \(total) interactive elements were visible; the app did not answer the Accessibility API"); exit(5) }
print("windows=\(windows.count) interactive=\(total) unlabelled=\(bad.count) roles=\(rolesSeen.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))")
for b in bad { print("  UNLABELLED \(b)") }
exit(bad.isEmpty ? 0 : 1)
