import Foundation

// The data and configuration languages (JSON, YAML, TOML, CSS) and the shell (with Dockerfiles, whose
// instructions run shell).

/// JSON, YAML, TOML and CSS.
enum DataLexer {
    private static let slashStar = Unit.of("/*"), starSlash = Unit.of("*/")
    private static let tripleDouble = Unit.of("\"\"\""), tripleSingle = Unit.of("'''")

    // MARK: JSON

    /// Keys (a string before `:`), strings, numbers, `true`/`false`/`null`, and JSONC's comments.
    static func json(_ s: inout LineScanner, mode: LexMode) -> LexMode {
        if case .blockComment(let depth) = mode,
           let still = Shared.blockComment(&s, from: 0, depth: depth, open: slashStar, close: starSlash, nests: false) { return still }
        while !s.atEnd {
            let start = s.position
            let u = s.current
            if u == Unit.slash, s.at(start + 1) == Unit.slash {
                s.add(start, s.end, .comment)
                return .normal
            }
            if s.starts(with: slashStar) {
                s.position += 2
                if let still = Shared.blockComment(&s, from: start, depth: 0, open: slashStar, close: starSlash, nests: false) { return still }
                continue
            }
            if u == Unit.quote || u == Unit.apostrophe {
                let end = quotedEnd(s, from: start, quote: u, escapes: true)
                let isKey = s.at(s.firstNonSpace(from: end)) == Unit.colon
                emitString(&s, start, end, kind: isKey ? .property : .string, escapes: true)
                s.position = end
                continue
            }
            if Unit.isDigit(u) || (u == Unit.minus && Unit.isDigit(s.at(start + 1))) {
                s.position = Shared.number(s, from: u == Unit.minus ? start + 1 : start)
                s.add(start, s.position, .number)
                continue
            }
            if Unit.isLetter(u) {
                let end = s.identifierEnd(from: start)
                let word = s.text(start, end)
                s.add(start, end, ["true", "false", "null"].contains(word) ? .constant : .plain)
                s.position = end
                continue
            }
            s.position += 1
        }
        return .normal
    }

    // MARK: YAML

    /// Keys, list dashes, comments, quoted strings, anchors and tags, and plain values that are numbers or
    /// constants.
    static func yaml(_ s: inout LineScanner, mode: LexMode) -> LexMode {
        var index = s.firstNonSpace()
        if index == 0, s.starts(with: Unit.of("---")) || s.starts(with: Unit.of("...")), s.at(3) == 0 || Unit.isSpace(s.at(3)) {
            s.add(0, 3, .punctuation)
            index = s.firstNonSpace(from: 3)
        }
        while s.at(index) == Unit.minus, index + 1 >= s.end || Unit.isSpace(s.at(index + 1)) {
            s.add(index, index + 1, .listMarker)
            index = s.firstNonSpace(from: index + 1)
        }
        if s.at(index) == Unit.hash {
            s.add(index, s.end, .comment)
            return .normal
        }
        if let colon = yamlKey(s, from: index) {
            var keyEnd = colon
            while keyEnd > index, Unit.isSpace(s.units[keyEnd - 1]) { keyEnd -= 1 }
            s.add(index, keyEnd, .property)
            index = colon + 1
        }
        s.position = index
        yamlValue(&s)
        return .normal
    }

    /// Where the `:` ending a key that starts at `from` is, if one does.
    private static func yamlKey(_ s: LineScanner, from: Int) -> Int? {
        var index = from
        let first = s.at(from)
        if first == Unit.quote || first == Unit.apostrophe {
            index = quotedEnd(s, from: from, quote: first, escapes: first == Unit.quote)
            index = s.firstNonSpace(from: index)
            return s.at(index) == Unit.colon && (index + 1 >= s.end || Unit.isSpace(s.at(index + 1))) ? index : nil
        }
        guard index < s.end, ![Unit.openBracket, Unit.openBrace, Unit.amp, Unit.star, Unit.bang, Unit.pipe, Unit.greater, Unit.percent, Unit.at, Unit.backtick].contains(first) else { return nil }
        while index < s.end {
            let u = s.units[index]
            if u == Unit.colon, index + 1 >= s.end || Unit.isSpace(s.at(index + 1)) { return index }
            if u == Unit.hash, index > from, Unit.isSpace(s.at(index - 1)) { return nil }
            index += 1
        }
        return nil
    }

    /// A value: in a block, the whole scalar; inside `[…]` or `{…}`, word by word.
    private static func yamlValue(_ s: inout LineScanner) {
        var flow = 0
        while !s.atEnd {
            let start = s.position
            let u = s.current
            if Unit.isSpace(u) {
                s.position += 1
                continue
            }
            if u == Unit.hash, start == 0 || Unit.isSpace(s.at(start - 1)) {
                s.add(start, s.end, .comment)
                return
            }
            if u == Unit.quote || u == Unit.apostrophe {
                let end = quotedEnd(s, from: start, quote: u, escapes: u == Unit.quote)
                let isKey = flow > 0 && s.at(s.firstNonSpace(from: end)) == Unit.colon
                emitString(&s, start, end, kind: isKey ? .property : .string, escapes: u == Unit.quote)
                s.position = end
                continue
            }
            if u == Unit.amp || u == Unit.star || u == Unit.bang {
                var end = start + 1
                while end < s.end, !Unit.isSpace(s.units[end]), ![Unit.comma, Unit.closeBracket, Unit.closeBrace].contains(s.units[end]) { end += 1 }
                s.add(start, end, .attribute)
                s.position = end
                continue
            }
            if flow == 0, u == Unit.pipe || u == Unit.greater {
                s.add(start, start + 1, .punctuation)
                s.position += 1
                continue
            }
            if u == Unit.openBracket || u == Unit.openBrace {
                flow += 1
                s.position += 1
                continue
            }
            if u == Unit.closeBracket || u == Unit.closeBrace || u == Unit.comma {
                flow = max(0, flow - (u == Unit.comma ? 0 : 1))
                s.position += 1
                continue
            }
            // A scalar: to the comment (or, in a flow, the next separator).
            var end = start
            while end < s.end {
                let c = s.units[end]
                if c == Unit.hash, end > start, Unit.isSpace(s.units[end - 1]) { break }
                if flow > 0, [Unit.comma, Unit.closeBracket, Unit.closeBrace].contains(c) { break }
                if flow > 0, c == Unit.colon, end + 1 >= s.end || Unit.isSpace(s.at(end + 1)) { break }
                end += 1
            }
            var trimmed = end
            while trimmed > start, Unit.isSpace(s.units[trimmed - 1]) { trimmed -= 1 }
            let isKey = flow > 0 && s.at(end) == Unit.colon
            s.add(start, trimmed, isKey ? .property : scalarKind(s.text(start, trimmed)))
            s.position = max(end, start + 1)
        }
    }

    /// `true`, `null`, `~`, `yes` are constants; `42`, `-1.5e3`, `0x1F` numbers; the rest plain.
    private static func scalarKind(_ text: String) -> SyntaxKind {
        switch text.lowercased() {
        case "true", "false", "null", "~", "yes", "no", "on", "off": return .constant
        case ".inf", "-.inf", ".nan": return .number
        default: break
        }
        var units = Array(text.utf16)
        if units.first == Unit.minus || units.first == Unit.plus { units.removeFirst() }
        guard let first = units.first, Unit.isDigit(first) else { return .plain }
        let scanner = LineScanner(units)
        return Shared.number(scanner, from: 0) == units.count ? .number : .plain
    }

    // MARK: TOML

    /// Tables, keys, strings (also over many lines), numbers and dates, and booleans.
    static func toml(_ s: inout LineScanner, mode: LexMode) -> LexMode {
        let strings = CodeLexer(spec: CodeSpec())
        if case .string(let open) = mode, let still = strings.string(&s, from: 0, open, multiline: true) { return still }
        var expectsKey = s.position == 0
        var braces = 0
        let first = s.firstNonSpace(from: s.position)
        if s.position == 0, s.at(first) == Unit.openBracket {
            var end = first
            while end < s.end, s.units[end] != Unit.closeBracket { end += 1 }
            if s.at(end + 1) == Unit.closeBracket { end += 1 }
            s.add(first, min(end + 1, s.end), .type)
            s.position = min(end + 1, s.end)
            expectsKey = false
        }
        while !s.atEnd {
            let start = s.position
            let u = s.current
            if Unit.isSpace(u) {
                s.position += 1
                continue
            }
            if u == Unit.hash {
                s.add(start, s.end, .comment)
                return .normal
            }
            if u == Unit.quote || u == Unit.apostrophe {
                let triple = u == Unit.quote ? tripleDouble : tripleSingle
                if s.starts(with: triple) {
                    s.position = start + 3
                    if let still = strings.string(&s, from: start, StringMode(close: triple, escapes: u == Unit.quote, interpolation: .none), multiline: true) { return still }
                    continue
                }
                let end = quotedEnd(s, from: start, quote: u, escapes: u == Unit.quote)
                emitString(&s, start, end, kind: expectsKey ? .property : .string, escapes: u == Unit.quote)
                s.position = end
                continue
            }
            switch u {
            case Unit.equals: expectsKey = false
            case Unit.openBrace:
                braces += 1
                expectsKey = true
            case Unit.closeBrace: braces = max(0, braces - 1)
            case Unit.comma: expectsKey = braces > 0
            default: break
            }
            if expectsKey, Unit.isIdentifier(u) || u == Unit.minus {
                var end = start
                while end < s.end, Unit.isIdentifier(s.units[end]) || s.units[end] == Unit.minus || s.units[end] == Unit.dot { end += 1 }
                s.add(start, end, .property)
                s.position = end
                continue
            }
            if Unit.isDigit(u) || ((u == Unit.plus || u == Unit.minus) && Unit.isDigit(s.at(start + 1))) {
                var end = start + 1
                while end < s.end {
                    let c = s.units[end]
                    guard Unit.isIdentifier(c) || [Unit.dot, Unit.colon, Unit.plus, Unit.minus].contains(c) else { break }
                    end += 1
                }
                s.add(start, end, .number)
                s.position = end
                continue
            }
            if Unit.isLetter(u) {
                let end = s.identifierEnd(from: start)
                let word = s.text(start, end)
                s.add(start, end, word == "true" || word == "false" ? .constant : ["inf", "nan"].contains(word) ? .number : .plain)
                s.position = end
                continue
            }
            s.position += 1
        }
        return .normal
    }

    // MARK: CSS

    /// Selectors outside braces, properties and values inside (the brace depth is carried to the next
    /// line), at-rules, comments, strings, numbers with units and colours.
    static func css(_ s: inout LineScanner, mode: LexMode, depth: inout Int) -> LexMode {
        if case .blockComment(let open) = mode,
           let still = Shared.blockComment(&s, from: 0, depth: open, open: slashStar, close: starSlash, nests: false) { return still }
        var statementStart = true
        var inValue = false
        // Inside `@media (…)` or `:not(…)`: `name: value` there is a feature, not a selector.
        var parens = 0
        while !s.atEnd {
            let start = s.position
            let u = s.current
            if Unit.isSpace(u) {
                s.position += 1
                continue
            }
            if s.starts(with: slashStar) {
                s.position += 2
                if let still = Shared.blockComment(&s, from: start, depth: 0, open: slashStar, close: starSlash, nests: false) { return still }
                continue
            }
            if u == Unit.slash, s.at(start + 1) == Unit.slash, start == 0 || Unit.isSpace(s.at(start - 1)) {
                s.add(start, s.end, .comment)
                return .normal
            }
            if u == Unit.quote || u == Unit.apostrophe {
                let end = quotedEnd(s, from: start, quote: u, escapes: true)
                emitString(&s, start, end, kind: .string, escapes: true)
                s.position = end
                continue
            }
            switch u {
            case Unit.openBrace:
                depth += 1
                statementStart = true
                inValue = false
                s.position += 1
                continue
            case Unit.closeBrace:
                depth = max(0, depth - 1)
                statementStart = true
                inValue = false
                s.position += 1
                continue
            case Unit.openParen, Unit.closeParen:
                parens = max(0, parens + (u == Unit.openParen ? 1 : -1))
                s.position += 1
                continue
            case Unit.semicolon:
                statementStart = true
                inValue = false
                s.position += 1
                continue
            default:
                break
            }
            if u == Unit.at, Unit.isIdentifierStart(s.at(start + 1)) {
                let end = cssNameEnd(s, from: start + 1)
                s.add(start, end, .keyword)
                s.position = end
                statementStart = false
                continue
            }
            if u == Unit.bang, Unit.isLetter(s.at(start + 1)) {
                let end = s.identifierEnd(from: start + 1)
                s.add(start, end, .keyword)
                s.position = end
                continue
            }
            if u == Unit.hash {
                let end = cssNameEnd(s, from: start + 1)
                s.add(start, end, inValue ? .number : .type)
                s.position = max(end, start + 1)
                continue
            }
            if Unit.isDigit(u) || ((u == Unit.dot || u == Unit.minus) && Unit.isDigit(s.at(start + 1))) {
                var end = start + 1
                while end < s.end, Unit.isDigit(s.units[end]) || s.units[end] == Unit.dot { end += 1 }
                while end < s.end, Unit.isLetter(s.units[end]) || s.units[end] == Unit.percent { end += 1 }
                s.add(start, end, .number)
                s.position = end
                continue
            }
            if !inValue, u == Unit.dot, Unit.isIdentifierStart(s.at(start + 1)) || s.at(start + 1) == Unit.minus {
                let end = cssNameEnd(s, from: start + 1)
                s.add(start, end, .type)
                s.position = end
                statementStart = false
                continue
            }
            if !inValue, parens == 0, u == Unit.colon {
                // A pseudo-class or -element: `:hover`, `::before`.
                var end = start + 1
                if s.at(end) == Unit.colon { end += 1 }
                end = cssNameEnd(s, from: end)
                s.add(start, end, .attribute)
                s.position = max(end, start + 1)
                continue
            }
            if inValue || parens > 0, u == Unit.colon {
                s.position += 1
                continue
            }
            if Unit.isIdentifierStart(u) || (u == Unit.minus && (Unit.isIdentifierStart(s.at(start + 1)) || s.at(start + 1) == Unit.minus)) {
                let end = cssNameEnd(s, from: start)
                if inValue || parens > 0 {
                    let property = parens > 0 && s.at(s.firstNonSpace(from: end)) == Unit.colon
                    s.add(start, end, s.at(end) == Unit.openParen ? .function : property ? .property : .plain)
                } else if depth > 0, statementStart, s.at(s.firstNonSpace(from: end)) == Unit.colon, !restHasBrace(s, from: end) {
                    s.add(start, end, .property)
                    s.position = s.firstNonSpace(from: end) + 1
                    inValue = true
                    statementStart = false
                    continue
                } else {
                    s.add(start, end, .tag)
                    statementStart = false
                }
                s.position = end
                continue
            }
            s.position += 1
        }
        return .normal
    }

    private static func cssNameEnd(_ s: LineScanner, from: Int) -> Int {
        var index = from
        while index < s.end, Unit.isIdentifier(s.units[index]) || s.units[index] == Unit.minus { index += 1 }
        return index
    }

    /// A `{` later on the line: `a:hover {` is a selector, not a property.
    private static func restHasBrace(_ s: LineScanner, from: Int) -> Bool {
        var index = from
        while index < s.end {
            if s.units[index] == Unit.openBrace { return true }
            if s.units[index] == Unit.semicolon { return false }
            index += 1
        }
        return false
    }

    // MARK: Strings

    /// Where a one-line string opened at `from` ends (after its closing quote, or the line's end).
    static func quotedEnd(_ s: LineScanner, from: Int, quote: UInt16, escapes: Bool) -> Int {
        var index = from + 1
        while index < s.end {
            let u = s.units[index]
            if escapes, u == Unit.backslash {
                index += 2
                continue
            }
            if u == quote { return index + 1 }
            index += 1
        }
        return s.end
    }

    /// A string from `from` to `to` as `kind`, its escapes (`\n`, `\"`) picked out.
    static func emitString(_ s: inout LineScanner, _ from: Int, _ to: Int, kind: SyntaxKind, escapes: Bool) {
        guard escapes else { return s.add(from, to, kind) }
        var segment = from
        var index = from + 1
        while index < to - 1 {
            if s.units[index] == Unit.backslash {
                s.add(segment, index, kind)
                s.add(index, min(index + 2, to), .escape)
                index += 2
                segment = index
                continue
            }
            index += 1
        }
        s.add(segment, to, kind)
    }
}

/// The shell, and Dockerfiles (an instruction, then shell).
enum ShellLexer {
    static let keywords: Set<String> = Set("if then else elif fi for while until do done case esac function in return local export readonly declare typeset unset shift break continue exit select time source alias eval exec trap set".split(separator: " ").map(String.init))
    static let instructions: Set<String> = Set("FROM RUN COPY ADD CMD ENTRYPOINT ENV ARG WORKDIR EXPOSE LABEL USER VOLUME HEALTHCHECK SHELL ONBUILD STOPSIGNAL MAINTAINER".split(separator: " ").map(String.init))

    /// Characters that end a word.
    private static let breaks: Set<UInt16> = [Unit.space, Unit.tab, Unit.semicolon, Unit.pipe, Unit.amp, Unit.openParen, Unit.closeParen, Unit.less, Unit.greater, Unit.quote, Unit.apostrophe, Unit.dollar, Unit.backtick]

    static func lex(_ s: inout LineScanner, mode: LexMode, dockerfile: Bool) -> LexMode {
        var expectsInstruction = dockerfile
        switch mode {
        case .string(let open):
            if let still = string(&s, from: 0, open) { return still }
            expectsInstruction = false
        case .heredoc(let delimiter, let indented):
            var start = 0
            if indented { while s.at(start) == Unit.tab { start += 1 } }
            if s.text(start, s.end) == delimiter {
                s.add(start, s.end, .string)
                return .normal
            }
            s.add(0, s.end, .string)
            return mode
        case .continued:
            expectsInstruction = false
        default:
            break
        }
        var isFrom = false
        if expectsInstruction {
            let first = s.firstNonSpace()
            if s.at(first) == Unit.hash {
                s.add(first, s.end, .comment)
                return .normal
            }
            let end = s.identifierEnd(from: first)
            if instructions.contains(s.text(first, end).uppercased()) {
                s.add(first, end, .keyword)
                isFrom = s.text(first, end).uppercased() == "FROM"
                s.position = end
            }
        }
        var heredoc: LexMode?
        while !s.atEnd {
            let start = s.position
            let u = s.current
            if Unit.isSpace(u) {
                s.position += 1
                continue
            }
            if u == Unit.hash, start == 0 || breaks.contains(s.at(start - 1)) && s.at(start - 1) != Unit.dollar {
                s.add(start, s.end, .comment)
                s.position = s.end
                break
            }
            if u == Unit.apostrophe {
                s.position += 1
                if let still = string(&s, from: start, StringMode(close: [Unit.apostrophe], escapes: false, interpolation: .none)) { return still }
                continue
            }
            if u == Unit.quote {
                s.position += 1
                if let still = string(&s, from: start, StringMode(close: [Unit.quote], escapes: true, interpolation: .shell)) { return still }
                continue
            }
            if u == Unit.dollar {
                variable(&s)
                continue
            }
            if u == Unit.less, s.at(start + 1) == Unit.less, s.at(start + 2) != Unit.less {
                var index = start + 2
                let indented = s.at(index) == Unit.minus
                if indented { index += 1 }
                index = s.firstNonSpace(from: index)
                let quote = s.at(index) == Unit.quote || s.at(index) == Unit.apostrophe
                if quote { index += 1 }
                let end = s.identifierEnd(from: index)
                if end > index {
                    heredoc = .heredoc(delimiter: s.text(index, end), indented: indented)
                    let close = quote ? end + 1 : end
                    s.add(start, close, .string)
                    s.position = close
                    continue
                }
            }
            if Unit.isIdentifierStart(u) {
                let end = s.identifierEnd(from: start)
                let word = s.text(start, end)
                if s.at(end) == Unit.equals, start == 0 || breaks.contains(s.at(start - 1)) {
                    s.add(start, end, .variable)
                } else if s.at(end) == Unit.openParen, s.at(end + 1) == Unit.closeParen {
                    s.add(start, end, .function)
                } else if (start == 0 || breaks.contains(s.at(start - 1))) && (end >= s.end || breaks.contains(s.at(end))) {
                    if keywords.contains(word) || (isFrom && word.uppercased() == "AS") { s.add(start, end, .keyword) }
                }
                s.position = wordEnd(s, from: end)
                continue
            }
            s.position = wordEnd(s, from: start + 1)
        }
        if let heredoc { return heredoc }
        let last = s.lastNonSpace
        if dockerfile, last >= 0, s.units[last] == Unit.backslash { return .continued }
        return .normal
    }

    /// The rest of a word (`file.txt`, `--flag`), so a `#` inside one is no comment.
    private static func wordEnd(_ s: LineScanner, from: Int) -> Int {
        var index = from
        while index < s.end, !breaks.contains(s.units[index]) {
            if s.units[index] == Unit.backslash { index += 1 }
            index += 1
        }
        return min(max(index, from), s.end)
    }

    /// `$name`, `${…}`, `$(`, `$1`, `$?`.
    private static func variable(_ s: inout LineScanner) {
        let start = s.position
        let next = s.at(start + 1)
        var end = start + 1
        if next == Unit.openBrace {
            while end < s.end, s.units[end] != Unit.closeBrace { end += 1 }
            end = min(end + 1, s.end)
        } else if next == Unit.openParen {
            end = start + 2
        } else if Unit.isIdentifierStart(next) {
            end = s.identifierEnd(from: start + 1)
        } else if Unit.isDigit(next) || [Unit.at, Unit.star, Unit.hash, Unit.question, Unit.dollar, Unit.bang, Unit.minus].contains(next) {
            end = start + 2
        }
        if end > start + 1 { s.add(start, end, .variable) }
        s.position = end
    }

    /// A quoted string's body: nil once it closes, else the string itself (shell strings run over lines).
    private static func string(_ s: inout LineScanner, from: Int, _ mode: StringMode) -> LexMode? {
        var segment = from
        while !s.atEnd {
            let at = s.position
            let u = s.units[at]
            if s.starts(with: mode.close) {
                s.position = at + mode.close.count
                s.add(segment, s.position, .string)
                return nil
            }
            if mode.escapes, u == Unit.backslash {
                s.add(segment, at, .string)
                s.add(at, at + 2, .escape)
                s.position = min(at + 2, s.end)
                segment = s.position
                continue
            }
            if mode.interpolation == .shell, u == Unit.dollar {
                s.add(segment, at, .string)
                if s.at(at + 1) == Unit.openParen {
                    // `$(command)` inside quotes, coloured as one variable when it closes on this line.
                    var end = at + 2, depth = 1
                    while end < s.end, depth > 0 {
                        if s.units[end] == Unit.openParen { depth += 1 }
                        if s.units[end] == Unit.closeParen { depth -= 1 }
                        end += 1
                    }
                    s.add(at, end, .variable)
                    s.position = end
                } else {
                    variable(&s)
                    if s.position == at { s.position += 1 }
                }
                segment = s.position
                continue
            }
            s.position += 1
        }
        s.add(segment, s.end, .string)
        return .string(mode)
    }
}
