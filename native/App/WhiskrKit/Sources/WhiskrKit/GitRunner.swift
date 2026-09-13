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
    /// fails, or when it has not finished after `timeout` seconds (it is then ended).
    @discardableResult
    public func run(_ arguments: [String], in folder: String, timeout: TimeInterval = 30) throws(GitError) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--no-pager"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw GitError(message: "git could not be started: \(error.localizedDescription)", status: -1)
        }
        // Both pipes are drained while git runs, so a long answer never fills one and stalls it.
        let collected = Collected()
        let reading = DispatchGroup()
        for (pipe, isError) in [(output, false), (errors, true)] {
            reading.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                collected.set(data, isError: isError)
                reading.leave()
            }
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 2)
            reading.wait()
            throw GitError(message: "git did not finish in \(Int(timeout)) seconds", status: -1)
        }
        reading.wait()
        let (out, err) = collected.both
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let message = GitError.cleaned(String(decoding: err, as: UTF8.self))
            throw GitError(message: message.isEmpty ? "git exited with status \(process.terminationStatus)" : message, status: process.terminationStatus)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The repository's state at `folder`: its branch, how far it is ahead of and behind its upstream,
    /// and its changed files (`GitStatus`). Ignored files are left out.
    public func status(in folder: String) throws(GitError) -> GitStatus {
        let text = try run(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=normal"], in: folder)
        return GitStatus.parse(Data(text.utf8))
    }
}

/// What git printed on each stream, handed over from the reading threads.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var errors = Data()

    func set(_ data: Data, isError: Bool) {
        lock.withLock { if isError { errors = data } else { output = data } }
    }

    var both: (Data, Data) { lock.withLock { (output, errors) } }
}
