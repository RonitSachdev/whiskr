import Foundation
import WhiskrKit

/// Runs the `git` executable, always off the main thread. Reads set `GIT_OPTIONAL_LOCKS=0`, so a status
/// never takes the index lock from under the user's own git or Claude's; nothing here writes unless a
/// person clicked for it (stage, unstage, discard, commit). Paths reach git only through `paths`, read
/// as names, never as patterns (`GitRunner.literalPathspecs`).
enum Git {
    struct Failure: Error, LocalizedError {
        let status: Int32
        let message: String
        var errorDescription: String? { message }
    }

    /// The git you would get in a terminal: Homebrew's first, then the system's.
    nonisolated static let executable: URL? = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
        .map { URL(fileURLWithPath: $0) }

    /// `git <arguments> -- <paths>` in `folder`; its output, or a `Failure` with what it printed on stderr.
    nonisolated static func run(_ arguments: [String], paths: [String] = [], in folder: URL, input: Data? = nil, writes: Bool = false) async throws -> Data {
        try await Task.detached(priority: writes ? .userInitiated : .utility) {
            try runNow(arguments, paths: paths, in: folder, input: input, writes: writes)
        }.value
    }

    nonisolated private static func runNow(_ arguments: [String], paths: [String], in folder: URL, input: Data?, writes: Bool) throws -> Data {
        guard let executable else { throw Failure(status: -1, message: String(localized: "git is not installed.", comment: "Changes panel: no git executable")) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-c", "core.quotepath=false", "-c", "color.ui=false"] + arguments + (paths.isEmpty ? [] : ["--"] + paths)
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        if !writes { environment["GIT_OPTIONAL_LOCKS"] = "0" }
        if !paths.isEmpty { GitRunner.literalPathspecs(&environment) }
        process.environment = environment
        let output = ProcessPipe.make(), errors = ProcessPipe.make()
        process.standardOutput = output
        process.standardError = errors
        let stdin = ProcessPipe.make()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        // Both pipes are drained as git writes, or a chatty stderr would block it on a full pipe.
        let reader = PipeReader([output, errors])
        do {
            try process.run()
        } catch {
            _ = reader.finish(by: .now)
            throw error
        }
        if let input {
            // git may stop before reading all of it (a refused patch): writing then fails with EPIPE, which
            // without F_SETNOSIGPIPE is a SIGPIPE that ends the app. The failure shows as git's own.
            let handle = stdin.fileHandleForWriting
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? handle.write(contentsOf: input)
            try? handle.close()
        }
        // No time limit: a commit runs the repository's hooks, which may take long.
        finished.wait()
        // The pipes end with git, unless something it started (a hook's helper, say) keeps one open.
        let streams = reader.finish(by: Date(timeIntervalSinceNow: 2))
        let (data, errorData) = (streams[0], streams[1])
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(status: process.terminationStatus, message: message.isEmpty ? String(localized: "git stopped with status \(process.terminationStatus).") : message)
        }
        return data
    }
}
