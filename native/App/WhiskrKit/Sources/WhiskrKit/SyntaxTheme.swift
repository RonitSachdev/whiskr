import Foundation
import Synchronization

// How code is coloured: a theme's TextMate scope rules (`tokenColors`) applied to a token's scope stack,
// exactly as VS Code applies them. Translated from vscode-textmate's theme.ts (MIT, Copyright (c) Microsoft
// Corporation): rules sorted into a trie by their last scope; for each scope of a stack, the most specific
// rule matching it (the deepest dotted match, then the most specific parent scopes, then the later rule)
// sets what it says, over what the scopes outside it set.

/// What a token looks like.
public struct TokenStyle: Hashable, Sendable {
    public var foreground: RGBColor
    /// nil: the editor's own background.
    public var background: RGBColor?
    public var fontStyle: FontStyle

    public init(foreground: RGBColor, background: RGBColor? = nil, fontStyle: FontStyle = []) {
        self.foreground = foreground
        self.background = background
        self.fontStyle = fontStyle
    }
}

/// A theme's token colours, ready to answer "how does this scope stack look". Each stack is worked out
/// once and kept.
public final class SyntaxTheme: Sendable {
    public let defaultStyle: TokenStyle
    private let defaultBackground: RGBColor
    private let root: TrieElement
    private let cache = Mutex<[UInt32: TokenStyle]>([:])

    /// `rules` in the theme's order; `foreground` and `background` are the editor's (VS Code's
    /// `editor.foreground` and `editor.background`), what a token no rule matches gets. Rules without a
    /// scope are left out, as VS Code does.
    public init(rules: [TokenColorRule], foreground: RGBColor, background: RGBColor) {
        defaultStyle = TokenStyle(foreground: foreground)
        defaultBackground = background
        var parsed: [ParsedRule] = []
        for (index, rule) in rules.enumerated() {
            for selector in rule.scopes {
                let segments = selector.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
                guard let scope = segments.last else { continue }
                parsed.append(ParsedRule(scope: scope, parentScopes: segments.count > 1 ? Array(segments.dropLast().reversed()) : nil, index: index,
                                         fontStyle: rule.fontStyle, foreground: rule.foreground, background: rule.background))
            }
        }
        parsed.sort { a, b in
            if a.scope != b.scope { return a.scope.utf16.lexicographicallyPrecedes(b.scope.utf16) }
            let order = Self.compare(a.parentScopes, b.parentScopes)
            if order != 0 { return order < 0 }
            return a.index < b.index
        }
        let root = TrieElement(main: TrieRule(scopeDepth: 0, parentScopes: [], fontStyle: nil, foreground: nil, background: nil))
        for rule in parsed {
            root.insert(scopeDepth: 0, scope: rule.scope[...], parentScopes: rule.parentScopes, fontStyle: rule.fontStyle, foreground: rule.foreground, background: rule.background)
        }
        self.root = root
    }

    /// The style of text in `scopes`.
    public func style(for scopes: ScopeStack) -> TokenStyle {
        if let known = cache.withLock({ $0[scopes.id] }) { return known }
        let names = scopes.scopes
        var style = defaultStyle
        var styles: [TokenStyle] = []
        styles.reserveCapacity(names.count)
        for depth in names.indices {
            if let rule = match(names, depth) {
                if let fontStyle = rule.fontStyle { style.fontStyle = fontStyle }
                if let foreground = rule.foreground { style.foreground = foreground }
                if let background = rule.background { style.background = background == defaultBackground ? nil : background }
            }
            styles.append(style)
        }
        // Every stack on the way is kept too: they are the parents of this one's neighbours.
        cache.withLock { cache in
            var stack: ScopeStack? = scopes
            for style in styles.reversed() {
                guard let current = stack else { break }
                cache[current.id] = style
                stack = current.parent
            }
        }
        return style
    }

    /// The rule for the scope at `depth` of `names`, given the scopes outside it.
    private func match(_ names: [String], _ depth: Int) -> TrieRule? {
        let candidates = root.match(names[depth][...])
        return candidates.first { Self.parentScopesMatch(names, below: depth, $0.parentScopes) }
    }

    /// Each parent scope of a rule (deepest first; "> x" for a direct parent) is found outside the scope,
    /// in order.
    private static func parentScopesMatch(_ names: [String], below depth: Int, _ parentScopes: [String]) -> Bool {
        guard !parentScopes.isEmpty else { return true }
        var position = depth - 1
        var index = 0
        while index < parentScopes.count {
            var pattern = parentScopes[index]
            var mustMatch = false
            if pattern == ">" {
                guard index != parentScopes.count - 1 else { return false }
                index += 1
                pattern = parentScopes[index]
                mustMatch = true
            }
            while position >= 0 {
                if ScopeSelector.scopeMatches(names[position], pattern) { break }
                if mustMatch { return false }
                position -= 1
            }
            guard position >= 0 else { return false }
            position -= 1
            index += 1
        }
        return true
    }

    static func compare(_ a: [String]?, _ b: [String]?) -> Int {
        switch (a, b) {
        case (nil, nil): return 0
        case (nil, _): return -1
        case (_, nil): return 1
        case (let a?, let b?):
            guard a.count == b.count else { return a.count - b.count }
            for (x, y) in zip(a, b) where x != y { return x.utf16.lexicographicallyPrecedes(y.utf16) ? -1 : 1 }
            return 0
        }
    }

    private struct ParsedRule {
        var scope: String
        var parentScopes: [String]?
        var index: Int
        var fontStyle: FontStyle?
        var foreground: RGBColor?
        var background: RGBColor?
    }

    struct TrieRule: Sendable {
        var scopeDepth: Int
        var parentScopes: [String]
        var fontStyle: FontStyle?
        var foreground: RGBColor?
        var background: RGBColor?

        mutating func overwrite(scopeDepth: Int, fontStyle: FontStyle?, foreground: RGBColor?, background: RGBColor?) {
            self.scopeDepth = max(self.scopeDepth, scopeDepth)
            if let fontStyle { self.fontStyle = fontStyle }
            if let foreground { self.foreground = foreground }
            if let background { self.background = background }
        }
    }

    /// One dotted part of a scope ("string", then "quoted", …), with the rules for scopes ending here.
    final class TrieElement: @unchecked Sendable {
        // Built in `SyntaxTheme.init`, then only read (its match results are kept behind `matches`'s lock).
        private var main: TrieRule
        private var withParentScopes: [TrieRule]
        private var children: [Substring: TrieElement] = [:]
        private let matches = Mutex<[Substring: [TrieRule]]>([:])

        init(main: TrieRule, withParentScopes: [TrieRule] = []) {
            self.main = main
            self.withParentScopes = withParentScopes
        }

        /// The rules that may apply to `scope`, most specific first.
        func match(_ scope: Substring) -> [TrieRule] {
            if let known = matches.withLock({ $0[scope] }) { return known }
            let found = find(scope)
            matches.withLock { $0[scope] = found }
            return found
        }

        private func find(_ scope: Substring) -> [TrieRule] {
            if !scope.isEmpty {
                let dot = scope.firstIndex(of: ".")
                let head = dot.map { scope[..<$0] } ?? scope
                let tail = dot.map { scope[scope.index(after: $0)...] } ?? ""
                if let child = children[head] { return child.find(tail) }
            }
            return (withParentScopes + [main]).sorted(by: Self.moreSpecific)
        }

        /// The deeper dotted match first; then, parent scope by parent scope, the longer; then the rule
        /// with more parent scopes.
        private static func moreSpecific(_ a: TrieRule, _ b: TrieRule) -> Bool {
            if a.scopeDepth != b.scopeDepth { return a.scopeDepth > b.scopeDepth }
            var i = 0, j = 0
            while true {
                if i < a.parentScopes.count, a.parentScopes[i] == ">" { i += 1 }
                if j < b.parentScopes.count, b.parentScopes[j] == ">" { j += 1 }
                if i >= a.parentScopes.count || j >= b.parentScopes.count { break }
                let difference = b.parentScopes[j].utf16.count - a.parentScopes[i].utf16.count
                if difference != 0 { return difference < 0 }
                i += 1
                j += 1
            }
            return a.parentScopes.count > b.parentScopes.count
        }

        func insert(scopeDepth: Int, scope: Substring, parentScopes: [String]?, fontStyle: FontStyle?, foreground: RGBColor?, background: RGBColor?) {
            if scope.isEmpty {
                insertHere(scopeDepth: scopeDepth, parentScopes: parentScopes, fontStyle: fontStyle, foreground: foreground, background: background)
                return
            }
            let dot = scope.firstIndex(of: ".")
            let head = dot.map { scope[..<$0] } ?? scope
            let tail = dot.map { scope[scope.index(after: $0)...] } ?? ""
            let child: TrieElement
            if let existing = children[head] {
                child = existing
            } else {
                child = TrieElement(main: main, withParentScopes: withParentScopes)
                children[head] = child
            }
            child.insert(scopeDepth: scopeDepth + 1, scope: tail, parentScopes: parentScopes, fontStyle: fontStyle, foreground: foreground, background: background)
        }

        private func insertHere(scopeDepth: Int, parentScopes: [String]?, fontStyle: FontStyle?, foreground: RGBColor?, background: RGBColor?) {
            guard let parentScopes else {
                main.overwrite(scopeDepth: scopeDepth, fontStyle: fontStyle, foreground: foreground, background: background)
                return
            }
            if let index = withParentScopes.firstIndex(where: { $0.parentScopes == parentScopes }) {
                withParentScopes[index].overwrite(scopeDepth: scopeDepth, fontStyle: fontStyle, foreground: foreground, background: background)
                return
            }
            // A new rule takes what the rule without parent scopes says where it says nothing.
            withParentScopes.append(TrieRule(scopeDepth: scopeDepth, parentScopes: parentScopes, fontStyle: fontStyle ?? main.fontStyle,
                                             foreground: foreground ?? main.foreground, background: background ?? main.background))
        }
    }
}

extension SyntaxTheme {
    /// A variant's code colours: its own scope rules (an imported VS Code theme's `tokenColors`, used as
    /// they are, its rule without a scope giving the editor's colours), else rules made from its terminal
    /// palette.
    public convenience init(variant: ThemeVariant) {
        let terminal = variant.terminal
        guard !variant.tokenColors.isEmpty else {
            self.init(rules: Self.rules(for: terminal), foreground: terminal.foreground, background: terminal.background)
            return
        }
        let defaults = variant.tokenColors.first { $0.scopes.isEmpty }
        self.init(rules: variant.tokenColors, foreground: defaults?.foreground ?? terminal.foreground, background: defaults?.background ?? terminal.background)
    }

    /// Scope rules from a terminal palette, so code matches the terminals in every theme (ANSI: 1 red,
    /// 2 green, 3 yellow, 4 blue, 5 magenta, 6 cyan): keywords magenta, strings green, types cyan, numbers
    /// and constants yellow, functions blue, properties red, comments the foreground faded and in
    /// italics; Markdown's headings blue and bold, emphasis in italics, code green, links cyan, quotes
    /// faded, list markers magenta. Every colour keeps at least 3:1 contrast with the background, moved
    /// toward the foreground where the theme's own falls short (yellow on a light background).
    public static func rules(for terminal: TerminalColors) -> [TokenColorRule] {
        let background = terminal.background, foreground = terminal.foreground
        func ansi(_ index: Int) -> RGBColor {
            let color = terminal.ansi.count == 16 ? terminal.ansi[index] : foreground
            return color.ensuring(contrast: 3, with: background, movingTo: foreground)
        }
        let red = ansi(1), green = ansi(2), yellow = ansi(3), blue = ansi(4), magenta = ansi(5), cyan = ansi(6)
        let faded = foreground.mixed(with: background, 0.45).ensuring(contrast: 2.6, with: background, movingTo: foreground)
        let quiet = foreground.mixed(with: background, 0.3)
        func rule(_ scopes: [String], _ color: RGBColor?, _ style: FontStyle? = nil) -> TokenColorRule {
            TokenColorRule(scopes: scopes, foreground: color, fontStyle: style)
        }
        return [
            rule(["comment", "punctuation.definition.comment", "string.quoted.docstring"], faded, .italic),
            rule(["keyword", "storage", "storage.type", "storage.modifier", "variable.language", "punctuation.section.embedded",
                  "keyword.operator.new", "keyword.operator.expression", "keyword.operator.logical.python", "keyword.operator.word",
                  "keyword.control.directive", "punctuation.definition.directive", "meta.preprocessor"], magenta),
            rule(["keyword.operator", "punctuation.separator", "punctuation.terminator", "punctuation.accessor"], foreground),
            rule(["string", "markup.inline.raw", "markup.raw", "markup.inserted", "punctuation.definition.string"], green),
            rule(["constant.character.escape", "constant.other.placeholder", "string.regexp constant.character.escape"], cyan),
            rule(["string.regexp"], red),
            rule(["constant", "support.constant", "keyword.other.unit", "entity.other.attribute-name", "meta.decorator", "punctuation.decorator",
                  "storage.modifier.attribute", "entity.name.function.decorator", "markup.changed", "punctuation.definition.annotation",
                  "storage.type.annotation"], yellow),
            rule(["entity.name.type", "entity.name.class", "entity.name.namespace", "entity.name.type.module", "entity.other.inherited-class",
                  "support.type", "support.class", "storage.type.primitive", "storage.type.built-in", "entity.name.scope-resolution"], cyan),
            rule(["entity.name.function", "support.function", "meta.function-call.generic", "entity.name.tag", "markup.heading",
                  "entity.name.section", "markup.heading entity.name"], blue),
            rule(["markup.heading", "markup.heading entity.name"], nil, .bold),
            rule(["variable.other.property", "variable.other.object.property", "support.variable.property", "variable.other.member",
                  "meta.object-literal.key", "support.type.property-name", "entity.name.tag.yaml", "variable.other.normal.shell",
                  "variable.other.bracket.shell", "variable.other.special.shell", "variable.other.positional.shell",
                  "variable.other.readwrite.instance", "variable.other.readwrite.class", "variable.other.readwrite.global",
                  "variable.other.php", "invalid", "markup.deleted"], red),
            rule(["punctuation.definition.tag"], quiet),
            rule(["markup.italic"], nil, .italic),
            rule(["markup.bold"], nil, .bold),
            rule(["markup.strikethrough"], nil, .strikethrough),
            rule(["markup.underline.link", "string.other.link", "markup.link"], cyan),
            rule(["markup.quote"], faded, .italic),
            rule(["punctuation.definition.list.begin.markdown", "punctuation.definition.list.markdown", "markup.list.numbered punctuation.definition.list",
                  "beginning.punctuation.definition.list.markdown", "beginning.punctuation.definition.quote.markdown"], magenta),
            rule(["fenced_code.block.language", "punctuation.definition.markdown"], faded),
        ]
    }
}
