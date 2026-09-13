import Foundation

/// The program in a terminal's foreground, as the app reads it from the system.
public struct ForegroundProcess: Sendable, Equatable, Codable {
    public var pid: Int32
    /// The kernel's short name, e.g. "claude.exe" or "vim".
    public var name: String
    /// The executable's full path, when it could be read.
    public var executable: String
    /// argv, when it could be read (argv[0] first).
    public var arguments: [String]

    public init(pid: Int32, name: String, executable: String = "", arguments: [String] = []) {
        self.pid = pid
        self.name = name
        self.executable = executable
        self.arguments = arguments
    }

    /// Claude Code, however it is installed: the native binary (`claude`, `claude.exe` in the npm
    /// package), or Node running its `cli.js`. Matched as herdr does, by name first, then by what a
    /// wrapper (node, a shell) was asked to run.
    public var isClaude: Bool {
        if Self.claudeNames.contains(name.lowercased()) { return true }
        if Self.claudeNames.contains(Describe.basename(executable).lowercased()) { return true }
        if let first = arguments.first, Self.claudeNames.contains(Describe.basename(first).lowercased()) { return true }
        // A wrapper: `node …/@anthropic-ai/claude-code/cli.js`.
        let wrappers: Set = ["node", "bun", "deno", "sh", "bash", "zsh", "env"]
        guard wrappers.contains(name.lowercased()) || wrappers.contains(Describe.basename(executable).lowercased()) else { return false }
        return arguments.dropFirst().prefix(3).contains { argument in
            argument.contains("@anthropic-ai/claude-code") || Self.claudeNames.contains(Describe.basename(argument).lowercased())
        }
    }

    static let claudeNames: Set = ["claude", "claude.exe", "claude-code"]
}

/// Whether a pane has Claude in it right now: decided from what the terminal itself shows (the
/// foreground program) and from the hook events its session sends. A cat appears the moment Claude is
/// in front, before its first hook event and even with no hooks at all, and leaves when the pane's
/// shell is back in front. Pure, so the rule is tested on its own.
public struct AgentPresence: Sendable, Equatable {
    /// Claude is in the pane now.
    public private(set) var present = false

    public init() {}

    /// The terminal's foreground: `process` is nil while the pane's own shell is in front (at its
    /// prompt). `liveSession` is true while a session that reported from this pane has not ended.
    /// Returns whether `present` changed.
    @discardableResult
    public mutating func observe(foreground process: ForegroundProcess?, liveSession: Bool) -> Bool {
        let now: Bool
        if let process {
            // Claude in front; or something else in front of the shell while its session is still
            // live (an editor Claude opened, a wrapper such as `npx`): Claude is still there.
            now = process.isClaude || liveSession
        } else {
            // The shell is back at its prompt: whatever ran has ended, however it ended.
            now = false
        }
        defer { present = now }
        return now != present
    }

    /// A hook event arrived from the pane: Claude is there, whatever the foreground looked like a
    /// moment ago (the next look confirms it).
    @discardableResult
    public mutating func heard() -> Bool {
        defer { present = true }
        return !present
    }
}
