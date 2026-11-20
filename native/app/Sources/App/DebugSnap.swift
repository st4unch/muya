// Test hook (`snap <path.png>`): renders the main window and what sits on top of it (an editor sheet, the Settings modal
// with its dimming layer) into one PNG at 1x, from the views themselves. Works with a locked screen, where
// `screencapture` returns black. Used by the restyle diff loop; not part of any user flow.
import AppKit

enum DebugSnap {
    @MainActor private static func render(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let frameView = window.contentView?.superview else { return nil }
        window.contentView?.layoutSubtreeIfNeeded()
        let b = frameView.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width), pixelsHigh: Int(b.height), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = b.size
        frameView.cacheDisplay(in: b, to: rep)
        return rep
    }

    @MainActor static func snapshot(_ main: NSWindow, to path: String) -> String {
        guard let base = render(main) else { return "error: render" }
        let size = main.frame.size
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: out) else { return "error: context" }
        out.size = size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ctx
        base.draw(in: NSRect(origin: .zero, size: size))
        func overlay(_ w: NSWindow) {
            guard w.isVisible else { return }
            let r = NSRect(x: w.frame.minX - main.frame.minX, y: w.frame.minY - main.frame.minY, width: w.frame.width, height: w.frame.height)
            if w.contentView?.superview != nil, w.styleMask.contains(.borderless), w.backgroundColor.alphaComponent > 0, w.backgroundColor.alphaComponent < 1 {
                w.backgroundColor.setFill(); r.fill()               // the dimming layer
            } else if let rep = render(w) {
                NSGraphicsContext.saveGraphicsState()
                if w.backgroundColor == .clear { NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12).addClip() }   // rounded dialogs: cacheDisplay paints the masked corners opaque
                rep.draw(in: r)
                NSGraphicsContext.restoreGraphicsState()
            }
            for c in w.childWindows ?? [] { overlay(c) }
        }
        for c in main.childWindows ?? [] { overlay(c) }
        for s in main.sheets { overlay(s) }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = out.representation(using: .png, properties: [:]) else { return "error: png" }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return "error: \(error)" }
        return "ok \(Int(size.width))x\(Int(size.height))"
    }
}
