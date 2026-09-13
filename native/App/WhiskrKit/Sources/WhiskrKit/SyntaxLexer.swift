import Foundation

// The editor's syntax colours come from a small line lexer of our own (docs/DESIGN.md, "Files, editor
// and changes"): each line is read once, left to right, starting from what the line before left open (a
// block comment, a multi-line string, a fenced code block …), and gives back its coloured stretches and
// what it leaves open in turn. Keeping each line's end state makes an edit cheap: lines are lexed again
// from the edited one until the state matches the old one.

/// What a stretch of text is, for colouring.
public enum SyntaxKind: UInt8, Sendable, CaseIterable {
    case plain, keyword, type, function, string, number, constant, comment, attribute, property, tag, variable, escape, heading, emphasis, strong, code, link, quote, listMarker, punctuation
}

/// A coloured stretch of one line.
public struct SyntaxToken: Equatable, Sendable {
    /// UTF-16 offsets within the line (so the app can use them as NSRange directly).
    public var range: Range<Int>
    public var kind: SyntaxKind

    public init(range: Range<Int>, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// What a line leaves open for the next one (a block comment, a multi-line string, a fenced code block
/// with its inner language's own state, …). `.initial` at the top of a file. Equality is what makes
/// incremental re-lexing stop, so it holds only what the next line needs.
public struct LexerState: Hashable, Sendable {
    var mode: LexMode
    /// How deep in braces CSS is (selectors outside, declarations inside).
    var depth: Int
    /// Nothing has been read yet: only the first line can open Markdown's front matter.
    var atStart: Bool

    public static let initial = LexerState(mode: .normal, depth: 0, atStart: true)
}

/// A multi-line string: what closes it and what happens inside.
struct StringMode: Hashable, Sendable {
    enum Interpolation: UInt8, Hashable, Sendable {
        /// None.
        case none
        /// Swift's `\(…)`.
        case swift
        /// JavaScript's and Kotlin's `${…}`.
        case dollarBrace
        /// Python's f-strings, `{…}`.
        case brace
        /// Ruby's `#{…}`.
        case hashBrace
        /// Shell and PHP: `$name`, `${…}`, `$(…)`.
        case shell
    }

    var close: [UInt16]
    var escapes: Bool
    var interpolation: Interpolation
}

indirect enum LexMode: Hashable, Sendable {
    case normal
    /// A block comment, nested `depth` deep beyond the first.
    case blockComment(depth: Int)
    /// `<!-- … -->`.
    case markupComment
    /// `<![CDATA[ … ]]>`.
    case cdata
    /// Inside a tag whose `>` is on a later line (attributes one per line).
    case markupTag
    case string(StringMode)
    /// A C preprocessor line ending in `\`.
    case preprocessor
    /// Ruby's `=begin` … `=end`.
    case rubyDoc
    /// A shell here-document, until a line holding only `delimiter`.
    case heredoc(delimiter: String, indented: Bool)
    /// A Dockerfile instruction continued with `\`.
    case continued
    /// A fenced code block in Markdown, lexed in its own language.
    case fence(marker: UInt16, length: Int, language: SyntaxLanguage, inner: LexMode, innerDepth: Int)
    /// Markdown's YAML front matter.
    case frontMatter(inner: LexMode)
}

/// Lexes lines of one language.
public struct SyntaxLexer: Sendable {
    public let language: SyntaxLanguage

    /// Past this many UTF-16 units a line (minified code, a data blob) is left plain.
    static let lineLimit = 10_000

    public init(language: SyntaxLanguage) {
        self.language = language
    }

    /// One line, without its line break. Tokens are sorted, do not overlap, and leave out plain text.
    public func tokenize(_ line: String, from state: LexerState) -> (tokens: [SyntaxToken], end: LexerState) {
        guard language != .plain else { return ([], LexerState(mode: .normal, depth: 0, atStart: false)) }
        var scanner = LineScanner(Array(line.utf16))
        var depth = state.depth
        let mode = Self.lex(language, &scanner, mode: state.mode, depth: &depth, atStart: state.atStart)
        return (scanner.tokens, LexerState(mode: mode, depth: depth, atStart: false))
    }

    /// Lexes what is left of `scanner`'s line in `language`, from `mode`; gives the mode the line ends in.
    static func lex(_ language: SyntaxLanguage, _ scanner: inout LineScanner, mode: LexMode, depth: inout Int, atStart: Bool) -> LexMode {
        switch language {
        case .plain: return .normal
        case .html, .xml: return MarkupLexer.lex(&scanner, mode: mode)
        case .markdown: return MarkdownLexer.lex(&scanner, mode: mode, atStart: atStart)
        case .shell: return ShellLexer.lex(&scanner, mode: mode, dockerfile: false)
        case .dockerfile: return ShellLexer.lex(&scanner, mode: mode, dockerfile: true)
        case .json: return DataLexer.json(&scanner, mode: mode)
        case .yaml: return DataLexer.yaml(&scanner, mode: mode)
        case .toml: return DataLexer.toml(&scanner, mode: mode)
        case .css: return DataLexer.css(&scanner, mode: mode, depth: &depth)
        default:
            let lexer = CodeLexer(spec: CodeSpec.of(language))
            return lexer.lex(&scanner, mode: mode)
        }
    }
}

/// One line as UTF-16 code units, read left to right, collecting tokens.
struct LineScanner {
    let units: [UInt16]
    /// Where reading stops: the line's end, or `SyntaxLexer.lineLimit`.
    let end: Int
    var position = 0
    private(set) var tokens: [SyntaxToken] = []

    init(_ units: [UInt16]) {
        self.units = units
        end = min(units.count, SyntaxLexer.lineLimit)
    }

    var atEnd: Bool { position >= end }

    /// The unit at `index`, or 0 past the end.
    @inline(__always) func at(_ index: Int) -> UInt16 {
        index >= 0 && index < end ? units[index] : 0
    }

    @inline(__always) var current: UInt16 { at(position) }

    func starts(with text: [UInt16], at index: Int) -> Bool {
        guard index >= 0, index + text.count <= end else { return false }
        for offset in 0..<text.count where units[index + offset] != text[offset] { return false }
        return true
    }

    func starts(with text: [UInt16]) -> Bool { starts(with: text, at: position) }

    /// Units `from` up to `to` as a String (once per word, never per character).
    func text(_ from: Int, _ to: Int) -> String {
        String(decoding: units[max(0, from)..<min(to, end)], as: UTF16.self)
    }

    /// Adds a token; plain and empty ones are left out, and one overlapping the last is trimmed.
    mutating func add(_ from: Int, _ to: Int, _ kind: SyntaxKind) {
        guard kind != .plain else { return }
        let start = max(from, tokens.last?.range.upperBound ?? 0)
        let stop = min(to, end)
        guard stop > start else { return }
        if let last = tokens.last, last.kind == kind, last.range.upperBound == start {
            tokens[tokens.count - 1].range = last.range.lowerBound..<stop
        } else {
            tokens.append(SyntaxToken(range: start..<stop, kind: kind))
        }
    }

    /// Skips spaces and tabs.
    mutating func skipSpace() {
        while position < end, Unit.isSpace(units[position]) { position += 1 }
    }

    /// The index of the first unit at or after `index` that is not a space or tab.
    func firstNonSpace(from index: Int = 0) -> Int {
        var index = index
        while index < end, Unit.isSpace(units[index]) { index += 1 }
        return index
    }

    /// The index of the last unit that is not a space or tab, or -1.
    var lastNonSpace: Int {
        var index = end - 1
        while index >= 0, Unit.isSpace(units[index]) { index -= 1 }
        return index
    }

    /// Reads an identifier at `position` and gives where it ends.
    func identifierEnd(from index: Int, extra: UInt16 = 0) -> Int {
        var index = index
        while index < end, Unit.isIdentifier(units[index]) || (extra != 0 && units[index] == extra) { index += 1 }
        return index
    }
}

/// UTF-16 units by name, and the classes the lexers need.
enum Unit {
    static let tab: UInt16 = 9, space: UInt16 = 32, bang: UInt16 = 33, quote: UInt16 = 34, hash: UInt16 = 35, dollar: UInt16 = 36
    static let percent: UInt16 = 37, amp: UInt16 = 38, apostrophe: UInt16 = 39, openParen: UInt16 = 40, closeParen: UInt16 = 41
    static let star: UInt16 = 42, plus: UInt16 = 43, comma: UInt16 = 44, minus: UInt16 = 45, dot: UInt16 = 46, slash: UInt16 = 47
    static let zero: UInt16 = 48, nine: UInt16 = 57, colon: UInt16 = 58, semicolon: UInt16 = 59, less: UInt16 = 60, equals: UInt16 = 61
    static let greater: UInt16 = 62, question: UInt16 = 63, at: UInt16 = 64, openBracket: UInt16 = 91, backslash: UInt16 = 92
    static let closeBracket: UInt16 = 93, caret: UInt16 = 94, underscore: UInt16 = 95, backtick: UInt16 = 96, openBrace: UInt16 = 123
    static let pipe: UInt16 = 124, closeBrace: UInt16 = 125, tilde: UInt16 = 126
    static let letterB: UInt16 = 98, letterE: UInt16 = 101, letterF: UInt16 = 102, letterO: UInt16 = 111, letterR: UInt16 = 114
    static let letterH: UInt16 = 104, letterU: UInt16 = 117, letterX: UInt16 = 120

    @inline(__always) static func isSpace(_ u: UInt16) -> Bool { u == space || u == tab }
    @inline(__always) static func isDigit(_ u: UInt16) -> Bool { u >= zero && u <= nine }
    @inline(__always) static func isUpper(_ u: UInt16) -> Bool { u >= 65 && u <= 90 }
    @inline(__always) static func isLower(_ u: UInt16) -> Bool { u >= 97 && u <= 122 }
    @inline(__always) static func isLetter(_ u: UInt16) -> Bool { isUpper(u) || isLower(u) }
    @inline(__always) static func isHex(_ u: UInt16) -> Bool { isDigit(u) || (u >= 65 && u <= 70) || (u >= 97 && u <= 102) }
    /// Letters, digits, `_`, and anything beyond ASCII (names in other scripts, and never a split surrogate pair).
    @inline(__always) static func isIdentifier(_ u: UInt16) -> Bool { isLetter(u) || isDigit(u) || u == underscore || u >= 0x80 }
    @inline(__always) static func isIdentifierStart(_ u: UInt16) -> Bool { isLetter(u) || u == underscore || u >= 0x80 }

    static func of(_ text: String) -> [UInt16] { Array(text.utf16) }
}
