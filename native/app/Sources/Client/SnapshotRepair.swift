// muyad's attach snapshot (muyad actor.rs `snapshot`) positions the cursor (`ESC [ r ; c H`) and
// then replays the tab stops (`ESC [ 3 g`, then `ESC [ n G ESC H` per stop). Those cursor moves
// leave the cursor on the last tab stop, so a freshly attached replica shows the cursor in the
// wrong column. Until the daemon orders them the other way round, the client puts the cursor
// back by repeating the last absolute cursor position that preceded the tab-stop block.

import Foundation

public func repairSnapshotCursor(_ snapshot: Data) -> Data {
    let bytes = [UInt8](snapshot)
    let clearTabs: [UInt8] = [0x1b, 0x5b, 0x33, 0x67] // ESC [ 3 g
    guard bytes.count > clearTabs.count,
          let tabs = (0 ... bytes.count - clearTabs.count).first(where: { Array(bytes[$0 ..< $0 + 4]) == clearTabs }) else { return snapshot }
    // Walk back to the last `ESC [ digits ; digits H` before the tab-stop block.
    var i = tabs - 1
    while i > 1 {
        if bytes[i] == 0x48 { // 'H'
            var j = i - 1
            var sawSemicolon = false, digits = 0
            while j >= 0, (0x30 ... 0x39).contains(bytes[j]) || bytes[j] == 0x3b {
                if bytes[j] == 0x3b { if sawSemicolon { break }; sawSemicolon = true }
                digits += 1
                j -= 1
            }
            if j >= 1, bytes[j] == 0x5b, bytes[j - 1] == 0x1b, sawSemicolon, digits >= 3 {
                return snapshot + Data(bytes[(j - 1) ... i])
            }
        }
        i -= 1
    }
    return snapshot
}
