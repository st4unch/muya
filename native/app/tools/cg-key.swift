// Posts one real key press (CGEvent, down then up) to one process:  cg-key <pid> <combo>
// combo = [cmd+][shift+][opt+][ctrl+]<key>; key = a-z, 0-9, = - [ ] , . / return enter esc tab space delete left right up down.
// Exit 2: this process may not post events (grant the terminal "Accessibility").
// Exit 3: the system frontmost application is not <pid> — NOTHING is posted (a key meant for the dev app must never
// reach another app, e.g. the Muya running this session: Cmd+W/T/Q went there once). `cg-key <pid> --check` only checks.
import AppKit
import Carbon.HIToolbox
import ApplicationServices
import Foundation

let codes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
    "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
]
guard CommandLine.arguments.count >= 3, let pid = pid_t(CommandLine.arguments[1]) else { print("usage: cg-key <pid> <combo>"); exit(64) }
let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
if front != pid { print("NOT-FRONTMOST: frontmost pid is \(front), not \(pid) (\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")) — no key posted"); exit(3) }
if CommandLine.arguments[2] == "--check" { print("frontmost ok"); exit(0) }
guard AXIsProcessTrusted() else { print("NOT-TRUSTED: this process may not post events"); exit(2) }
var flags: CGEventFlags = []
var name = ""
let parts = CommandLine.arguments[2].split(separator: "+", omittingEmptySubsequences: false).map(String.init)
var i = 0
while i < parts.count {
    let p = parts[i]
    switch p {
    case "cmd": flags.insert(.maskCommand)
    case "shift": flags.insert(.maskShift)
    case "opt": flags.insert(.maskAlternate)
    case "ctrl": flags.insert(.maskControl)
    case "": if i + 1 < parts.count, parts[i + 1] == "" || i == parts.count - 2 { name = "="; i += 1 } // "cmd++" = the "+" key typed as shift+=
    default: name = p
    }
    i += 1
}
// Key codes are per keyboard LAYOUT (the table above is the US one; on a Turkish keyboard code 24 types "-" and "=" needs
// Shift+0): characters are looked up in the CURRENT layout, so the app receives the character the test names.
let named: Set<String> = ["return", "enter", "tab", "space", "delete", "esc", "left", "right", "down", "up"]
func layoutKey(for ch: Character) -> (CGKeyCode, Bool)? {
    guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    for shifted in [false, true] {
        for code in 0..<128 {
            var dead: UInt32 = 0, len = 0; var out = [UniChar](repeating: 0, count: 4)
            let ok = data.withUnsafeBytes { p -> Bool in
                UCKeyTranslate(p.bindMemory(to: UCKeyboardLayout.self).baseAddress!, UInt16(code), UInt16(kUCKeyActionDown), shifted ? 2 : 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &out) == noErr
            }
            if ok, len == 1, Character(UnicodeScalar(out[0])!) == ch { return (CGKeyCode(code), shifted) }
        }
    }
    return nil
}
var codeOpt: CGKeyCode? = codes[name]
if !named.contains(name), name.count == 1, let (c, needShift) = layoutKey(for: Character(name)) { codeOpt = c; if needShift { flags.insert(.maskShift) } }
guard let code = codeOpt else { print("unknown key \(name)"); exit(64) }
// Delivery: the SESSION tap (reaches only the frontmost app, once) — NOT postToPid: with the target frontmost, macOS delivers
// an event posted to its pid twice (measured in the native app: every Cmd+key ran twice, once via the key monitor and once
// straight into the window). The frontmost pid is re-checked right before each post, so a key can only go to the dev app;
// if the focus moved between key-down and key-up the up goes to the pid (to release the key there) and we exit 3.
// A pause between down and up is needed: posted back to back, the pair was dropped.
func frontmostIsTarget() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
let src = CGEventSource(stateID: .combinedSessionState)
var lost = false
for down in [true, false] {
    guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
    e.flags = flags
    if frontmostIsTarget() { e.post(tap: .cgSessionEventTap) } else if !down { e.postToPid(pid); lost = true } else { print("NOT-FRONTMOST: focus moved before the key — no key posted"); exit(3) }
    usleep(60_000)
}
if lost { print("NOT-FRONTMOST: focus moved between key-down and key-up"); exit(3) }
