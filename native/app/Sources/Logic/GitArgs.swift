import Foundation

/// The one place that decides how the app calls git inside a folder it does not own. A repository's own `.git/config`
/// can name a program (`core.fsmonitor`) or a hooks folder (`core.hooksPath`) that git would run for a plain `status`;
/// the workspace folders are whatever an agent is working in, so the app switches both off on the command line
/// (command-line `-c` wins over every config file).
public enum GitArgs {
    /// `-c` options every git call of the app starts with.
    public static let prefix = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    /// `args` behind the safety prefix and the plain-output options the readers rely on.
    public static func readOnly(_ args: [String]) -> [String] {
        prefix + ["-c", "core.quotepath=false", "-c", "color.ui=never"] + args
    }

    /// `args` behind the safety prefix only (callers that bring their own options, like `-C <dir>`).
    public static func hardened(_ args: [String]) -> [String] { prefix + args }
}
