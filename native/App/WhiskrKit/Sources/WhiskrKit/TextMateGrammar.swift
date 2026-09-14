import Foundation
import Synchronization

// A TextMate grammar compiled into rules, as VS Code runs it. Translated from vscode-textmate's rule.ts,
// grammar/grammar.ts and grammar/grammarDependencies.ts (MIT, Copyright (c) Microsoft Corporation), so a
// grammar gives the scopes it gives in VS Code: the same rule kinds (`match`, `begin`/`end`,
// `begin`/`while`, include-only), includes (`$self`, `$base`, `#name`, `scope`, `scope#name`), captures
// (also with their own `patterns`), `name`/`contentName` made from captures ("$1", "${1:/downcase}"),
// back-references from `begin` in `end` and `while`, `applyEndPatternLast`, `\A`/`\G` anchors, and
// injections (the grammar's own and injection grammars').
//
// Rules are made once, all at once (every include followed, other grammars read through the provider),
// so a rule's number is the same in every `TextMateGrammar` made from the same files and a line's state
// from one thread is good on another. Expressions are compiled when first needed, by a `TextMateTokenizer`.

/// A grammar's rules, ready to tokenize with. Immutable: shared by every tokenizer of a language.
public final class TextMateGrammar: Sendable {
    public let scopeName: String
    let rules: [Rule]
    let rootRuleID: Int
    let injections: [Injection]
    /// The grammar's own word on what is code, a string or a comment (`tokenTypes`), by selector.
    private let tokenTypes: [(selector: ScopeSelector, context: TokenContext)]
    private let contexts = Mutex<[UInt32: TokenContext]>([:])

    struct Injection: Sendable {
        let selector: ScopeSelector.Matcher
        /// -1 "L:" (wins a tie with the grammar's own match), 0, 1 "R:".
        let priority: Int
        let ruleID: Int
    }

    /// Compiles `grammar`'s rules, reading the grammars it includes and those injected into it from
    /// `provider` (on the calling thread: make grammars off the main thread). `tokenTypes` is what the
    /// grammar's extension says about scopes whose names mislead (VS Code's `tokenTypes`).
    public init(_ grammar: RawGrammar, provider: (any GrammarProvider)? = nil, tokenTypes: [String: TokenContext] = [:]) {
        self.tokenTypes = tokenTypes.sorted { $0.key < $1.key }.map { (ScopeSelector($0.key), $0.value) }
        let factory = RuleFactory(root: grammar, provider: provider)
        let root = factory.compile(grammar.selfRule, factory.repository(for: grammar, base: grammar))
        var injections: [Injection] = []
        func collect(_ selector: String, _ rule: RawRule, _ owner: RawGrammar) {
            let parsed = ScopeSelector(selector)
            let id = factory.compile(rule, factory.repository(for: owner, base: grammar))
            for alternative in parsed.alternatives {
                injections.append(Injection(selector: alternative.matcher, priority: alternative.priority, ruleID: id))
            }
        }
        for (selector, rule) in grammar.injections { collect(selector, rule, grammar) }
        for scope in provider?.injections(into: grammar.scopeName) ?? [] {
            guard let injecting = factory.grammar(scope), let selector = injecting.injectionSelector else { continue }
            collect(selector, injecting.selfRule, injecting)
        }
        // By priority, keeping each priority's order.
        self.injections = injections.enumerated().sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }.map(\.element)
        scopeName = grammar.scopeName
        rootRuleID = root
        // Rule 0 is no rule (numbers start at 1, as in vscode-textmate).
        rules = factory.rules.enumerated().map { $0.element ?? Rule(id: $0.offset, name: nil, contentName: nil, kind: .includeOnly(patterns: [])) }
    }

    func rule(_ id: Int) -> Rule { rules[id] }

    /// Whether text in `scopes` is code, a string, a comment or a regular expression, as VS Code decides
    /// for bracket pairs and auto-closing: the innermost scope named "comment", "string" or "regex" (or
    /// "meta.embedded", code again) says, unless the grammar's `tokenTypes` say otherwise.
    public func context(of scopes: ScopeStack) -> TokenContext {
        if let known = contexts.withLock({ $0[scopes.id] }) { return known }
        let names = scopes.scopes
        var context = TokenContext.code
        for name in names {
            for part in name.split(separator: ".") {
                switch part {
                case "comment": context = .comment
                case "string": context = .string
                case "regex": context = .regex
                default: continue
                }
                break
            }
            if name.hasPrefix("meta.embedded") { context = .code }
        }
        for type in tokenTypes where type.selector.alternatives.contains(where: { $0.matcher.matches(names) }) { context = type.context }
        contexts.withLock { $0[scopes.id] = context }
        return context
    }
}

// MARK: Rules

/// An expression as a rule gives it, with what it needs at match time.
struct RegexSource: Sendable {
    static let endRuleID = -1
    static let whileRuleID = -2

    let source: String
    /// The rule a match of it means (`endRuleID` for a region's end, `whileRuleID` for its while).
    let ruleID: Int
    /// It uses `\A` or `\G`, so it is compiled four ways: each anchor kept, or made unmatchable (`￿`)
    /// where it cannot hold (`\A` off the first line, `\G` away from where the last match ended).
    let hasAnchor: Bool
    let hasBackReferences: Bool

    init(_ source: String, ruleID: Int) {
        // `\z` is "the very end"; Oniguruma's own also matches before a final "\n", which every line has.
        self.source = source.contains("\\z") ? Self.replacingEndAnchor(source) : source
        self.ruleID = ruleID
        hasAnchor = Self.hasAnchor(self.source)
        hasBackReferences = self.source.range(of: #"\\\d+"#, options: .regularExpression) != nil
    }

    private static func replacingEndAnchor(_ source: String) -> String {
        var result = ""
        var chars = source.makeIterator()
        while let c = chars.next() {
            if c == "\\", let next = chars.next() {
                if next == "z" { result += "$(?!\\n)(?<!\\n)" } else { result.append(c); result.append(next) }
            } else {
                result.append(c)
            }
        }
        return result
    }

    private static func hasAnchor(_ source: String) -> Bool {
        var chars = source.makeIterator()
        while let c = chars.next() {
            if c == "\\", let next = chars.next(), next == "A" || next == "G" { return true }
        }
        return false
    }

    /// The expression with `\A` and `\G` kept or switched off.
    func resolvingAnchors(allowA: Bool, allowG: Bool) -> String {
        guard hasAnchor else { return source }
        var result = ""
        var chars = source.makeIterator()
        while let c = chars.next() {
            result.append(c)
            guard c == "\\", let next = chars.next() else { continue }
            switch next {
            case "A": result.append(allowA ? "A" : "\u{FFFF}")
            case "G": result.append(allowG ? "G" : "\u{FFFF}")
            default: result.append(next)
            }
        }
        return result
    }

    /// `end`/`while` with each "\1" replaced by what the `begin` captured, escaped.
    func resolvingBackReferences(_ line: RegexLine, _ captures: [CaptureRange]) -> String {
        var result = ""
        var chars = Array(source)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\\", index + 1 < chars.count, chars[index + 1].isASCII, chars[index + 1].isNumber {
                var end = index + 1
                while end < chars.count, chars[end].isASCII, chars[end].isNumber { end += 1 }
                let number = Int(String(chars[(index + 1)..<end])) ?? 0
                if number < captures.count { result += Self.escaped(line.text(captures[number].start, captures[number].end)) }
                index = end
                continue
            }
            result.append(c)
            index += 1
        }
        chars.removeAll()
        return result
    }

    static func escaped(_ text: String) -> String {
        var result = ""
        for c in text {
            if "-\\{}*+?|^$.,[]()#".contains(c) || c.isWhitespace { result.append("\\") }
            result.append(c)
        }
        return result
    }
}

/// A rule's name or content name, made from captures when it says "$1" or "${1:/downcase}".
struct ScopeName: Sendable {
    let text: String
    let usesCaptures: Bool

    init?(_ text: String?) {
        guard let text, !text.isEmpty else { return nil }
        self.text = text
        usesCaptures = text.range(of: #"\$(\d+)|\$\{(\d+):/(downcase|upcase)\}"#, options: .regularExpression) != nil
    }

    func resolve(_ line: RegexLine?, _ captures: [CaptureRange]?) -> String {
        guard usesCaptures, let line, let captures else { return text }
        let pattern = /\$(\d+)|\$\{(\d+):\/(downcase|upcase)\}/
        return text.replacing(pattern) { match in
            let number = Int(match.output.1 ?? match.output.2 ?? "") ?? -1
            guard number >= 0, number < captures.count else { return String(match.output.0) }
            var value = Substring(line.text(captures[number].start, captures[number].end))
            // Leading dots would make the scope's selector invalid.
            while value.first == "." { value = value.dropFirst() }
            switch match.output.3 {
            case "downcase": return value.lowercased()
            case "upcase": return value.uppercased()
            default: return String(value)
            }
        }
    }
}

final class Rule: Sendable {
    enum Kind: Sendable {
        /// A capture's name; with patterns of its own, the captured text is tokenized again with rule
        /// `retokenize`.
        case capture(retokenize: Int?)
        case match(RegexSource, captures: [Rule?])
        case includeOnly(patterns: [Int])
        case beginEnd(begin: RegexSource, beginCaptures: [Rule?], end: RegexSource, endCaptures: [Rule?], applyEndPatternLast: Bool, patterns: [Int])
        case beginWhile(begin: RegexSource, beginCaptures: [Rule?], while: RegexSource, whileCaptures: [Rule?], patterns: [Int])
    }

    let id: Int
    let name: ScopeName?
    let contentName: ScopeName?
    let kind: Kind
    /// Some of its patterns were includes that found nothing.
    let hasMissingPatterns: Bool

    init(id: Int, name: String?, contentName: String?, kind: Kind, hasMissingPatterns: Bool = false) {
        self.id = id
        self.name = ScopeName(name)
        self.contentName = ScopeName(contentName)
        self.kind = kind
        self.hasMissingPatterns = hasMissingPatterns
    }

    var patterns: [Int]? {
        switch kind {
        case .includeOnly(let patterns), .beginEnd(_, _, _, _, _, let patterns), .beginWhile(_, _, _, _, let patterns): patterns
        default: nil
        }
    }
}

/// Where a rule's includes are looked up: its grammar's repository (with the repositories of the rules
/// around it), `$self` (its grammar) and `$base` (the grammar being tokenized).
private struct Repository {
    var rules: [String: RawRule]
    var selfRule: RawRule
    var baseRule: RawRule

    subscript(name: String) -> RawRule? {
        switch name {
        case "$self": selfRule
        case "$base": baseRule
        default: rules[name]
        }
    }
}

/// Turns raw rules into numbered rules (vscode-textmate's RuleFactory).
private final class RuleFactory {
    var rules: [Rule?] = [nil]
    private var ids: [ObjectIdentifier: Int] = [:]
    private let root: RawGrammar
    private let provider: (any GrammarProvider)?
    private var grammars: [String: RawGrammar] = [:]

    init(root: RawGrammar, provider: (any GrammarProvider)?) {
        self.root = root
        self.provider = provider
        grammars[root.scopeName] = root
    }

    func repository(for grammar: RawGrammar, base: RawGrammar) -> Repository {
        Repository(rules: grammar.repository, selfRule: grammar.selfRule, baseRule: base.selfRule)
    }

    func grammar(_ scopeName: String) -> RawGrammar? {
        if let known = grammars[scopeName] { return known }
        guard let found = provider?.grammar(scopeName: scopeName) else { return nil }
        grammars[scopeName] = found
        return found
    }

    /// The number of `raw`'s rule, making it (and everything it includes) the first time.
    func compile(_ raw: RawRule, _ repository: Repository) -> Int {
        if let id = ids[ObjectIdentifier(raw)] { return id }
        let id = rules.count
        rules.append(nil)
        ids[ObjectIdentifier(raw)] = id

        let rule: Rule
        if let match = raw.match {
            rule = Rule(id: id, name: raw.name, contentName: nil,
                        kind: .match(RegexSource(match, ruleID: id), captures: captures(raw.captures, repository)))
        } else if let begin = raw.begin {
            let (patterns, missing) = compilePatterns(raw.patterns, repository)
            if let whilePattern = raw.while {
                rule = Rule(id: id, name: raw.name, contentName: raw.contentName,
                            kind: .beginWhile(begin: RegexSource(begin, ruleID: id), beginCaptures: captures(raw.beginCaptures ?? raw.captures, repository),
                                              while: RegexSource(whilePattern, ruleID: RegexSource.whileRuleID), whileCaptures: captures(raw.whileCaptures ?? raw.captures, repository),
                                              patterns: patterns),
                            hasMissingPatterns: missing)
            } else {
                let end = raw.end.flatMap { $0.isEmpty ? nil : $0 } ?? "\u{FFFF}"
                rule = Rule(id: id, name: raw.name, contentName: raw.contentName,
                            kind: .beginEnd(begin: RegexSource(begin, ruleID: id), beginCaptures: captures(raw.beginCaptures ?? raw.captures, repository),
                                            end: RegexSource(end, ruleID: RegexSource.endRuleID), endCaptures: captures(raw.endCaptures ?? raw.captures, repository),
                                            applyEndPatternLast: raw.applyEndPatternLast, patterns: patterns),
                            hasMissingPatterns: missing)
            }
        } else {
            var inner = repository
            if let own = raw.repository { inner.rules.merge(own) { _, new in new } }
            let list = raw.patterns ?? raw.include.map { [RawRule(include: $0)] }
            let (patterns, missing) = compilePatterns(list, inner)
            rule = Rule(id: id, name: raw.name, contentName: raw.contentName, kind: .includeOnly(patterns: patterns), hasMissingPatterns: missing)
        }
        rules[id] = rule
        return id
    }

    private func captures(_ captures: [Int: RawRule]?, _ repository: Repository) -> [Rule?] {
        guard let captures, let highest = captures.keys.max(), highest >= 0 else { return [] }
        var result: [Rule?] = Array(repeating: nil, count: highest + 1)
        for (index, raw) in captures.sorted(by: { $0.key < $1.key }) where index >= 0 {
            let retokenize = raw.patterns != nil ? compile(raw, repository) : nil
            let id = rules.count
            let rule = Rule(id: id, name: raw.name, contentName: raw.contentName, kind: .capture(retokenize: retokenize))
            rules.append(rule)
            result[index] = rule
        }
        return result
    }

    private func compilePatterns(_ patterns: [RawRule]?, _ repository: Repository) -> (patterns: [Int], missing: Bool) {
        guard let patterns else { return ([], false) }
        var result: [Int] = []
        for pattern in patterns {
            var id: Int?
            if let include = pattern.include {
                if include == "$base" || include == "$self" {
                    id = repository[include].map { compile($0, repository) }
                } else if include.hasPrefix("#") {
                    id = repository[String(include.dropFirst())].map { compile($0, repository) }
                } else {
                    let parts = include.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                    let scope = String(parts[0])
                    if let external = grammar(scope) {
                        let externalRepository = Repository(rules: external.repository, selfRule: external.selfRule, baseRule: repository.baseRule)
                        if parts.count == 2 {
                            id = external.repository[String(parts[1])].map { compile($0, externalRepository) }
                        } else {
                            id = compile(external.selfRule, externalRepository)
                        }
                    }
                }
            } else {
                id = compile(pattern, repository)
            }
            guard let id else { continue }
            // A rule whose patterns were all missing includes is left out entirely.
            if let rule = rules[id], rule.hasMissingPatterns, rule.patterns?.isEmpty == true { continue }
            result.append(id)
        }
        return (result, result.count != patterns.count)
    }
}
