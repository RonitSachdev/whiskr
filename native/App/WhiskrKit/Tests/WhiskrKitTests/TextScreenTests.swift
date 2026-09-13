import Foundation
import Testing
@testable import WhiskrKit

private let esc = "\u{1b}"

private func screen(_ text: String, columns: Int = 20, rows: Int = 5, scrollback: Int = 100) -> TextScreen {
    var screen = TextScreen(columns: columns, rows: rows, scrollback: scrollback)
    screen.feed(Data(text.utf8))
    return screen
}

/// The screen's lines, with the empty ones at the end dropped.
private func shown(_ screen: TextScreen) -> [String] { screen.text(history: 0) }

@Suite("TextScreen")
struct TextScreenTests {
    @Test func plainTextAndLineBreaks() {
        let s = screen("hello\r\nworld\r\n")
        #expect(s.screenLines.count == 5)
        #expect(shown(s) == ["hello", "world"])
        #expect(s.cursor == (2, 0))
    }

    @Test func lineFeedMovesDownOnly() {
        #expect(shown(screen("ab\ncd")) == ["ab", "  cd"])
    }

    @Test func wrapsAtTheEdgeWithPendingWrap() {
        let s = screen("abcdefghij", columns: 5)
        #expect(shown(s) == ["abcde", "fghij"])
        // The cursor waits at the last column; a carriage return there keeps the line.
        #expect(s.cursor == (1, 4))
        #expect(shown(screen("abcde\r\nx", columns: 5)) == ["abcde", "x"])
    }

    @Test func noAutowrapOverwritesTheLastColumn() {
        #expect(shown(screen("\(esc)[?7labcdefg", columns: 5)) == ["abcdg"])
    }

    @Test func backspaceAndTabs() {
        #expect(shown(screen("abc\u{8}\u{8}X")) == ["aXc"])
        #expect(shown(screen("a\tb\tc", columns: 30)) == ["a       b       c"])
        // A tab never passes the last column.
        #expect(screen("\t\t\t\t", columns: 10).cursor.column == 9)
    }

    @Test func cursorMovesAndErases() {
        var s = screen("line one\r\nline two\r\nline three")
        s.feed(Data("\(esc)[2;6H\(esc)[K".utf8))
        #expect(shown(s) == ["line one", "line", "line three"])
        s.feed(Data("\(esc)[1;1H\(esc)[2C\(esc)[1K".utf8))
        #expect(shown(s) == ["   e one", "line", "line three"])
        s.feed(Data("\(esc)[3;3H\(esc)[J".utf8))
        #expect(shown(s) == ["   e one", "line", "li"])
        s.feed(Data("\(esc)[2J".utf8))
        #expect(shown(s) == [])
    }

    @Test func relativeAndAbsoluteMoves() {
        var s = screen("\(esc)[3;4HX")
        s.feed(Data("\(esc)[AY\(esc)[2DZ\(esc)[BW\(esc)[1GV\(esc)[5dU".utf8))
        let lines = s.screenLines
        #expect(lines[1] == "   ZY")
        #expect(lines[2].hasPrefix("V  X"))
        #expect(lines[4] == " U")
        // Moves stop at the edges.
        s.feed(Data("\(esc)[99A\(esc)[99D".utf8))
        #expect(s.cursor == (0, 0))
        s.feed(Data("\(esc)[99B\(esc)[99C".utf8))
        #expect(s.cursor == (4, 19))
        // Next line and previous line go to the first column.
        s.feed(Data("\(esc)[2F".utf8))
        #expect(s.cursor == (2, 0))
        s.feed(Data("\(esc)[E".utf8))
        #expect(s.cursor == (3, 0))
    }

    @Test func eraseInsertAndDeleteCharacters() {
        #expect(shown(screen("abcdef\(esc)[1;2H\(esc)[2X")) == ["a  def"])
        #expect(shown(screen("abcdef\(esc)[1;2H\(esc)[2@")) == ["a  bcdef"])
        #expect(shown(screen("abcdef\(esc)[1;2H\(esc)[2P")) == ["adef"])
        #expect(shown(screen("abcdef", columns: 6).withFeed("\(esc)[1;1H\(esc)[3@"))[0] == "   abc")
        // Insert mode pushes what follows along.
        #expect(shown(screen("abc\(esc)[1;2H\(esc)[4hXY\(esc)[4lZ")) == ["aXYZc"])
    }

    @Test func insertAndDeleteLines() {
        var s = screen("1\r\n2\r\n3\r\n4\r\n5")
        s.feed(Data("\(esc)[2;1H\(esc)[2L".utf8))
        #expect(s.screenLines == ["1", "", "", "2", "3"])
        s.feed(Data("\(esc)[3M".utf8))
        #expect(s.screenLines == ["1", "3", "", "", ""])
    }

    @Test func claudeLikeRedraw() {
        // A prompt box drawn, then redrawn in place: up four lines, erasing each, and printed again.
        var s = screen("", columns: 30, rows: 8)
        s.feed(Data("Welcome\r\n\r\n╭────╮\r\n│ > │\r\n╰────╯\r\n  ? for shortcuts".utf8))
        s.feed(Data("\r\(esc)[2K\(esc)[1A\(esc)[2K\(esc)[1A\(esc)[2K\(esc)[1A\(esc)[2K\(esc)[1A\(esc)[2K\(esc)[G".utf8))
        s.feed(Data("● Hi there\r\n╭────╮\r\n│ > │\r\n╰────╯\r\n  esc to interrupt".utf8))
        #expect(shown(s) == ["Welcome", "● Hi there", "╭────╮", "│ > │", "╰────╯", "  esc to interrupt"])
        #expect(s.historyLines.isEmpty)
    }

    @Test func historyKeepsWhatScrolledOff() {
        let s = screen((1...8).map { "line \($0)" }.joined(separator: "\r\n"), rows: 3)
        #expect(s.historyLines == ["line 1", "line 2", "line 3", "line 4", "line 5"])
        #expect(s.screenLines == ["line 6", "line 7", "line 8"])
        #expect(s.text(history: 2) == ["line 4", "line 5", "line 6", "line 7", "line 8"])
    }

    @Test func historyIsBounded() {
        let s = screen((1...500).map { "\($0)" }.joined(separator: "\r\n"), rows: 2, scrollback: 10)
        #expect(s.historyLines == (489...498).map { "\($0)" })
        #expect(screen("a\r\nb\r\nc\r\nd", rows: 2, scrollback: 0).historyLines.isEmpty)
        // Erase saved lines clears it.
        #expect(screen("a\r\nb\r\nc\r\nd\(esc)[3J", rows: 2).historyLines.isEmpty)
    }

    @Test func alternateScreenRestoresTheMainOne() {
        var s = screen("$ vim\r\n", rows: 4)
        s.feed(Data("\(esc)[?1049h".utf8))
        #expect(s.isAlternateScreen)
        #expect(shown(s) == [])
        s.feed(Data("\(esc)[H~\r\n~\r\n~\r\n\(esc)[4;1H\"file\" 3L".utf8))
        #expect(s.screenLines == ["~", "~", "~", "\"file\" 3L"])
        // Scrolling on the alternate screen keeps no history.
        s.feed(Data("\r\n\r\n".utf8))
        #expect(s.historyLines.isEmpty)
        s.feed(Data("\(esc)[?1049l".utf8))
        #expect(!s.isAlternateScreen)
        #expect(shown(s) == ["$ vim"])
        #expect(s.cursor == (1, 0))
        // 1047 clears the alternate screen on leaving; 47 does not.
        s.feed(Data("\(esc)[?47hkept\(esc)[?47l\(esc)[?47h".utf8))
        #expect(s.screenLines.joined().contains("kept"))
        s.feed(Data("\(esc)[?47l\(esc)[?1047h\(esc)[Hgone\(esc)[?1047l\(esc)[?1047h".utf8))
        #expect(!s.screenLines.joined().contains("gone"))
    }

    @Test func scrollRegions() {
        var s = screen("top\r\n2\r\n3\r\n4\r\nbottom", rows: 5)
        // Lines 2–4 scroll; the first and last stay.
        s.feed(Data("\(esc)[2;4r\(esc)[4;1H\r\nnew".utf8))
        #expect(s.screenLines == ["top", "3", "4", "new", "bottom"])
        #expect(s.historyLines.isEmpty)
        s.feed(Data("\(esc)[2S".utf8))
        #expect(s.screenLines == ["top", "new", "", "", "bottom"])
        s.feed(Data("\(esc)[1T".utf8))
        #expect(s.screenLines == ["top", "", "new", "", "bottom"])
        // Origin mode puts row 1 at the region's top.
        s.feed(Data("\(esc)[?6h\(esc)[1;1HO".utf8))
        #expect(s.screenLines[1] == "O")
    }

    @Test func reverseIndexScrollsDownAtTheTop() {
        var s = screen("a\r\nb\r\nc", rows: 3)
        s.feed(Data("\(esc)[H\(esc)Mz".utf8))
        #expect(s.screenLines == ["z", "a", "b"])
        var region = screen("1\r\n2\r\n3\r\n4", rows: 4)
        region.feed(Data("\(esc)[2;3r\(esc)[2;1H\(esc)M".utf8))
        #expect(region.screenLines == ["1", "", "2", "4"])
    }

    @Test func saveAndRestoreTheCursor() {
        #expect(shown(screen("ab\(esc)7\r\nxyz\(esc)8C")) == ["abC", "xyz"])
        #expect(shown(screen("ab\(esc)[s\r\nxyz\(esc)[uC")) == ["abC", "xyz"])
    }

    @Test func fullReset() {
        let s = screen("junk\(esc)[2;3r\(esc)cfresh")
        #expect(shown(s) == ["fresh"])
    }

    @Test func wideCharacters() {
        let s = screen("日本語x", columns: 10)
        #expect(shown(s) == ["日本語x"])
        #expect(s.cursor == (0, 7))
        // A wide character that does not fit at the edge starts the next line.
        #expect(shown(screen("abcd日", columns: 5)) == ["abcd", "日"])
        // Emoji take two cells; a combining mark joins the character before it.
        #expect(screen("🐱a", columns: 10).cursor.column == 3)
        #expect(shown(screen("e\u{301}x")) == ["e\u{301}x"])
        #expect(screen("e\u{301}x").cursor.column == 2)
        // Overwriting half a wide character blanks the other half.
        #expect(shown(screen("日\(esc)[1;2HX", columns: 10)) == [" X"])
    }

    @Test func lineDrawingCharacters() {
        #expect(shown(screen("\(esc)(0lqqk\(esc)(B ok")) == ["┌──┐ ok"])
        #expect(shown(screen("\(esc))0a\u{0E}x\u{0F}x")) == ["a│x"])
    }

    @Test func repeatsTheLastCharacter() {
        #expect(shown(screen("-\(esc)[4b")) == ["-----"])
    }

    @Test func stringsAreSkipped() {
        let osc = "\(esc)]0;title\u{7}\(esc)]7501;state=working\(esc)\\\(esc)]8;;https://x.dev\(esc)\\link\(esc)]8;;\(esc)\\"
        #expect(shown(screen("a\(osc)b")) == ["alinkb"])
        #expect(shown(screen("a\(esc)Pq#0;2;0;0;0\(esc)\\b\(esc)_apc\(esc)\\c\(esc)^pm\(esc)\\d\(esc)Xsos\(esc)\\e")) == ["abcde"])
    }

    @Test func malformedSequencesDoNotSwallowText() {
        // An OSC that never ends stops at the line break; the text after it is kept.
        #expect(shown(screen("a\(esc)]0;never ended\r\nnext")) == ["a", "next"])
        // An overlong control sequence is dropped up to its final byte.
        #expect(shown(screen("x\(esc)[\(String(repeating: "1;", count: 80))mY")) == ["xY"])
        // ESC inside a sequence starts a new one.
        #expect(shown(screen("a\(esc)[12\(esc)[Cb")) == ["a b"])
        // A broken UTF-8 character shows as the replacement character.
        var s = TextScreen(columns: 10, rows: 2)
        s.feed(Data([0x61, 0xE6, 0x97, 0x62]))
        #expect(shown(s) == ["a\u{FFFD}b"])
        // Private and intermediate sequences pass by.
        #expect(shown(screen("a\(esc)[>1u\(esc)[2 q\(esc)[?2026h\(esc)[?25lb")) == ["ab"])
    }

    @Test func splitAnywhere() {
        let text = "日本\(esc)[2;3H\(esc)]0;tït\u{7}é🐱\(esc)(0q\(esc)(B\(esc)[?1049h\(esc)[?1049lend"
        let bytes = Array(text.utf8)
        let whole = screen(text)
        for cut in 0...bytes.count {
            var s = TextScreen(columns: 20, rows: 5)
            s.feed(Data(bytes[..<cut]))
            s.feed(Data(bytes[cut...]))
            #expect(s.screenLines == whole.screenLines, "cut at \(cut)")
            #expect(s.cursor == whole.cursor)
        }
        // And one byte at a time.
        var single = TextScreen(columns: 20, rows: 5)
        for byte in bytes { single.feed(Data([byte])) }
        #expect(single.screenLines == whole.screenLines)
    }

    @Test func sizesAreAtLeastOne() {
        let s = screen("abc", columns: 0, rows: 0)
        #expect(s.columns == 1 && s.rows == 1)
        #expect(s.screenLines == ["c"])
    }

    @Test("Lines wrapped only because they were too long read back as the one line printed")
    func unwrapsSoftWraps() {
        var wide = TextScreen(columns: 10, rows: 4)
        wide.feed(Data("short\r\nabcdefghij klmnopqrst uv\r\nend\r\n".utf8))
        #expect(wide.text(history: 10) == ["short", "abcdefghij", " klmnopqrs", "t uv", "end"])
        #expect(wide.unwrappedText(history: 10) == ["short", "abcdefghij klmnopqrst uv", "end"])
        // A line erased and rewritten no longer runs on; one that wrapped into history still joins.
        var redrawn = TextScreen(columns: 5, rows: 2)
        redrawn.feed(Data("1234567\r\n".utf8))
        #expect(redrawn.unwrappedText(history: 5) == ["1234567"])
        redrawn.feed(Data("\u{1B}[1;1H\u{1B}[2Kab".utf8))
        #expect(redrawn.unwrappedText(history: 0) == ["ab"])
        #expect(redrawn.unwrappedText(history: 5) == ["12345", "ab"])
    }
}

@Suite("OutputText")
struct OutputTextTests {
    private func text(_ pieces: String..., capacity: Int = 1000) -> OutputText {
        var output = OutputText(capacity: capacity)
        for piece in pieces { output.append(Data(piece.utf8)) }
        return output
    }

    @Test func stripsEscapesAndControls() {
        let output = text("\(esc)[1;32mready\(esc)[0m on\r\n\(esc)]0;title\u{7}port\t3000\u{7}\u{8}")
        #expect(output.text == "ready on\nport\t3000")
        #expect(output.contains("ready on"))
        #expect(!output.contains("title"))
        #expect(output.contains(""))
    }

    @Test func cursorMovesSeparateWords() {
        #expect(text("Hello\(esc)[1Cworld").text == "Hello world")
        #expect(text("one\(esc)[2;1Htwo\(esc)[3;1H\(esc)[4;1Hthree").text == "one\ntwo\nthree")
        // Real line feeds are kept as they are.
        #expect(text("a\n\nb").text == "a\n\nb")
    }

    @Test func splitSafe() {
        let source = "é\(esc)[31m日\(esc)]8;;x\(esc)\\本 done"
        let bytes = Array(source.utf8)
        for cut in 0...bytes.count {
            var output = OutputText()
            output.append(Data(bytes[..<cut]))
            output.append(Data(bytes[cut...]))
            #expect(output.text == "é日本 done", "cut at \(cut)")
        }
    }

    @Test func keepsARollingTail() {
        var output = OutputText(capacity: 10)
        for index in 0..<100 { output.append(Data("\(index % 10)".utf8)) }
        #expect(output.text == "0123456789")
        #expect(output.text.count == 10)
        output.append(Data("marker".utf8))
        #expect(output.text == "6789marker")
        #expect(output.contains("marker"))
        #expect(!output.contains("012"))
    }
}

private extension TextScreen {
    func withFeed(_ text: String) -> TextScreen {
        var copy = self
        copy.feed(Data(text.utf8))
        return copy
    }

}
