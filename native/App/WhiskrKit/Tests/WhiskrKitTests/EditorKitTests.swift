import Foundation
import Testing
@testable import WhiskrKit

@Suite("Reading and writing text files")
struct TextFileTests {
    private func roundTrip(_ bytes: [UInt8]) -> (TextFile, Data) {
        guard case .text(let file) = TextFile.read(Data(bytes)) else {
            Issue.record("read as binary")
            return (TextFile(text: ""), Data())
        }
        return (file, file.data(for: file.text))
    }

    @Test("UTF-8 with LF comes back byte for byte, trailing newline or not")
    func utf8() {
        for text in ["a\nb\n", "a\nb", "", "\n", "名前 = \"é😀\"\n"] {
            let (file, data) = roundTrip(Array(text.utf8))
            #expect(file.encoding == .utf8)
            #expect(file.lineEnding == .lf)
            #expect(file.text == text)
            #expect(data == Data(text.utf8))
        }
    }

    @Test("CRLF and CR are read as LF and written back as they were")
    func lineEndings() {
        let (crlf, crlfData) = roundTrip(Array("one\r\ntwo\r\n".utf8))
        #expect(crlf.text == "one\ntwo\n")
        #expect(crlf.lineEnding == .crlf)
        #expect(!crlf.hadMixedLineEndings)
        #expect(crlfData == Data("one\r\ntwo\r\n".utf8))

        let (cr, crData) = roundTrip(Array("one\rtwo\r".utf8))
        #expect(cr.text == "one\ntwo\n")
        #expect(cr.lineEnding == .cr)
        #expect(crData == Data("one\rtwo\r".utf8))

        let (mixed, _) = roundTrip(Array("a\r\nb\r\nc\nd\r\n".utf8))
        #expect(mixed.lineEnding == .crlf)
        #expect(mixed.hadMixedLineEndings)
        #expect(mixed.text == "a\nb\nc\nd\n")
    }

    @Test("a byte order mark decides the encoding and is written back")
    func byteOrderMarks() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF] + Array("hé\n".utf8)
        let (utf8, utf8Data) = roundTrip(bom)
        #expect(utf8.encoding == .utf8WithBOM)
        #expect(utf8.text == "hé\n")
        #expect(utf8Data == Data(bom))

        let le: [UInt8] = [0xFF, 0xFE] + Array("hi\r\n".data(using: .utf16LittleEndian)!)
        let (utf16, utf16Data) = roundTrip(le)
        #expect(utf16.encoding == .utf16LittleEndian)
        #expect(utf16.text == "hi\n")
        #expect(utf16.lineEnding == .crlf)
        #expect(utf16Data == Data(le))

        let be: [UInt8] = [0xFE, 0xFF] + Array("ok".data(using: .utf16BigEndian)!)
        #expect(roundTrip(be).0.encoding == .utf16BigEndian)
        #expect(roundTrip(be).1 == Data(be))
    }

    @Test("bytes that are not UTF-8 are read as Latin 1 and written back unchanged")
    func latin1() {
        let bytes: [UInt8] = [0x63, 0x61, 0x66, 0xE9, 0x0A, 0x80, 0xFF]
        let (file, data) = roundTrip(bytes)
        #expect(file.encoding == .latin1)
        #expect(file.text.hasPrefix("café\n"))
        #expect(data == Data(bytes))
        // A character Latin 1 cannot hold is written as UTF-8 rather than lost.
        #expect(file.encodingNeeded(for: "日本") == .utf8)
        #expect(String(data: file.data(for: "日本"), encoding: .utf8) == "日本")
    }

    @Test("a NUL byte near the start means binary, unless the file is UTF-16")
    func binary() {
        #expect(TextFile.read(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])) == .binary)
        #expect(TextFile.read(Data(Array("text".utf8) + [0])) == .binary)
        if case .binary = TextFile.read(Data([0xFF, 0xFE, 0x41, 0x00])) { Issue.record("UTF-16 read as binary") }
    }

    @Test("indentation is detected from the lines' own steps")
    func indentation() {
        #expect(Indentation.detect(in: "a {\n    b {\n        c\n    }\n}\n") == Indentation(usesTabs: false, width: 4))
        #expect(Indentation.detect(in: "a:\n  b:\n    c: 1\n  d: 2\n") == Indentation(usesTabs: false, width: 2))
        #expect(Indentation.detect(in: "func a() {\n\tb()\n\tif c {\n\t\td()\n\t}\n}\n")?.usesTabs == true)
        #expect(Indentation.detect(in: "no indentation\nat all\n") == nil)
        // A block comment's " * " lines are not steps.
        #expect(Indentation.detect(in: "/**\n * doc\n */\nfunc a() {\n    b()\n}\n") == Indentation(usesTabs: false, width: 4))
        #expect(Indentation(usesTabs: false, width: 2).unit == "  ")
        #expect(Indentation(usesTabs: true, width: 8).unit == "\t")
    }
}

@Suite("Line index")
struct LineIndexTests {
    @Test("the longest line is found, the first of equals, without its line break")
    func longestLine() {
        let found = LineIndex("ab\ncdef\nghij").longestLine
        #expect(found.line == 1 && found.length == 4)
        #expect(LineIndex("").longestLine.length == 0)
        let last = LineIndex("a\nbb\nccc").longestLine
        #expect(last.line == 2 && last.length == 3)
    }

    @Test("lines start after each newline; offsets find their line")
    func basics() {
        let index = LineIndex("ab\ncd\n\nef")
        #expect(index.starts == [0, 3, 6, 7])
        #expect(index.lineCount == 4)
        #expect(index.line(at: 0) == 0)
        #expect(index.line(at: 2) == 0)
        #expect(index.line(at: 3) == 1)
        #expect(index.line(at: 6) == 2)
        #expect(index.line(at: 9) == 3)
        #expect(index.range(ofLine: 1) == 3..<5)
        #expect(index.range(ofLine: 2) == 6..<6)
        #expect(index.range(ofLine: 3) == 7..<9)
        #expect(LineIndex("").lineCount == 1)
        #expect(LineIndex("é😀\nx").starts == [0, 4])
    }

    @Test("an edit updates the index as rebuilding it would, and says which lines it touched")
    func edits() {
        var text = "one\ntwo\nthree\nfour\n"
        var index = LineIndex(text)
        func apply(_ range: Range<Int>, _ inserted: String) -> (lines: Range<Int>, replacing: Int) {
            let ns = NSMutableString(string: text)
            ns.replaceCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: inserted)
            text = ns as String
            return index.replace(range, with: inserted)
        }
        let typed = apply(5..<5, "X")
        #expect(index == LineIndex(text))
        #expect(typed.lines == 1..<2 && typed.replacing == 1)
        let broke = apply(4..<4, "new\nlines\n")
        #expect(index == LineIndex(text))
        #expect(broke.lines == 1..<4 && broke.replacing == 1)
        let joined = apply(0..<12, "")
        #expect(index == LineIndex(text))
        #expect(joined.lines == 0..<1 && joined.replacing == 3)
        _ = apply(0..<text.utf16.count, "")
        #expect(index == LineIndex(""))
    }
}

@Suite("Finding files by name")
struct PathIndexTests {
    let index = PathIndex(paths: [
        "native/App/Whiskr/Model/Workbench+Scene.swift",
        "native/App/Whiskr/Model/Workbench.swift",
        "web/bootstrap.css",
        "README.md",
        "docs/readme-old.md",
        "src/components/Button.tsx",
        "src/components/button/index.ts",
    ])

    @Test("the file's name counts before its folders")
    func nameFirst() {
        let found = index.search("wbs").map(\.path)
        #expect(found.first == "native/App/Whiskr/Model/Workbench+Scene.swift")
        #expect(found.contains("web/bootstrap.css"))
        #expect(index.search("workbench").first?.path == "native/App/Whiskr/Model/Workbench.swift")
        #expect(index.search("readme").first?.path == "README.md")
        #expect(index.search("button").first?.path == "src/components/Button.tsx")
    }

    @Test("a slash matches along the path; nothing matches nothing")
    func paths() {
        #expect(index.search("button/index").first?.path == "src/components/button/index.ts")
        #expect(index.search("zzz").isEmpty)
        #expect(index.search("   ").isEmpty)
        #expect(index.search("wbs").first?.nameOffsets.isEmpty == false)
    }

    @Test("a search over 100,000 paths costs a few tens of milliseconds, even in a debug build")
    func speed() {
        let many = PathIndex(paths: (0..<100_000).map { "src/module\($0 % 300)/sub\($0 % 17)/File\($0).swift" })
        let elapsed = threadTime { _ = many.search("mod12file99", limit: 50) }
        #expect(elapsed < .milliseconds(150))
        print("PathIndex 100k search:", elapsed)
    }

    @Test("every word must match, in the name or along the path, in any order")
    func words() {
        let index = PathIndex(paths: ["src/main/java/App.java", "src/main/kotlin/App.kt", "src/test/java/AppTest.java"])
        #expect(index.search("main java").map(\.path) == ["src/main/java/App.java"])
        #expect(index.search("java main").map(\.path) == ["src/main/java/App.java"])
        #expect(index.search("app test").first?.path == "src/test/java/AppTest.java")
    }

    @Test("a quoted word matches side by side")
    func quoted() {
        let found = index.search("\"bench+\"").map(\.path)
        #expect(found == ["native/App/Whiskr/Model/Workbench+Scene.swift"])
    }

    @Test("the shorter name a query starts comes first; word starts beat letters inside a word")
    func ranking() {
        let names = PathIndex(paths: ["src/windowActions.ts", "src/window.ts", "lib/window/view.ts"])
        #expect(names.search("window").map(\.path).prefix(2) == ["src/window.ts", "src/windowActions.ts"])
        let starts = PathIndex(paths: ["src/wb/x.ts", "src/awbx.ts", "src/w-b.ts"])
        #expect(starts.search("wb").map(\.path) == ["src/w-b.ts", "src/awbx.ts", "src/wb/x.ts"])
        #expect(starts.search("src/wb").first?.path == "src/wb/x.ts")
    }

    @Test("a two-word search over 100,000 paths stays quick, even in a debug build")
    func wordsSpeed() {
        let many = PathIndex(paths: (0..<100_000).map { "src/module\($0 % 300)/sub\($0 % 17)/File\($0).swift" })
        let elapsed = threadTime { _ = many.search("sub3 file99", limit: 50) }
        #expect(elapsed < .milliseconds(150))
        print("PathIndex 100k two-word search:", elapsed)
        let quoted = threadTime { _ = many.search("\"module12/\" file", limit: 50) }
        #expect(quoted < .milliseconds(150))
        print("PathIndex 100k quoted search:", quoted)
    }
}

@Suite("When a file changes on disk")
struct FileSyncTests {
    @Test("unchanged disk does nothing; untouched files reload; edited ones ask; gone ones say so")
    func responses() {
        let known = Data("a".utf8)
        #expect(FileSync.respond(disk: known, known: known, edited: true) == .nothing)
        #expect(FileSync.respond(disk: known, known: known, edited: false) == .nothing)
        #expect(FileSync.respond(disk: Data("b".utf8), known: known, edited: false) == .reload)
        #expect(FileSync.respond(disk: Data("b".utf8), known: known, edited: true) == .ask)
        #expect(FileSync.respond(disk: nil, known: known, edited: false) == .deleted)
    }

    @Test("the selection keeps its line and column across a reload")
    func carry() {
        let old = LineIndex("one\ntwo\nthree\n"), new = LineIndex("ONE!\ntwo\nthr\n")
        #expect(FileSync.carry(offset: 6, from: old, to: new) == 7)
        #expect(FileSync.carry(offset: 12, from: old, to: new) == 12)
        #expect(FileSync.carry(offset: 13, from: old, to: LineIndex("x")) == 1)
    }
}

@Suite("Line commands")
struct TextEditsTests {
    @Test("Toggle Comment comments at the shallowest indentation and uncomments when all are")
    func lineComments() {
        let lines = ["    a()", "", "        b()"]
        let commented = TextEdits.toggleLineComment(lines, marker: "//")
        #expect(commented == ["    // a()", "", "    //     b()"])
        #expect(TextEdits.toggleLineComment(commented, marker: "//") == lines)
        #expect(TextEdits.toggleLineComment(["# x", "y"], marker: "#") == ["# # x", "# y"])
        #expect(TextEdits.toggleLineComment(["", "  "], marker: "#") == ["", "  "])
    }

    @Test("block comments wrap and unwrap")
    func blockComments() {
        #expect(TextEdits.toggleBlockComment("  <p>hi</p>\n", open: "<!--", close: "-->") == "  <!-- <p>hi</p> -->\n")
        #expect(TextEdits.toggleBlockComment("  <!-- <p>hi</p> -->\n", open: "<!--", close: "-->") == "  <p>hi</p>\n")
    }

    @Test("Shift Right and Left")
    func shifting() {
        #expect(TextEdits.shiftRight(["a", "", " b"], unit: "    ") == ["    a", "", "     b"])
        #expect(TextEdits.shiftLeft(["    a", "  b", "\tc", "d"], width: 4) == ["a", "b", "c", "d"])
    }

    @Test("a new line keeps the indentation, and indents (or continues a doc comment) where the language's rules say")
    func newlines() {
        func indent(_ line: String, _ unit: String, _ id: String, following: String = "") -> String {
            TextEdits.newlineIndent(after: line, following: following, unit: unit, configuration: LanguageRegistry.shared.language(id: id)!.configuration)
        }
        #expect(indent("    let a = 1", "    ", "swift") == "    ")
        #expect(indent("    if x {", "    ", "swift") == "        ")
        #expect(indent("key:", "  ", "yaml") == "  ")
        #expect(indent("def f():", "    ", "python") == "    ")
        // Return inside a line comment carries the comment on to the new line.
        #expect(indent("    // a note", "    ", "swift", following: "that goes on") == "    // ")
        #expect(indent("  <div>", "  ", "html") == "    ")
        #expect(indent("  <br/>", "  ", "html") == "  ")
        #expect(indent("- item", "  ", "markdown") == "")
        #expect(TextEdits.outdentedForClosing("        ", unit: "    ") == "    ")
    }
}

@Suite("Saved pages and panels")
struct LayoutPagesTests {
    @Test("a tab may hold files beside terminals, or only files; inconsistent ones are dropped")
    func pages() throws {
        let pane = UUID(), page = UUID(), other = UUID()
        let mixed = LayoutSnapshot.Tab(id: UUID(), name: nil, tree: PaneTree.pane(pane).splitting(pane, axis: .horizontal, new: page),
                                       panes: [LayoutSnapshot.Pane(id: pane, folder: "/", isClaude: false, accountConfigDir: nil, claudeSessionID: nil, claudeSessionTitle: nil)],
                                       focusedPane: page, zoomedPane: nil, pages: [.init(id: page, kind: .file, path: "/a.swift")])
        let filesOnly = LayoutSnapshot.Tab(id: UUID(), name: nil, tree: .pane(other), panes: [], focusedPane: nil, zoomedPane: nil,
                                           pages: [.init(id: other, kind: .changes, path: "/b.swift")])
        let broken = LayoutSnapshot.Tab(id: UUID(), name: nil, tree: .pane(UUID()), panes: [], focusedPane: nil, zoomedPane: nil, pages: nil)
        let layout = LayoutSnapshot(workspaces: [.init(id: UUID(), folder: "/", tabs: [mixed, filesOnly, broken], selectedTab: nil,
                                                       panel: .init(shown: true, mode: .changes, width: 320))])
        let data = try JSONEncoder().encode(layout)
        let read = try JSONDecoder().decode(LayoutSnapshot.self, from: data).repaired
        #expect(read.workspaces[0].tabs.map(\.id) == [mixed.id, filesOnly.id])
        #expect(read.workspaces[0].tabs[0].focusedPane == page)
        #expect(read.workspaces[0].panel == .init(shown: true, mode: .changes, width: 320))
    }
}

@Suite("Paths printed in a terminal")
struct FileLocationTests {
    @Test("relative paths, lines and columns, home, file URLs and quotes")
    func parsing() {
        #expect(FileLocation("src/app.ts:12:4", folder: "/repo") == FileLocation(path: "/repo/src/app.ts", line: 12, column: 4))
        #expect(FileLocation("./README.md", folder: "/repo") == FileLocation(path: "/repo/README.md"))
        #expect(FileLocation("../x/y.swift:7", folder: "/repo/sub") == FileLocation(path: "/repo/x/y.swift", line: 7))
        #expect(FileLocation("~/notes.txt:3", folder: "/repo", home: "/Users/me") == FileLocation(path: "/Users/me/notes.txt", line: 3))
        #expect(FileLocation("file:///tmp/a.swift", folder: "/repo") == FileLocation(path: "/tmp/a.swift"))
        // Any case, one slash or three: a path, never a relative name that cannot exist (which sent the link
        // to the system to open as it liked, running a script).
        #expect(FileLocation("file:/tmp/x.command", folder: "/repo") == FileLocation(path: "/tmp/x.command"))
        #expect(FileLocation("FILE:///tmp/a.swift:3", folder: "/repo") == FileLocation(path: "/tmp/a.swift", line: 3))
        #expect(FileLocation("file:12", folder: "/repo") == FileLocation(path: "/repo/file", line: 12))
        #expect(FileLocation("\"/abs/path.go:10:\"", folder: "/") == FileLocation(path: "/abs/path.go", line: 10))
        #expect(FileLocation("(lib/main.rs:3)", folder: "/r") == FileLocation(path: "/r/lib/main.rs", line: 3))
        #expect(FileLocation("  ", folder: "/r") == nil)
        #expect(FileLocation(":12", folder: "/r") == nil)
    }
}

@Suite("Dropped paths typed for the shell")
struct ShellQuoteTests {
    @Test("plain paths stay bare; others are single-quoted, quotes escaped")
    func quoting() {
        #expect(ShellQuote.quote("/Users/me/src/app.ts") == "/Users/me/src/app.ts")
        #expect(ShellQuote.quote("/tmp/my file.txt") == "'/tmp/my file.txt'")
        #expect(ShellQuote.quote("/tmp/it's.md") == "'/tmp/it'\\''s.md'")
        #expect(ShellQuote.quote("/tmp/café$x") == "'/tmp/café$x'")
        #expect(ShellQuote.quote("") == "''")
    }
}

@Suite("Markdown names")
struct MarkdownNamesTests {
    @Test("heading anchors are GitHub's")
    func slugs() {
        #expect(MarkdownSlug.make("Getting started") == "getting-started")
        #expect(MarkdownSlug.make("What's **new** in 2.0?") == "whats-new-in-20")
        #expect(MarkdownSlug.make("`make` targets") == "make-targets")
    }
}
