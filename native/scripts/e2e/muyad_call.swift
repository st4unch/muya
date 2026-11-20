// e2e helper: `muyad_call <socket> <method> [params-json]` — one muya-proto v1 rpc call to muyad.
// muyad only talks to apps signed by our team (peer gate), so the e2e script signs this binary with the
// Native identifier. Test tool, not shipped.
// MUYAD_CALL_EVENTS_SECS=N: after the reply keep listening N seconds and print each pushed event
// ("EVENT <name> <payload>"), then "CLOSED" if the daemon hung up (it exited) or "TIMEOUT".
import Foundation
signal(SIGPIPE, SIG_IGN) // a refusal closes the socket right after its error frame: read it instead of dying on the next write

let a = CommandLine.arguments
guard a.count >= 3 else { FileHandle.standardError.write(Data("usage: muyad_call <socket> <method> [params]\n".utf8)); exit(64) }
let path = a[1], method = a[2], params = a.count > 3 ? a[3] : "{}"

func frame(_ o: [String: Any]) -> Data {
    var body = Data([1]); body.append(try! JSONSerialization.data(withJSONObject: o))
    var len = UInt32(body.count).bigEndian
    return Data(bytes: &len, count: 4) + body
}
let fd = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
let bytes = Array(path.utf8CString)
withUnsafeMutablePointer(to: &addr.sun_path) { $0.withMemoryRebound(to: CChar.self, capacity: 104) { p in for (i, b) in bytes.enumerated() where i < 104 { p[i] = b } } }
let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
guard rc == 0 else { print("cannot connect: \(String(cString: strerror(errno)))"); exit(2) }
func send(_ d: Data) { _ = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) } }
send(frame(["type": "hello", "major": 1, "minor": 3, "role": "app", "build": "e2e"]))
send(frame(["type": "rpc", "req": 1, "method": method, "params": params]))
var tv = timeval(tv_sec: 120, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
var buf = Data()
var chunk = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(fd, &chunk, chunk.count)
    if n <= 0 { print("no reply"); exit(3) }
    buf.append(contentsOf: chunk[0..<n])
    while buf.count >= 4 {
        let len = Int(buf.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) })
        if buf.count < 4 + len { break }
        let body = buf.subdata(in: 4..<(4 + len)); buf = buf.subdata(in: (4 + len)..<buf.count)
        guard body.first == 1, let o = try? JSONSerialization.jsonObject(with: body.dropFirst()) as? [String: Any] else { continue }
        if o["type"] as? String == "error" { print("refused: \(o["message"] ?? "")"); exit(4) }
        if o["type"] as? String == "rpc_reply", (o["req"] as? Int) == 1 {
            print("{\"ok\":\(o["ok"] ?? false),\"result\":\(o["result"] ?? "null")}")
            fflush(stdout)
            let ok = (o["ok"] as? Bool) == true
            let secs = Int(ProcessInfo.processInfo.environment["MUYAD_CALL_EVENTS_SECS"] ?? "") ?? 0
            if secs <= 0 || !ok { exit(ok ? 0 : 1) }
            listenForEvents(secs: secs, leftover: buf)
        }
        if o["type"] as? String == "event" { print("EVENT \(o["name"] ?? "") \(o["payload"] ?? "")") }
    }
}

func listenForEvents(secs: Int, leftover: Data) -> Never {
    var tv = timeval(tv_sec: 1, tv_usec: 0); setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var buf = leftover
    let end = Date().addingTimeInterval(Double(secs))
    var chunk = [UInt8](repeating: 0, count: 65536)
    while Date() < end {
        while buf.count >= 4 {
            let len = Int(buf.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) })
            if buf.count < 4 + len { break }
            let body = buf.subdata(in: 4..<(4 + len)); buf = buf.subdata(in: (4 + len)..<buf.count)
            if body.first == 1, let o = try? JSONSerialization.jsonObject(with: body.dropFirst()) as? [String: Any], o["type"] as? String == "event" {
                print("EVENT \(o["name"] ?? "") \(o["payload"] ?? "")"); fflush(stdout)
            }
        }
        let n = read(fd, &chunk, chunk.count)
        if n == 0 { print("CLOSED"); exit(0) }
        if n < 0 { if errno == EAGAIN || errno == EWOULDBLOCK { continue }; print("CLOSED"); exit(0) }
        buf.append(contentsOf: chunk[0..<n])
    }
    print("TIMEOUT"); exit(0)
}
