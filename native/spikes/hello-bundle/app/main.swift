// Faz 0 S2 hello app: registers the nested ptyd/muyad LaunchAgents through SMAppService and
// talks to muyad over its socket. Command-line flags drive the same code paths for scripted
// checks; with no flags it opens a small window.

import AppKit
import Darwin
import ServiceManagement

let agentPlists = ["com.staunch.muya.spike.ptyd.plist", "com.staunch.muya.spike.muyad.plist"]

func statusName(_ s: SMAppService.Status) -> String {
    switch s {
    case .notRegistered: return "notRegistered"
    case .enabled: return "enabled"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    @unknown default: return "unknown(\(s.rawValue))"
    }
}

func status() -> String {
    agentPlists.map { "\($0): \(statusName(SMAppService.agent(plistName: $0).status))" }.joined(separator: "\n")
}

func register() -> String {
    agentPlists.map { name in
        do {
            try SMAppService.agent(plistName: name).register()
            return "\(name): registered"
        } catch {
            return "\(name): register failed: \(error)"
        }
    }.joined(separator: "\n")
}

func unregister() -> String {
    agentPlists.map { name in
        do {
            try SMAppService.agent(plistName: name).unregister()
            return "\(name): unregistered"
        } catch {
            return "\(name): unregister failed: \(error)"
        }
    }.joined(separator: "\n")
}

/// One request line to `<name>.sock`, one reply line back.
func request(_ name: String, _ line: String) -> String {
    let path = NSHomeDirectory() + "/Library/Application Support/MuyaSpike/\(name).sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return "error: socket: \(errno)" }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return "error: socket path too long" }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: bytes)
        buf[bytes.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return "error: connect \(name): \(String(cString: strerror(errno)))" }
    let out = Array((line + "\n").utf8)
    guard write(fd, out, out.count) == out.count else { return "error: write" }
    var reply = [UInt8]()
    var byte: UInt8 = 0
    while read(fd, &byte, 1) == 1, byte != 10 { reply.append(byte) }
    return String(decoding: reply, as: UTF8.self)
}

/// `n` app→muyad→ptyd round trips over one kept-open connection: the keystroke path.
func bench(_ n: Int) -> String {
    let path = NSHomeDirectory() + "/Library/Application Support/MuyaSpike/muyad.sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return "error: socket" }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        buf.copyBytes(from: bytes)
        buf[bytes.count] = 0
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard rc == 0 else { return "error: connect muyad" }
    let ping = Array("relay-ping\n".utf8)
    var buf = [UInt8](repeating: 0, count: 64)
    var ns = [UInt64]()
    ns.reserveCapacity(n)
    for _ in 0..<n {
        let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        guard write(fd, ping, ping.count) == ping.count else { return "error: write" }
        var got = 0
        repeat {
            let r = read(fd, &buf[got], buf.count - got)
            guard r > 0 else { return "error: read" }
            got += r
        } while buf[got - 1] != 10
        guard String(decoding: buf[0..<got], as: UTF8.self) == "pong\n" else {
            return "error: \(String(decoding: buf[0..<got], as: UTF8.self))"
        }
        ns.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t)
    }
    ns.sort()
    func q(_ p: Double) -> String { String(format: "%.1f", Double(ns[min(ns.count - 1, Int(Double(ns.count) * p))]) / 1000) }
    return "app->muyad->ptyd n=\(n) us p50=\(q(0.5)) p95=\(q(0.95)) p99=\(q(0.99)) max=\(q(1))"
}

/// Polls until muyad (and through it ptyd) answers, to time agent start-up after register.
func hello(waitSeconds: Double) -> String {
    let start = Date()
    var last = ""
    repeat {
        last = request("muyad", "hello")
        if last.hasPrefix("{") {
            return "after \(Int(Date().timeIntervalSince(start) * 1000)) ms: \(last)"
        }
        usleep(50_000)
    } while Date().timeIntervalSince(start) < waitSeconds
    return last
}

let args = CommandLine.arguments
func arg(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

if args.count > 1 {
    switch args[1] {
    case "--status": print(status())
    case "--register": print(register())
    case "--unregister": print(unregister())
    case "--hello": print(hello(waitSeconds: Double(arg(after: "--wait") ?? "0") ?? 0))
    case "--envprobe": print(request("muyad", "envprobe"))
    case "--probe": print(request("muyad", "probe \(arg(after: "--probe") ?? "ptyd")"))
    case "--bench":
        let n = Int(arg(after: "--bench") ?? "2000") ?? 2000
        print(bench(n))
        print("muyad->ptyd " + request("muyad", "bench \(n)"))
    case "--direct": print(request(arg(after: "--direct") ?? "ptyd", "hello"))
    default: print("usage: --status | --register | --unregister | --hello [--wait s] | --probe ptyd|muyad | --direct ptyd|muyad")
    }
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let output = NSTextView()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Muya Spike"
        let buttons = NSStackView(views: [
            NSButton(title: "Register", target: self, action: #selector(doRegister)),
            NSButton(title: "Hello", target: self, action: #selector(doHello)),
            NSButton(title: "Status", target: self, action: #selector(doStatus)),
            NSButton(title: "Unregister", target: self, action: #selector(doUnregister)),
        ])
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = NSScrollView()
        scroll.documentView = output
        scroll.hasVerticalScroller = true
        output.autoresizingMask = [.width]
        let stack = NSStackView(views: [buttons, scroll])
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        window.contentView = stack
        window.center()
        window.makeKeyAndOrderFront(nil)
        show(status())
    }

    func show(_ text: String) { output.string += text + "\n" }
    @objc func doRegister() { show(register()) }
    @objc func doHello() {
        Task { show(await Task.detached { hello(waitSeconds: 5) }.value) }
    }
    @objc func doStatus() { show(status()) }
    @objc func doUnregister() { show(unregister()) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
