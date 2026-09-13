import Foundation

/// A path as a shell reads it back unchanged: bare when it holds nothing the shell treats specially,
/// else in single quotes (a single quote inside written as '\''), as a dropped file is typed.
public enum ShellQuote {
    private static let safe = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_-+=:,./")

    public static func quote(_ text: String) -> String {
        guard !text.isEmpty else { return "''" }
        if text.allSatisfy({ safe.contains($0) }) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
