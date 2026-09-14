import Foundation
import Testing
@testable import WhiskrKit

// The TextMate engine against VS Code's own expected results (`vscode-colorize-tests`: each token's text,
// scopes and colour in the built-in themes), and its pieces on their own.

private let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")

/// Grammars written in a test, by scope.
private struct TestGrammars: GrammarProvider {
    var grammars: [String: RawGrammar]
    var injecting: [String: [String]] = [:]
    func grammar(scopeName: String) -> RawGrammar? { grammars[scopeName] }
    func injections(into scopeName: String) -> [String] { injecting[scopeName] ?? [] }
}

private func grammar(_ json: String) throws -> RawGrammar {
    try RawGrammar(data: Data(json.utf8))
}

/// Each line's tokens as "text:innermost scope" (scopes past the grammar's own), for short expectations.
private func tokenize(_ lines: [String], _ grammar: TextMateGrammar) -> [[String]] {
    let tokenizer = TextMateTokenizer(grammar: grammar)
    var state: StateStack?
    return lines.map { line in
        let result = tokenizer.tokenize(line, state: state)
        state = result.end
        let units = Array(line.utf16)
        return result.tokens.map { token in
            let scopes = token.scopes.scopes.dropFirst().joined(separator: " ")
            return String(decoding: units[token.range], as: UTF16.self) + ":" + scopes
        }
    }
}

@Suite("TextMate grammars against VS Code's colorize tests")
struct ColorizeTests {
    struct Expected: Decodable {
        var scopes: [String]
        var colors: [String]
        /// [text, scope index, colour index per theme …]
        var tokens: [[Value]]

        enum Value: Decodable {
            case text(String)
            case index(Int)
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) { self = .index(number) } else { self = .text(try container.decode(String.self)) }
            }
            var text: String { if case .text(let text) = self { text } else { "" } }
            var index: Int { if case .index(let index) = self { index } else { -1 } }
        }
    }

    static let themes = ["dark_plus", "light_plus", "dark_modern", "light_modern"]

    /// The themes as the app imports them (`VSCodeThemeConversion`), so the whole path from a theme file
    /// to a token's colour is the one checked.
    static func imported(_ name: String) throws -> SyntaxTheme {
        let url = fixtures.appendingPathComponent("Themes/\(name).json")
        let document = try VSCodeThemeDocument.read(url, root: url.deletingLastPathComponent())
        let kind = VSCodeThemeConversion.kind(of: document, declared: nil)
        return SyntaxTheme(variant: VSCodeThemeConversion(document, kind: kind).variant)
    }

    @Test("every fixture of a bundled language gets VS Code's scopes and, in imported built-in themes, its colours, token for token")
    func fixturesMatch() throws {
        let registry = LanguageRegistry.shared
        let themes = try Self.themes.map(Self.imported)
        let folder = fixtures.appendingPathComponent("Colorize")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("fixtures").path).sorted()
        #expect(names.count >= 80)
        var grammars: [String: TextMateGrammar] = [:]
        for name in names {
            let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: folder.appendingPathComponent("results/\(name).json")))
            let language = registry.detect(fileName: name)
            let scope = try #require(language.scopeName, "\(name): no grammar")
            let grammar = try grammars[scope] ?? TextMateGrammar(#require(registry.grammar(scopeName: scope)), provider: registry)
            grammars[scope] = grammar
            let tokenizer = TextMateTokenizer(grammar: grammar)
            let text = try String(contentsOf: folder.appendingPathComponent("fixtures/\(name)"), encoding: .utf8)
            // As VS Code's test: tokens joined while their scopes are the same, line by line.
            var actual: [(text: String, scopes: ScopeStack)] = []
            var state: StateStack?
            for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
                let result = tokenizer.tokenize(line, state: state)
                state = result.end
                let units = Array(line.utf16)
                var previous: ScopeStack?
                for token in result.tokens {
                    let piece = String(decoding: units[token.range], as: UTF16.self)
                    if token.scopes == previous { actual[actual.count - 1].text += piece } else { actual.append((piece, token.scopes)) }
                    previous = token.scopes
                }
            }
            let wanted = expected.tokens.filter { !$0[0].text.isEmpty }
            #expect(actual.count == wanted.count, "\(name): \(actual.count) tokens, VS Code has \(wanted.count)")
            for (index, (token, want)) in zip(actual, wanted).enumerated() {
                let scopes = expected.scopes[want[1].index]
                guard token.text == want[0].text, token.scopes.description == scopes else {
                    Issue.record("\(name) token \(index): \"\(token.text)\" \(token.scopes), VS Code has \"\(want[0].text)\" \(scopes)")
                    break
                }
                for (themeIndex, theme) in themes.enumerated() {
                    let color = expected.colors[want[2 + themeIndex].index]
                    guard !color.isEmpty else { continue }
                    #expect(theme.style(for: token.scopes).foreground.hex.uppercased() == String(color.prefix(7)), "\(name) \"\(token.text)\" \(Self.themes[themeIndex])")
                }
            }
        }
    }
}

@Suite("TextMate engine")
struct TextMateEngineTests {
    @Test("matches, regions with captures, back-references in the end, and names made from captures")
    func rules() throws {
        let raw = try grammar(#"""
        { "scopeName": "source.t", "patterns": [
            { "match": "\\b(let|var)\\b", "name": "keyword.${1:/upcase}.t" },
            { "begin": "<<(\\w+)", "end": "^\\1$", "name": "string.heredoc.t", "beginCaptures": { "1": { "name": "entity.name.$1.t" } } },
            { "begin": "\"", "end": "\"", "name": "string.quoted.t", "patterns": [ { "include": "#escape" } ] },
            { "match": "(\\w+)\\((\\w+)\\)", "captures": { "1": { "name": "entity.name.function.t" }, "2": { "patterns": [ { "include": "$self" } ] } } }
          ],
          "repository": { "escape": { "match": "\\\\.", "name": "constant.character.escape.t" } } }
        """#)
        let tokens = tokenize(["let x = \"a\\nb\"", "s = <<EOF", "let", "EOF", "f(var)"], TextMateGrammar(raw))
        #expect(tokens[0] == ["let:keyword.LET.t", " x = :", "\"a:string.quoted.t", "\\n:string.quoted.t constant.character.escape.t", "b\":string.quoted.t"])
        #expect(tokens[1] == ["s = :", "<<:string.heredoc.t", "EOF:string.heredoc.t entity.name.EOF.t"])
        #expect(tokens[2] == ["let:string.heredoc.t"])
        #expect(tokens[3] == ["EOF:string.heredoc.t"])
        #expect(tokens[4] == ["f:entity.name.function.t", "(:", "var:keyword.VAR.t", "):"])
    }

    @Test("begin/while regions end on the first line that does not continue them")
    func whileRegions() throws {
        let raw = try grammar(#"""
        { "scopeName": "text.q", "patterns": [ { "begin": "^> ", "while": "^> ", "name": "markup.quote.q" } ] }
        """#)
        let tokens = tokenize(["> one", "> two", "three"], TextMateGrammar(raw))
        #expect(tokens[0] == ["> one:markup.quote.q"])
        #expect(tokens[1] == ["> two:markup.quote.q"])
        #expect(tokens[2] == ["three:"])
    }

    @Test("includes reach other grammars and their repositories; injections apply where their selector matches")
    func includesAndInjections() throws {
        let host = try grammar(#"""
        { "scopeName": "source.host", "patterns": [
            { "begin": "```", "end": "```", "name": "meta.embedded.host", "patterns": [ { "include": "source.guest" } ] },
            { "begin": "#", "end": "$", "name": "comment.line.host" } ] }
        """#)
        let guest = try grammar(#"""
        { "scopeName": "source.guest", "patterns": [ { "include": "source.guest#word" } ],
          "repository": { "word": { "match": "\\bfn\\b", "name": "keyword.guest" } } }
        """#)
        let todo = try grammar(#"""
        { "scopeName": "todo.injection", "injectionSelector": "L:comment", "patterns": [ { "match": "TODO", "name": "keyword.todo" } ] }
        """#)
        let provider = TestGrammars(grammars: ["source.guest": guest, "todo.injection": todo], injecting: ["source.host": ["todo.injection"]])
        let tokens = tokenize(["```fn```", "# TODO fn"], TextMateGrammar(host, provider: provider))
        #expect(tokens[0] == ["```:meta.embedded.host", "fn:meta.embedded.host keyword.guest", "```:meta.embedded.host"])
        #expect(tokens[1] == ["# :comment.line.host", "TODO:comment.line.host keyword.todo", " fn:comment.line.host"])
    }

    @Test("injections of the same priority are tried in the order the file lists them, in JSON and in a property list")
    func injectionOrder() throws {
        // Both match "x" at the same place; the first listed wins, as in VS Code. Sorted, "z…" would come last.
        let json = try grammar(#"""
        { "scopeName": "source.o", "patterns": [ { "begin": "#", "end": "$", "name": "comment.o" } ],
          "injections": {
            "z.selector, comment.o": { "patterns": [ { "match": "x", "name": "first.o" } ] },
            "a.selector, comment.o": { "patterns": [ { "match": "x", "name": "second.o", "captures": { "0": { "patterns": [] } } } ] } } }
        """#)
        #expect(json.injections.map(\.selector) == ["z.selector, comment.o", "a.selector, comment.o"])
        #expect(tokenize(["#x"], TextMateGrammar(json))[0] == ["#:comment.o", "x:comment.o first.o"])
        let plist = try RawGrammar(data: Data(#"""
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>scopeName</key><string>source.p</string>
          <key>repository</key><dict><key>b</key><dict><key>match</key><string>b</string></dict></dict>
          <key>injections</key><dict>
            <key>z.selector</key><dict><key>patterns</key><array/></dict>
            <key>a.selector</key><dict><key>patterns</key><array/></dict>
          </dict>
          <key>patterns</key><array/>
        </dict></plist>
        """#.utf8))
        #expect(plist.injections.map(\.selector) == ["z.selector", "a.selector"])
    }

    @Test("a grammar that would loop without advancing stops the line instead")
    func endlessLoops() throws {
        let raw = try grammar(#"""
        { "scopeName": "source.loop", "patterns": [
            { "begin": "(?=x)", "end": "(?=x)", "name": "meta.empty.loop" },
            { "match": "(?=y)", "name": "meta.nothing.loop" } ] }
        """#)
        let tokenizer = TextMateTokenizer(grammar: TextMateGrammar(raw))
        let first = tokenizer.tokenize("ax", state: nil)
        let second = tokenizer.tokenize("ay", state: first.end)
        #expect(first.tokens.map(\.range) == [0..<1, 1..<2])
        #expect(second.tokens.last?.range.upperBound == 2)
    }

    @Test("a line past the length limit is left plain and the state carries over")
    func longLines() throws {
        let raw = try grammar(#"""
        { "scopeName": "source.c2", "patterns": [ { "begin": "/\\*", "end": "\\*/", "name": "comment.block.c2" }, { "match": "\\d+", "name": "constant.numeric.c2" } ] }
        """#)
        let tokenizer = TextMateTokenizer(grammar: TextMateGrammar(raw))
        let open = tokenizer.tokenize("/* open", state: nil)
        let long = tokenizer.tokenize(String(repeating: "1 */ ", count: 5_000), state: open.end)
        #expect(long.stoppedEarly)
        #expect(long.tokens.count == 1 && long.tokens[0].range == 0..<25_000)
        #expect(long.end == open.end)
        let after = tokenizer.tokenize("still */ 2", state: long.end)
        #expect(after.tokens.first?.scopes.scope == "comment.block.c2")
    }

    @Test("an expression with catastrophic backtracking gives up in milliseconds, and a slow line stops at its time limit")
    func pathologicalExpressions() throws {
        let raw = try grammar(#"""
        { "scopeName": "source.slow", "patterns": [ { "match": "(a+)+b", "name": "invalid.slow" }, { "match": "a", "name": "constant.a" } ] }
        """#)
        let tokenizer = TextMateTokenizer(grammar: TextMateGrammar(raw))
        let line = String(repeating: "a", count: 3_000)
        let start = DispatchTime.now().uptimeNanoseconds
        let result = tokenizer.tokenize(line, state: nil, timeLimit: 0.05)
        let took = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        #expect(took < 2_000, "took \(took) ms")
        #expect(result.tokens.last?.range.upperBound == 3_000)
        // A line that runs out of time keeps what it reached; the next line starts as this one did.
        let stopped = tokenizer.tokenize("aaa", state: nil, timeLimit: 0)
        #expect(stopped.stoppedEarly)
        #expect(stopped.tokens.map(\.range) == [0..<3])
        #expect(stopped.end == tokenizer.initialState)
    }

    @Test("lines beyond ASCII get UTF-16 offsets")
    func unicode() throws {
        let raw = try grammar(#"""
        { "scopeName": "source.u", "patterns": [ { "match": "\"[^\"]*\"", "name": "string.u" }, { "match": "\\bx\\b", "name": "variable.u" } ] }
        """#)
        let tokens = tokenize(["\"日本🐈\" x"], TextMateGrammar(raw))
        #expect(tokens[0] == ["\"日本🐈\":string.u", " :", "x:variable.u"])
    }
}

@Suite("Scope selectors")
struct ScopeSelectorTests {
    private func matches(_ selector: String, _ scopes: String) -> Bool {
        ScopeSelector(selector).alternatives.contains { $0.matcher.matches(scopes.split(separator: " ").map(String.init)) }
    }

    @Test("names match by whole dotted parts, in order, with exclusions, groups and alternatives")
    func matching() {
        #expect(matches("string", "source.js string.quoted.double.js"))
        #expect(matches("source.js string.quoted", "source.js meta.x string.quoted.double.js"))
        #expect(!matches("str", "source.js string.quoted.js"))
        #expect(!matches("string source.js", "source.js string.quoted.js"))
        #expect(matches("source.js - comment", "source.js string.js"))
        #expect(!matches("source.js - comment", "source.js comment.line.js"))
        #expect(matches("text.html (meta.paragraph | markup.heading)", "text.html markup.heading.md"))
        #expect(matches("comment, string", "source.c string.quoted.c"))
    }

    @Test("L: and R: set an injection's priority")
    func priorities() {
        #expect(ScopeSelector("L:comment.line").alternatives.map(\.priority) == [-1])
        #expect(ScopeSelector("R:string, source.ts").alternatives.map(\.priority) == [1, 0])
    }
}

@Suite("Token colours from scope rules")
struct SyntaxThemeTests {
    private let red = RGBColor(0xFF0000), green = RGBColor(0x00FF00), blue = RGBColor(0x0000FF), plain = RGBColor(0xCCCCCC)

    private func color(_ rules: [TokenColorRule], _ scopes: String) -> RGBColor {
        let theme = SyntaxTheme(rules: rules, foreground: plain, background: .black)
        return theme.style(for: ScopeStack(scopes.split(separator: " ").map(String.init))!).foreground
    }

    @Test("the deepest dotted match wins, then the more specific parents, then the later rule")
    func specificity() {
        let rules = [
            TokenColorRule(scopes: ["string"], foreground: red),
            TokenColorRule(scopes: ["string.quoted"], foreground: green),
            TokenColorRule(scopes: ["meta.embedded string"], foreground: blue),
        ]
        #expect(color(rules, "source string.quoted.double") == green)
        #expect(color(rules, "source string.unquoted") == red)
        #expect(color(rules, "source meta.embedded string.unquoted") == blue)
        #expect(color(rules, "source meta.embedded string.quoted") == green)
        #expect(color(rules, "source keyword") == plain)
        #expect(color(rules + [TokenColorRule(scopes: ["string.quoted"], foreground: blue)], "source string.quoted.x") == blue)
    }

    @Test("parent scopes may require a direct parent, and outer scopes' colours hold inside unless overridden")
    func parents() {
        let rules = [
            TokenColorRule(scopes: ["a > b"], foreground: red),
            TokenColorRule(scopes: ["comment"], foreground: green, fontStyle: .italic),
            TokenColorRule(scopes: ["comment.todo"], fontStyle: []),
        ]
        #expect(color(rules, "x a b") == red)
        #expect(color(rules, "x a c b") == plain)
        let theme = SyntaxTheme(rules: rules, foreground: plain, background: .black)
        let todo = theme.style(for: ScopeStack(["x", "comment.line", "comment.todo"])!)
        #expect(todo.foreground == green)
        #expect(todo.fontStyle == [])
        #expect(theme.style(for: ScopeStack(["x", "comment.line"])!).fontStyle == .italic)
    }

    @Test("built-in themes colour code from their terminal palette, readable in light and dark")
    func builtInThemes() {
        for builtIn in BuiltInThemes.all {
            for variant in [builtIn.light, builtIn.dark].compactMap({ $0 }) {
                let background = variant.terminal.background
                let rules = SyntaxTheme.rules(for: variant.terminal)
                for rule in rules {
                    if let color = rule.foreground { #expect(color.contrast(with: background) >= 2.2, "\(builtIn.name) \(rule.scopes)") }
                }
                let theme = SyntaxTheme(rules: rules, foreground: variant.terminal.foreground, background: background)
                func style(_ scopes: String...) -> TokenStyle { theme.style(for: ScopeStack(["source.x"] + scopes)!) }
                #expect(style("comment.line.x").fontStyle.contains(.italic))
                #expect(style("keyword.control.x").foreground != style("string.quoted.x").foreground)
                #expect(style("keyword.operator.x").foreground == variant.terminal.foreground)
                #expect(style("markup.heading.x").fontStyle.contains(.bold))
            }
        }
    }

    @Test("scope stacks are kept once: the same scopes are the same stack")
    func interning() {
        let a = ScopeStack(["source.swift", "string.quoted"])!
        let b = ScopeStack.root("source.swift").pushing("string.quoted")
        #expect(a == b)
        #expect(a.scopes == ["source.swift", "string.quoted"])
        #expect(a.parent == ScopeStack.root("source.swift"))
    }
}

@Suite("Incremental syntax states")
struct SyntaxStatesTests {
    private static let swift = TextMateGrammar(LanguageRegistry.shared.grammar(scopeName: "source.swift")!, provider: LanguageRegistry.shared)

    private func units(_ lines: [String]) -> (Int) -> [UInt16] {
        { Array(lines[$0].utf16) + [0x0A] }
    }

    /// Every line's tokens after a full pass from scratch.
    private func fresh(_ lines: [String]) -> [[SyntaxToken]] {
        var states = SyntaxStates(lineCount: lines.count)
        states.advance(using: TextMateTokenizer(grammar: Self.swift), units: units(lines))
        return (0..<lines.count).map { states.tokens(line: $0) ?? [] }
    }

    private func all(_ states: SyntaxStates) -> [[SyntaxToken]] {
        (0..<states.lineCount).map { states.tokens(line: $0) ?? [] }
    }

    @Test("an edit inside a function re-tokenizes one line; opening a comment the rest; closing it comes back to the old states")
    func edits() {
        var source = (0..<300).map { "func f\($0)() {\n    let x = \"s\" // c\n}" }.joined(separator: "\n").components(separatedBy: "\n")
        let tokenizer = TextMateTokenizer(grammar: Self.swift)
        var states = SyntaxStates(lineCount: source.count)
        #expect(states.advance(using: tokenizer, units: units(source)) == 0..<source.count)
        #expect(states.isComplete)

        source[1] = "    let x = \"st\" // c"
        states.replaceLines(1..<2, with: 1)
        #expect(states.advance(using: tokenizer, units: units(source)) == 1..<2)
        #expect(states.isComplete)
        #expect(all(states) == fresh(source))

        source[1] = "    /* open"
        states.replaceLines(1..<2, with: 1)
        let opened = states.advance(using: tokenizer, lines: 50, units: units(source))
        #expect(opened == 1..<51)
        #expect(!states.isComplete)
        // The old tokens of the lines not reached are still there.
        #expect(states.tokens(line: 200) != nil)

        source[1] = "    let x = 1"
        states.replaceLines(1..<2, with: 1)
        let closed = states.advance(using: tokenizer, units: units(source))
        #expect(closed.upperBound < source.count)
        #expect(states.isComplete)
        #expect(all(states) == fresh(source))
    }

    @Test("inserting and removing lines keeps the states after them, also with edits before an earlier one settled")
    func structural() {
        var source = (0..<200).map { "let v\($0) = \"x\"" }
        let tokenizer = TextMateTokenizer(grammar: Self.swift)
        var states = SyntaxStates(lineCount: source.count)
        states.advance(using: tokenizer, units: units(source))
        source.insert(contentsOf: ["// one", "// two"], at: 10)
        states.replaceLines(10..<10, with: 2)
        #expect(states.lineCount == source.count)
        #expect(states.advance(using: tokenizer, units: units(source)) == 10..<12)
        #expect(states.isComplete)

        // A string opened at 5 and not settled, then lines removed above it, then the string closed.
        source[5] = "let s = \"\"\""
        states.replaceLines(5..<6, with: 1)
        states.advance(using: tokenizer, lines: 3, units: units(source))
        source.removeSubrange(1..<3)
        states.replaceLines(1..<3, with: 0)
        source[3] = "let v5 = \"x\""
        states.replaceLines(3..<4, with: 1)
        states.advance(using: tokenizer, units: units(source))
        #expect(states.lineCount == source.count)
        #expect(all(states) == fresh(source))
    }

    @Test("work done on a copy is taken in by the value it was copied from")
    func progress() {
        let source = (0..<500).map { "let v\($0) = [\($0), \"x\"]" }
        var main = SyntaxStates(lineCount: source.count)
        var copy = main
        let tokenizer = TextMateTokenizer(grammar: Self.swift)
        let first = copy.advance(using: tokenizer, lines: 100, units: units(source))
        main.apply(copy.progress(of: first))
        let rest = copy.advance(using: tokenizer, units: units(source))
        main.apply(copy.progress(of: rest))
        #expect(main.isComplete)
        #expect(all(main) == fresh(source))
    }

    @Test("a background pass delivers every line, in order, and a shown far part first from a guessed start")
    func background() async throws {
        let source = (0..<3_000).map { $0 % 10 == 0 ? "func f\($0)() {" : $0 % 10 == 9 ? "}" : "    let v = \($0) // n" }
        let text = TextSnapshot(source.joined(separator: "\n") as NSString, lines: LineIndex(source.joined(separator: "\n")))
        let deliveries = AsyncStream<BackgroundTokenizer.Delivery>.makeStream()
        let worker = BackgroundTokenizer(tokenizer: TextMateTokenizer(grammar: Self.swift)) { deliveries.continuation.yield($0) }
        var states = SyntaxStates(lineCount: source.count)
        worker.update(generation: 1, states: states, text: text)
        worker.show(generation: 1, lines: 2_800..<2_840)
        var provisional = false
        for await delivery in deliveries.stream {
            switch delivery {
            case .progress(let generation, let progress):
                #expect(generation == 1)
                states.apply(progress)
            case .provisional(_, let lines, let tokens):
                provisional = true
                #expect(lines == 2_800..<2_840 && tokens.count == 40)
                _ = states.takeProvisional(tokens, from: lines.lowerBound)
            }
            if states.isComplete { break }
        }
        worker.stop()
        #expect(provisional)
        #expect(all(states) == fresh(source))
    }
}
