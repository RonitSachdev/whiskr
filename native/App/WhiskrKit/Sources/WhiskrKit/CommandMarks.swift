import Foundation

/// A terminal's commands, read from the marks its shell writes (OSC 133, `ShellIntegration`): each prompt
/// starts a group of rows (the prompt and the line typed at it, with any rows it wrapped onto); what the
/// command printed is the rows after that group, up to the next prompt. ⌘↑ and ⌘↓ go from prompt to
/// prompt; ⇧⌘↑ and ⇧⌘↓ select what a command printed, the one before or after the one selected last.
public enum CommandMarks {
    /// How the terminal classes a row (SwiftTerm's `semanticRowKind`).
    public enum Row: Sendable, Equatable {
        /// The first row of a prompt.
        case prompt
        /// The rest of a prompt and the command typed at it.
        case promptContinued
        /// Anything else: a command's output, or text from before the marks began.
        case other
    }

    /// One command: its prompt's row and the rows it printed.
    public struct Command: Sendable, Equatable {
        public let prompt: Int
        public let output: ClosedRange<Int>

        public init(prompt: Int, output: ClosedRange<Int>) {
            self.prompt = prompt
            self.output = output
        }
    }

    /// The command whose output to select from `reference` (the prompt of the command selected last, or the
    /// row the cursor is on): the nearest one above (`backward`) or below it that printed something. Rows
    /// are counted from the top of the scrollback; `count` is how many there are; `isBlank` tells an empty
    /// row, so trailing empty rows are left out of the selection.
    public static func command(from reference: Int, backward: Bool, count: Int, row: (Int) -> Row, isBlank: (Int) -> Bool) -> Command? {
        guard count > 0 else { return nil }
        let reference = min(max(reference, 0), count - 1)
        // The prompt the reference is in (or below), and from there the one asked for.
        var current = promptAtOrAbove(reference, row: row)
        while true {
            let next: Int?
            if backward {
                guard let from = current else { return nil }
                next = promptAtOrAbove(from - 1, row: row)
            } else {
                next = promptBelow(current ?? -1, count: count, row: row)
            }
            guard let prompt = next else { return nil }
            if let output = output(of: prompt, count: count, row: row, isBlank: isBlank) {
                return Command(prompt: prompt, output: output)
            }
            current = prompt
        }
    }

    /// The rows a command printed: after its prompt's group, to the row before the next prompt, without the
    /// empty rows at its end. Nil when it printed nothing.
    public static func output(of prompt: Int, count: Int, row: (Int) -> Row, isBlank: (Int) -> Bool) -> ClosedRange<Int>? {
        var first = prompt + 1
        while first < count, row(first) == .promptContinued { first += 1 }
        var last = first
        while last < count, row(last) == .other { last += 1 }
        last -= 1
        while last >= first, isBlank(last) { last -= 1 }
        return last >= first ? first...last : nil
    }

    /// The nearest prompt row at or above `row` (nil above the first).
    static func promptAtOrAbove(_ start: Int, row: (Int) -> Row) -> Int? {
        var index = start
        while index >= 0 {
            if row(index) == .prompt { return index }
            index -= 1
        }
        return nil
    }

    static func promptBelow(_ start: Int, count: Int, row: (Int) -> Row) -> Int? {
        var index = start + 1
        while index < count {
            if row(index) == .prompt { return index }
            index += 1
        }
        return nil
    }
}
