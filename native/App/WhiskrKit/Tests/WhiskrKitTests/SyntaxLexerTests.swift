import Foundation
import Testing
@testable import WhiskrKit

/// Each token of a line as "kind text", in order.
private func tokens(_ line: String, _ language: SyntaxLanguage, from state: LexerState = .initial) -> [String] {
    let utf16 = Array(line.utf16)
    return SyntaxLexer(language: language).tokenize(line, from: state).tokens.map { token in
        "\(token.kind) " + String(decoding: utf16[token.range], as: UTF16.self)
    }
}

/// Lexes lines in order; gives each line's tokens and the state after the last.
private func lines(_ text: [String], _ language: SyntaxLanguage) -> (tokens: [[String]], end: LexerState) {
    let lexer = SyntaxLexer(language: language)
    var state = LexerState.initial
    var all: [[String]] = []
    for line in text {
        let utf16 = Array(line.utf16)
        let result = lexer.tokenize(line, from: state)
        all.append(result.tokens.map { "\($0.kind) " + String(decoding: utf16[$0.range], as: UTF16.self) })
        state = result.end
    }
    return (all, state)
}

@Suite("Syntax language detection")
struct SyntaxLanguageTests {
    @Test("extensions, in any case")
    func extensions() {
        #expect(SyntaxLanguage.detect(fileName: "App.swift", firstLine: nil) == .swift)
        #expect(SyntaxLanguage.detect(fileName: "main.TSX", firstLine: nil) == .typescript)
        #expect(SyntaxLanguage.detect(fileName: "a.mjs", firstLine: nil) == .javascript)
        #expect(SyntaxLanguage.detect(fileName: "lib.rs", firstLine: nil) == .rust)
        #expect(SyntaxLanguage.detect(fileName: "x.hpp", firstLine: nil) == .cpp)
        #expect(SyntaxLanguage.detect(fileName: "x.h", firstLine: nil) == .c)
        #expect(SyntaxLanguage.detect(fileName: "Info.plist", firstLine: nil) == .xml)
        #expect(SyntaxLanguage.detect(fileName: "style.scss", firstLine: nil) == .css)
        #expect(SyntaxLanguage.detect(fileName: "README.md", firstLine: nil) == .markdown)
        #expect(SyntaxLanguage.detect(fileName: "ci.YML", firstLine: nil) == .yaml)
        #expect(SyntaxLanguage.detect(fileName: "Cargo.toml", firstLine: nil) == .toml)
        #expect(SyntaxLanguage.detect(fileName: "q.sql", firstLine: nil) == .sql)
        #expect(SyntaxLanguage.detect(fileName: "run.zsh", firstLine: nil) == .shell)
        #expect(SyntaxLanguage.detect(fileName: "tsconfig.jsonc", firstLine: nil) == .json)
        #expect(SyntaxLanguage.detect(fileName: "notes.txt", firstLine: nil) == .plain)
    }

    @Test("whole names and Dockerfiles")
    func names() {
        #expect(SyntaxLanguage.detect(fileName: "Dockerfile", firstLine: nil) == .dockerfile)
        #expect(SyntaxLanguage.detect(fileName: "/repo/api.dockerfile", firstLine: nil) == .dockerfile)
        #expect(SyntaxLanguage.detect(fileName: "Containerfile", firstLine: nil) == .dockerfile)
        #expect(SyntaxLanguage.detect(fileName: "Dockerfile.dev", firstLine: nil) == .dockerfile)
        #expect(SyntaxLanguage.detect(fileName: ".zshrc", firstLine: nil) == .shell)
        #expect(SyntaxLanguage.detect(fileName: "Gemfile", firstLine: nil) == .ruby)
        #expect(SyntaxLanguage.detect(fileName: "package.json", firstLine: nil) == .json)
        #expect(SyntaxLanguage.detect(fileName: ".gitignore", firstLine: "#!/bin/sh") == .plain)
        #expect(SyntaxLanguage.detect(fileName: "Makefile", firstLine: nil) == .plain)
    }

    @Test("shebangs and declarations on the first line")
    func firstLines() {
        #expect(SyntaxLanguage.detect(fileName: "tool", firstLine: "#!/usr/bin/env python3") == .python)
        #expect(SyntaxLanguage.detect(fileName: "tool", firstLine: "#!/usr/bin/env -S node --no-warnings") == .javascript)
        #expect(SyntaxLanguage.detect(fileName: "tool", firstLine: "#!/bin/bash") == .shell)
        #expect(SyntaxLanguage.detect(fileName: "tool", firstLine: "#!/usr/bin/ruby -w") == .ruby)
        #expect(SyntaxLanguage.detect(fileName: "data", firstLine: "<?xml version=\"1.0\"?>") == .xml)
        #expect(SyntaxLanguage.detect(fileName: "page", firstLine: "<!DOCTYPE html>") == .html)
        #expect(SyntaxLanguage.detect(fileName: "tool", firstLine: "hello") == .plain)
    }

    @Test("comment markers for Toggle Comment")
    func comments() {
        #expect(SyntaxLanguage.swift.lineComment == "//")
        #expect(SyntaxLanguage.python.lineComment == "#")
        #expect(SyntaxLanguage.sql.lineComment == "--")
        #expect(SyntaxLanguage.html.lineComment == nil)
        #expect(SyntaxLanguage.html.blockComment?.open == "<!--")
        #expect(SyntaxLanguage.css.blockComment?.close == "*/")
        #expect(SyntaxLanguage.swift.blockComment == nil)
        #expect(SyntaxLanguage.allCases.allSatisfy { !$0.displayName.isEmpty })
    }
}

@Suite("Syntax lexer: code")
struct SyntaxCodeTests {
    @Test("Swift: keywords, names, types, attributes, numbers, constants")
    func swift() {
        #expect(tokens("@MainActor final class Cart: View {", .swift) == ["attribute @MainActor", "keyword final", "keyword class", "type Cart", "type View"])
        #expect(tokens("    func total(of items: [Int]) -> Int {", .swift) == ["keyword func", "function total", "type Int", "type Int"])
        #expect(tokens("let x = 0x1F + 1_000.5e-3 // done", .swift) == ["keyword let", "number 0x1F", "number 1_000.5e-3", "comment // done"])
        #expect(tokens("if value == nil { return self.count(MAX_ITEMS) }", .swift) == ["keyword if", "constant nil", "keyword return", "constant self", "function count", "constant MAX_ITEMS"])
        #expect(tokens("#if DEBUG", .swift) == ["attribute #if", "constant DEBUG"])
        #expect(tokens("for i in 0..<5 {}", .swift) == ["keyword for", "keyword in", "number 0", "number 5"])
    }

    @Test("Swift: escapes and interpolation inside strings")
    func swiftStrings() {
        #expect(tokens(#"print("a\n\(name.count)b")"#, .swift) == ["function print", "string \"a", "escape \\n\\(", "escape )", "string b\""])
        #expect(tokens(#"let s = "x \(f("y")) z""#, .swift) == ["keyword let", "string \"x ", "escape \\(", "function f", "string \"y\"", "escape )", "string  z\""])
        #expect(tokens(##"let r = #"no \n here"#"##, .swift) == ["keyword let", "string #\"no \\n here\"#"])
    }

    @Test("UTF-16 offsets hold after text beyond ASCII")
    func offsets() {
        let line = #"let 名前 = "é😀" // ok"#
        let result = SyntaxLexer(language: .swift).tokenize(line, from: .initial)
        let ns = line as NSString
        let texts = result.tokens.map { ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
        #expect(texts == ["let", "\"é😀\"", "// ok"])
        #expect(result.tokens.map(\.kind) == [.keyword, .string, .comment])
    }

    @Test("TypeScript: types, template literals, JSX")
    func typescript() {
        #expect(tokens("export interface Props { name: string; count?: number }", .typescript) == ["keyword export", "keyword interface", "type Props", "type string", "type number"])
        #expect(tokens("const s = `hi ${user.name}!`", .typescript) == ["keyword const", "string `hi ", "escape ${", "escape }", "string !`"])
        #expect(tokens("return <Button kind=\"primary\" onClick={go}>Go</Button>", .typescript)
                == ["keyword return", "tag <Button", "property kind", "string \"primary\"", "property onClick", "tag >", "type Go", "tag </Button>"])
        #expect(tokens("if (a < b) {}", .typescript) == ["keyword if"])
        #expect(tokens("const $el = undefined", .javascript) == ["keyword const", "constant undefined"])
    }

    @Test("JavaScript and TypeScript: regular expression literals, told apart from division")
    func regexLiterals() {
        #expect(tokens("const re = /ab+c/gi;", .javascript) == ["keyword const", "string /ab+c/gi"])
        #expect(tokens("if (/^\\d+$/.test(s)) {}", .typescript) == ["keyword if", "string /^", "escape \\d", "string +$/", "function test"])
        // A `/` inside a character class does not close it; an escaped one neither.
        #expect(tokens("return /[/]x\\/y/u", .javascript) == ["keyword return", "string /[/]x", "escape \\/", "string y/u"])
        #expect(tokens("s.replace(/\"/g, \"'\")", .javascript) == ["function replace", "string /\"/g", "string \"'\""])
        // After a value, `/` divides.
        #expect(tokens("const half = total / 2 / count", .javascript) == ["keyword const", "number 2"])
        #expect(tokens("x = (a + b) / c / d", .javascript) == [])
        #expect(tokens("n = list[0] / 2", .typescript) == ["number 0", "number 2"])
        #expect(tokens("i++ / 2", .javascript) == ["number 2"])
        // Comments are still comments; an unclosed `/` is division.
        #expect(tokens("a = b // c / d", .javascript) == ["comment // c / d"])
        #expect(tokens("let r = /* not */ 1", .javascript) == ["keyword let", "comment /* not */", "number 1"])
        #expect(tokens("const ratio = a /b", .javascript) == ["keyword const"])
        // Other languages have no such literals.
        #expect(tokens("let r = a / b / c", .swift) == ["keyword let"])
    }

    @Test("Python: def and class names, decorators, f-strings, constants")
    func python() {
        #expect(tokens("@dataclass", .python) == ["attribute @dataclass"])
        #expect(tokens("def load(self, path=None):  # read it", .python) == ["keyword def", "function load", "constant self", "constant None", "comment # read it"])
        #expect(tokens("class Cart(Base):", .python) == ["keyword class", "type Cart", "type Base"])
        #expect(tokens(#"x = f"{a} and {{b}}" + r"\d""#, .python) == ["string f\"", "escape {", "escape }", "string  and {{b}}\"", "string r\"\\d\""])
    }

    @Test("Rust: macros, lifetimes, characters, attributes, raw strings")
    func rust() {
        #expect(tokens("#[derive(Debug, Clone)]", .rust) == ["attribute #[derive(Debug, Clone)]"])
        #expect(tokens("fn get<'a>(x: &'a str) -> u32 { println!(\"{}\", 'c'); 42u32 }", .rust)
                == ["keyword fn", "function get", "attribute 'a", "attribute 'a", "type str", "type u32", "function println!", "string \"{}\"", "string 'c'", "number 42u32"])
        #expect(tokens(##"let r = r#"a "quoted" b"#;"##, .rust) == ["keyword let", "string r#\"a \"quoted\" b\"#"])
    }

    @Test("Go, C, Java, Kotlin")
    func others() {
        #expect(tokens("func (s *Server) Start(port int) error {", .go) == ["keyword func", "type Server", "function Start", "type int", "type error"])
        #expect(tokens("#include <stdio.h>", .c) == ["attribute #include", "string <stdio.h>"])
        #expect(tokens("static int count = 0; /* n */", .c) == ["keyword static", "type int", "number 0", "comment /* n */"])
        #expect(tokens("@Override public void run() {", .java) == ["attribute @Override", "keyword public", "type void", "function run"])
        #expect(tokens("val s = \"${a.b} \"", .kotlin) == ["keyword val", "string \"", "escape ${", "escape }", "string  \""])
    }

    @Test("Ruby, PHP, SQL")
    func scripting() {
        #expect(tokens("def save!(opts) = @store[:key] if $debug", .ruby) == ["keyword def", "function save!", "variable @store", "constant :key", "keyword if", "variable $debug"])
        #expect(tokens("puts \"hi #{name}\"", .ruby) == ["string \"hi ", "escape #{", "escape }", "string \""])
        #expect(tokens("<?php echo \"Hi $name\"; ?>", .php) == ["tag <?php", "keyword echo", "string \"Hi ", "variable $name", "string \"", "tag ?>"])
        #expect(tokens("SELECT count(*) FROM users WHERE id = 'a''b' -- x", .sql)
                == ["keyword SELECT", "function count", "keyword FROM", "keyword WHERE", "string 'a''b'", "comment -- x"])
        #expect(tokens("create table t (id INTEGER primary key, ok boolean default TRUE)", .sql).contains("type INTEGER"))
    }

    @Test("pathological lines do not crash and give sorted, separate tokens")
    func pathological() {
        let lines = ["", "\"", "\\", "'", "`", "/*", "*/", "#", "\"\"\"", "r#", "#\"", "<", "<<", "$", "${", "\\(", "@", "😀\"", "a😀", "{{{{", "))))", "#!", "[](", "**", "` `` ```"]
        for language in SyntaxLanguage.allCases {
            let lexer = SyntaxLexer(language: language)
            for line in lines {
                let result = lexer.tokenize(line, from: .initial)
                var last = 0
                for token in result.tokens {
                    #expect(token.range.lowerBound >= last && token.range.upperBound <= line.utf16.count && !token.range.isEmpty, "\(language) \(line.debugDescription)")
                    last = token.range.upperBound
                }
                _ = lexer.tokenize(line, from: result.end)
            }
        }
    }

    @Test("a 100,000-character line is quick")
    func longLine() {
        let line = String(repeating: "var a=\"x\";/*c*/ ", count: 6_300)
        #expect(line.utf16.count > 100_000)
        for language in [SyntaxLanguage.javascript, .json, .markdown, .html, .css, .shell] {
            let elapsed = threadTime { _ = SyntaxLexer(language: language).tokenize(line, from: .initial) }
            #expect(elapsed < .milliseconds(50), "\(language) took \(elapsed)")
        }
    }
}

@Suite("Syntax lexer: what lines leave open")
struct SyntaxStateTests {
    @Test("nested block comments in Swift, plain ones in C")
    func blockComments() {
        let swift = lines(["/* a /* b */", "still */ let x", "let y"], .swift)
        #expect(swift.tokens == [["comment /* a /* b */"], ["comment still */", "keyword let"], ["keyword let"]])
        let c = lines(["/* a /* b */ int x;"], .c)
        #expect(c.tokens == [["comment /* a /* b */", "type int"]])
    }

    @Test("triple-quoted, template and raw strings run over lines")
    func multilineStrings() {
        #expect(lines(["let s = \"\"\"", "body \\(x) here", "\"\"\" + y"], .swift).tokens
                == [["keyword let", "string \"\"\""], ["string body ", "escape \\(", "escape )", "string  here"], ["string \"\"\""]])
        #expect(lines(["doc = '''one", "two''' if x else 1"], .python).tokens == [["string '''one"], ["string two'''", "keyword if", "keyword else", "number 1"]])
        #expect(lines(["const t = `a", "${b} c`; let"], .javascript).tokens == [["keyword const", "string `a"], ["escape ${", "escape }", "string  c`", "keyword let"]])
        #expect(lines([##"let s = r#"one"##, ##"two"# ;"##], .rust).tokens == [["keyword let", "string r#\"one"], ["string two\"#"]])
        #expect(lines(["x := `raw", "line` + 1"], .go).tokens == [["string `raw"], ["string line`", "number 1"]])
        #expect(lines(["String s = \"\"\"", "  text", "  \"\"\";"], .java).end == lines(["int x;"], .java).end)
    }

    @Test("preprocessor lines continue with a backslash")
    func preprocessor() {
        let result = lines(["#define MAX(a, b) \\", "  ((a) > (b) ? (a) : (b))", "int x;"], .c)
        #expect(result.tokens[0].first == "attribute #define")
        #expect(result.tokens[2] == ["type int"])
    }

    @Test("Ruby's =begin … =end")
    func rubyDoc() {
        #expect(lines(["=begin", "def nope", "=end", "def yes"], .ruby).tokens == [["comment =begin"], ["comment def nope"], ["comment =end"], ["keyword def", "function yes"]])
    }

    @Test("HTML comments and tags over lines")
    func markup() {
        #expect(lines(["<div class=\"a\"> <!-- start", "still --> <b>&amp;</b>"], .html).tokens
                == [["tag <div", "property class", "string \"a\"", "tag >", "comment <!-- start"], ["comment still -->", "tag <b>", "escape &amp;", "tag </b>"]])
        #expect(lines(["<input", "  type=\"text\"", "  />"], .html).tokens == [["tag <input"], ["property type", "string \"text\""], ["tag />"]])
        #expect(tokens("<?xml version=\"1.0\"?><!DOCTYPE x>", .xml) == ["attribute <?xml version=\"1.0\"?>", "keyword <!DOCTYPE x>"])
    }

    @Test("TOML multi-line strings and tables")
    func toml() {
        #expect(lines(["[package]", "name = \"app\" # n", "desc = \"\"\"", "long", "\"\"\"", "debug = true"], .toml).tokens
                == [["type [package]"], ["property name", "string \"app\"", "comment # n"], ["property desc", "string \"\"\""], ["string long"], ["string \"\"\""], ["property debug", "constant true"]])
        #expect(tokens("[[bin]]", .toml) == ["type [[bin]]"])
        #expect(tokens("when = 1979-05-27T07:32:00Z", .toml) == ["property when", "number 1979-05-27T07:32:00Z"])
        #expect(tokens("point = { x = 1, y = 2 }", .toml) == ["property point", "property x", "number 1", "property y", "number 2"])
    }

    @Test("shell strings and here-documents over lines")
    func shell() {
        #expect(tokens("export PATH=\"$HOME/bin:${PATH}\" # set", .shell) == ["keyword export", "variable PATH", "string \"", "variable $HOME", "string /bin:", "variable ${PATH}", "string \"", "comment # set"])
        #expect(tokens("echo a#b $(date) 'x' $1", .shell) == ["variable $(", "string 'x'", "variable $1"])
        #expect(lines(["cat <<EOF", "if not a keyword", "EOF", "if true; then"], .shell).tokens
                == [["string <<EOF"], ["string if not a keyword"], ["string EOF"], ["keyword if", "keyword then"]])
        #expect(lines(["echo \"one", "two\" done"], .shell).tokens == [["string \"one"], ["string two\"", "keyword done"]])
    }

    @Test("Dockerfile instructions, continuations and comments")
    func dockerfile() {
        #expect(lines(["# base", "FROM node:20 AS build", "RUN npm ci && \\", "    npm run build", "copy . ."], .dockerfile).tokens
                == [["comment # base"], ["keyword FROM", "keyword AS"], ["keyword RUN"], [], ["keyword copy"]])
        let continued = lines(["RUN echo \\", "  FROM"], .dockerfile)
        #expect(continued.tokens[1] == [])
    }

    @Test("JSON, YAML and CSS")
    func data() {
        #expect(tokens("{\"name\": \"app\", \"n\": -1.5e3, \"ok\": true, \"x\": null} // c", .json)
                == ["property \"name\"", "string \"app\"", "property \"n\"", "number -1.5e3", "property \"ok\"", "constant true", "property \"x\"", "constant null", "comment // c"])
        #expect(tokens("  - name: Build app # step", .yaml) == ["listMarker -", "property name", "comment # step"])
        #expect(tokens("retries: 3", .yaml) == ["property retries", "number 3"])
        #expect(tokens("enabled: yes", .yaml) == ["property enabled", "constant yes"])
        #expect(tokens("base: &base !!map", .yaml) == ["property base", "attribute &base", "attribute !!map"])
        #expect(tokens("url: http://a.b/c", .yaml) == ["property url"])
        #expect(tokens("---", .yaml) == ["punctuation ---"])
        #expect(tokens("list: [a, 'b', 2]", .yaml) == ["property list", "string 'b'", "number 2"])
        let css = lines(["@media (max-width: 600px) {", ".card:hover, #top > a {", "  color: #fff !important;", "  margin: 0 auto; /* c", "*/ background: rgb(0, 0, 0);", "}}"], .css)
        #expect(css.tokens == [
            ["keyword @media", "property max-width", "number 600px"],
            ["type .card", "attribute :hover", "type #top", "tag a"],
            ["property color", "number #fff", "keyword !important"],
            ["property margin", "number 0", "comment /* c"],
            ["comment */", "property background", "function rgb", "number 0", "number 0", "number 0"],
            [],
        ])
        #expect(css.end.depth == 0)
    }
}

@Suite("Syntax lexer: Markdown")
struct SyntaxMarkdownTests {
    @Test("headings, emphasis, code, links, lists, quotes, rules")
    func inline() {
        #expect(tokens("## Getting started", .markdown) == ["heading ## Getting started"])
        #expect(tokens("Use **bold**, *it*, `code` and snake_case_name.", .markdown) == ["strong **bold**", "emphasis *it*", "code `code`"])
        #expect(tokens("See [the docs](docs/a.md) and <https://x.dev>.", .markdown) == ["link [the docs]", "string (docs/a.md)", "link <https://x.dev>"])
        #expect(tokens("- [x] done", .markdown) == ["listMarker -", "listMarker [x]"])
        #expect(tokens("12. step", .markdown) == ["listMarker 12."])
        #expect(tokens("> quoted *a*", .markdown) == ["quote >", "emphasis *a*"])
        #expect(tokens("***", .markdown) == ["punctuation ***"])
        #expect(tokens("====", .markdown) == ["heading ===="])
        #expect(tokens("![logo](img/logo.png)", .markdown) == ["link ![logo]", "string (img/logo.png)"])
        #expect(tokens("2 * 3 * 4", .markdown) == [])
        #expect(tokens("\\*not em\\*", .markdown) == ["escape \\*", "escape \\*"])
    }

    @Test("fenced code is lexed in its own language, carrying its own state")
    func fences() {
        let result = lines(["```swift", "let a = 1 /* open", "still */ func f()", "```", "**after**"], .markdown)
        #expect(result.tokens == [
            ["punctuation ```", "attribute swift"],
            ["keyword let", "number 1", "comment /* open"],
            ["comment still */", "keyword func", "function f"],
            ["punctuation ```"],
            ["strong **after**"],
        ])
        #expect(result.end.mode == .normal)
        // A shorter fence does not close a longer one; ~~~ does not close ```.
        let nested = lines(["````md", "```", "~~~", "````", "# Title"], .markdown)
        #expect(nested.tokens[4] == ["heading # Title"])
        #expect(lines(["```", "# not a heading"], .markdown).tokens[1] == [])
    }

    @Test("front matter is YAML, only at the top")
    func frontMatter() {
        let result = lines(["---", "title: Hello", "---", "# Body", "---"], .markdown)
        #expect(result.tokens == [["punctuation ---"], ["property title"], ["punctuation ---"], ["heading # Body"], ["punctuation ---"]])
    }

    @Test("HTML comments over lines")
    func comments() {
        #expect(lines(["<!-- a", "b --> *c*"], .markdown).tokens == [["comment <!-- a"], ["comment b -->", "emphasis *c*"]])
    }
}

@Suite("Syntax lexer: incremental use")
struct SyntaxIncrementalTests {
    private static func swiftFile(lines count: Int) -> [String] {
        var lines: [String] = []
        for index in 0..<count {
            switch index % 10 {
            case 0: lines.append("/// Item \(index), with a \"quote\"")
            case 1: lines.append("@MainActor final class Item\(index): Codable {")
            case 2: lines.append("    let name = \"item \\(\(index)) é\"")
            case 3: lines.append("    /* a comment")
            case 4: lines.append("       still */ var count = 0x\(index)")
            case 5: lines.append("    func total(of values: [Int]) -> Int {")
            case 6: lines.append("        values.reduce(0, +) // sum")
            case 7: lines.append("    }")
            case 8: lines.append("    let text = \"\"\"\n".trimmingCharacters(in: .newlines))
            default: lines.append("    \"\"\" }")
            }
        }
        return lines
    }

    @Test("lexing twice gives the same states; an edit inside a function changes only its line")
    func convergence() {
        let file = Self.swiftFile(lines: 2_000)
        let lexer = SyntaxLexer(language: .swift)
        func states(_ lines: [String]) -> [LexerState] {
            var state = LexerState.initial
            return lines.map { line in
                state = lexer.tokenize(line, from: state).end
                return state
            }
        }
        let first = states(file)
        #expect(first == states(file))
        var edited = file
        edited[1_006] = "        values.reduce(1, *) /* inline */ // product"
        let second = states(edited)
        let changed = zip(first, second).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(changed.isEmpty || changed == [1_006])
        #expect(first[1_003] != first[1_002], "the open comment and string carry over lines")
    }

    @Test("a 50,000-line Swift file lexes in linear time")
    func speed() {
        let file = Self.swiftFile(lines: 50_000)
        let lexer = SyntaxLexer(language: .swift)
        var count = 0
        let elapsed = threadTime {
            var state = LexerState.initial
            for line in file {
                let result = lexer.tokenize(line, from: state)
                count += result.tokens.count
                state = result.end
            }
        }
        print("lexed 50,000 Swift lines (\(file.reduce(0) { $0 + $1.utf8.count + 1 }) bytes, \(count) tokens) in \(elapsed)")
        #expect(elapsed < .seconds(5))
    }
}
