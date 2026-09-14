import Foundation

/// What is typed into Go to (⌘P), read as VS Code's Quick Open reads it: a file to find, ">" and a
/// command, ":" and a line of the open file, or a file to find and a line to open it at.
public enum GoToQuery: Equatable, Sendable {
    /// Text to find files by, trimmed.
    case search(String)
    /// After ">": the text (trimmed) to find commands by; empty for every command.
    case commands(String)
    /// ":42" or ":42:3": a line (and column) of the focused file, 1-based.
    case line(Int, column: Int?)
    /// "name:42", "src/x.ts:42:3", "my file.ts:3": find files by the name, open the chosen one at the line.
    case fileAtLine(String, line: Int, column: Int?)

    /// A colon with no number after it changes nothing yet: "name:" (about to get its line) is still
    /// `.search("name")`, so the files found stay put while the number is typed; ":" alone and ":abc" are
    /// searches for that text, as no line can be read from them. Text before a ":42" is always a name,
    /// even "12" in "12:30", so the rule stays the same for every name. One colon after the numbers is
    /// ignored, as compilers print "x.go:4:5:".
    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") {
            self = .commands(trimmed.dropFirst().trimmingCharacters(in: .whitespaces))
            return
        }
        var rest = Substring(trimmed)
        if rest.hasSuffix(":") { rest.removeLast() }
        // Up to two numbers off the end: "name:12:3" or "name:12".
        var numbers: [Int] = []
        while numbers.count < 2, let colon = rest.lastIndex(of: ":"),
              let number = Self.number(rest[rest.index(after: colon)...]) {
            numbers.insert(number, at: 0)
            rest = rest[..<colon]
        }
        let name = rest.trimmingCharacters(in: .whitespaces)
        switch (numbers.first, name.isEmpty) {
        case (let line?, true):
            self = .line(line, column: numbers.count > 1 ? numbers[1] : nil)
        case (let line?, false):
            self = .fileAtLine(name, line: line, column: numbers.count > 1 ? numbers[1] : nil)
        case (nil, false):
            self = .search(name)
        default:
            self = .search(trimmed)
        }
    }

    /// Digits only, so "-3", "+3" and "3a" are not numbers here.
    private static func number(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 9, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }
}
