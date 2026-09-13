import Foundation

/// A Markdown file's blocks (headings, paragraphs, lists, code, quotes, tables, rules, HTML), each with the
/// source lines it came from, so a preview can follow the editor's scroll. The structure follows CommonMark
/// and GitHub's tables and task lists where real READMEs need it; text inside a block stays Markdown, for
/// Foundation's inline parser (emphasis, code, links) to read.
public struct MarkdownDocument: Sendable, Equatable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public static func parse(_ text: String) -> MarkdownDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { MarkdownLine(text: Substring($1), number: $0) }
        if normalized.hasSuffix("\n") || normalized.isEmpty { lines.removeLast() }
        return MarkdownDocument(blocks: MarkdownParser.blocks(lines, topLevel: true))
    }
}

public struct MarkdownBlock: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case heading(level: Int, text: String)
        /// Its lines joined with "\n"; hard breaks (two trailing spaces, a backslash) stay as written.
        case paragraph(String)
        case list(MarkdownList)
        /// Fenced or indented code, without its final line break; the fence's language, if it names one.
        case code(language: String?, code: String)
        case quote([MarkdownBlock])
        case table(MarkdownTable)
        case rule
        case html(String)
        /// YAML between a `---` on the first line and the next `---` or `...`.
        case frontMatter(String)
    }

    public var kind: Kind
    /// The 0-based source lines it spans: where it starts, and the line after its last.
    public var lines: Range<Int>

    public init(kind: Kind, lines: Range<Int>) {
        self.kind = kind
        self.lines = lines
    }
}

public struct MarkdownList: Sendable, Equatable {
    public var ordered: Bool
    /// The first item's number (1 for a bulleted list).
    public var start: Int
    public var items: [MarkdownListItem]

    public init(ordered: Bool, start: Int, items: [MarkdownListItem]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }
}

public struct MarkdownListItem: Sendable, Equatable {
    /// nil when the item is not a task; otherwise whether its box is ticked. The box is not in the text.
    public var task: Bool?
    public var blocks: [MarkdownBlock]

    public init(task: Bool?, blocks: [MarkdownBlock]) {
        self.task = task
        self.blocks = blocks
    }
}

public struct MarkdownTable: Sendable, Equatable {
    public enum Alignment: Sendable, Equatable { case none, leading, center, trailing }

    public var alignments: [Alignment]
    /// Each cell's Markdown, trimmed, with escaped pipes unescaped.
    public var header: [String]
    /// Each row has as many cells as the header.
    public var rows: [[String]]

    public init(alignments: [Alignment], header: [String], rows: [[String]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }
}

/// Images and text in an HTML block (READMEs often centre a logo with `<p align="center"><img src=…></p>`).
public enum MarkdownHTML {
    public struct Image: Sendable, Equatable {
        public var source: String
        public var alt: String?
        public var width: Double?

        public init(source: String, alt: String? = nil, width: Double? = nil) {
            self.source = source
            self.alt = alt
            self.width = width
        }
    }

    /// Every `<img>` with a `src`, in order.
    public static func images(in html: String) -> [Image] {
        tags(in: html).compactMap { tag -> Image? in
            guard tag.name == "img", let source = tag.attributes["src"], !source.isEmpty else { return nil }
            let width = tag.attributes["width"].flatMap { Double($0.replacingOccurrences(of: "px", with: "").trimmingCharacters(in: .whitespaces)) }
            return Image(source: decodeEntities(source), alt: tag.attributes["alt"].map(decodeEntities), width: width)
        }
    }

    /// The text with the tags taken out, entities decoded and whitespace collapsed; "" when there are only tags.
    public static func text(in html: String) -> String {
        var text = ""
        var inTag = false, inComment = false
        var index = html.startIndex
        while index < html.endIndex {
            if inComment {
                if html[index...].hasPrefix("-->") { inComment = false; index = html.index(index, offsetBy: 3); continue }
            } else if inTag {
                if html[index] == ">" { inTag = false; text.append(" ") }
            } else if html[index...].hasPrefix("<!--") {
                inComment = true
                index = html.index(index, offsetBy: 4)
                continue
            } else if html[index] == "<", html.index(after: index) < html.endIndex,
                      html[html.index(after: index)].isLetter || "/!?".contains(html[html.index(after: index)]) {
                inTag = true
            } else {
                text.append(html[index])
            }
            index = html.index(after: index)
        }
        let decoded = decodeEntities(text)
        return decoded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// &amp; &lt; &gt; &quot; &#39; &apos; &nbsp; and numeric entities.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            rest = rest[amp...]
            guard let semicolon = rest.prefix(12).firstIndex(of: ";") else {
                result.append("&")
                rest = rest.dropFirst()
                continue
            }
            let name = rest[rest.index(after: rest.startIndex)..<semicolon]
            var replacement: String?
            switch name {
            case "amp": replacement = "&"
            case "lt": replacement = "<"
            case "gt": replacement = ">"
            case "quot": replacement = "\""
            case "apos": replacement = "'"
            case "nbsp": replacement = "\u{a0}"
            default:
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                }
            }
            if let replacement {
                result += replacement
                rest = rest[rest.index(after: semicolon)...]
            } else {
                result.append("&")
                rest = rest.dropFirst()
            }
        }
        return result + rest
    }

    private struct Tag {
        var name: String
        var attributes: [String: String]
    }

    /// The opening tags, with their attributes (names lowercased; values unquoted).
    private static func tags(in html: String) -> [Tag] {
        var tags: [Tag] = []
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            rest = rest[rest.index(after: open)...]
            guard let close = rest.firstIndex(of: ">") else { break }
            let body = rest[..<close]
            rest = rest[rest.index(after: close)...]
            guard let first = body.first, first.isLetter else { continue }
            let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()
            tags.append(Tag(name: name, attributes: attributes(body.dropFirst(name.count))))
        }
        return tags
    }

    private static func attributes(_ text: Substring) -> [String: String] {
        var attributes: [String: String] = [:]
        var rest = text
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "/" }
            let name = rest.prefix { !$0.isWhitespace && $0 != "=" && $0 != "/" }
            guard !name.isEmpty else { break }
            rest = rest.dropFirst(name.count).drop(while: \.isWhitespace)
            var value = ""
            if rest.first == "=" {
                rest = rest.dropFirst().drop(while: \.isWhitespace)
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    let inner = rest.dropFirst()
                    let end = inner.firstIndex(of: quote) ?? inner.endIndex
                    value = String(inner[..<end])
                    rest = end < inner.endIndex ? inner[inner.index(after: end)...] : inner[end...]
                } else {
                    let unquoted = rest.prefix { !$0.isWhitespace }
                    value = String(unquoted)
                    rest = rest.dropFirst(unquoted.count)
                }
            }
            attributes[name.lowercased()] = value
        }
        return attributes
    }
}

// MARK: Parsing

/// A source line, and where it is in the file.
struct MarkdownLine: Sendable {
    var text: Substring
    var number: Int

    var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

    /// Its leading whitespace in columns, tabs to the next multiple of four.
    var indent: Int {
        var column = 0
        for character in text {
            if character == " " { column += 1 } else if character == "\t" { column += 4 - column % 4 } else { break }
        }
        return column
    }

    /// The line without its leading whitespace.
    var trimmed: Substring { text.drop { $0 == " " || $0 == "\t" } }

    /// The line with `columns` of leading whitespace taken off (a tab only partly taken leaves spaces).
    func removingIndent(_ columns: Int) -> MarkdownLine {
        var column = 0
        var index = text.startIndex
        while index < text.endIndex, column < columns {
            let character = text[index]
            if character == " " {
                column += 1
            } else if character == "\t" {
                let width = 4 - column % 4
                if column + width > columns {
                    let left = column + width - columns
                    return MarkdownLine(text: Substring(String(repeating: " ", count: left)) + text[text.index(after: index)...], number: number)
                }
                column += width
            } else {
                break
            }
            index = text.index(after: index)
        }
        return MarkdownLine(text: text[index...], number: number)
    }
}

/// The block parser: reads a run of lines at one level (a document, or what is inside a quote or a list
/// item), handing containers' inner lines back to itself.
enum MarkdownParser {
    static func blocks(_ lines: [MarkdownLine], topLevel: Bool = false) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0
        if topLevel, let front = frontMatter(lines) {
            blocks.append(front.block)
            index = front.next
        }
        while index < lines.count {
            let line = lines[index]
            if line.isBlank {
                index += 1
                continue
            }
            if let (block, next) = fencedCode(lines, at: index) ?? indentedCode(lines, at: index) ?? heading(lines, at: index) ?? rule(lines, at: index)
                ?? quote(lines, at: index) ?? list(lines, at: index) ?? html(lines, at: index) ?? table(lines, at: index) {
                blocks.append(block)
                index = next
                continue
            }
            let (block, next) = paragraph(lines, at: index)
            blocks.append(block)
            index = next
        }
        return blocks
    }

    private static func span(_ lines: [MarkdownLine], _ from: Int, _ to: Int) -> Range<Int> {
        lines[from].number..<(lines[max(from, to - 1)].number + 1)
    }

    // MARK: Leaves

    private static func frontMatter(_ lines: [MarkdownLine]) -> (block: MarkdownBlock, next: Int)? {
        guard let first = lines.first, first.number == 0, first.text.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let end = lines.indices.dropFirst().first(where: { ["---", "..."].contains(lines[$0].text.trimmingCharacters(in: .whitespaces)) }) else { return nil }
        let yaml = lines[1..<end].map { String($0.text) }.joined(separator: "\n")
        return (MarkdownBlock(kind: .frontMatter(yaml), lines: span(lines, 0, end + 1)), end + 1)
    }

    /// An opening fence: up to three spaces, then three or more backticks or tildes.
    private static func fence(_ line: MarkdownLine) -> (character: Character, length: Int, indent: Int, info: Substring)? {
        guard line.indent <= 3 else { return nil }
        let rest = line.trimmed
        guard let character = rest.first, character == "`" || character == "~" else { return nil }
        let length = rest.prefix { $0 == character }.count
        guard length >= 3 else { return nil }
        let info = rest.dropFirst(length)
        if character == "`", info.contains("`") { return nil }
        return (character, length, line.indent, info)
    }

    private static func fencedCode(_ lines: [MarkdownLine], at start: Int) -> (MarkdownBlock, Int)? {
        guard let open = fence(lines[start]) else { return nil }
        let language = open.info.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init)
        var code: [String] = []
        var index = start + 1
        var closed = false
        while index < lines.count {
            let line = lines[index]
            if line.indent <= 3 {
                let rest = line.trimmed
                let run = rest.prefix { $0 == open.character }.count
                if run >= open.length, rest.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    closed = true
                    break
                }
            }
            code.append(String(line.removingIndent(open.indent).text))
            index += 1
        }
        let end = closed ? index + 1 : index
        return (MarkdownBlock(kind: .code(language: language?.isEmpty == false ? language : nil, code: code.joined(separator: "\n")),
                              lines: span(lines, start, end)), end)
    }

    private static func indentedCode(_ lines: [MarkdownLine], at start: Int) -> (MarkdownBlock, Int)? {
        guard lines[start].indent >= 4 else { return nil }
        var index = start
        var last = start
        while index < lines.count, lines[index].isBlank || lines[index].indent >= 4 {
            if !lines[index].isBlank { last = index }
            index += 1
        }
        let code = lines[start...last].map { $0.isBlank ? "" : String($0.removingIndent(4).text) }.joined(separator: "\n")
        return (MarkdownBlock(kind: .code(language: nil, code: code), lines: span(lines, start, last + 1)), last + 1)
    }

    private static func atxHeading(_ line: MarkdownLine) -> (level: Int, text: String)? {
        guard line.indent <= 3 else { return nil }
        let rest = line.trimmed
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // A closing run of #s, after a space (or the whole text), is not part of it.
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0 {
            let before = text.dropLast(closing)
            if before.isEmpty || before.last == " " || before.last == "\t" { text = before.trimmingCharacters(in: .whitespaces) }
        }
        return (level, text)
    }

    private static func heading(_ lines: [MarkdownLine], at index: Int) -> (MarkdownBlock, Int)? {
        guard let (level, text) = atxHeading(lines[index]) else { return nil }
        return (MarkdownBlock(kind: .heading(level: level, text: text), lines: span(lines, index, index + 1)), index + 1)
    }

    private static func isRule(_ line: MarkdownLine) -> Bool {
        guard line.indent <= 3 else { return false }
        let marks = line.trimmed.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let character = marks.first, "*-_".contains(character) else { return false }
        return marks.allSatisfy { $0 == character }
    }

    private static func rule(_ lines: [MarkdownLine], at index: Int) -> (MarkdownBlock, Int)? {
        guard isRule(lines[index]) else { return nil }
        return (MarkdownBlock(kind: .rule, lines: span(lines, index, index + 1)), index + 1)
    }

    private static func isHTMLStart(_ line: MarkdownLine) -> Bool {
        guard line.indent <= 3 else { return false }
        let rest = line.trimmed
        guard rest.first == "<", let next = rest.dropFirst().first else { return false }
        return next.isLetter || next == "/" || next == "!" || next == "?"
    }

    private static func html(_ lines: [MarkdownLine], at start: Int) -> (MarkdownBlock, Int)? {
        guard isHTMLStart(lines[start]) else { return nil }
        var index = start
        while index < lines.count, !lines[index].isBlank { index += 1 }
        let text = lines[start..<index].map { String($0.text) }.joined(separator: "\n")
        return (MarkdownBlock(kind: .html(text), lines: span(lines, start, index)), index)
    }

    /// Whether a line begins a block that ends a paragraph before it.
    private static func interruptsParagraph(_ line: MarkdownLine) -> Bool {
        if line.isBlank || fence(line) != nil || atxHeading(line) != nil || isRule(line) || isHTMLStart(line) { return true }
        if line.indent <= 3, line.trimmed.first == ">" { return true }
        if let marker = listMarker(line) {
            // An empty item, or a numbered one not starting at 1, does not break a paragraph (CommonMark).
            return !marker.empty && (!marker.ordered || marker.number == 1)
        }
        return false
    }

    private static func paragraph(_ lines: [MarkdownLine], at start: Int) -> (MarkdownBlock, Int) {
        var text: [Substring] = [lines[start].trimmed]
        var index = start + 1
        while index < lines.count {
            let line = lines[index]
            // A line of = or - under the text makes it a heading.
            if line.indent <= 3 {
                let rest = line.trimmed.trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty, rest.allSatisfy({ $0 == "=" }) || rest.allSatisfy({ $0 == "-" }) {
                    let level = rest.first == "=" ? 1 : 2
                    let joined = text.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
                    return (MarkdownBlock(kind: .heading(level: level, text: joined), lines: span(lines, start, index + 1)), index + 1)
                }
            }
            if interruptsParagraph(line) { break }
            text.append(line.trimmed)
            index += 1
        }
        var joined = text.joined(separator: "\n")
        while joined.last == " " || joined.last == "\t" { joined.removeLast() }
        return (MarkdownBlock(kind: .paragraph(joined), lines: span(lines, start, index)), index)
    }

    // MARK: Tables

    /// A row's cells, split at pipes not escaped with a backslash; outer pipes are optional.
    static func cells(_ text: Substring) -> [String] {
        var row = text.trimmingCharacters(in: .whitespaces)[...]
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|"), !row.hasSuffix("\\|") { row = row.dropLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in row {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func alignments(_ line: MarkdownLine) -> [MarkdownTable.Alignment]? {
        guard line.indent <= 3, line.text.contains("-") else { return nil }
        let cells = cells(line.text)
        var result: [MarkdownTable.Alignment] = []
        for cell in cells {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (true, false): result.append(.leading)
            case (false, true): result.append(.trailing)
            case (false, false): result.append(.none)
            }
        }
        return result
    }

    private static func table(_ lines: [MarkdownLine], at start: Int) -> (MarkdownBlock, Int)? {
        guard start + 1 < lines.count, lines[start].indent <= 3, lines[start].text.contains("|"),
              let alignments = alignments(lines[start + 1]) else { return nil }
        let header = cells(lines[start].text)
        guard header.count == alignments.count else { return nil }
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count, !lines[index].isBlank, lines[index].text.contains("|") {
            var row = cells(lines[index].text)
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(Array(row.prefix(header.count)))
            index += 1
        }
        return (MarkdownBlock(kind: .table(MarkdownTable(alignments: alignments, header: header, rows: rows)), lines: span(lines, start, index)), index)
    }

    // MARK: Containers

    private static func quote(_ lines: [MarkdownLine], at start: Int) -> (MarkdownBlock, Int)? {
        guard lines[start].indent <= 3, lines[start].trimmed.first == ">" else { return nil }
        var inner: [MarkdownLine] = []
        var index = start
        var last = start
        while index < lines.count {
            let line = lines[index]
            if line.indent <= 3, line.trimmed.first == ">" {
                var rest = line.trimmed.dropFirst()
                if rest.first == " " { rest = rest.dropFirst() } else if rest.first == "\t" { rest = Substring("  ") + rest.dropFirst() }
                inner.append(MarkdownLine(text: rest, number: line.number))
            } else if !line.isBlank, let previous = inner.last, !previous.isBlank, !interruptsParagraph(line), !isOpenFence(inner) {
                // Lazy continuation: paragraph text carried on without its ">".
                inner.append(line)
            } else {
                break
            }
            last = index
            index += 1
        }
        return (MarkdownBlock(kind: .quote(blocks(inner)), lines: span(lines, start, last + 1)), last + 1)
    }

    struct ListMarker {
        var ordered: Bool
        /// The bullet, or the delimiter after the number ("." or ")").
        var character: Character
        var number: Int
        var indent: Int
        /// Where the item's text begins, in columns.
        var contentColumn: Int
        /// Nothing follows the marker on its line.
        var empty: Bool
    }

    static func listMarker(_ line: MarkdownLine) -> ListMarker? {
        let indent = line.indent
        guard indent <= 3 else { return nil }
        let rest = line.trimmed
        var ordered = false
        var character: Character
        var number = 1
        var markerWidth: Int
        if let first = rest.first, "-*+".contains(first) {
            character = first
            markerWidth = 1
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count), let delimiter = rest.dropFirst(digits.count).first, delimiter == "." || delimiter == ")" else { return nil }
            ordered = true
            character = delimiter
            number = Int(digits) ?? 1
            markerWidth = digits.count + 1
        }
        let after = rest.dropFirst(markerWidth)
        if after.allSatisfy({ $0 == " " || $0 == "\t" }) {
            return ListMarker(ordered: ordered, character: character, number: number, indent: indent, contentColumn: indent + markerWidth + 1, empty: true)
        }
        guard after.first == " " || after.first == "\t" else { return nil }
        let spaces = MarkdownLine(text: after, number: 0).indent
        // Five or more spaces: the text is indented code, one space after the marker.
        let gap = spaces >= 5 ? 1 : spaces
        return ListMarker(ordered: ordered, character: character, number: number, indent: indent, contentColumn: indent + markerWidth + gap, empty: false)
    }

    private static func list(_ lines: [MarkdownLine], at start: Int) -> (MarkdownBlock, Int)? {
        guard let first = listMarker(lines[start]) else { return nil }
        // "- - -" is a rule, not a list.
        if isRule(lines[start]) { return nil }
        var items: [MarkdownListItem] = []
        var index = start
        var last = start
        var marker = first
        while true {
            var inner: [MarkdownLine] = []
            // The marker's line, from where its text starts.
            let firstLine = lines[index]
            inner.append(marker.empty ? MarkdownLine(text: "", number: firstLine.number) : content(firstLine, marker))
            last = index
            index += 1
            while index < lines.count {
                let line = lines[index]
                if line.isBlank {
                    inner.append(MarkdownLine(text: "", number: line.number))
                    index += 1
                    continue
                }
                if line.indent >= marker.contentColumn {
                    inner.append(line.removingIndent(marker.contentColumn))
                } else if let previous = inner.last, !previous.isBlank, !interruptsParagraph(line), listMarker(line) == nil, !isOpenFence(inner) {
                    // Lazy continuation of the item's paragraph.
                    inner.append(line)
                } else {
                    break
                }
                last = index
                index += 1
            }
            // Blank lines after the item belong to the list only if another item follows.
            while let tail = inner.last, tail.isBlank, inner.count > 1 { inner.removeLast() }
            items.append(item(inner))
            guard index < lines.count, let next = listMarker(lines[index]), !isRule(lines[index]),
                  next.ordered == first.ordered, next.character == first.character, next.indent < marker.contentColumn else {
                break
            }
            marker = next
        }
        // Blank lines skipped between the last item and what follows are not the list's.
        index = last + 1
        let list = MarkdownList(ordered: first.ordered, start: first.ordered ? first.number : 1, items: items)
        return (MarkdownBlock(kind: .list(list), lines: span(lines, start, last + 1)), index)
    }

    /// The marker's line from where the item's text starts: the marker counts as spaces, so a tab after it
    /// still lands on the right column.
    private static func content(_ line: MarkdownLine, _ marker: ListMarker) -> MarkdownLine {
        let rest = line.trimmed
        let width = rest.prefix { !($0 == " " || $0 == "\t") }.count
        let blanked = Substring(String(repeating: " ", count: marker.indent + width)) + rest.dropFirst(width)
        return MarkdownLine(text: blanked, number: line.number).removingIndent(marker.contentColumn)
    }

    /// Whether the lines end inside a fenced code block that has not closed.
    private static func isOpenFence(_ lines: [MarkdownLine]) -> Bool {
        var open: (character: Character, length: Int)?
        for line in lines {
            if let current = open {
                let rest = line.trimmed
                let run = rest.prefix { $0 == current.character }.count
                if line.indent <= 3, run >= current.length, rest.dropFirst(run).allSatisfy({ $0 == " " || $0 == "\t" }) { open = nil }
            } else if let fence = fence(line) {
                open = (fence.character, fence.length)
            }
        }
        return open != nil
    }

    /// An item's blocks, with a leading task box taken off its first line.
    private static func item(_ lines: [MarkdownLine]) -> MarkdownListItem {
        var lines = lines
        var task: Bool?
        if let first = lines.first {
            let text = first.text
            for (box, ticked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where text.hasPrefix(box) {
                let after = text.dropFirst(3)
                if after.isEmpty || after.first == " " || after.first == "\t" {
                    task = ticked
                    lines[0] = MarkdownLine(text: after.drop { $0 == " " || $0 == "\t" }, number: first.number)
                }
                break
            }
        }
        return MarkdownListItem(task: task, blocks: blocks(lines))
    }
}
