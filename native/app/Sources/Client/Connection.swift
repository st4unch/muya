// A connection to muyad: Hello/Welcome handshake, then one reader thread. Replies (ok, error,
// sessions, spawned, ...) come back in request order and complete the oldest pending request;
// everything else (output, attached, screen, event, exited) goes to `onFrame`.

import Darwin
import Foundation

public enum ClientError: Error, CustomStringConvertible {
    case socket(String)
    case handshake(String)
    case timeout
    case closed
    /// The socket or the process behind it failed the identity check; nothing was sent to it.
    case untrusted(String)
    /// No connection to muyad exists right now (never made, or lost). The text says what the app is doing about it.
    case notConnected(String)
    case server(code: String, message: String)
    /// The daemon refused the hello for its protocol version and says what to do about it (AC19).
    case incompatible(Incompat)

    public var description: String {
        switch self {
        case let .socket(m): return "socket: \(m)"
        case let .handshake(m): return "handshake: \(m)"
        case .timeout: return "muyad did not answer in time"
        case .closed: return "connection closed"
        case let .untrusted(m): return "The background service could not be verified and Muya did not connect to it: \(m). Restart your Mac or reinstall Muya if this persists."
        case let .notConnected(m): return m
        case let .server(c, m): return "muyad \(c): \(m)"
        case let .incompatible(i): return "muyad runs protocol \(i.daemon.major).\(i.daemon.minor), this app speaks \(i.client.major).\(i.client.minor)"
        }
    }
}

public final class MuyadConnection: @unchecked Sendable {
    private let fd: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var pending: [(Result<Control, ClientError>) -> Void] = []
    private var rpcWaiting: [UInt64: @Sendable (Result<Any, ClientError>) -> Void] = [:]
    private var nextRpc: UInt64 = 1
    private var decoder = FrameDecoder()
    private var closedFlag = false
    public private(set) var serverBuild = ""
    /// Protocol minor the server announced (0 = no `detach`).
    public private(set) var serverMinor: UInt16 = 0

    /// The process on the other end of the socket (the running muyad), as the kernel reports it.
    public var peerPID: Int32? { ServiceIdentity.peerPID(fd: fd) }

    /// Called on the reader thread for every non-reply frame.
    public var onFrame: (@Sendable (Frame) -> Void)?
    /// Called once, on the reader thread, when the stream ends.
    public var onClose: (@Sendable () -> Void)?

    /// Connects and completes the handshake synchronously (an `incompatible` or `refused`
    /// answer is thrown here, not later).
    /// `announce` replaces the version in the hello: the daemon's own `Incompat.speak` keeps a running daemon of another
    /// major usable ("later"); the daemon then accepts only the messages that version knows.
    public init(path: String, build: String, timeout: TimeInterval = 5, announce: (major: UInt16, minor: UInt16)? = nil, peer: PeerVerify.Policy = .strict) throws {
        if peer == .strict, let why = PeerVerify.checkSocketFile(path: path) { throw ClientError.untrusted(why) }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.socket(String(cString: strerror(errno))) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        var buffer: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &buffer, 4)
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &buffer, 4)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { closedFlag = true; Darwin.close(fd); throw ClientError.socket("path too long (\(bytes.count) bytes)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { let e = String(cString: strerror(errno)); closedFlag = true; Darwin.close(fd); throw ClientError.socket("\(path): \(e)") }

        if let why = PeerVerify.checkPeer(fd: fd, policy: peer) { closedFlag = true; Darwin.close(fd); throw ClientError.untrusted(why) }
        let hello: Control = announce.map { .helloAs(major: $0.major, minor: $0.minor, role: "app", build: build) } ?? .hello(role: "app", build: build)
        let announcedMajor = announce?.major ?? protoMajor
        try write(Frame.control(hello).encoded())
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { closedFlag = true; Darwin.close(fd); throw ClientError.handshake(n == 0 ? "muyad closed the connection" : "no answer") }
            decoder.push(Data(buf[0 ..< n]))
            let frame: Frame?
            do { frame = try decoder.next() } catch { closedFlag = true; Darwin.close(fd); throw ClientError.handshake("\(error)") }
            guard let frame else { continue }
            switch frame {
            case let .control(.welcome(major, minor, serverBuild)):
                guard major == announcedMajor else { closedFlag = true; Darwin.close(fd); throw ClientError.handshake("protocol \(major) is not \(protoMajor)") }
                self.serverBuild = serverBuild
                self.serverMinor = minor
            case let .control(.incompatible(_, detail)): closedFlag = true; Darwin.close(fd); throw ClientError.incompatible(detail)
            case let .control(.error(code, message)): closedFlag = true; Darwin.close(fd); throw ClientError.server(code: code, message: message)
            default: closedFlag = true; Darwin.close(fd); throw ClientError.handshake("unexpected \(frame)")
            }
            break
        }
        var none = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &none, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit { if !closedFlag { Darwin.close(fd) } }

    /// Starts the reader thread. Set `onFrame` / `onClose` first.
    public func start() {
        let t = Thread { [self] in readLoop() }
        t.name = "muyad-reader"
        t.qualityOfService = .userInteractive
        t.stackSize = 1 << 20
        t.start()
    }

    public func close() {
        stateLock.lock()
        let was = closedFlag
        closedFlag = true
        stateLock.unlock()
        if !was { shutdown(fd, SHUT_RDWR) } // wakes the reader, which closes the descriptor
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        outer: while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            buf.withUnsafeBytes { decoder.push(UnsafeRawBufferPointer(rebasing: $0[0 ..< n])) }
            while true {
                let frame: Frame?
                do { frame = try decoder.next() } catch { break outer }
                guard let frame else { break }
                if case let .control(c) = frame, Self.isReply(c) { complete(.success(c)) }
                else if case let .control(.rpcReply(req, ok, result)) = frame { finishRpc(req, ok: ok, result: result) }
                else { onFrame?(frame) }
            }
        }
        stateLock.lock()
        closedFlag = true
        let waiting = pending
        pending = []
        let rpcs = rpcWaiting
        rpcWaiting = [:]
        stateLock.unlock()
        Darwin.close(fd)
        for w in waiting { w(.failure(.closed)) }
        for (_, w) in rpcs { w(.failure(.closed)) }
        onClose?()
    }

    static func isReply(_ c: Control) -> Bool {
        switch c {
        case .ok, .error, .sessions, .spawned, .welcome, .upgrading, .incompatible: return true
        default: return false
        }
    }

    private func finishRpc(_ req: UInt64, ok: Bool, result: String) {
        stateLock.lock()
        let h = rpcWaiting.removeValue(forKey: req)
        stateLock.unlock()
        guard let h else { return }
        if !ok { h(.failure(.server(code: "rpc", message: result))); return }
        guard let v = try? JSONSerialization.jsonObject(with: Data(result.utf8), options: [.fragmentsAllowed]) else { h(.failure(.server(code: "rpc", message: "unreadable answer"))); return }
        h(.success(v))
    }

    /// A call into the daemon's core logic (protocol minor 2). The completion runs on the reader thread; the
    /// result is the decoded JSON value (`NSNull` for "no result"). Returns the request id for [`cancelCall`].
    @discardableResult
    public func call(_ method: String, _ params: [String: Any] = [:], completion: @escaping @Sendable (Result<Any, ClientError>) -> Void) -> UInt64 {
        stateLock.lock()
        let req = nextRpc
        nextRpc += 1
        if closedFlag { stateLock.unlock(); completion(.failure(.closed)); return req }
        rpcWaiting[req] = completion
        stateLock.unlock()
        let text = (try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        // An rpc has no ordered reply (its `rpc_reply` carries the id): it must not take a slot in `pending`.
        do { try write(Frame.control(.rpc(req: req, method: method, params: text)).encoded()) } catch { close() }
        return req
    }

    /// Asks the daemon to stop a running call; its completion still runs (with whatever it had).
    public func cancelCall(_ req: UInt64) { send(.rpcCancel(req: req)) }

    private func complete(_ r: Result<Control, ClientError>) {
        stateLock.lock()
        let h = pending.isEmpty ? nil : pending.removeFirst()
        stateLock.unlock()
        h?(r)
    }

    private func write(_ data: Data) throws {
        writeLock.lock(); defer { writeLock.unlock() }
        try data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ClientError.closed
                }
                off += n
            }
        }
    }

    /// Sends a request and hands its reply (or the failure) to `completion` on the reader thread.
    /// The queue entry and the write happen under one lock so reply order always matches.
    public func send(_ c: Control, completion: ((Result<Control, ClientError>) -> Void)? = nil) {
        writeLock.lock()
        stateLock.lock()
        if closedFlag { stateLock.unlock(); writeLock.unlock(); completion?(.failure(.closed)); return }
        pending.append(completion ?? { _ in })
        stateLock.unlock()
        let data = Frame.control(c).encoded()
        var failed = false
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; failed = true; return }
                off += n
            }
        }
        writeLock.unlock()
        if failed { close() }
    }

    /// Raw terminal input for a session (IME commits, typed text): muyad forwards it to the PTY.
    public func sendInput(session: UInt64, _ data: Data) {
        guard !data.isEmpty else { return }
        for start in stride(from: 0, to: data.count, by: 1 << 20) {
            let chunk = data[data.startIndex + start ..< data.startIndex + min(start + (1 << 20), data.count)]
            do { try write(Frame.input(session: session, data: Data(chunk)).encoded()) } catch { close(); return }
        }
    }

    /// Blocking request/reply. Never call from the reader thread.
    public func request(_ c: Control, timeout: TimeInterval = 5) throws -> Control {
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<Control, ClientError> = .failure(.timeout)
        send(c) { result = $0; sem.signal() }
        guard sem.wait(timeout: .now() + timeout) == .success else { throw ClientError.timeout }
        let reply = try result.get()
        if case let .error(code, message) = reply { throw ClientError.server(code: code, message: message) }
        return reply
    }
}
