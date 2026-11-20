// Wire format of muya-proto v1 (native/crates/muya-proto/src/lib.rs): frames are a u32 big-endian
// length followed by a body whose first byte is the kind (1 control JSON, 2 output, 3 input).

import Foundation

public let protoMajor: UInt16 = 1
public let protoMinor: UInt16 = 3
/// First server minor that understands `detach`.
public let minorDetach: UInt16 = 1
/// First server minor that understands `rpc` / `rpc_cancel`.
public let minorRpc: UInt16 = 2
/// First server minor that understands `upgrade` / `upgrading` and reports `cwd` in its session list (AC19).
public let minorUpgrade: UInt16 = 3
public let maxFrame = 16 << 20

public let modShift: UInt16 = 1
public let modAlt: UInt16 = 2
public let modCtrl: UInt16 = 4
public let modSuper: UInt16 = 8

public struct SessionInfo: Equatable, Sendable {
    public var id: UInt64
    public var pid: Int32
    public var cols: UInt16
    public var rows: UInt16
    public var endSeq: UInt64
    public var exited: Int32?
    /// Where the session was started (minor 3; empty when the daemon does not say).
    public var cwd: String = ""
}

/// A protocol version as a daemon or client reports it (muya-proto `Version`).
public struct ProtoVersion: Equatable, Sendable {
    public var major: UInt16, minor: UInt16, build: String
    public init(major: UInt16, minor: UInt16, build: String) { self.major = major; self.minor = minor; self.build = build }
}

/// One live session as the restart dialog and the resume plan describe it (muya-proto `LiveSession`).
public struct LiveSession: Equatable, Sendable {
    public var id: UInt64
    public var pid: Int32
    public var cwd: String
    public var claudeSessionId: String?
    public var exited: Int32?
    public init(id: UInt64, pid: Int32, cwd: String, claudeSessionId: String? = nil, exited: Int32? = nil) {
        self.id = id; self.pid = pid; self.cwd = cwd; self.claudeSessionId = claudeSessionId; self.exited = exited
    }
}

/// Why a hello was refused for its version (muya-proto `Incompat`): who runs what, the hello that keeps the running
/// daemon usable ("later"), and the sessions a restart would end.
public struct Incompat: Equatable, Sendable {
    public var daemon: ProtoVersion, client: ProtoVersion, required: ProtoVersion, speak: ProtoVersion
    public var sessions: [LiveSession]
    public init(daemon: ProtoVersion, client: ProtoVersion, required: ProtoVersion, speak: ProtoVersion, sessions: [LiveSession]) {
        self.daemon = daemon; self.client = client; self.required = required; self.speak = speak; self.sessions = sessions
    }
}

public enum Control: Equatable, Sendable {
    case hello(role: String, build: String)
    case welcome(major: UInt16, minor: UInt16, serverBuild: String)
    case error(code: String, message: String)
    case spawn(argv: [String], cwd: String, env: [[String]], cols: UInt16, rows: UInt16)
    case spawned(id: UInt64, pid: Int32)
    case list
    case sessions([SessionInfo])
    case attach(id: UInt64)
    case detach(id: UInt64)
    case attached(id: UInt64, startSeq: UInt64, endSeq: UInt64, modes: String)
    case resize(id: UInt64, cols: UInt16, rows: UInt16)
    case close(id: UInt64)
    case key(id: UInt64, key: String, mods: UInt16, text: String?)
    case paste(id: UInt64, text: String)
    case mouse(id: UInt64, col: UInt16, row: UInt16, button: String, action: String, mods: UInt16)
    case ok
    case exited(id: UInt64, status: Int32)
    case screen(id: UInt64, state: String)
    case event(name: String, payload: String)
    case rpc(req: UInt64, method: String, params: String)
    case rpcReply(req: UInt64, ok: Bool, result: String)
    case rpcCancel(req: UInt64)
    /// A hello that announces another version than this build's (AC19 "later": the daemon's own `speak` version).
    case helloAs(major: UInt16, minor: UInt16, role: String, build: String)
    /// An `incompatible` error that carries the version-skew detail (a plain one stays `.error`).
    case incompatible(message: String, detail: Incompat)
    /// "Restart sessions now" (minor 3, app).
    case upgrade
    case upgrading(plan: [LiveSession], ptydRestarting: Bool)
}

public enum Frame: Equatable, Sendable {
    case control(Control)
    case output(session: UInt64, seq: UInt64, data: Data)
    case input(session: UInt64, data: Data)
}

public enum WireError: Error, Equatable {
    case tooLarge(Int)
    case empty
    case unknownKind(UInt8)
    case truncated
    case json(String)
}

// MARK: - Control <-> JSON

extension Control {
    var json: [String: Any] {
        switch self {
        case let .hello(role, build): return ["type": "hello", "major": Int(protoMajor), "minor": Int(protoMinor), "role": role, "build": build]
        case let .welcome(major, minor, serverBuild): return ["type": "welcome", "major": Int(major), "minor": Int(minor), "server_build": serverBuild]
        case let .error(code, message): return ["type": "error", "code": code, "message": message]
        case let .spawn(argv, cwd, env, cols, rows): return ["type": "spawn", "argv": argv, "cwd": cwd, "env": env, "cols": Int(cols), "rows": Int(rows)]
        case let .spawned(id, pid): return ["type": "spawned", "id": id, "pid": Int(pid)]
        case .list: return ["type": "list"]
        case let .sessions(list):
            return ["type": "sessions", "sessions": list.map { s -> [String: Any] in
                var d: [String: Any] = ["id": s.id, "pid": Int(s.pid), "cols": Int(s.cols), "rows": Int(s.rows), "end_seq": s.endSeq]
                d["exited"] = s.exited.map { Int($0) } ?? NSNull()
                if !s.cwd.isEmpty { d["cwd"] = s.cwd }
                return d
            }]
        case let .attach(id): return ["type": "attach", "id": id]
        case let .detach(id): return ["type": "detach", "id": id]
        case let .attached(id, start, end, modes): return ["type": "attached", "id": id, "start_seq": start, "end_seq": end, "modes": modes]
        case let .resize(id, cols, rows): return ["type": "resize", "id": id, "cols": Int(cols), "rows": Int(rows)]
        case let .close(id): return ["type": "close", "id": id]
        case let .key(id, key, mods, text):
            var d: [String: Any] = ["type": "key", "id": id, "key": key, "mods": Int(mods)]
            d["text"] = text ?? NSNull()
            return d
        case let .paste(id, text): return ["type": "paste", "id": id, "text": text]
        case let .mouse(id, col, row, button, action, mods):
            return ["type": "mouse", "id": id, "col": Int(col), "row": Int(row), "button": button, "action": action, "mods": Int(mods)]
        case .ok: return ["type": "ok"]
        case let .exited(id, status): return ["type": "exited", "id": id, "status": Int(status)]
        case let .screen(id, state): return ["type": "screen", "id": id, "state": state]
        case let .event(name, payload): return ["type": "event", "name": name, "payload": payload]
        case let .rpc(req, method, params): return ["type": "rpc", "req": req, "method": method, "params": params]
        case let .rpcReply(req, ok, result): return ["type": "rpc_reply", "req": req, "ok": ok, "result": result]
        case let .rpcCancel(req): return ["type": "rpc_cancel", "req": req]
        case let .helloAs(major, minor, role, build): return ["type": "hello", "major": Int(major), "minor": Int(minor), "role": role, "build": build]
        case let .incompatible(message, d): return ["type": "error", "code": "incompatible", "message": message, "detail": Self.incompatJSON(d)]
        case .upgrade: return ["type": "upgrade"]
        case let .upgrading(plan, ptyd): return ["type": "upgrading", "plan": plan.map(Self.liveJSON), "ptyd_restarting": ptyd]
        }
    }

    private static func versionJSON(_ v: ProtoVersion) -> [String: Any] { ["major": Int(v.major), "minor": Int(v.minor), "build": v.build] }
    static func liveJSON(_ s: LiveSession) -> [String: Any] {
        var d: [String: Any] = ["id": s.id, "pid": Int(s.pid), "cwd": s.cwd]
        if let c = s.claudeSessionId { d["claude_session_id"] = c }
        if let e = s.exited { d["exited"] = Int(e) }
        return d
    }
    private static func incompatJSON(_ i: Incompat) -> [String: Any] {
        ["daemon": versionJSON(i.daemon), "client": versionJSON(i.client), "required": versionJSON(i.required), "speak": versionJSON(i.speak), "sessions": i.sessions.map(liveJSON)]
    }
    private static func version(_ o: Any?) throws -> ProtoVersion {
        guard let d = o as? [String: Any], let ma = (d["major"] as? NSNumber)?.uint16Value, let mi = (d["minor"] as? NSNumber)?.uint16Value else { throw WireError.json("bad version") }
        return ProtoVersion(major: ma, minor: mi, build: (d["build"] as? String) ?? "")
    }
    static func live(_ o: Any?) throws -> LiveSession {
        guard let d = o as? [String: Any], let id = (d["id"] as? NSNumber)?.uint64Value, let pid = (d["pid"] as? NSNumber)?.int32Value else { throw WireError.json("bad session") }
        return LiveSession(id: id, pid: pid, cwd: (d["cwd"] as? String) ?? "", claudeSessionId: d["claude_session_id"] as? String, exited: (d["exited"] as? NSNumber)?.int32Value)
    }

    static func parse(_ data: Data) throws -> Control {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let type = obj["type"] as? String else {
            throw WireError.json("not an object with a type")
        }
        func num<T: BinaryInteger>(_ k: String) throws -> T {
            guard let n = obj[k] as? NSNumber, let v = T(exactly: n.int64Value) ?? T(exactly: n.uint64Value) else {
                throw WireError.json("missing or bad number \(k) in \(type)")
            }
            return v
        }
        func str(_ k: String) throws -> String {
            guard let s = obj[k] as? String else { throw WireError.json("missing string \(k) in \(type)") }
            return s
        }
        switch type {
        case "hello": return .hello(role: try str("role"), build: try str("build"))
        case "welcome": return .welcome(major: try num("major"), minor: try num("minor"), serverBuild: try str("server_build"))
        case "error":
            if let d = obj["detail"] as? [String: Any], (obj["code"] as? String) == "incompatible" {
                let info = Incompat(daemon: try version(d["daemon"]), client: try version(d["client"]), required: try version(d["required"]), speak: try version(d["speak"]),
                                    sessions: try ((d["sessions"] as? [Any]) ?? []).map(live))
                return .incompatible(message: try str("message"), detail: info)
            }
            return .error(code: try str("code"), message: try str("message"))
        case "spawn":
            let env = (obj["env"] as? [[String]]) ?? []
            return .spawn(argv: (obj["argv"] as? [String]) ?? [], cwd: try str("cwd"), env: env, cols: try num("cols"), rows: try num("rows"))
        case "spawned": return .spawned(id: try num("id"), pid: try num("pid"))
        case "list": return .list
        case "sessions":
            guard let arr = obj["sessions"] as? [[String: Any]] else { throw WireError.json("sessions") }
            return .sessions(try arr.map { d in
                func n<T: BinaryInteger>(_ k: String) throws -> T {
                    guard let v = (d[k] as? NSNumber).flatMap({ T(exactly: $0.int64Value) ?? T(exactly: $0.uint64Value) }) else { throw WireError.json("session.\(k)") }
                    return v
                }
                return SessionInfo(id: try n("id"), pid: try n("pid"), cols: try n("cols"), rows: try n("rows"), endSeq: try n("end_seq"),
                                   exited: (d["exited"] as? NSNumber).map { Int32(truncatingIfNeeded: $0.int64Value) }, cwd: (d["cwd"] as? String) ?? "")
            })
        case "attach": return .attach(id: try num("id"))
        case "detach": return .detach(id: try num("id"))
        case "attached": return .attached(id: try num("id"), startSeq: try num("start_seq"), endSeq: try num("end_seq"), modes: (obj["modes"] as? String) ?? "")
        case "resize": return .resize(id: try num("id"), cols: try num("cols"), rows: try num("rows"))
        case "close": return .close(id: try num("id"))
        case "key": return .key(id: try num("id"), key: try str("key"), mods: try num("mods"), text: obj["text"] as? String)
        case "paste": return .paste(id: try num("id"), text: try str("text"))
        case "mouse":
            return .mouse(id: try num("id"), col: try num("col"), row: try num("row"), button: try str("button"), action: try str("action"), mods: try num("mods"))
        case "ok": return .ok
        case "exited": return .exited(id: try num("id"), status: try num("status"))
        case "screen": return .screen(id: try num("id"), state: try str("state"))
        case "event": return .event(name: try str("name"), payload: try str("payload"))
        case "rpc": return .rpc(req: try num("req"), method: try str("method"), params: try str("params"))
        case "rpc_reply": return .rpcReply(req: try num("req"), ok: (obj["ok"] as? Bool) ?? false, result: try str("result"))
        case "rpc_cancel": return .rpcCancel(req: try num("req"))
        case "upgrade": return .upgrade
        case "upgrading": return .upgrading(plan: try ((obj["plan"] as? [Any]) ?? []).map(live), ptydRestarting: (obj["ptyd_restarting"] as? Bool) ?? false)
        default: throw WireError.json("unknown control type \(type)")
        }
    }
}

// MARK: - Frame encode / decode

extension Frame {
    /// The frame with its length prefix, ready to write. Large output/input must be split by the caller.
    public func encoded() -> Data {
        var body = Data()
        switch self {
        case let .control(c):
            body.append(1)
            body.append((try? JSONSerialization.data(withJSONObject: c.json, options: [.sortedKeys])) ?? Data())
        case let .output(session, seq, data):
            body.append(2)
            body.append(be64(session)); body.append(be64(seq)); body.append(data)
        case let .input(session, data):
            body.append(3)
            body.append(be64(session)); body.append(data)
        }
        precondition(body.count <= maxFrame, "frame body \(body.count) > maxFrame")
        var out = Data(capacity: 4 + body.count)
        out.append(be32(UInt32(body.count)))
        out.append(body)
        return out
    }

    public static func decodeBody(_ body: Data) throws -> Frame {
        try body.withUnsafeBytes { try decode(UnsafeRawBufferPointer($0)) }
    }

    /// Decodes one frame body in place; output and input payloads are copied exactly once.
    static func decode(_ body: UnsafeRawBufferPointer) throws -> Frame {
        guard let kind = body.first else { throw WireError.empty }
        func u64(_ at: Int) throws -> UInt64 {
            guard body.count >= 1 + at + 8 else { throw WireError.truncated }
            return UInt64(bigEndian: body.loadUnaligned(fromByteOffset: 1 + at, as: UInt64.self))
        }
        switch kind {
        case 1: return .control(try Control.parse(Data(body.dropFirst())))
        case 2: return .output(session: try u64(0), seq: try u64(8), data: Data(body.dropFirst(17)))
        case 3: return .input(session: try u64(0), data: Data(body.dropFirst(9)))
        default: throw WireError.unknownKind(kind)
        }
    }
}

func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
func be64(_ v: UInt64) -> Data { Data((0 ..< 8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 255) }) }

/// Incremental decoder for a byte stream: works with partial reads and back-to-back frames.
/// After an error the stream is unusable and the connection must be closed.
public struct FrameDecoder {
    private var buf = Data()
    private var head = 0

    public init() {}

    public mutating func push(_ bytes: Data) { buf.append(bytes) }

    public mutating func push(_ p: UnsafeRawBufferPointer) { buf.append(contentsOf: p) }

    public var buffered: Int { buf.count - head }

    public mutating func next() throws -> Frame? {
        guard buf.count - head >= 4 else { return nil }
        let start = head
        let result: (frame: Frame, consumed: Int)? = try buf.withUnsafeBytes { raw in
            let len = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: start, as: UInt32.self)))
            if len > maxFrame { throw WireError.tooLarge(len) }
            guard raw.count - start >= 4 + len else { return nil }
            return (try Frame.decode(UnsafeRawBufferPointer(rebasing: raw[(start + 4) ..< (start + 4 + len)])), 4 + len)
        }
        guard let result else { return nil }
        head += result.consumed
        // Compact once the consumed prefix dominates, so a long stream never grows without bound.
        if head > 1 << 16 && head * 2 > buf.count { buf.removeSubrange(0 ..< head); head = 0 }
        return result.frame
    }
}
