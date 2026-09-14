import Foundation

/// What git said when it refused: its own words, cut to what a person needs ("a branch named 'x' already
/// exists"), for showing calmly in place, and its exit status.
public struct GitError: Error, Sendable, Equatable {
    public let message: String
    public let status: Int32

    public init(message: String, status: Int32) {
        self.message = message
        self.status = status
    }

    /// git's standard error as a person reads it: the lines that say what went wrong, without git's
    /// "fatal: " and "error: " prefixes and without its "hint:" lines.
    public static func cleaned(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let said = lines.filter { !$0.isEmpty && !$0.hasPrefix("hint:") }.map { line -> String in
            for prefix in ["fatal: ", "error: ", "warning: "] where line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
            return line
        }
        return said.prefix(3).joined(separator: "\n")
    }
}

/// Runs the `git` executable, never a library: what git does is exactly what the user's own git would
/// do, hooks and configuration included. Each call blocks until git has finished, so it is for use off
/// the main thread. Git never asks for anything (no password prompt, no pager, no editor), and its
/// messages are in English whatever the system language, so they can be recognised.
public struct GitRunner: Sendable {
    public let executable: String

    public init(executable: String = "/usr/bin/git") {
        self.executable = executable
    }

    /// Runs git with `arguments` in `folder` and returns what it printed. Throws its message when it
    /// fails, or when it has not finished after `timeout` seconds (it is then ended). `paths` go last,
    /// after `--`, each meaning exactly that file or folder (`literalPathspecs`).
    @discardableResult
    public func run(_ arguments: [String], paths: [String] = [], in folder: String, timeout: TimeInterval = 30) throws(GitError) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--no-pager"] + arguments + (paths.isEmpty ? [] : ["--"] + paths)
        process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        if !paths.isEmpty { Self.literalPathspecs(&environment) }
        process.environment = environment
        let output = ProcessPipe.make(), errors = ProcessPipe.make()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        // Both pipes are drained while git runs, so a long answer never fills one and stalls it.
        let reader = PipeReader([output, errors])
        do {
            try process.run()
        } catch {
            _ = reader.finish(by: .now)
            throw GitError(message: "git could not be started: \(error.localizedDescription)", status: -1)
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            _ = reader.finish(by: .now)
            throw GitError(message: "git did not finish in \(Int(timeout)) seconds", status: -1)
        }
        // The pipes end with git, unless something it started (a hook's helper, say) keeps one open.
        let streams = reader.finish(by: Date(timeIntervalSinceNow: 2))
        let (out, err) = (streams[0], streams[1])
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = GitError.cleaned(String(decoding: err, as: UTF8.self))
            throw GitError(message: message.isEmpty ? "git exited with status \(process.terminationStatus)" : message, status: process.terminationStatus)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Makes git read every path on its command line as a name, never a pattern: `--` only ends the
    /// options, and git still matches what follows as pathspecs, so `app/[id]/page.tsx` would also mean
    /// `app/i/page.tsx` and `app/d/page.tsx`, `*` and `?` would match other files, and a leading `:`
    /// would be pathspec magic. A folder still means everything in it. The other global pathspec
    /// settings, which git refuses beside this one, are dropped. Only for a command given paths: the
    /// hooks git runs inherit its environment, and a hook's own patterns must keep their meaning.
    public static func literalPathspecs(_ environment: inout [String: String]) {
        environment["GIT_LITERAL_PATHSPECS"] = "1"
        for setting in ["GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"] {
            environment.removeValue(forKey: setting)
        }
    }

    /// The repository's state at `folder`: its branch, how far it is ahead of and behind its upstream,
    /// and its changed files (`GitStatus`). Ignored files are left out.
    public func status(in folder: String) throws(GitError) -> GitStatus {
        let text = try run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"], in: folder)
        return GitStatus.parse(Data(text.utf8))
    }
}
