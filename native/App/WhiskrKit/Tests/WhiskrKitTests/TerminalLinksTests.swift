import Foundation
import Testing
@testable import WhiskrKit

@Suite("Links in terminal lines")
struct TerminalLinksTests {
    /// A line, the text its one link should cover, and what that link points at.
    struct Case: CustomTestStringConvertible, Sendable {
        let line: String
        let covered: String
        let target: TerminalLink.Target
        var testDescription: String { line }

        init(_ line: String, _ covered: String, _ path: String, _ number: Int? = nil, _ column: Int? = nil) {
            self.line = line
            self.covered = covered
            target = .file(path: path, line: number, column: column)
        }

        init(_ line: String, url: String) {
            self.line = line
            covered = url
            target = .url(url)
        }
    }

    static let cases: [Case] = [
        // Lines and columns.
        Case("foo.ts:12", "foo.ts:12", "foo.ts", 12),
        Case("foo.ts:12:3", "foo.ts:12:3", "foo.ts", 12, 3),
        Case("src/foo.ts:12:3:", "src/foo.ts:12:3", "src/foo.ts", 12, 3),
        Case("foo.ts:12.3", "foo.ts:12.3", "foo.ts", 12, 3),
        Case("foo.ts#12", "foo.ts#12", "foo.ts", 12),
        Case("foo.ts(12,3)", "foo.ts(12,3)", "foo.ts", 12, 3),
        Case("foo.ts(12, 3)", "foo.ts(12, 3)", "foo.ts", 12, 3),
        Case("foo.ts(12)", "foo.ts(12)", "foo.ts", 12),
        Case("foo.ts line 12", "foo.ts line 12", "foo.ts", 12),
        Case("foo.ts:line 12", "foo.ts:line 12", "foo.ts", 12),
        Case("foo.ts: line 12, col 4", "foo.ts: line 12, col 4", "foo.ts", 12, 4),
        // Kinds of path.
        Case("./foo.ts", "./foo.ts", "./foo.ts"),
        Case("../a/b.rs:7", "../a/b.rs:7", "../a/b.rs", 7),
        Case("/abs/path/x.swift:10:2", "/abs/path/x.swift:10:2", "/abs/path/x.swift", 10, 2),
        Case("~/notes.txt:3", "~/notes.txt:3", "~/notes.txt", 3),
        Case("README.md", "README.md", "README.md"),
        Case("open src/Makefile", "src/Makefile", "src/Makefile"),
        Case("file:///tmp/a%20b.swift", "file:///tmp/a%20b.swift", "file:///tmp/a%20b.swift"),
        Case("file:///tmp/a.swift:4", "file:///tmp/a.swift:4", "file:///tmp/a.swift", 4),
        Case("--- a/src/x.ts", "a/src/x.ts", "a/src/x.ts"),
        Case("+++ b/src/x.ts", "b/src/x.ts", "b/src/x.ts"),
        // Quotes.
        Case("  File \"/x/foo.py\", line 12, in main", "\"/x/foo.py\", line 12", "/x/foo.py", 12),
        Case("\"foo.py\", line 12, column 3", "\"foo.py\", line 12, column 3", "foo.py", 12, 3),
        Case("at \"path with spaces/x.ts\":12", "\"path with spaces/x.ts\":12", "path with spaces/x.ts", 12),
        Case("at 'path with spaces/x.ts' now", "'path with spaces/x.ts'", "path with spaces/x.ts"),
        Case("at \"path with spaces/x.ts\"", "\"path with spaces/x.ts\"", "path with spaces/x.ts"),
        Case("don't open 'src/x.ts'", "'src/x.ts'", "src/x.ts"),
        Case("\"/abs/path.go:10:\"", "/abs/path.go:10", "/abs/path.go", 10),
        // Brackets and punctuation round it.
        Case("[foo.ts:12]", "foo.ts:12", "foo.ts", 12),
        Case("app/[id]/page.tsx:2", "app/[id]/page.tsx:2", "app/[id]/page.tsx", 2),
        Case("see app/(shop)/[...slug]/page.tsx now", "app/(shop)/[...slug]/page.tsx", "app/(shop)/[...slug]/page.tsx"),
        Case("pages/[id].tsx(4,5): error", "pages/[id].tsx(4,5)", "pages/[id].tsx", 4, 5),
        Case("(see src/x.ts)", "src/x.ts", "src/x.ts"),
        Case("(foo.ts:12)", "foo.ts:12", "foo.ts", 12),
        Case("<foo.ts:12>", "foo.ts:12", "foo.ts", 12),
        Case("see foo.ts:12.", "foo.ts:12", "foo.ts", 12),
        Case("foo.ts:12, then", "foo.ts:12", "foo.ts", 12),
        Case("foo.ts; bar", "foo.ts", "foo.ts"),
        Case("(see foo.ts)", "foo.ts", "foo.ts"),
        Case("see foo.ts.", "foo.ts", "foo.ts"),
        // What tools print.
        Case("  --> src/main.rs:4:5", "src/main.rs:4:5", "src/main.rs", 4, 5),
        Case("src/x.ts(4,5): error TS2322: Type 'a'", "src/x.ts(4,5)", "src/x.ts", 4, 5),
        Case("./x.go:4:5: undefined: y", "./x.go:4:5", "./x.go", 4, 5),
        Case("/x/y.swift:4:5: error: no", "/x/y.swift:4:5", "/x/y.swift", 4, 5),
        Case("src/x.ts:12:const a = 1", "src/x.ts:12", "src/x.ts", 12),
        Case("FAILED tests/test_x.py::test_y - assert", "tests/test_x.py", "tests/test_x.py"),
        Case("ERROR:src/x.ts:3", "src/x.ts:3", "src/x.ts", 3),
        // Web addresses.
        Case("go to https://example.com/a?b=c#d.", url: "https://example.com/a?b=c#d"),
        Case("(https://example.com/a)", url: "https://example.com/a"),
        Case("https://example.com/a, and", url: "https://example.com/a"),
        Case("https://en.wikipedia.org/wiki/Foo_(bar)", url: "https://en.wikipedia.org/wiki/Foo_(bar)"),
        Case("(see https://en.wikipedia.org/wiki/Foo_(bar)).", url: "https://en.wikipedia.org/wiki/Foo_(bar)"),
        Case("Local: http://localhost:3000/path", url: "http://localhost:3000/path"),
        // Wide characters before the link.
        Case("エラー：src/x.ts:3 を開けません", "src/x.ts:3", "src/x.ts", 3),
        Case("ファイル「資料/メモ.txt」", "資料/メモ.txt", "資料/メモ.txt"),
        Case("日本語 👩‍👩‍👧 foo.ts:12", "foo.ts:12", "foo.ts", 12),
    ]

    @Test("finds each form, with its line and column, covering just the link", arguments: cases)
    func forms(_ example: Case) throws {
        let links = TerminalLink.links(in: example.line)
        try #require(links.count == 1, "\(links)")
        let link = links[0]
        let characters = Array(example.line)
        #expect(String(characters[link.range]) == example.covered)
        #expect(link.target == example.target)
        // Anywhere in it, the line and column included, finds the whole link.
        for index in link.range { #expect(TerminalLink.link(in: example.line, at: index) == link) }
    }

    @Test("words, versions, times, numbers and addresses are not links")
    func notLinks() {
        for line in ["hello", "error: something failed", "1.2.3", "v1.2.3", "12:30:45", "42", "3.14", "-->",
                     "192.168.0.1", "192.168.0.1:8080", "say \"hello world\"", "a // b", ""] {
            #expect(TerminalLink.links(in: line).isEmpty, "\(line)")
        }
        // A quoted sentence is not one path; a path in it still is.
        #expect(TerminalLink.links(in: "\"see the docs/guide for details.\"").map(\.target) == [.file(path: "docs/guide", line: nil, column: nil)])
    }

    @Test("several links on a line, left to right; none on spaces or plain words")
    func positions() {
        let line = "diff --git a/src/x.ts b/src/x.ts https://x.org"
        #expect(TerminalLink.links(in: line).map(\.range) == [11..<21, 22..<32, 33..<46])
        #expect(TerminalLink.link(in: line, at: 21) == nil)
        #expect(TerminalLink.link(in: line, at: 2) == nil)
        #expect(TerminalLink.link(in: line, at: 999) == nil)
        #expect(TerminalLink.link(in: line, at: -1) == nil)
    }

    @Test("long lines of punctuation cost well under a few milliseconds")
    func speed() {
        let lines = [
            String(repeating: ".:[(", count: 500),
            String(repeating: "a:", count: 1000),
            String(repeating: "\"'`", count: 667),
            String(repeating: "x/", count: 1000),
            String(repeating: "h://", count: 500),
            String(repeating: "ab://\"", count: 334),
            "https://" + String(repeating: "(", count: 1992),
            "https://" + String(repeating: ")", count: 1992),
            String(repeating: "x.ts:1 ", count: 286),
            String(repeating: "資料/メモ.txt ", count: 200),
        ]
        for line in lines {
            // The best of three: the budget is on what the line costs, not on how busy the Mac is.
            let elapsed = (0..<3).map { _ in threadTime { _ = TerminalLink.links(in: line) } }.min()!
            #expect(elapsed < .milliseconds(5), "\(line.prefix(8)): \(elapsed)")
            print("TerminalLink 2,000 characters:", line.prefix(8), elapsed)
        }
    }

    @Test("candidates: home, the terminal's folder, git's prefixes stripped first, file URLs decoded")
    func candidates() {
        #expect(TerminalLink.candidates(for: "~/notes.txt", folder: "/repo", home: "/Users/me") == ["/Users/me/notes.txt"])
        #expect(TerminalLink.candidates(for: "./src/../x.ts", folder: "/repo", home: "/h") == ["/repo/x.ts"])
        #expect(TerminalLink.candidates(for: "../a/b.rs", folder: "/repo/sub", home: "/h") == ["/repo/a/b.rs"])
        #expect(TerminalLink.candidates(for: "x.ts", folder: "/repo/", home: "/h") == ["/repo/x.ts"])
        #expect(TerminalLink.candidates(for: "/abs/x.swift", folder: "/repo", home: "/h") == ["/abs/x.swift"])
        #expect(TerminalLink.candidates(for: "a/src/x.ts", folder: "/repo", home: "/h") == ["/repo/src/x.ts", "/repo/a/src/x.ts"])
        #expect(TerminalLink.candidates(for: "b/src/x.ts", folder: "/repo", home: "/h") == ["/repo/src/x.ts", "/repo/b/src/x.ts"])
        #expect(TerminalLink.candidates(for: "ab/x.ts", folder: "/repo", home: "/h") == ["/repo/ab/x.ts"])
        #expect(TerminalLink.candidates(for: "file:///tmp/a%20b.swift", folder: "/repo", home: "/h") == ["/tmp/a b.swift"])
    }
}
