//
//  CLIExecutable.swift
//  GhostMeet
//

import Foundation

/// Finding a command-line tool from inside a GUI app.
///
/// This is its own file because it is the single most likely reason a CLI
/// provider fails, and the reason is invisible from the code that calls it: an
/// app launched from Finder or Xcode inherits **launchd's** environment, whose
/// `PATH` is usually just `/usr/bin:/bin:/usr/sbin:/sbin`. None of the tools we
/// care about live there — `claude`, `codex` and `kimi` are installed by npm,
/// bun or Homebrew into directories only the user's shell profile knows about.
///
/// So "not on PATH" is not the same as "not installed", and treating it as such
/// would tell a user who runs `claude` in Terminal every day that they have not
/// installed it. We look in `PATH` first and then in the places these tools
/// actually land.
nonisolated enum CLIExecutable {

    /// Where CLI tools are installed on a Mac, in the order worth trying.
    ///
    /// Tilde paths are expanded against the current user's home.
    static let commonInstallDirectories = [
        "/opt/homebrew/bin",        // Homebrew on Apple Silicon
        "/usr/local/bin",           // Homebrew on Intel, and `npm -g` by default
        "/opt/homebrew/opt/node/bin",
        "~/.local/bin",
        "~/.bun/bin",
        "~/.deno/bin",
        "~/.cargo/bin",
        "~/.volta/bin",
        "~/.npm-global/bin",
        "~/.claude/local",          // Claude Code's own local install
        "~/.codeium/bin",
    ]

    /// `PATH` as the app actually has it, widened by the directories above.
    ///
    /// Also handed to the child as its own `PATH`: `claude` is a Node script and
    /// has to be able to find `node`, which sits in exactly the same
    /// launchd-invisible directories.
    static func searchPaths(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        let declared = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)

        var seen = Set<String>()
        return (declared + commonInstallDirectories)
            .map(expandingTilde)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The executable for `name`, or nil if the tool is not installed.
    ///
    /// A name containing a separator is taken as a path the user typed and is
    /// checked as given, so "укажите полный путь" is real advice and not a
    /// consolation.
    static func locate(
        _ name: String,
        in searchPaths: [String],
        fileManager: FileManager = .default
    ) -> URL? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        if name.contains("/") {
            let path = expandingTilde(name)
            return isRunnable(path, fileManager: fileManager) ? URL(fileURLWithPath: path) : nil
        }

        for directory in searchPaths {
            let path = (directory as NSString).appendingPathComponent(name)
            if isRunnable(path, fileManager: fileManager) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func expandingTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// A directory is executable in the `access(2)` sense — it is searchable —
    /// so the directory check is what keeps a stray folder named `claude` from
    /// being launched as a program.
    private static func isRunnable(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return fileManager.isExecutableFile(atPath: path)
    }
}
