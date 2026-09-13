import Foundation

// The programming languages: one lexer for the C family and its relatives (Swift, TypeScript, JavaScript,
// Python, Rust, Go, C, C++, Java, Kotlin, Ruby, PHP, SQL), told apart by a `CodeSpec` of each one's words
// and quirks.

/// What sets one programming language apart for colouring.
struct CodeSpec: Sendable {
    enum SingleQuote: Sendable {
        /// `'…'` is a string.
        case string
        /// `'a'` is a character, which reads as a string.
        case character
        /// Rust: `'a'` is a character, `'a` a lifetime.
        case rust
        /// Not a quote at all (Swift).
        case none
    }

    enum Backtick: Sendable {
        case none
        /// JavaScript's template literal, over many lines, with `${…}`.
        case template
        /// Go's raw string, over many lines.
        case raw
    }

    var keywords: Set<String> = []
    var types: Set<String> = []
    var constants: Set<String> = []
    var lineComments: [[UInt16]] = [Unit.of("//")]
    var blockComment: (open: [UInt16], close: [UInt16])? = (Unit.of("/*"), Unit.of("*/"))
    var nestedComments = false
    var singleQuote = SingleQuote.string
    /// Quote characters that also open `"""` strings over many lines.
    var tripleQuotes: Set<UInt16> = []
    /// What a double-quoted string interpolates.
    var interpolation = StringMode.Interpolation.none
    var backtick = Backtick.none
    /// Rust's double-quoted strings may run over lines.
    var multilineStrings = false
    /// Python's `r"…"`, `f"…"`, `rb'…'`.
    var stringPrefixes = false
    /// Swift's `#"…"#`.
    var swiftRawStrings = false
    /// Rust's `r#"…"#` and `b"…"`.
    var rustStrings = false
    /// `@Observable`, `@Override`, `@decorator`.
    var decorators = false
    /// Swift's `#if`, `#Preview`; Rust's `#[derive(…)]`.
    var hashAttributes = false
    /// C's `#include`, `#define`.
    var preprocessor = false
    /// Words after which a name is a function's (`func`, `fn`, `def`, `function`, `fun`).
    var functionKeywords: Set<String> = []
    /// Words after which a name is a type's (`class`, `struct`, `enum`, …).
    var typeKeywords: Set<String> = []
    /// `<Tag attribute="…">` in JSX and TSX.
    var markupTags = false
    /// `$` is part of names (JavaScript).
    var dollarInNames = false
    /// `/pattern/flags` is a regular expression where a value may start (JavaScript).
    var regexLiterals = false
    /// `$name` is a variable (PHP).
    var dollarVariables = false
    /// Ruby: `:symbol`, `@ivar`, `$global`, `=begin`, `name?`.
    var ruby = false
    /// `<?php` and `?>`.
    var phpTags = false
    /// SQL's words are the same in any case.
    var caseInsensitive = false
    /// `Capitalised` names are types (not in SQL, whose keywords are often upper case).
    var capitalisedTypes = true

    static func of(_ language: SyntaxLanguage) -> CodeSpec {
        switch language {
        case .swift: swift
        case .typescript: typescript
        case .javascript: javascript
        case .python: python
        case .rust: rust
        case .go: go
        case .c: c
        case .cpp: cpp
        case .java: java
        case .kotlin: kotlin
        case .ruby: ruby
        case .php: php
        case .sql: sql
        default: c
        }
    }

    private static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }

    static let swift: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words("associatedtype class deinit enum extension fileprivate func import init inout internal let operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as async await is throws try any some actor nonisolated mutating nonmutating override final lazy weak unowned required convenience indirect willSet didSet")
        spec.constants = words("true false nil self Self super")
        spec.functionKeywords = ["func"]
        spec.typeKeywords = words("class struct enum protocol extension actor typealias associatedtype")
        spec.nestedComments = true
        spec.singleQuote = .none
        spec.tripleQuotes = [Unit.quote]
        spec.interpolation = .swift
        spec.swiftRawStrings = true
        spec.decorators = true
        spec.hashAttributes = true
        return spec
    }()

    private static let scriptKeywords = "break case catch class const continue debugger default delete do else export extends finally for function if import in instanceof new return switch throw try typeof var void while with yield let static async await of"

    static let javascript: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words(scriptKeywords + " from as get set")
        spec.constants = words("true false null undefined this super NaN Infinity")
        spec.functionKeywords = ["function"]
        spec.typeKeywords = ["class"]
        spec.backtick = .template
        spec.markupTags = true
        spec.decorators = true
        spec.dollarInNames = true
        spec.regexLiterals = true
        return spec
    }()

    static let typescript: CodeSpec = {
        var spec = javascript
        spec.keywords.formUnion(words("enum implements interface package private protected public type namespace declare abstract readonly keyof infer is satisfies module override asserts unique"))
        spec.types = words("string number boolean any unknown never void object symbol bigint")
        spec.typeKeywords = words("class interface type enum namespace")
        return spec
    }()

    static let python: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case")
        spec.constants = words("None True False self cls __name__ __file__ NotImplemented Ellipsis")
        spec.types = words("int str float bool list dict set tuple bytes bytearray object complex frozenset")
        spec.functionKeywords = ["def"]
        spec.typeKeywords = ["class"]
        spec.lineComments = [Unit.of("#")]
        spec.blockComment = nil
        spec.tripleQuotes = [Unit.quote, Unit.apostrophe]
        spec.stringPrefixes = true
        spec.decorators = true
        return spec
    }()

    static let rust: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct trait type unsafe use where while union macro_rules yield")
        spec.constants = words("true false self Self super")
        spec.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
        spec.functionKeywords = ["fn"]
        spec.typeKeywords = words("struct enum trait type union")
        spec.nestedComments = true
        spec.singleQuote = .rust
        spec.multilineStrings = true
        spec.rustStrings = true
        spec.hashAttributes = true
        return spec
    }()

    static let go: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var")
        spec.constants = words("true false nil iota")
        spec.types = words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any")
        spec.functionKeywords = ["func"]
        spec.typeKeywords = ["type"]
        spec.singleQuote = .character
        spec.backtick = .raw
        return spec
    }()

    static let c: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words("auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while _Alignas _Alignof _Atomic _Generic _Noreturn _Static_assert _Thread_local")
        spec.constants = words("true false NULL nullptr YES NO nil self")
        spec.types = words("int char float double void long short unsigned signed bool _Bool size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t FILE id instancetype BOOL")
        spec.typeKeywords = words("struct enum union typedef")
        spec.singleQuote = .character
        spec.preprocessor = true
        spec.decorators = true
        return spec
    }()

    static let cpp: CodeSpec = {
        var spec = c
        spec.keywords.formUnion(words("alignas alignof and asm catch class constexpr consteval constinit const_cast decltype delete dynamic_cast explicit export friend mutable namespace new noexcept not operator or private protected public reinterpret_cast static_assert static_cast template throw try typeid typename using virtual co_await co_return co_yield concept requires final override"))
        spec.constants.formUnion(["this"])
        spec.types.formUnion(words("wchar_t char8_t char16_t char32_t auto"))
        spec.typeKeywords.formUnion(words("class namespace concept"))
        return spec
    }()

    static let java: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public return static strictfp switch synchronized throw throws transient try volatile while var record sealed permits yield non-sealed")
        spec.constants = words("true false null this super")
        spec.types = words("boolean byte char double float int long short void")
        spec.typeKeywords = words("class interface enum record extends implements")
        spec.singleQuote = .character
        spec.tripleQuotes = [Unit.quote]
        spec.decorators = true
        return spec
    }()

    static let kotlin: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words("as break class continue do else for fun if in interface is object package return throw try typealias typeof val var when while by catch constructor finally import init where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg value")
        spec.constants = words("true false null this super it")
        spec.functionKeywords = ["fun"]
        spec.typeKeywords = words("class interface object typealias")
        spec.nestedComments = true
        spec.singleQuote = .character
        spec.tripleQuotes = [Unit.quote]
        spec.interpolation = .dollarBrace
        spec.decorators = true
        return spec
    }()

    static let ruby: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words("BEGIN END alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require require_relative include extend prepend attr_accessor attr_reader attr_writer private protected public raise lambda proc loop")
        spec.constants = words("nil true false self __FILE__ __LINE__ __method__")
        spec.functionKeywords = ["def"]
        spec.typeKeywords = words("class module")
        spec.lineComments = [Unit.of("#")]
        spec.blockComment = nil
        spec.interpolation = .hashBrace
        spec.ruby = true
        return spec
    }()

    static let php: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile eval exit extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list match namespace new or print private protected public readonly require require_once return static switch throw trait try unset use var while xor yield enum")
        spec.constants = words("true false null TRUE FALSE NULL self parent")
        spec.types = words("int float string bool void mixed never iterable object")
        spec.functionKeywords = words("function fn")
        spec.typeKeywords = words("class interface trait enum extends implements new")
        spec.lineComments = [Unit.of("//"), Unit.of("#")]
        spec.interpolation = .shell
        spec.dollarVariables = true
        spec.phpTags = true
        spec.decorators = false
        return spec
    }()

    static let sql: CodeSpec = {
        var spec = CodeSpec()
        spec.keywords = words("select from where and or not insert into values update set delete create table drop alter add column index primary key foreign references join left right inner outer full cross on as group by order having limit offset union all distinct case when then else end is like ilike in between exists default constraint unique check view trigger begin commit rollback transaction with returning if replace database schema grant revoke asc desc natural using cascade auto_increment autoincrement serial function procedure returns language declare do loop return execute materialized recursive over partition window filter conflict nothing upsert pragma explain analyze vacuum truncate rename to cast")
        spec.constants = words("null true false")
        spec.types = words("int integer bigint smallint tinyint decimal numeric float real double precision varchar char character text blob boolean bool date time timestamp timestamptz datetime interval json jsonb uuid bytea money")
        spec.lineComments = [Unit.of("--")]
        spec.caseInsensitive = true
        spec.capitalisedTypes = false
        return spec
    }()
}

/// The lexer for the programming languages.
struct CodeLexer {
    let spec: CodeSpec

    private static let rubyBegin = Unit.of("=begin"), rubyEnd = Unit.of("=end")
    private static let phpOpen = Unit.of("<?php"), phpEcho = Unit.of("<?="), phpClose = Unit.of("?>")
    private static let tripleDouble = Unit.of("\"\"\""), tripleSingle = Unit.of("'''")

    func lex(_ s: inout LineScanner, mode: LexMode) -> LexMode {
        switch mode {
        case .blockComment(let depth):
            guard let open = spec.blockComment else { break }
            if let still = Shared.blockComment(&s, from: 0, depth: depth, open: open.open, close: open.close, nests: spec.nestedComments) { return still }
        case .string(let open):
            if let still = string(&s, from: 0, open, multiline: true) { return still }
        case .preprocessor:
            return continuePreprocessor(&s)
        case .rubyDoc:
            s.add(0, s.end, .comment)
            s.position = s.end
            return s.starts(with: Self.rubyEnd, at: 0) ? .normal : .rubyDoc
        default:
            break
        }
        if s.position == 0 {
            if spec.ruby, s.starts(with: Self.rubyBegin, at: 0) {
                s.add(0, s.end, .comment)
                return .rubyDoc
            }
            let first = s.firstNonSpace()
            if spec.preprocessor, s.at(first) == Unit.hash { return preprocessor(&s, at: first) }
        }
        return run(&s, closer: nil) ?? .normal
    }

    /// Lexes code until the line ends (giving the mode it ends in) or, inside an interpolation, until
    /// `closer` is met at its own depth (giving nil, with `position` on it).
    func run(_ s: inout LineScanner, closer: UInt16?) -> LexMode? {
        let opener: UInt16 = closer == Unit.closeParen ? Unit.openParen : Unit.openBrace
        var nest = 0
        var pending: SyntaxKind?
        while s.position < s.end {
            let start = s.position
            let u = s.units[start]
            if Unit.isSpace(u) {
                s.position += 1
                continue
            }
            if let closer {
                if u == opener { nest += 1 }
                if u == closer {
                    if nest == 0 { return nil }
                    nest -= 1
                }
            }
            if spec.lineComments.contains(where: { s.starts(with: $0) }) {
                s.add(start, s.end, .comment)
                s.position = s.end
                return .normal
            }
            if let block = spec.blockComment, s.starts(with: block.open) {
                s.position += block.open.count
                if let still = Shared.blockComment(&s, from: start, depth: 0, open: block.open, close: block.close, nests: spec.nestedComments) { return still }
                continue
            }
            if spec.phpTags, let tag = [Self.phpOpen, Self.phpEcho, Self.phpClose].first(where: { s.starts(with: $0) }) {
                s.add(start, start + tag.count, .tag)
                s.position = start + tag.count
                continue
            }
            if let open = stringStart(&s) {
                if let still = string(&s, from: start, open.mode, multiline: open.multiline) { return still }
                continue
            }
            if u == Unit.slash, spec.regexLiterals, regex(&s) { continue }
            if u == Unit.hash, spec.hashAttributes, hashAttribute(&s) { continue }
            if u == Unit.at {
                if spec.ruby {
                    var end = start + 1
                    if s.at(end) == Unit.at { end += 1 }
                    end = s.identifierEnd(from: end)
                    s.add(start, end, .variable)
                    s.position = max(end, start + 1)
                    continue
                }
                if spec.decorators, Unit.isIdentifierStart(s.at(start + 1)) {
                    var end = s.identifierEnd(from: start + 1)
                    while s.at(end) == Unit.dot, Unit.isIdentifierStart(s.at(end + 1)) { end = s.identifierEnd(from: end + 1) }
                    s.add(start, end, .attribute)
                    s.position = end
                    continue
                }
            }
            if u == Unit.dollar, spec.ruby || spec.dollarVariables, Unit.isIdentifierStart(s.at(start + 1)) || (spec.ruby && s.at(start + 1) != 0 && !Unit.isSpace(s.at(start + 1))) {
                let end = max(s.identifierEnd(from: start + 1), start + 2)
                s.add(start, end, .variable)
                s.position = end
                continue
            }
            if spec.ruby, u == Unit.colon, Unit.isIdentifierStart(s.at(start + 1)), start == 0 || (!Unit.isIdentifier(s.at(start - 1)) && s.at(start - 1) != Unit.colon) {
                var end = s.identifierEnd(from: start + 1)
                if s.at(end) == Unit.question || s.at(end) == Unit.bang { end += 1 }
                s.add(start, end, .constant)
                s.position = end
                continue
            }
            if Unit.isDigit(u) || (u == Unit.dot && Unit.isDigit(s.at(start + 1)) && !Unit.isIdentifier(s.at(start - 1))) {
                s.position = Shared.number(s, from: start)
                s.add(start, s.position, .number)
                continue
            }
            if Unit.isIdentifierStart(u) || (spec.dollarInNames && u == Unit.dollar) {
                word(&s, pending: &pending)
                continue
            }
            if spec.markupTags, u == Unit.less, markupAllowed(s, at: start) {
                s.position = Shared.tag(&s, from: start, braces: true)
                continue
            }
            s.position += 1
        }
        return .normal
    }

    /// A name: a keyword, a constant, a function, a type, or plain.
    private func word(_ s: inout LineScanner, pending: inout SyntaxKind?) {
        let start = s.position
        var end = s.identifierEnd(from: start, extra: spec.dollarInNames ? Unit.dollar : 0)
        if spec.ruby, s.at(end) == Unit.question || s.at(end) == Unit.bang, s.at(end + 1) != Unit.equals { end += 1 }
        s.position = end
        let text = s.text(start, end)
        let key = spec.caseInsensitive ? text.lowercased() : text
        // Rust's macros: `println!(…)`.
        if spec.rustStrings, s.at(end) == Unit.bang, s.at(end + 1) == Unit.openParen || s.at(end + 1) == Unit.openBracket || s.at(end + 1) == Unit.openBrace {
            s.add(start, end + 1, .function)
            s.position = end + 1
            pending = nil
            return
        }
        let kind: SyntaxKind
        if spec.constants.contains(key) {
            kind = .constant
            pending = nil
        } else if spec.keywords.contains(key) {
            kind = .keyword
            let next = s.at(s.firstNonSpace(from: end))
            // `func (r *T) Name(` and `function (` name nothing yet.
            if spec.functionKeywords.contains(key) { pending = next == Unit.openParen ? nil : .function }
            else if spec.typeKeywords.contains(key) { pending = .type }
            else { pending = nil }
        } else if let named = pending {
            kind = named
            pending = nil
        } else if s.at(end) == Unit.openParen {
            kind = .function
        } else if spec.types.contains(key) {
            kind = .type
        } else if spec.capitalisedTypes, Unit.isUpper(s.units[start]) {
            kind = Self.allCaps(s, start, end) ? .constant : .type
        } else {
            kind = .plain
        }
        s.add(start, end, kind)
    }

    /// `MAX_SIZE`: a constant, not a type.
    private static func allCaps(_ s: LineScanner, _ start: Int, _ end: Int) -> Bool {
        guard end - start > 1 else { return false }
        for index in start..<end {
            let u = s.units[index]
            if !(Unit.isUpper(u) || Unit.isDigit(u) || u == Unit.underscore) { return false }
        }
        return true
    }

    // MARK: Strings

    /// A string beginning at `position` (with any prefix): moves past its opening and says how it ends.
    private func stringStart(_ s: inout LineScanner) -> (mode: StringMode, multiline: Bool)? {
        let start = s.position
        let u = s.units[start]
        if spec.swiftRawStrings, u == Unit.hash {
            var hashes = 0
            while s.at(start + hashes) == Unit.hash { hashes += 1 }
            guard s.at(start + hashes) == Unit.quote else { return nil }
            let tail = [UInt16](repeating: Unit.hash, count: hashes)
            if s.starts(with: Self.tripleDouble, at: start + hashes) {
                s.position = start + hashes + 3
                return (StringMode(close: Self.tripleDouble + tail, escapes: false, interpolation: .none), true)
            }
            s.position = start + hashes + 1
            return (StringMode(close: [Unit.quote] + tail, escapes: false, interpolation: .none), false)
        }
        if spec.rustStrings, u == Unit.letterR || (u == Unit.letterB && (s.at(start + 1) == Unit.letterR || s.at(start + 1) == Unit.quote || s.at(start + 1) == Unit.apostrophe)) {
            var index = start + 1
            if u == Unit.letterB {
                if s.at(index) == Unit.quote {
                    s.position = index + 1
                    return (StringMode(close: [Unit.quote], escapes: true, interpolation: .none), true)
                }
                if s.at(index) == Unit.apostrophe {
                    s.position = index + 1
                    return (StringMode(close: [Unit.apostrophe], escapes: true, interpolation: .none), false)
                }
                index += 1
            }
            var hashes = 0
            while s.at(index + hashes) == Unit.hash { hashes += 1 }
            guard s.at(index + hashes) == Unit.quote, !Unit.isIdentifier(s.at(start - 1)) else { return nil }
            s.position = index + hashes + 1
            return (StringMode(close: [Unit.quote] + [UInt16](repeating: Unit.hash, count: hashes), escapes: false, interpolation: .none), true)
        }
        if spec.stringPrefixes, Unit.isLetter(u), !Unit.isIdentifier(s.at(start - 1)) {
            var index = start
            var raw = false, formatted = false
            while index < start + 3, Unit.isLetter(s.at(index)) {
                switch s.at(index) | 0x20 {
                case Unit.letterR: raw = true
                case Unit.letterF: formatted = true
                case Unit.letterB, Unit.letterU: break
                default: return nil
                }
                index += 1
            }
            let quote = s.at(index)
            guard quote == Unit.quote || quote == Unit.apostrophe else { return nil }
            s.position = index
            guard var open = quoted(&s) else { return nil }
            open.mode.escapes = !raw
            open.mode.interpolation = formatted ? .brace : .none
            return open
        }
        switch u {
        case Unit.quote:
            return quoted(&s)
        case Unit.apostrophe:
            switch spec.singleQuote {
            case .none: return nil
            case .string, .character: return quoted(&s)
            case .rust:
                // A character ('a', '\n', '😀'), else a lifetime ('a, 'static), which `word` colours.
                let next = s.at(start + 1)
                let isCharacter = next == Unit.backslash || s.at(start + 2) == Unit.apostrophe
                    || (next >= 0xD800 && next < 0xDC00 && s.at(start + 3) == Unit.apostrophe)
                guard isCharacter else {
                    let end = s.identifierEnd(from: start + 1)
                    s.add(start, end, .attribute)
                    s.position = max(end, start + 1)
                    return nil
                }
                s.position = start + 1
                return (StringMode(close: [Unit.apostrophe], escapes: true, interpolation: .none), false)
            }
        case Unit.backtick:
            switch spec.backtick {
            case .none:
                // Swift's `name` is a name.
                var end = start + 1
                while end < s.end, s.units[end] != Unit.backtick { end += 1 }
                s.position = min(end + 1, s.end)
                return nil
            case .template:
                s.position = start + 1
                return (StringMode(close: [Unit.backtick], escapes: true, interpolation: .dollarBrace), true)
            case .raw:
                s.position = start + 1
                return (StringMode(close: [Unit.backtick], escapes: false, interpolation: .none), true)
            }
        default:
            return nil
        }
    }

    /// A `"…"` or `'…'` string at `position`, or its triple-quoted form.
    private func quoted(_ s: inout LineScanner) -> (mode: StringMode, multiline: Bool)? {
        let start = s.position
        let quote = s.units[start]
        let triple = quote == Unit.quote ? Self.tripleDouble : Self.tripleSingle
        let interpolation = quote == Unit.quote ? spec.interpolation : .none
        if spec.tripleQuotes.contains(quote), s.starts(with: triple, at: start) {
            s.position = start + 3
            return (StringMode(close: triple, escapes: true, interpolation: interpolation), true)
        }
        s.position = start + 1
        return (StringMode(close: [quote], escapes: true, interpolation: interpolation), spec.multilineStrings && quote == Unit.quote)
    }

    /// A string's body from `position`, coloured from `from`: nil once it closes, else the mode the line
    /// ends in (the string itself, when it can run over lines).
    func string(_ s: inout LineScanner, from: Int, _ mode: StringMode, multiline: Bool) -> LexMode? {
        var segment = from
        while s.position < s.end {
            let at = s.position
            let u = s.units[at]
            if s.starts(with: mode.close) {
                s.position = at + mode.close.count
                s.add(segment, s.position, .string)
                return nil
            }
            if mode.escapes, u == Unit.backslash {
                s.add(segment, at, .string)
                if mode.interpolation == .swift, s.at(at + 1) == Unit.openParen {
                    if !interpolate(&s, at: at, opening: 2, closer: Unit.closeParen) { return multiline ? .string(mode) : .normal }
                } else {
                    var end = at + 2
                    if s.at(at + 1) == Unit.letterU, s.at(at + 2) == Unit.openBrace {
                        while end < s.end, s.units[end] != Unit.closeBrace { end += 1 }
                        end += 1
                    }
                    s.add(at, end, .escape)
                    s.position = min(end, s.end)
                }
                segment = s.position
                continue
            }
            let next = s.at(at + 1)
            switch mode.interpolation {
            case .dollarBrace where u == Unit.dollar && next == Unit.openBrace,
                 .hashBrace where u == Unit.hash && next == Unit.openBrace:
                s.add(segment, at, .string)
                if !interpolate(&s, at: at, opening: 2, closer: Unit.closeBrace) { return multiline ? .string(mode) : .normal }
                segment = s.position
                continue
            case .brace where u == Unit.openBrace:
                if next == Unit.openBrace {
                    s.position = at + 2
                    continue
                }
                s.add(segment, at, .string)
                if !interpolate(&s, at: at, opening: 1, closer: Unit.closeBrace) { return multiline ? .string(mode) : .normal }
                segment = s.position
                continue
            case .shell where u == Unit.dollar && (Unit.isIdentifierStart(next) || next == Unit.openBrace):
                s.add(segment, at, .string)
                var end = at + 1
                if next == Unit.openBrace {
                    while end < s.end, s.units[end] != Unit.closeBrace { end += 1 }
                    end += 1
                } else {
                    end = s.identifierEnd(from: end)
                }
                s.add(at, end, .variable)
                s.position = min(end, s.end)
                segment = s.position
                continue
            default:
                break
            }
            s.position += 1
        }
        s.add(segment, s.end, .string)
        return multiline ? .string(mode) : .normal
    }

    /// `\(…)`, `${…}`, `{…}`: the marks as escapes, what is between them as code. False when the line
    /// ends first.
    private func interpolate(_ s: inout LineScanner, at: Int, opening: Int, closer: UInt16) -> Bool {
        s.add(at, at + opening, .escape)
        s.position = at + opening
        guard run(&s, closer: closer) == nil else { return false }
        s.add(s.position, s.position + 1, .escape)
        s.position += 1
        return true
    }

    // MARK: Regular expressions

    /// Words after which `/` starts a regular expression rather than dividing.
    private static let beforeRegex: Set<String> = ["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await"]

    /// A regular expression literal at `position` (`/a[/]b\/c/gi`), coloured as a string with its escapes;
    /// false, moving nothing, when the `/` divides (after a value) or nothing closes it on this line.
    private func regex(_ s: inout LineScanner) -> Bool {
        let start = s.position
        guard regexAllowed(s, at: start) else { return false }
        var index = start + 1
        var inClass = false
        var escapes: [Int] = []
        while index < s.end {
            let u = s.units[index]
            if u == Unit.backslash {
                escapes.append(index)
                index += 2
                continue
            }
            if u == Unit.openBracket { inClass = true }
            else if u == Unit.closeBracket { inClass = false }
            else if u == Unit.slash, !inClass { break }
            index += 1
        }
        // Unclosed on this line (or empty, which would be a comment): not a regular expression.
        guard index < s.end, index > start + 1 else { return false }
        var end = index + 1
        while end < s.end, Unit.isLetter(s.units[end]) { end += 1 }
        var segment = start
        for escape in escapes {
            s.add(segment, escape, .string)
            s.add(escape, min(escape + 2, index), .escape)
            segment = min(escape + 2, index)
        }
        s.add(segment, end, .string)
        s.position = end
        return true
    }

    /// Whether a value may start at `index`, judged by what comes before it on the line: an operator,
    /// an opening bracket, a keyword such as `return`, or nothing. After a name, a number, a closing `)` or
    /// `]`, a string or `x++`, `/` divides.
    private func regexAllowed(_ s: LineScanner, at index: Int) -> Bool {
        var before = index - 1
        while before >= 0, Unit.isSpace(s.units[before]) { before -= 1 }
        guard before >= 0 else { return true }
        let u = s.units[before]
        if Unit.isIdentifier(u) || u == Unit.dollar {
            var first = before
            while first > 0, Unit.isIdentifier(s.units[first - 1]) || s.units[first - 1] == Unit.dollar { first -= 1 }
            // A member named like a keyword (`a.return / 2`) is still a value.
            guard first == 0 || s.units[first - 1] != Unit.dot else { return false }
            return Self.beforeRegex.contains(s.text(first, before + 1))
        }
        switch u {
        case Unit.closeParen, Unit.closeBracket, Unit.quote, Unit.apostrophe, Unit.backtick:
            return false
        case Unit.plus, Unit.minus:
            // `i++ / 2` divides; `a + /x/.source` does not.
            return before == 0 || s.units[before - 1] != u
        default:
            return true
        }
    }

    // MARK: Attributes and the preprocessor

    /// Swift's `#if`, `#available`, `#Preview`; Rust's `#[derive(…)]` and `#![…]`.
    private func hashAttribute(_ s: inout LineScanner) -> Bool {
        let start = s.position
        var index = start + 1
        if s.at(index) == Unit.bang { index += 1 }
        if s.at(index) == Unit.openBracket {
            var depth = 0
            while index < s.end {
                if s.units[index] == Unit.openBracket { depth += 1 }
                if s.units[index] == Unit.closeBracket {
                    depth -= 1
                    if depth == 0 { break }
                }
                index += 1
            }
            s.position = min(index + 1, s.end)
            s.add(start, s.position, .attribute)
            return true
        }
        guard Unit.isIdentifierStart(s.at(start + 1)) else { return false }
        s.position = s.identifierEnd(from: start + 1)
        s.add(start, s.position, .attribute)
        return true
    }

    /// `#include <stdio.h>`, `#define MAX 10`: the directive as an attribute, the rest as code.
    private func preprocessor(_ s: inout LineScanner, at hash: Int) -> LexMode {
        let wordStart = s.firstNonSpace(from: hash + 1)
        let wordEnd = s.identifierEnd(from: wordStart)
        s.add(hash, wordEnd, .attribute)
        s.position = wordEnd
        let directive = s.text(wordStart, wordEnd)
        if directive == "include" || directive == "import" {
            s.skipSpace()
            if s.current == Unit.less {
                let start = s.position
                while s.position < s.end, s.units[s.position] != Unit.greater { s.position += 1 }
                s.position = min(s.position + 1, s.end)
                s.add(start, s.position, .string)
            }
        }
        return continuePreprocessor(&s)
    }

    /// The rest of a preprocessor line; a `\` at its end carries it on.
    private func continuePreprocessor(_ s: inout LineScanner) -> LexMode {
        let mode = run(&s, closer: nil) ?? .normal
        let last = s.lastNonSpace
        if mode == .normal, last >= 0, s.units[last] == Unit.backslash { return .preprocessor }
        return mode
    }

    /// Whether `<` at `index` opens JSX markup rather than comparing: it must follow something that
    /// cannot end an expression (`(`, `=`, `,`, `return`, the line's start …) and lead to a name or `>`.
    private func markupAllowed(_ s: LineScanner, at index: Int) -> Bool {
        let next = s.at(index + 1)
        guard Unit.isLetter(next) || next == Unit.slash || next == Unit.greater else { return false }
        // `</name` is never an operator: a closing tag after a child's text.
        if next == Unit.slash, Unit.isLetter(s.at(index + 2)) { return true }
        var before = index - 1
        while before >= 0, Unit.isSpace(s.units[before]) { before -= 1 }
        guard before >= 0 else { return true }
        let previous = s.units[before]
        if [Unit.openParen, Unit.equals, Unit.comma, Unit.openBrace, Unit.openBracket, Unit.greater, Unit.question, Unit.colon, Unit.amp, Unit.pipe, Unit.semicolon].contains(previous) {
            // `a >= <b` never happens, but `=>` does: an arrow function's body.
            return true
        }
        guard Unit.isIdentifier(previous) else { return false }
        var start = before
        while start > 0, Unit.isIdentifier(s.units[start - 1]) { start -= 1 }
        return s.text(start, before + 1) == "return"
    }
}

/// What several lexers share: comments, numbers, tags.
enum Shared {
    /// A block comment's body from `position`, coloured from `from`: nil once it closes, else the mode the
    /// line ends in.
    static func blockComment(_ s: inout LineScanner, from: Int, depth: Int, open: [UInt16], close: [UInt16], nests: Bool) -> LexMode? {
        var depth = depth
        while s.position < s.end {
            if s.starts(with: close) {
                s.position += close.count
                if depth == 0 {
                    s.add(from, s.position, .comment)
                    return nil
                }
                depth -= 1
                continue
            }
            if nests, s.starts(with: open) {
                s.position += open.count
                depth += 1
                continue
            }
            s.position += 1
        }
        s.add(from, s.end, .comment)
        return .blockComment(depth: depth)
    }

    /// Where a number starting at `from` ends: hex, binary and octal, decimals with `_`, fractions,
    /// exponents and a suffix (`u32`, `f`, `L`, `n`).
    static func number(_ s: LineScanner, from: Int) -> Int {
        var index = from
        let second = s.at(from + 1) | 0x20
        if s.at(from) == Unit.zero, second == Unit.letterX || second == Unit.letterB || second == Unit.letterO {
            index += 2
            while Unit.isHex(s.at(index)) || s.at(index) == Unit.underscore { index += 1 }
        } else {
            while Unit.isDigit(s.at(index)) || s.at(index) == Unit.underscore { index += 1 }
            if s.at(index) == Unit.dot, Unit.isDigit(s.at(index + 1)) {
                index += 1
                while Unit.isDigit(s.at(index)) || s.at(index) == Unit.underscore { index += 1 }
            }
            if s.at(index) | 0x20 == Unit.letterE {
                let sign = s.at(index + 1) == Unit.plus || s.at(index + 1) == Unit.minus ? 1 : 0
                if Unit.isDigit(s.at(index + 1 + sign)) {
                    index += 1 + sign
                    while Unit.isDigit(s.at(index)) { index += 1 }
                }
            }
        }
        while Unit.isLetter(s.at(index)) || Unit.isDigit(s.at(index)) || s.at(index) == Unit.underscore { index += 1 }
        return max(index, from + 1)
    }

    /// A tag at `from` (`<name`, `</name`, `<>`) with its attributes, to its `>` or the line's end;
    /// gives where it ends. With `braces`, `{…}` values (JSX) are passed over as code.
    static func tag(_ s: inout LineScanner, from: Int, braces: Bool) -> Int {
        var index = from + 1
        if s.at(index) == Unit.slash { index += 1 }
        index = nameEnd(s, from: index)
        s.add(from, index, .tag)
        return attributes(&s, from: index, braces: braces).end
    }

    /// A tag's attributes from `from`: names as properties, values as strings, to the closing `>` or `/>`.
    /// Gives where it stopped and whether the tag closed on this line.
    static func attributes(_ s: inout LineScanner, from: Int, braces: Bool) -> (end: Int, closed: Bool) {
        var index = from
        while index < s.end {
            let u = s.units[index]
            if Unit.isSpace(u) {
                index += 1
            } else if u == Unit.greater {
                s.add(index, index + 1, .tag)
                return (index + 1, true)
            } else if (u == Unit.slash || u == Unit.question) && s.at(index + 1) == Unit.greater {
                s.add(index, index + 2, .tag)
                return (index + 2, true)
            } else if Unit.isIdentifierStart(u) {
                let end = nameEnd(s, from: index)
                s.add(index, end, .property)
                index = end
            } else if u == Unit.quote || u == Unit.apostrophe {
                var end = index + 1
                while end < s.end, s.units[end] != u { end += 1 }
                end = min(end + 1, s.end)
                s.add(index, end, .string)
                index = end
            } else if braces, u == Unit.openBrace {
                var depth = 0
                while index < s.end {
                    if s.units[index] == Unit.openBrace { depth += 1 }
                    if s.units[index] == Unit.closeBrace {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    index += 1
                }
                index += 1
            } else {
                index += 1
            }
        }
        return (s.end, false)
    }

    /// A tag's or attribute's name: letters, digits, `-`, `_`, `:` and `.`.
    static func nameEnd(_ s: LineScanner, from: Int) -> Int {
        var index = from
        while index < s.end {
            let u = s.units[index]
            guard Unit.isIdentifier(u) || u == Unit.minus || u == Unit.colon || u == Unit.dot else { break }
            index += 1
        }
        return index
    }
}
