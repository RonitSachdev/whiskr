import Foundation

// The markup languages: HTML and XML, and Markdown (whose fenced code blocks are lexed in their own
// language, carried inside Markdown's state).

/// HTML and XML: tags, attributes, comments, CDATA, declarations and entities.
enum MarkupLexer {
    private static let commentOpen = Unit.of("<!--"), commentClose = Unit.of("-->")
    private static let cdataOpen = Unit.of("<![CDATA["), cdataClose = Unit.of("]]>")
    private static let processingClose = Unit.of("?>")

    static func lex(_ s: inout LineScanner, mode: LexMode) -> LexMode {
        switch mode {
        case .markupComment:
            if !until(&s, from: 0, close: commentClose, kind: .comment) { return .markupComment }
        case .cdata:
            if !until(&s, from: 0, close: cdataClose, kind: .string) { return .cdata }
        case .markupTag:
            let attributes = Shared.attributes(&s, from: 0, braces: false)
            s.position = attributes.end
            if !attributes.closed { return .markupTag }
        default:
            break
        }
        while !s.atEnd {
            let start = s.position
            let u = s.current
            if u == Unit.less {
                if s.starts(with: commentOpen) {
                    s.position += commentOpen.count
                    if !until(&s, from: start, close: commentClose, kind: .comment) { return .markupComment }
                    continue
                }
                if s.starts(with: cdataOpen) {
                    s.position += cdataOpen.count
                    if !until(&s, from: start, close: cdataClose, kind: .string) { return .cdata }
                    continue
                }
                let next = s.at(start + 1)
                if next == Unit.bang {
                    var end = start
                    while end < s.end, s.units[end] != Unit.greater { end += 1 }
                    s.add(start, min(end + 1, s.end), .keyword)
                    s.position = min(end + 1, s.end)
                    continue
                }
                if next == Unit.question {
                    s.position += 2
                    _ = until(&s, from: start, close: processingClose, kind: .attribute)
                    continue
                }
                if Unit.isLetter(next) || next == Unit.slash || next >= 0x80 {
                    var end = start + 1
                    if s.at(end) == Unit.slash { end += 1 }
                    end = Shared.nameEnd(s, from: end)
                    s.add(start, end, .tag)
                    let attributes = Shared.attributes(&s, from: end, braces: false)
                    s.position = attributes.end
                    if !attributes.closed { return .markupTag }
                    continue
                }
            }
            if u == Unit.amp {
                var end = start + 1
                while end < s.end, end - start < 12, Unit.isIdentifier(s.units[end]) || s.units[end] == Unit.hash { end += 1 }
                if s.at(end) == Unit.semicolon, end > start + 1 {
                    s.add(start, end + 1, .escape)
                    s.position = end + 1
                    continue
                }
            }
            s.position += 1
        }
        return .normal
    }

    /// Colours from `from` as `kind` up to and including `close`; false when the line ends first.
    static func until(_ s: inout LineScanner, from: Int, close: [UInt16], kind: SyntaxKind) -> Bool {
        while !s.atEnd {
            if s.starts(with: close) {
                s.position += close.count
                s.add(from, s.position, kind)
                return true
            }
            s.position += 1
        }
        s.add(from, s.end, kind)
        return false
    }
}

/// Markdown: headings, emphasis, code, links, lists and task boxes, quotes, rules, HTML, fenced code in
/// its own language, and YAML front matter.
enum MarkdownLexer {
    /// How far ahead a closing mark is looked for: emphasis or a code span longer than this stays plain,
    /// which keeps a pathological line linear.
    private static let window = 1_000
    private static let commentOpen = Unit.of("<!--"), commentClose = Unit.of("-->")

    static func lex(_ s: inout LineScanner, mode: LexMode, atStart: Bool) -> LexMode {
        switch mode {
        case .fence(let marker, let length, let language, let inner, let innerDepth):
            if closesFence(s, marker: marker, length: length) {
                s.add(0, s.end, .punctuation)
                return .normal
            }
            var depth = innerDepth
            let end = SyntaxLexer.lex(language, &s, mode: inner, depth: &depth, atStart: false)
            return .fence(marker: marker, length: length, language: language, inner: end, innerDepth: depth)
        case .frontMatter(let inner):
            let text = s.text(0, s.end).trimmingCharacters(in: .whitespaces)
            if text == "---" || text == "..." {
                s.add(0, s.end, .punctuation)
                return .normal
            }
            return .frontMatter(inner: DataLexer.yaml(&s, mode: inner))
        case .markupComment:
            if !MarkupLexer.until(&s, from: 0, close: commentClose, kind: .comment) { return .markupComment }
            return inline(&s)
        default:
            break
        }
        let first = s.firstNonSpace()
        if atStart, first == 0, s.text(0, s.end).trimmingCharacters(in: .whitespaces) == "---" {
            s.add(0, s.end, .punctuation)
            return .frontMatter(inner: .normal)
        }
        if first <= 3, let fence = opensFence(&s, at: first) { return fence }
        var index = first
        while s.at(index) == Unit.greater {
            s.add(index, index + 1, .quote)
            index = s.firstNonSpace(from: index + 1)
        }
        if s.at(index) == Unit.hash {
            var hashes = 0
            while s.at(index + hashes) == Unit.hash { hashes += 1 }
            if hashes <= 6, index + hashes >= s.end || Unit.isSpace(s.at(index + hashes)) {
                s.add(index, s.end, .heading)
                return .normal
            }
        }
        if let rule = ruleKind(s, from: index) {
            s.add(index, s.end, rule)
            return .normal
        }
        let marker = s.at(index)
        if (marker == Unit.minus || marker == Unit.star || marker == Unit.plus), index + 1 >= s.end || Unit.isSpace(s.at(index + 1)) {
            s.add(index, index + 1, .listMarker)
            index = taskBox(&s, at: s.firstNonSpace(from: index + 1))
        } else if Unit.isDigit(marker) {
            var end = index
            while Unit.isDigit(s.at(end)), end - index < 9 { end += 1 }
            if s.at(end) == Unit.dot || s.at(end) == Unit.closeParen, end + 1 >= s.end || Unit.isSpace(s.at(end + 1)) {
                s.add(index, end + 1, .listMarker)
                index = taskBox(&s, at: s.firstNonSpace(from: end + 1))
            }
        }
        s.position = index
        return inline(&s)
    }

    /// `[ ]` or `[x]` after a list marker; gives where the item's text starts.
    private static func taskBox(_ s: inout LineScanner, at index: Int) -> Int {
        let mark = s.at(index + 1)
        guard s.at(index) == Unit.openBracket, s.at(index + 2) == Unit.closeBracket,
              mark == Unit.space || mark == Unit.letterX || mark == 88,
              index + 3 >= s.end || Unit.isSpace(s.at(index + 3)) else { return index }
        s.add(index, index + 3, .listMarker)
        return index + 3
    }

    /// `===` under a heading's text, or a rule (`---`, `***`, `___`, spaces allowed).
    private static func ruleKind(_ s: LineScanner, from: Int) -> SyntaxKind? {
        let mark = s.at(from)
        guard mark == Unit.equals || mark == Unit.minus || mark == Unit.star || mark == Unit.underscore else { return nil }
        var count = 0
        for index in from..<s.end {
            let u = s.units[index]
            if u == mark { count += 1 } else if !Unit.isSpace(u) { return nil }
            if mark == Unit.equals, Unit.isSpace(u) { return nil }
        }
        if mark == Unit.equals { return count >= 2 ? .heading : nil }
        return count >= 3 ? .punctuation : nil
    }

    // MARK: Fences

    /// ```` ```swift ```` or `~~~`: the fence as punctuation, the info string as an attribute, and the
    /// block's language for the lines that follow.
    private static func opensFence(_ s: inout LineScanner, at index: Int) -> LexMode? {
        let marker = s.at(index)
        guard marker == Unit.backtick || marker == Unit.tilde else { return nil }
        var length = 0
        while s.at(index + length) == marker { length += 1 }
        guard length >= 3 else { return nil }
        let infoStart = s.firstNonSpace(from: index + length)
        if marker == Unit.backtick, s.units[infoStart..<s.end].contains(Unit.backtick) { return nil }
        s.add(index, index + length, .punctuation)
        let info = s.text(infoStart, s.end).trimmingCharacters(in: .whitespaces)
        s.add(infoStart, s.end, .attribute)
        s.position = s.end
        return .fence(marker: marker, length: length, language: SyntaxLanguage.detect(fence: info), inner: .normal, innerDepth: 0)
    }

    /// A line closing a fence: up to three spaces, at least as many of the same mark, nothing after.
    private static func closesFence(_ s: LineScanner, marker: UInt16, length: Int) -> Bool {
        let first = s.firstNonSpace()
        guard first <= 3 else { return false }
        var count = 0
        while s.at(first + count) == marker { count += 1 }
        return count >= length && s.firstNonSpace(from: first + count) >= s.end
    }

    // MARK: Inline

    /// Emphasis, code spans, links, autolinks, HTML and escapes in the rest of the line.
    private static func inline(_ s: inout LineScanner) -> LexMode {
        while !s.atEnd {
            let start = s.position
            let u = s.current
            switch u {
            case Unit.backslash where isPunctuation(s.at(start + 1)):
                s.add(start, start + 2, .escape)
                s.position = start + 2
            case Unit.backtick:
                var run = 0
                while s.at(start + run) == Unit.backtick { run += 1 }
                if let close = findRun(s, of: Unit.backtick, length: run, from: start + run) {
                    s.add(start, close + run, .code)
                    s.position = close + run
                } else {
                    s.position = start + run
                }
            case Unit.star, Unit.underscore, Unit.tilde:
                s.position = emphasis(&s, at: start)
            case Unit.bang where s.at(start + 1) == Unit.openBracket:
                s.position = link(&s, at: start, text: start + 1)
            case Unit.openBracket:
                s.position = link(&s, at: start, text: start)
            case Unit.less:
                if s.starts(with: commentOpen) {
                    s.position += commentOpen.count
                    if !MarkupLexer.until(&s, from: start, close: commentClose, kind: .comment) { return .markupComment }
                } else if let end = autolink(s, at: start) {
                    s.add(start, end, .link)
                    s.position = end
                } else if Unit.isLetter(s.at(start + 1)) || s.at(start + 1) == Unit.slash {
                    s.position = Shared.tag(&s, from: start, braces: false)
                } else {
                    s.position += 1
                }
            case Unit.letterH where !Unit.isIdentifier(s.at(start - 1)) && (s.starts(with: http) || s.starts(with: https)):
                var end = start
                while end < s.end, !Unit.isSpace(s.units[end]), s.units[end] != Unit.closeParen, s.units[end] != Unit.greater { end += 1 }
                s.add(start, end, .link)
                s.position = end
            default:
                s.position += 1
            }
        }
        return .normal
    }

    private static let http = Unit.of("http://"), https = Unit.of("https://")

    /// `**strong**`, `__strong__`, `*em*`, `_em_`, `~~struck~~`: from the opening mark to the closing one,
    /// or just past the mark when nothing closes it. Gives where reading goes on.
    private static func emphasis(_ s: inout LineScanner, at start: Int) -> Int {
        let mark = s.units[start]
        var run = 0
        while s.at(start + run) == mark { run += 1 }
        let strong = run >= 2
        let width = strong ? 2 : 1
        if mark == Unit.tilde && !strong { return start + run }
        let after = s.at(start + width)
        // An opening mark is followed by text, and `_` inside a word (snake_case) is no mark.
        guard after != 0, !Unit.isSpace(after), !(mark == Unit.underscore && Unit.isIdentifier(s.at(start - 1))) else { return start + run }
        var index = start + width + 1
        let limit = min(s.end, start + window)
        while index < limit {
            if s.units[index] == mark, !Unit.isSpace(s.units[index - 1]) {
                var count = 0
                while s.at(index + count) == mark { count += 1 }
                let fits = strong ? count >= 2 : count == 1
                if fits, !(mark == Unit.underscore && Unit.isIdentifier(s.at(index + width))) {
                    s.add(start, index + width, mark == Unit.tilde ? .emphasis : strong ? .strong : .emphasis)
                    return index + width
                }
                index += count
                continue
            }
            index += 1
        }
        return start + run
    }

    /// `[text](url)`, `![alt](src)`, `[text][ref]`, and `[ref]: url` definitions.
    private static func link(_ s: inout LineScanner, at start: Int, text: Int) -> Int {
        var close = text + 1
        var depth = 0
        let limit = min(s.end, start + window)
        while close < limit {
            let u = s.units[close]
            if u == Unit.backslash { close += 2; continue }
            if u == Unit.openBracket { depth += 1 }
            if u == Unit.closeBracket {
                if depth == 0 { break }
                depth -= 1
            }
            close += 1
        }
        guard close < limit else { return start + 1 }
        let after = s.at(close + 1)
        if after == Unit.openParen {
            var end = close + 2, parens = 0
            while end < s.end {
                let u = s.units[end]
                if u == Unit.openParen { parens += 1 }
                if u == Unit.closeParen {
                    if parens == 0 { break }
                    parens -= 1
                }
                end += 1
            }
            guard end < s.end else { return start + 1 }
            s.add(start, close + 1, .link)
            s.add(close + 1, end + 1, .string)
            return end + 1
        }
        if after == Unit.openBracket {
            var end = close + 2
            while end < s.end, s.units[end] != Unit.closeBracket { end += 1 }
            guard end < s.end else { return start + 1 }
            s.add(start, end + 1, .link)
            return end + 1
        }
        if after == Unit.colon, s.firstNonSpace() == start {
            s.add(start, close + 2, .link)
            s.add(s.firstNonSpace(from: close + 2), s.end, .string)
            return s.end
        }
        return start + 1
    }

    /// `<https://…>` or `<mailto:…>`: where it ends.
    private static func autolink(_ s: LineScanner, at start: Int) -> Int? {
        guard s.starts(with: http, at: start + 1) || s.starts(with: https, at: start + 1) || s.starts(with: Unit.of("mailto:"), at: start + 1) else { return nil }
        var end = start + 1
        while end < s.end, s.units[end] != Unit.greater, !Unit.isSpace(s.units[end]) { end += 1 }
        return s.at(end) == Unit.greater ? end + 1 : nil
    }

    /// Finds the next run of exactly `length` `mark`s from `from`.
    private static func findRun(_ s: LineScanner, of mark: UInt16, length: Int, from: Int) -> Int? {
        var index = from
        let limit = min(s.end, from + window)
        while index < limit {
            if s.units[index] == mark {
                var count = 0
                while s.at(index + count) == mark { count += 1 }
                if count == length { return index }
                index += count
                continue
            }
            index += 1
        }
        return nil
    }

    private static func isPunctuation(_ u: UInt16) -> Bool {
        (u >= 33 && u <= 47) || (u >= 58 && u <= 64) || (u >= 91 && u <= 96) || (u >= 123 && u <= 126)
    }
}
