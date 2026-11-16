import Foundation

/// The environment every child process starts with.
///
/// Children used to inherit this app's whole environment. Bash runs the file named by
/// `BASH_ENV` before the requested command (even with `--noprofile --norc`), and other
/// inherited variables (`ENV`, `SHELLOPTS`, `BASH_FUNC_*`, `DYLD_*`, `PATH`, `IFS`, ...)
/// change what a shell or a dynamically linked tool does before our script runs. Every
/// child is started from this small allowlist instead: a fixed system `PATH`, the
/// identity/locale values GUI tools and Zoom expect, and nothing else. Values are
/// validated, so a malformed inherited value is dropped rather than passed on.
enum ChildProcessEnvironment {
    static let fixedPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Keys copied from the parent when their value passes validation. `PATH` is never
    /// copied; it is always `fixedPath`.
    static let allowedKeys: [String] = [
        "HOME",
        "TMPDIR",
        "USER",
        "LOGNAME",
        "LANG",
        "LC_ALL",
        "LC_COLLATE",
        "LC_CTYPE",
        "LC_MESSAGES",
        "LC_MONETARY",
        "LC_NUMERIC",
        "LC_TIME",
        "__CF_USER_TEXT_ENCODING",
        "COMMAND_MODE",
    ]

    private static let maximumValueLength = 1_024

    /// The sanitized environment for this process.
    static func current() -> [String: String] {
        sanitized(
            ProcessInfo.processInfo.environment,
            homeFallback: NSHomeDirectory(),
            temporaryDirectoryFallback: NSTemporaryDirectory()
        )
    }

    /// Builds the child environment from `source`. `HOME` and `TMPDIR` fall back to the
    /// supplied values when the inherited ones are missing or invalid, because the
    /// sandboxed Zoom launch and its profile file depend on both.
    static func sanitized(
        _ source: [String: String],
        homeFallback: String?,
        temporaryDirectoryFallback: String?
    ) -> [String: String] {
        var result: [String: String] = ["PATH": fixedPath]
        for key in allowedKeys {
            guard let value = source[key], isAcceptable(value, forKey: key) else { continue }
            result[key] = value
        }
        if result["HOME"] == nil, let homeFallback, isAcceptable(homeFallback, forKey: "HOME") {
            result["HOME"] = homeFallback
        }
        if result["TMPDIR"] == nil, let temporaryDirectoryFallback,
           isAcceptable(temporaryDirectoryFallback, forKey: "TMPDIR") {
            result["TMPDIR"] = temporaryDirectoryFallback
        }
        return result
    }

    static func isAcceptable(_ value: String, forKey key: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumValueLength,
              value.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            return false
        }
        switch key {
        case "HOME", "TMPDIR":
            return value.hasPrefix("/") && value != "/"
        case "USER", "LOGNAME":
            return matches(value, #"^[A-Za-z0-9_][A-Za-z0-9_.-]*$"#)
        case "__CF_USER_TEXT_ENCODING":
            return matches(value, #"^0x[0-9A-Fa-f]{1,8}:0x[0-9A-Fa-f]{1,8}:0x[0-9A-Fa-f]{1,8}$"#)
        case "COMMAND_MODE":
            return matches(value, #"^[a-z0-9]+$"#)
        default:
            // LANG and LC_* (for example en_US.UTF-8, C, POSIX, sr_RS@latin).
            return matches(value, #"^[A-Za-z0-9_.@-]+$"#)
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
