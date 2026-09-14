import Testing
@testable import WhiskrKit

@Suite("Command marks: jumping between commands and selecting what one printed")
struct CommandMarksTests {
    /// A screen written as one letter per row: P a prompt, p the rest of a prompt or the typed line,
    /// o output, _ an empty row.
    struct Screen {
        let rows: [Character]
        init(_ text: String) { rows = Array(text) }
        var count: Int { rows.count }
        func row(_ index: Int) -> CommandMarks.Row {
            switch rows[index] {
            case "P": .prompt
            case "p": .promptContinued
            default: .other
            }
        }
        func isBlank(_ index: Int) -> Bool { rows[index] == "_" }
        func command(from reference: Int, backward: Bool) -> CommandMarks.Command? {
            CommandMarks.command(from: reference, backward: backward, count: count, row: row, isBlank: isBlank)
        }
    }

    @Test("from the prompt the cursor is at, back through each command that printed something")
    func backward() {
        //                        0123456789012
        let screen = Screen("ooPooo_PpPoP")
        // Cursor on the last prompt (11): the command before it printed row 10.
        let last = screen.command(from: 11, backward: true)
        #expect(last == CommandMarks.Command(prompt: 9, output: 10...10))
        // Then the one at 7 printed nothing (its typed line wrapped onto 8): skipped, on to 2.
        let earlier = screen.command(from: 9, backward: true)
        #expect(earlier == CommandMarks.Command(prompt: 2, output: 3...5))
        // Text before the first prompt is no command's.
        #expect(screen.command(from: 2, backward: true) == nil)
    }

    @Test("forward from the command selected, never past the prompt waiting now")
    func forward() {
        let screen = Screen("PoopPoo_P")
        #expect(screen.command(from: 0, backward: false) == CommandMarks.Command(prompt: 4, output: 5...6))
        #expect(screen.command(from: 4, backward: false) == nil)
        // A reference inside an output counts from its command.
        #expect(screen.command(from: 1, backward: false) == CommandMarks.Command(prompt: 4, output: 5...6))
    }

    @Test("a multi-line prompt and a wrapped command line are not output")
    func longPrompt() {
        let screen = Screen("PppooP")
        #expect(CommandMarks.output(of: 0, count: screen.count, row: screen.row, isBlank: screen.isBlank) == 3...4)
        #expect(screen.command(from: 5, backward: true)?.output == 3...4)
    }

    @Test("a running command's output so far is its output; nothing marked is nothing")
    func edges() {
        let running = Screen("PoPooo")
        #expect(CommandMarks.output(of: 2, count: running.count, row: running.row, isBlank: running.isBlank) == 3...5)
        let unmarked = Screen("ooooo")
        #expect(unmarked.command(from: 4, backward: true) == nil)
        #expect(unmarked.command(from: 0, backward: false) == nil)
        #expect(CommandMarks.command(from: 0, backward: true, count: 0, row: { _ in .other }, isBlank: { _ in true }) == nil)
    }
}
