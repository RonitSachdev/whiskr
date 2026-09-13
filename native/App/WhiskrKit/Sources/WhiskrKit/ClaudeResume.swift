import Foundation

/// The command that resumes a Claude Code conversation in a shell: what a restored pane types, what
/// File › Reopen Closed Tab types, and what a cat's "Copy Resume Command" copies.
public enum ClaudeResume {
    /// Session ids are UUIDs; nothing else is ever put on a command line.
    static func isSessionID(_ text: String) -> Bool {
        UUID(uuidString: text) != nil
    }

    /// What to type in a shell to resume `id` under `account`: the account is named explicitly, since the
    /// folder's own shell setup may choose another one. The default account is the one with no
    /// `CLAUDE_CONFIG_DIR` at all. nil for anything that is not a plain session id.
    public static func resumeCommand(sessionID id: String, account: ClaudeAccount?) -> String? {
        guard isSessionID(id) else { return nil }
        guard let account else { return "claude --resume \(id)" }
        if account.isDefault { return "env -u CLAUDE_CONFIG_DIR claude --resume \(id)" }
        return "CLAUDE_CONFIG_DIR=\(shellQuoted(account.configDir)) claude --resume \(id)"
    }

    /// Single-quoted for a POSIX shell (and zsh and fish), with any single quote inside escaped.
    static func shellQuoted(_ text: String) -> String {
        guard text.contains(where: { !($0.isLetter || $0.isNumber || "/._-~".contains($0)) }) else { return text }
        return "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
