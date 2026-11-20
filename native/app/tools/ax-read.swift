// Reads the terminal text area of a running app through the Accessibility API (AXUIElement), the way a
// screen reader does: finds the AXTextArea whose label starts with "Terminal" in the front window and prints
// its AXValue (the visible rows), or a field with --info.
//
//   ax-read <pid> [--info]      exit 3 when no terminal element is found, 2 when not trusted
import ApplicationServices
import Foundation

guard CommandLine.arguments.count >= 2, let pid = pid_t(CommandLine.arguments[1]) else { print("usage: ax-read <pid> [--info]"); exit(64) }
guard AXIsProcessTrusted() else { print("NOT-TRUSTED: this process may not use the Accessibility API"); exit(2) }
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v as AnyObject? : nil
}
func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
    if depth > 14 { return nil }
    if (attr(e, "AXRole") as? String) == "AXTextArea", ((attr(e, "AXDescription") as? String) ?? (attr(e, "AXLabel") as? String) ?? "").hasPrefix("Terminal") { return e }
    for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { if let f = find(c, depth + 1) { return f } }
    return nil
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 5)
guard let term = find(app, 0) else { print("no terminal text area"); exit(3) }
if CommandLine.arguments.contains("--info") {
    var n: CFTypeRef?; AXUIElementCopyAttributeValue(term, "AXNumberOfCharacters" as CFString, &n)
    var vr: CFTypeRef?; AXUIElementCopyAttributeValue(term, "AXVisibleCharacterRange" as CFString, &vr)
    print("role=AXTextArea label=\((attr(term, "AXDescription") as? String) ?? "") chars=\(n.map { "\($0)" } ?? "?") visible=\(vr.map { "\($0)" } ?? "?")")
} else {
    print((attr(term, "AXValue") as? String) ?? "")
}
