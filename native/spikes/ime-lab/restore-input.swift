// Puts the operator's input sources back after an IME run: selects Turkish Q and disables the
// Japanese input method. run.sh calls it even if ImeLab hangs or is killed.
import Carbon
func src(_ id: String) -> TISInputSource? {
    (TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource])?.first
}
if let tr = src("com.apple.keylayout.Turkish-QWERTY-PC") { print("select Turkish-QWERTY-PC:", TISSelectInputSource(tr)) }
if let im = src("com.apple.inputmethod.Kotoeri.RomajiTyping") { print("disable Kotoeri RomajiTyping:", TISDisableInputSource(im)) }
let cur = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
print("current:", Unmanaged<CFString>.fromOpaque(TISGetInputSourceProperty(cur, kTISPropertyInputSourceID)).takeUnretainedValue())
