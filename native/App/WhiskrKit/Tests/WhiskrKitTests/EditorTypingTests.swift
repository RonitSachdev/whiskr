import Foundation
import Testing
@testable import WhiskrKit

@Suite("Auto-closing, surrounding and deleting pairs")
struct AutoClosingTests {
    let pairs = EditingPairs.common

    func typing(_ typed: String, before: String, after: String = "", selected: String = "", added: Bool = false, context: TokenContext = .code,
                pairs: EditingPairs? = nil) -> AutoClosing.Typing? {
        AutoClosing.typing(typed, at: .init(before: before, after: after, selected: selected, closerWasAdded: added, context: context), pairs: pairs ?? self.pairs)
    }

    @Test("an opening bracket closes at the end of a line, before whitespace and before a closing")
    func closesBrackets() {
        #expect(typing("(", before: "foo") == .close(open: "(", close: ")"))
        #expect(typing("{", before: "if x ", after: " ") == .close(open: "{", close: "}"))
        #expect(typing("[", before: "a = ", after: ";") == .close(open: "[", close: "]"))
        // Before another pair's closing: `f(|)` typing `[`.
        #expect(typing("[", before: "f(", after: ")") == .close(open: "[", close: "]"))
        // Not before a word.
        #expect(typing("(", before: "", after: "foo") == nil)
        // Not a closing character, nor anything else.
        #expect(typing(")", before: "foo") == nil)
        #expect(typing("a", before: "") == nil)
    }

    @Test("a bracket the line already closes, unmatched, is not closed again")
    func balance() {
        #expect(typing("(", before: "foo", after: ")") == nil)
        // `(|)`: the closing has its opening, so typing `(` nests a new pair.
        #expect(typing("(", before: "(", after: ")") == .close(open: "(", close: ")"))
    }

    @Test("quotes close, but not after a word character, nor where the language says not")
    func quotes() {
        #expect(typing("\"", before: "let s = ") == .close(open: "\"", close: "\""))
        #expect(typing("'", before: "don") == nil)
        #expect(typing("\"", before: "x = 1", context: .string) == nil)
        #expect(typing("'", before: "// it", context: .comment) == nil)
        // A double quote may close in a comment (notIn is only string).
        #expect(typing("\"", before: "// say ", context: .comment) == .close(open: "\"", close: "\""))
        // Before a word: no.
        #expect(typing("\"", before: "", after: "abc") == nil)
        // The language's own `autoCloseBefore` decides what may follow.
        let strict = EditingPairs(brackets: [.init("(", ")")], autoCloseBefore: " ")
        #expect(typing("(", before: "f", after: ";", pairs: strict) == nil)
        #expect(typing("(", before: "f", after: " ", pairs: strict) == .close(open: "(", close: ")"))
    }

    @Test("a closing the editor added is typed over; one the editor did not add is not")
    func overtype() {
        #expect(typing(")", before: "f(", after: ")", added: true) == .overtype)
        #expect(typing(")", before: "f(", after: ")", added: false) == nil)
        #expect(typing("\"", before: "\"abc", after: "\"", added: true) == .overtype)
        // An escaped quote is a quote, not the end of the string.
        #expect(typing("\"", before: "\"a\\", after: "\"", added: true, context: .string) == nil)
    }

    @Test("a selection is wrapped in the pair typed, but not a blank one, nor a quote over a quote")
    func surround() {
        #expect(typing("(", before: "", selected: "a + b") == .surround(open: "(", close: ")"))
        #expect(typing("\"", before: "", selected: "word") == .surround(open: "\"", close: "\""))
        #expect(typing("(", before: "", selected: "  \n ") == nil)
        #expect(typing("'", before: "", selected: "\"") == nil)
        #expect(typing("x", before: "", selected: "word") == nil)
        let languageDefined = EditingPairs(brackets: [.init("(", ")")], surroundingPairs: [.init("<", ">")])
        #expect(typing("<", before: "", selected: "T", pairs: languageDefined) == .surround(open: "<", close: ">"))
        #expect(typing("(", before: "", selected: "T", pairs: languageDefined) == nil)
    }

    @Test("a longer opening wins: `/**` closes with ` */`")
    func multiCharacter() {
        let doc = EditingPairs(brackets: [.init("(", ")")], autoClosingPairs: [.init("(", ")"), .init("/**", " */", notIn: [.string])])
        #expect(typing("*", before: "/*", pairs: doc) == .close(open: "*", close: " */"))
        #expect(typing("*", before: "a", pairs: doc) == nil)
    }

    @Test("Backspace in an empty pair the editor closed deletes both")
    func deletePair() {
        let place = { (before: String, after: String, added: Bool) in AutoClosing.Place(before: before, after: after, closerWasAdded: added) }
        #expect(AutoClosing.deletesPair(at: place("f(", ")", true), pairs: pairs))
        #expect(AutoClosing.deletesPair(at: place("x = \"", "\";", true), pairs: pairs))
        #expect(!AutoClosing.deletesPair(at: place("f(", ")", false), pairs: pairs))
        #expect(!AutoClosing.deletesPair(at: place("f(", "]", true), pairs: pairs))
        #expect(!AutoClosing.deletesPair(at: place("", ")", true), pairs: pairs))
    }

    @Test("added closings follow edits and are forgotten once touched or left")
    func added() {
        var added = AutoClosing.Added()
        added.add(open: 3, close: 4)          // f( | )
        added.edited(NSRange(location: 4, length: 0), replacementLength: 2)   // typed inside
        #expect(added.isClosing(at: 6))
        added.edited(NSRange(location: 0, length: 0), replacementLength: 1)   // typed before
        #expect(added.isClosing(at: 7))
        added.keep(inside: NSRange(location: 7, length: 0))
        #expect(added.isClosing(at: 7))
        added.keep(inside: NSRange(location: 8, length: 0))                    // stepped out
        #expect(!added.isClosing(at: 7))
        added.add(open: 10, close: 11)
        added.edited(NSRange(location: 11, length: 1), replacementLength: 0)   // the closing deleted
        #expect(added.pairs.isEmpty)
    }
}

@Suite("Bracket matching")
struct BracketMatchingTests {
    let brackets = EditingPairs.common.brackets

    @Test("the bracket after the cursor, else before it, and its partner")
    func matches() {
        let text = "f(a[1], {b}) x" as NSString
        #expect(BracketMatching.match(in: text, at: 1, brackets: brackets) == .init(open: 1, close: 11))
        #expect(BracketMatching.match(in: text, at: 12, brackets: brackets) == .init(open: 1, close: 11))
        #expect(BracketMatching.match(in: text, at: 3, brackets: brackets) == .init(open: 3, close: 5))
        #expect(BracketMatching.match(in: text, at: 9, brackets: brackets) == .init(open: 8, close: 10))
        #expect(BracketMatching.match(in: text, at: 13, brackets: brackets) == nil)
        // An unmatched bracket after the cursor gives way to the matched one before.
        #expect(BracketMatching.match(in: "()(" as NSString, at: 2, brackets: brackets) == .init(open: 0, close: 1))
        #expect(BracketMatching.match(in: "(((" as NSString, at: 0, brackets: brackets) == nil)
    }

    @Test("brackets in strings and comments neither match nor count; a search has a limit")
    func skipsStrings() {
        let text = "f(\")\", x)" as NSString
        let inString: Set<Int> = [2, 3, 4]
        #expect(BracketMatching.match(in: text, at: 1, brackets: brackets, isCode: { !inString.contains($0) }) == .init(open: 1, close: 8))
        #expect(BracketMatching.match(in: text, at: 3, brackets: brackets, isCode: { !inString.contains($0) }) == nil)
        let far = "(" + String(repeating: " ", count: 100) + ")" as NSString
        #expect(BracketMatching.match(in: far, at: 0, brackets: brackets, limit: 50) == nil)
        #expect(BracketMatching.match(in: far, at: 0, brackets: brackets, limit: 500) == .init(open: 0, close: 101))
    }

    @Test("away from brackets, the innermost pair around the cursor")
    func enclosing() {
        let text = "f(a, [b], c) + g" as NSString
        #expect(BracketMatching.enclosing(in: text, at: 3, brackets: brackets) == .init(open: 1, close: 11))
        #expect(BracketMatching.enclosing(in: text, at: 9, brackets: brackets) == .init(open: 1, close: 11))
        #expect(BracketMatching.enclosing(in: text, at: 7, brackets: brackets) == .init(open: 5, close: 7))
        #expect(BracketMatching.enclosing(in: text, at: 14, brackets: brackets) == nil)
    }
}

@Suite("Line moves")
struct LineMovesTests {
    func apply(_ edit: LineMoves.Edit?, to text: String) -> (String, NSRange)? {
        guard let edit else { return nil }
        return ((text as NSString).replacingCharacters(in: edit.range, with: edit.text), edit.selection)
    }

    @Test("Move Line Up and Down swap the selected lines with their neighbour, the selection going along")
    func move() {
        let text = "one\ntwo\nthree"
        let up = apply(LineMoves.move(text as NSString, selection: NSRange(location: 5, length: 0), up: true), to: text)
        #expect(up?.0 == "two\none\nthree")
        #expect(up?.1 == NSRange(location: 1, length: 0))
        let down = apply(LineMoves.move(text as NSString, selection: NSRange(location: 5, length: 0), up: false), to: text)
        #expect(down?.0 == "one\nthree\ntwo")
        #expect(down?.1 == NSRange(location: 11, length: 0))
        // Two lines selected; the selection ending at a line's start leaves that line.
        let block = apply(LineMoves.move(text as NSString, selection: NSRange(location: 0, length: 8), up: false), to: text)
        #expect(block?.0 == "three\none\ntwo")
        #expect(block?.1 == NSRange(location: 6, length: 8))
        #expect(LineMoves.move(text as NSString, selection: NSRange(location: 1, length: 0), up: true) == nil)
        #expect(LineMoves.move(text as NSString, selection: NSRange(location: 10, length: 0), up: false) == nil)
        // After a file's last line break is an empty line, which a line can move below.
        let ending = "a\nb\n"
        #expect(apply(LineMoves.move(ending as NSString, selection: NSRange(location: 2, length: 0), up: false), to: ending)?.0 == "a\n\nb")
    }

    @Test("Copy Line Up and Down double the lines; Down selects the lower copy")
    func copy() {
        let text = "one\ntwo"
        let down = apply(LineMoves.copy(text as NSString, selection: NSRange(location: 1, length: 1), up: false), to: text)
        #expect(down?.0 == "one\none\ntwo")
        #expect(down?.1 == NSRange(location: 5, length: 1))
        let up = apply(LineMoves.copy(text as NSString, selection: NSRange(location: 5, length: 0), up: true), to: text)
        #expect(up?.0 == "one\ntwo\ntwo")
        #expect(up?.1 == NSRange(location: 5, length: 0))
    }

    @Test("Delete Line takes the lines and their break; the cursor keeps its column where it can")
    func delete() {
        let text = "alpha\nbe\ngamma"
        let middle = apply(LineMoves.delete(text as NSString, selection: NSRange(location: 4, length: 0)), to: text)
        #expect(middle?.0 == "be\ngamma")
        #expect(middle?.1 == NSRange(location: 2, length: 0))
        let last = apply(LineMoves.delete(text as NSString, selection: NSRange(location: 12, length: 0)), to: text)
        #expect(last?.0 == "alpha\nbe")
        #expect(last?.1 == NSRange(location: 8, length: 0))
        let only = apply(LineMoves.delete("solo" as NSString, selection: NSRange(location: 2, length: 0)), to: "solo")
        #expect(only?.0 == "")
        #expect(only?.1 == NSRange(location: 0, length: 0))
        let two = apply(LineMoves.delete(text as NSString, selection: NSRange(location: 1, length: 6)), to: text)
        #expect(two?.0 == "gamma")
    }
}

@Suite("Occurrences of a word")
struct OccurrencesTests {
    @Test("the word at the cursor, by VS Code's separators")
    func words() {
        let text = "let foo_bar = foo.bar(x) // é1" as NSString
        #expect(Occurrences.word(in: text, at: 5) == NSRange(location: 4, length: 7))
        #expect(Occurrences.word(in: text, at: 11) == NSRange(location: 4, length: 7))
        #expect(Occurrences.word(in: text, at: 17) == NSRange(location: 14, length: 3))
        #expect(Occurrences.word(in: text, at: 12) == nil)
        #expect(Occurrences.word(in: text, at: 29) == NSRange(location: 28, length: 2))
    }

    @Test("whole words only, case-sensitive, within the range given")
    func find() {
        let text = "foo food Foo foo.foo xfoo foo" as NSString
        let all = Occurrences.find("foo", in: text, range: NSRange(location: 0, length: text.length))
        #expect(all.map(\.location) == [0, 13, 17, 26])
        let some = Occurrences.find("foo", in: text, range: NSRange(location: 10, length: 10))
        #expect(some.map(\.location) == [13, 17])
    }

    @Test("an empty selection highlights its word everywhere; a selected word, the others; other selections, nothing")
    func highlights() {
        let text = "a = b + a * ab" as NSString
        let everything = NSRange(location: 0, length: text.length)
        #expect(Occurrences.highlights(in: text, selection: NSRange(location: 0, length: 0), visible: everything).map(\.location) == [0, 8])
        #expect(Occurrences.highlights(in: text, selection: NSRange(location: 8, length: 1), visible: everything).map(\.location) == [0])
        #expect(Occurrences.highlights(in: text, selection: NSRange(location: 0, length: 3), visible: everything).isEmpty)
        #expect(Occurrences.highlights(in: text, selection: NSRange(location: 1, length: 0), visible: everything).map(\.location) == [0, 8])
        #expect(Occurrences.highlights(in: text, selection: NSRange(location: 2, length: 0), visible: everything).isEmpty)
    }
}

@Suite("Indent guides")
struct IndentGuidesTests {
    func lines(_ text: String, size: Int = 4, offSide: Bool = false) -> IndentGuides.Lines {
        let all = text.components(separatedBy: "\n")
        return IndentGuides.Lines(count: all.count, tabSize: size, indentSize: size, offSide: offSide) { all[$0] }
    }

    @Test("columns of indentation, tabs to the next stop; blank lines have none")
    func columns() {
        #expect(IndentGuides.indentColumns("    x", tabSize: 4) == 4)
        #expect(IndentGuides.indentColumns("\tx", tabSize: 4) == 4)
        #expect(IndentGuides.indentColumns("  \tx", tabSize: 4) == 4)
        #expect(IndentGuides.indentColumns("x", tabSize: 4) == 0)
        #expect(IndentGuides.indentColumns("   ", tabSize: 4) == nil)
    }

    @Test("a level per indentation step; a blank line takes its block's")
    func levels() {
        let text = "func f() {\n    if x {\n        y()\n\n        z()\n    }\n\n}"
        let guides = IndentGuides.levels(0..<8, of: lines(text))
        #expect(guides == [0, 1, 2, 2, 2, 1, 1, 0])
        // Off-side languages: a blank line before a dedent belongs below.
        let python = "def f():\n    x = 1\n\ny = 2"
        #expect(IndentGuides.levels(0..<4, of: lines(python, offSide: true)) == [0, 1, 0, 0])
        #expect(IndentGuides.levels(0..<4, of: lines(python)) == [0, 1, 1, 0])
        // The same lines one at a time agree.
        let each = lines(text)
        #expect((0..<8).map { each.level($0) } == guides)
    }

    @Test("the cursor's block: inside it, on the line opening it, or on the line closing it")
    func active() {
        let text = "func f() {\n    if x {\n        y()\n        z()\n    }\n    w()\n}"
        let all = lines(text)
        #expect(IndentGuides.active(at: 2, in: all, bounds: 0..<7) == .init(lines: 2...3, level: 2))
        #expect(IndentGuides.active(at: 1, in: all, bounds: 0..<7) == .init(lines: 2...3, level: 2))
        #expect(IndentGuides.active(at: 4, in: all, bounds: 0..<7) == .init(lines: 2...3, level: 2))
        #expect(IndentGuides.active(at: 5, in: all, bounds: 0..<7) == .init(lines: 1...5, level: 1))
        #expect(IndentGuides.active(at: 0, in: all, bounds: 0..<7) == .init(lines: 1...5, level: 1))
        // Bounded by the lines on screen.
        #expect(IndentGuides.active(at: 5, in: all, bounds: 3..<6) == .init(lines: 3...5, level: 1))
        #expect(IndentGuides.active(at: 0, in: lines("a\nb"), bounds: 0..<2).level == 0)
    }
}

@Suite("Fixes on saving")
struct SaveFixesTests {
    func apply(_ text: String, trim: Bool, newline: Bool) -> String {
        let edits = SaveFixes.edits(in: text as NSString, trimTrailingWhitespace: trim, insertFinalNewline: newline)
        var result = text as NSString
        for edit in edits.reversed() { result = result.replacingCharacters(in: edit.range, with: edit.text) as NSString }
        return result as String
    }

    @Test("trailing spaces and tabs go from every line; nothing else changes")
    func trim() {
        #expect(apply("a  \nb\t\n  \nc", trim: true, newline: false) == "a\nb\n\nc")
        #expect(apply("a \u{00A0}\n", trim: true, newline: false) == "a \u{00A0}\n")
        #expect(SaveFixes.edits(in: "clean\n", trimTrailingWhitespace: true, insertFinalNewline: true).isEmpty)
    }

    @Test("a final line break is added, except to an empty file or a last line trimming empties")
    func finalNewline() {
        #expect(apply("a", trim: false, newline: true) == "a\n")
        #expect(apply("", trim: false, newline: true) == "")
        #expect(apply("a\n  ", trim: true, newline: true) == "a\n")
        #expect(apply("a\n  ", trim: false, newline: true) == "a\n  \n")
        #expect(apply("a \nb ", trim: true, newline: true) == "a\nb\n")
    }
}
