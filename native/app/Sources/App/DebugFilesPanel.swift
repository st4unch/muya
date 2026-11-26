#if MUYA_TEST_HOOKS
// Test-hook commands of the open-files list (verify-files-panel.sh); only while MUYA_DEBUG_SOCKET is set.
//   of-state                    "frame=x,y,w,h hidden=… compact=… count=… offset=… max=… scrolls=… visible=a..b headerY=… current=…"
//   of-scroll <px>              scrolls the cards to that offset (clamped), answers like of-state
//   of-overdraw                 draws the list into a bitmap 1500 px taller/wider than its frame and counts the painted pixels
//                               that fall outside the frame: "below=N right=N above=N" (0 everywhere = nothing leaves the frame)
//   of-click <basename> name|x  a mouse press through the list's own mouseDown: on the right part of the NAME (the spot the old
//                               30 px close zone covered) or on the × button; scrolls the card into view first

import AppKit

extension DebugServer {
    func runFilesPanel(_ cmd: String, _ arg: String) -> String? {
        guard cmd.hasPrefix("of-"), let sb = controller.sidebar else { return nil }
        let l = sb.openFiles
        func state() -> String {
            let m = l.layoutModel, f = l.frame
            return "frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height)) hidden=\(l.isHidden) compact=\(l.compact) count=\(l.paths.count) offset=\(Int(l.scrollOffset)) max=\(Int(m.maxOffset)) scrolls=\(m.scrolls) visible=\(m.visible(offset: l.scrollOffset)) headerY=\(Int(sb.filesHeaderFrame.minY)) current=\(l.current.map { ($0 as NSString).lastPathComponent } ?? "-")"
        }
        switch cmd {
        case "of-state": return state()
        case "of-scroll": l.scroll(to: CGFloat(Double(arg) ?? 0)); return state()
        case "of-overdraw":
            let w = Int(l.bounds.width), h = Int(l.bounds.height), pad = 1500, W = w + 2 * pad, H = h + 2 * pad
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let g = NSGraphicsContext(bitmapImageRep: rep) else { return "error: no bitmap" }
            let cg = g.cgContext
            cg.translateBy(x: CGFloat(pad), y: CGFloat(H - pad)); cg.scaleBy(x: 1, y: -1)   // the list's top-left at (pad, pad), y down
            let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = flipped
            l.effectiveAppearance.performAsCurrentDrawingAppearance { l.draw(NSRect(x: -pad, y: -pad, width: W, height: H)) }
            NSGraphicsContext.restoreGraphicsState()
            var below = 0, right = 0, above = 0, inside = 0
            for y in 0..<H { for x in 0..<W {
                guard (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 else { continue }
                if y < pad { above += 1 } else if y >= pad + h { below += 1 } else if x < pad || x >= pad + w { right += 1 } else { inside += 1 }
            } }
            return "below=\(below) right=\(right) above=\(above) inside=\(inside)"
        case "of-click":
            let a = arg.split(separator: " ").map(String.init)
            guard a.count == 2, let i = l.paths.firstIndex(where: { ($0 as NSString).lastPathComponent == a[0] }) else { return "error: of-click <basename> name|x" }
            l.scroll(to: l.layoutModel.offsetRevealing(i, from: l.scrollOffset))
            let m = l.layoutModel, card = m.card(i, offset: l.scrollOffset), x = OpenFilesLayout.closeRect(card: card)
            let pt = a[1] == "x" ? NSPoint(x: x.midX, y: x.midY) : NSPoint(x: x.minX - 4, y: card.minY + 12)
            guard let e = NSEvent.mouseEvent(with: .leftMouseDown, location: l.convert(pt, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return "error: no event" }
            l.mouseDown(with: e)
            return "clicked \(a[1]) of \(a[0]) at \(Int(pt.x)),\(Int(pt.y))"
        default: return nil
        }
    }
}
#endif
