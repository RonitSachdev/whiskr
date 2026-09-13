import Foundation
import Testing
@testable import WhiskrKit

@Suite("Markdown blocks")
struct MarkdownDocumentTests {
    private func kinds(_ text: String) -> [MarkdownBlock.Kind] { MarkdownDocument.parse(text).blocks.map(\.kind) }

    private func list(_ kind: MarkdownBlock.Kind?) -> MarkdownList? {
        if case .list(let list) = kind { return list }
        return nil
    }

    @Test("empty input has no blocks")
    func empty() {
        #expect(MarkdownDocument.parse("").blocks.isEmpty)
        #expect(MarkdownDocument.parse("\n\n  \n").blocks.isEmpty)
    }

    @Test("ATX headings, closing hashes, and what is not a heading")
    func headings() {
        #expect(kinds("# Title\n## Sub ##\n###### Six #\n####### seven\n#hashtag") == [
            .heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub"), .heading(level: 6, text: "Six"),
            .paragraph("####### seven\n#hashtag"),
        ])
        #expect(kinds("# C# #") == [.heading(level: 1, text: "C#")])
        #expect(kinds("#") == [.heading(level: 1, text: "")])
    }

    @Test("setext headings beat rules under paragraph text; rules alone are rules")
    func setext() {
        #expect(kinds("Title\n=====\nSub\n---\n\n---\n***\n_ _ _") == [
            .heading(level: 1, text: "Title"), .heading(level: 2, text: "Sub"), .rule, .rule, .rule,
        ])
        let blocks = MarkdownDocument.parse("Two\nlines\n===").blocks
        #expect(blocks.map(\.kind) == [.heading(level: 1, text: "Two\nlines")])
        #expect(blocks[0].lines == 0..<3)
    }

    @Test("paragraphs keep soft and hard breaks; trailing space at the end goes")
    func paragraphs() {
        #expect(kinds("one  \ntwo\\\n   three   \n\nnext") == [.paragraph("one  \ntwo\\\nthree"), .paragraph("next")])
    }

    @Test("fenced code: language, tildes, indentation, longer closing fence, unterminated")
    func fences() {
        #expect(kinds("```swift title=x\nlet a = 1\n\n  b\n```\nafter") == [.code(language: "swift", code: "let a = 1\n\n  b"), .paragraph("after")])
        #expect(kinds("~~~~\n```\n~~~\n~~~~~") == [.code(language: nil, code: "```\n~~~")])
        #expect(kinds("  ```\n  indented\n    more\n  ```") == [.code(language: nil, code: "indented\n  more")])
        let open = MarkdownDocument.parse("```js\nnever\nclosed")
        #expect(open.blocks.map(\.kind) == [.code(language: "js", code: "never\nclosed")])
        #expect(open.blocks[0].lines == 0..<3)
        #expect(kinds("``` a`b\n") == [.paragraph("``` a`b")])
    }

    @Test("indented code, but not inside a paragraph")
    func indented() {
        #expect(kinds("    code\n\tline\n\n    more\n\ntext") == [.code(language: nil, code: "code\nline\n\nmore"), .paragraph("text")])
        #expect(kinds("text\n    lazy") == [.paragraph("text\nlazy")])
    }

    @Test("block quotes: nesting, lazy continuation, lists and code inside")
    func quotes() {
        let outer = MarkdownDocument.parse("> one\ncontinued\n> > deep\n\nout").blocks
        #expect(outer.count == 2 && outer[1].kind == .paragraph("out"))
        #expect(outer[0].kind == .quote([
            MarkdownBlock(kind: .paragraph("one\ncontinued"), lines: 0..<2),
            MarkdownBlock(kind: .quote([MarkdownBlock(kind: .paragraph("deep"), lines: 2..<3)]), lines: 2..<3),
        ]))
        let blocks = MarkdownDocument.parse("> - a\n> - b\n>\n> ```\n> code\n> ```").blocks
        guard case .quote(let inner) = blocks.first?.kind else { Issue.record("not a quote"); return }
        #expect(list(inner.first?.kind)?.items.count == 2)
        #expect(inner.last?.kind == .code(language: nil, code: "code"))
        #expect(blocks[0].lines == 0..<6)
    }

    @Test("bulleted lists: tight and loose, bullet changes start a new list, nesting by indentation")
    func lists() throws {
        let tight = try #require(list(kinds("- a\n- b\n- c").first))
        #expect(!tight.ordered && tight.items.count == 3)
        #expect(tight.items[1].blocks.map(\.kind) == [.paragraph("b")])

        let blocks = MarkdownDocument.parse("- a\n\n- b\n\n\n- c\n+ other\n\nafter").blocks
        #expect(blocks.count == 3)
        #expect(list(blocks[0].kind)?.items.count == 3)
        #expect(blocks[0].lines == 0..<6)
        #expect(list(blocks[1].kind)?.items.count == 1)
        #expect(blocks[2].kind == .paragraph("after"))

        let nested = try #require(list(kinds("- top\n  - inner\n    - deeper\n  - inner two\n- second").first))
        #expect(nested.items.count == 2)
        let inner = try #require(list(nested.items[0].blocks.last?.kind))
        #expect(inner.items.count == 2)
        #expect(list(inner.items[0].blocks.last?.kind)?.items.first?.blocks.first?.kind == .paragraph("deeper"))
    }

    @Test("list items hold code blocks, more paragraphs and lazy lines")
    func itemContents() throws {
        let item = try #require(list(kinds("1. Install:\n\n   ```sh\n   npm i\n   ```\n\n   Then run.\n2. Done\nlazy line").first))
        #expect(item.ordered && item.start == 1 && item.items.count == 2)
        #expect(item.items[0].blocks.map(\.kind) == [.paragraph("Install:"), .code(language: "sh", code: "npm i"), .paragraph("Then run.")])
        #expect(item.items[1].blocks.map(\.kind) == [.paragraph("Done\nlazy line")])
    }

    @Test("ordered lists: start number, delimiters; '- - -' is a rule")
    func ordered() {
        #expect(list(kinds("3) three\n4) four").first)?.start == 3)
        #expect(kinds("1. a\n1) b").count == 2)
        #expect(kinds("- - -") == [.rule])
        // A numbered line not starting at 1 does not break a paragraph.
        #expect(kinds("The year\n2024. was long") == [.paragraph("The year\n2024. was long")])
    }

    @Test("task lists: open, ticked, and a box that is not a task")
    func tasks() throws {
        let tasks = try #require(list(kinds("- [ ] open\n- [x] done\n- [X] Done\n- [ ]\n- [link](x)").first))
        #expect(tasks.items.map(\.task) == [false, true, true, false, nil])
        #expect(tasks.items[0].blocks.map(\.kind) == [.paragraph("open")])
        #expect(tasks.items[4].blocks.map(\.kind) == [.paragraph("[link](x)")])
    }

    @Test("tables: alignment, escaped pipes, optional outer pipes, ragged rows")
    func tables() throws {
        let blocks = MarkdownDocument.parse("| Name | Code |  Count |\n|:-----|:----:|------:|\n| a \\| b | `x` | 1 |\n| only |\nc | d | e | f\n\nafter").blocks
        guard case .table(let table) = blocks.first?.kind else { Issue.record("not a table"); return }
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.header == ["Name", "Code", "Count"])
        #expect(table.rows == [["a | b", "`x`", "1"], ["only", "", ""], ["c", "d", "e"]])
        #expect(blocks[0].lines == 0..<5)
        #expect(blocks[1].kind == .paragraph("after"))
        #expect(kinds("a | b\n--- | ---").first == .table(MarkdownTable(alignments: [.none, .none], header: ["a", "b"], rows: [])))
        // A delimiter row whose columns do not match is not a table.
        #expect(kinds("a | b\n---").first == .heading(level: 2, text: "a | b"))
    }

    @Test("HTML blocks run to a blank line; images and text inside")
    func htmlBlocks() {
        let text = "<p align=\"center\">\n  <img src=\"docs/logo.png\" alt=\"Logo &amp; name\" width=\"120px\">\n</p>\n\ntext"
        let blocks = MarkdownDocument.parse(text).blocks
        guard case .html(let html) = blocks.first?.kind else { Issue.record("not html"); return }
        #expect(blocks[0].lines == 0..<3)
        #expect(MarkdownHTML.images(in: html) == [MarkdownHTML.Image(source: "docs/logo.png", alt: "Logo & name", width: 120)])
        #expect(MarkdownHTML.text(in: html) == "")
        #expect(MarkdownHTML.text(in: "<b>Bold</b> &lt;tag&gt; <!-- hidden --> caf&#233; &#x1F600;") == "Bold <tag> café 😀")
        #expect(MarkdownHTML.images(in: "<IMG SRC='a.svg'/><img alt=x>") == [MarkdownHTML.Image(source: "a.svg")])
        #expect(blocks[1].kind == .paragraph("text"))
    }

    @Test("front matter only at the very top, and only when closed")
    func frontMatter() {
        #expect(kinds("---\ntitle: X\ntags: [a]\n---\n# Hi") == [.frontMatter("title: X\ntags: [a]"), .heading(level: 1, text: "Hi")])
        #expect(kinds("---\nunclosed") == [.rule, .paragraph("unclosed")])
        #expect(kinds("text\n\n---\na: b\n---").first == .paragraph("text"))
    }

    @Test("line ranges follow the source, CRLF included")
    func lineRanges() {
        let blocks = MarkdownDocument.parse("# A\r\n\r\npara\r\nmore\r\n\r\n- x\r\n- y\r\n").blocks
        #expect(blocks.map(\.lines) == [0..<1, 2..<4, 5..<7])
        #expect(blocks[1].kind == .paragraph("para\nmore"))
    }

    @Test("tabs count as four columns")
    func tabs() throws {
        #expect(kinds("\tcode") == [.code(language: nil, code: "code")])
        let nested = try #require(list(kinds("- a\n\t- b").first))
        #expect(list(nested.items[0].blocks.last?.kind)?.items.count == 1)
    }
}
