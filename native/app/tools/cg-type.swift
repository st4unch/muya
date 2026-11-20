// Posts real CGEvent key events to one process (not to the HID tap: other apps never see them), one per
// character, carrying the character as the event's Unicode string, the way a keyboard layout delivers it.
//
//   cg-type <pid> <text|@file> [--caps|--caps-for CHARS] [--gap-ms N]    "\n" = Return; "\u{4}" = Ctrl-D
//   cg-type <pid> --key <name[+shift|cmd|opt|ctrl]>   one named key (tab return esc space left right up down delete a c k w comma n f 1 2)
//   --caps  sets the Caps Lock flag on every event (Turkish layout: i -> İ, ı -> I)
//   --caps-for <chars>  sets it only for those characters (a typist who holds Caps Lock for İ and I)
// Per-character key codes follow the Turkish Q layout for ı (kVK 34) and i/İ (kVK 40); everything else uses kVK 0.
// Exit 2: this process may not post events (grant the terminal "Accessibility" / "Input Monitoring").
import ApplicationServices
import Foundation

// cg-type <pid> --key tab|shift+tab|return|esc|space|left|right|up|down|delete|cmd+k|...   one named key with modifiers
if CommandLine.arguments.count >= 4, CommandLine.arguments[2] == "--key", let pid = pid_t(CommandLine.arguments[1]) {
    guard AXIsProcessTrusted() else { print("NOT-TRUSTED: this process may not post events"); exit(2) }
    let codes: [String: CGKeyCode] = ["tab": 48, "return": 36, "esc": 53, "space": 49, "left": 123, "right": 124, "down": 125, "up": 126, "delete": 51,
                                      "a": 0, "c": 8, "k": 40, "w": 13, "comma": 43, "n": 45, "f": 3, "1": 18, "2": 19]
    var flags: CGEventFlags = []
    var name = ""
    for part in CommandLine.arguments[3].split(separator: "+") {
        switch part {
        case "shift": flags.insert(.maskShift)
        case "cmd": flags.insert(.maskCommand)
        case "opt": flags.insert(.maskAlternate)
        case "ctrl": flags.insert(.maskControl)
        default: name = String(part)
        }
    }
    guard let code = codes[name] else { print("unknown key \(name)"); exit(64) }
    let src = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
        e.flags = flags
        e.postToPid(pid)
    }
    exit(0)
}

guard CommandLine.arguments.count >= 3, let pid = pid_t(CommandLine.arguments[1]) else { print("usage: cg-type <pid> <text|@file> [--caps] [--gap-ms N]"); exit(64) }
var text = CommandLine.arguments[2]
if text.hasPrefix("@") { text = (try? String(contentsOfFile: String(text.dropFirst()), encoding: .utf8)) ?? "" }
let caps = CommandLine.arguments.contains("--caps")
var capsFor = Set<Character>()
if let i = CommandLine.arguments.firstIndex(of: "--caps-for"), i + 1 < CommandLine.arguments.count { capsFor = Set(CommandLine.arguments[i + 1]) }
var gapMs = 4
if let i = CommandLine.arguments.firstIndex(of: "--gap-ms"), i + 1 < CommandLine.arguments.count { gapMs = Int(CommandLine.arguments[i + 1]) ?? 4 }
guard AXIsProcessTrusted() else { print("NOT-TRUSTED: this process may not post events"); exit(2) }
let src = CGEventSource(stateID: .privateState)

func post(_ ch: Character) {
    let s = String(ch)
    let code: CGKeyCode
    var flags: CGEventFlags = (caps || capsFor.contains(ch)) ? .maskAlphaShift : []
    switch s {
    case "\n": code = 36
    case "\u{4}": code = 2; flags.insert(.maskControl)
    case "\u{3}": code = 8; flags.insert(.maskControl)
    case "ı", "I": code = 34
    case "i", "İ": code = 40
    default: code = 0
    }
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
        e.flags = flags
        if s != "\n" && s != "\u{4}" && s != "\u{3}" { var u = Array(s.utf16); e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u) }
        e.postToPid(pid)
    }
    usleep(UInt32(gapMs) * 1000)
}
for ch in text { post(ch) }
