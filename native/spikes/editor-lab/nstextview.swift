// Faz 0 S7 baseline: Apple's NSTextView (TextKit 2) on a 5 MB source-like file, measured without
// the display: open (set text + lay out and draw the first screen), page-by-page scroll through the
// whole file (layout + draw per step), jump to end, memory. The same harness will drive STTextView
// and CodeEditTextView once fetching them is allowed.
//
//   swiftc -O nstextview.swift -o build/nstextview && build/nstextview <file>

import AppKit
import Darwin

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func ms(_ t: UInt64) -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t) / 1e6 }
func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func pct(_ v: [Double], _ p: Double) -> Double { let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))] }

@MainActor
func run(path: String) {
    let text = try! String(contentsOfFile: path, encoding: .utf8)
    let base = footprintMB()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    // `--tk1`: classic TextKit 1 with non-contiguous layout, for comparison.
    let scroll: NSScrollView
    let view: NSTextView
    if CommandLine.arguments.contains("--tk1") {
        scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        view = NSTextView(usingTextLayoutManager: false)
        view.layoutManager?.allowsNonContiguousLayout = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
    } else {
        scroll = NSTextView.scrollableTextView()
        view = scroll.documentView as! NSTextView
    }
    view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    view.isRichText = false
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isContinuousSpellCheckingEnabled = false
    scroll.frame = window.contentView!.bounds
    window.contentView!.addSubview(scroll)

    // The window is never on screen, so display() may draw nothing; render the visible area into a
    // bitmap instead, which forces layout and drawing for real.
    let rep = scroll.bitmapImageRepForCachingDisplay(in: NSRect(x: 0, y: 0, width: 1000, height: 800))!
    func draw() { scroll.cacheDisplay(in: scroll.bounds, to: rep) }

    // Open: content in, first screen laid out and drawn.
    var t = now()
    view.string = text
    scroll.layoutSubtreeIfNeeded()
    draw()
    let openMs = ms(t)
    let layoutKind = view.textLayoutManager != nil ? "TextKit 2" : "TextKit 1 (fell back)"
    let openMB = footprintMB() - base

    // Scroll page by page through the whole file.
    let page = scroll.contentView.bounds.height
    var steps: [Double] = []
    var y: CGFloat = 0
    let total = view.frame.height
    t = now()
    while y < total - page, steps.count < 20000 {
        y += page
        let s = now()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        draw()
        steps.append(ms(s))
        // The document height grows as TextKit 2 lays out lazily.
    }
    let scrollTotal = ms(t)
    let scrolledMB = footprintMB() - base

    // Mitigation probe: drop layout outside the viewport (an editor would do this as it scrolls).
    t = now()
    if let tlm = view.textLayoutManager {
        tlm.invalidateLayout(for: tlm.documentRange)
        scroll.layoutSubtreeIfNeeded()
        scroll.display()
    }
    let evictMs = ms(t)
    let evictedMB = footprintMB() - base

    t = now()
    view.scrollToEndOfDocument(nil)
    draw()
    let endMs = ms(t)

    // Typing at the end: insert 200 characters one by one (layout + draw each).
    var typeMs: [Double] = []
    for c in "Pijamalı hasta yağız şoföre çabucak güvendi. ".repeated(5).prefix(200) {
        let s = now()
        view.insertText(String(c), replacementRange: view.selectedRange())
        draw()
        typeMs.append(ms(s))
    }

    print("NSTextView \(layoutKind): file \(String(format: "%.1f", Double(text.utf8.count) / 1e6)) MB, \(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
    print(String(format: "open + first screen %.0f ms; footprint +%.0f MB after open, +%.0f MB after scrolling the whole file", openMs, openMB, scrolledMB))
    print(String(format: "scroll %d pages in %.0f ms: per page p50 %.2f p95 %.2f p99 %.2f max %.2f ms", steps.count, scrollTotal, pct(steps, 0.5), pct(steps, 0.95), pct(steps, 0.99), steps.max() ?? 0))
    print(String(format: "invalidate all layout: %.0f ms, footprint +%.0f MB", evictMs, evictedMB))
    print(String(format: "jump to end %.0f ms; typing at end per key p50 %.2f p95 %.2f max %.2f ms; footprint after %.0f MB", endMs, pct(typeMs, 0.5), pct(typeMs, 0.95), typeMs.max() ?? 0, footprintMB()))
}

extension String { func repeated(_ n: Int) -> String { String(repeating: self, count: n) } }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated { run(path: CommandLine.arguments[1]) }
