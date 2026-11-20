// Safe first contact with a path the user dropped or clicked: only regular files are ever read, never on the main thread, and
// "Open with Default App" asks before running anything that can execute code.

import Darwin
import Foundation

/// A FIFO, a device node or a socket would block `read` forever (its reported size is 0, so the size gate never fires).
enum FileProbe {
    struct Result {
        var size: Int
        var binary: Bool
        /// The first bytes (up to 8 KB).
        var head: Data
    }

    /// `stat` follows symlinks (a link to a regular file is fine); it does not open, so a FIFO cannot block it.
    static func isRegular(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// Opens non-blocking (a FIFO would otherwise wait for a writer) and checks the opened descriptor, not the path: no swap race.
    private static func openRegular(_ url: URL) -> Int32? {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); return nil }
        return fd
    }

    private static func readUpTo(_ fd: Int32, _ limit: Int) -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: min(max(limit, 1), 1 << 20))
        while out.count < limit {
            let n = read(fd, &buf, min(buf.count, limit - out.count))
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    /// nil = not a regular file (or unreadable).
    static func probe(_ url: URL) -> Result? {
        guard let fd = openRegular(url) else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return nil }
        let head = readUpTo(fd, 8192)
        return Result(size: Int(st.st_size), binary: head.contains(0), head: head)
    }

    /// Up to `limit + 1` bytes (the extra byte tells the caller the file was longer); nil = not a regular file.
    static func readHead(_ url: URL, limit: Int) -> Data? {
        guard let fd = openRegular(url) else { return nil }
        defer { close(fd) }
        return readUpTo(fd, limit + 1)
    }
}

/// "Open with Default App" runs whatever the file is. Anything that can execute code asks first.
enum ExecutableGuard {
    static let riskyExtensions: Set<String> = [
        "app", "command", "sh", "bash", "zsh", "csh", "ksh", "fish", "tool", "terminal", "workflow", "action", "jar", "pkg", "mpkg", "dmg",
        "scpt", "scptd", "applescript", "osascript", "webloc", "inetloc", "url", "exe", "bat", "cmd", "msi", "ps1", "vbs", "py", "pl", "rb",
        "appex", "prefpane", "saver", "kext", "plugin", "xpc", "service", "wflow", "shortcut", "jnlp", "run", "bin",
    ]

    static func needsConfirmation(_ url: URL) -> Bool {
        if riskyExtensions.contains(url.pathExtension.lowercased()) { return true }
        var st = stat()
        guard stat(url.path, &st) == 0 else { return false }
        // A symlink `x.txt -> Foo.app` stat()s as a directory: judge the link's TARGET name too, so a
        // risky extension behind a link (or a link to a bundle) still asks first.
        let resolved = url.resolvingSymlinksInPath()
        if resolved.path != url.path, riskyExtensions.contains(resolved.pathExtension.lowercased()) { return true }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            // A link to a folder / bundle asks; a real folder does not.
            var ls = stat()
            return lstat(url.path, &ls) == 0 && (ls.st_mode & S_IFMT) == S_IFLNK
        }
        return st.st_mode & 0o111 != 0 // executable bit
    }
}
