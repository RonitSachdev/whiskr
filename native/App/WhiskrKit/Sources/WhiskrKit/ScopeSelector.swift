import Foundation

// TextMate scope selectors as grammars' injections use them: "source.js - comment", "L:text.html.markdown
// (meta.paragraph | markup.heading)", "R:string.quoted.double.js, source.ts". Translated from
// vscode-textmate's matcher.ts and grammar.ts (nameMatcher) (MIT, Copyright (c) Microsoft Corporation).

/// A parsed selector: alternatives (",") each with a priority ("L:" before the grammar's own rules on a
/// tie, "R:" after), each a test of a scope stack.
struct ScopeSelector {
    struct Alternative {
        /// -1 for "L:", 1 for "R:", 0 otherwise.
        var priority: Int
        var matcher: Matcher
    }

    indirect enum Matcher {
        /// Scopes that must appear in this order (each a prefix by whole dotted parts).
        case path([String])
        case not(Matcher?)
        case all([Matcher])
        case any([Matcher])

        func matches(_ scopes: [String]) -> Bool {
            switch self {
            case .path(let identifiers): return ScopeSelector.nameMatches(identifiers, scopes)
            case .not(let inner): return inner.map { !$0.matches(scopes) } ?? false
            case .all(let matchers): return matchers.allSatisfy { $0.matches(scopes) }
            case .any(let matchers): return matchers.contains { $0.matches(scopes) }
            }
        }
    }

    let alternatives: [Alternative]

    init(_ selector: String) {
        var tokens = Self.tokens(selector)[...]
        var token = tokens.popFirst()
        var alternatives: [Alternative] = []

        func next() { token = tokens.popFirst() }
        func isIdentifier(_ token: String?) -> Bool {
            guard let token, let first = token.unicodeScalars.first else { return false }
            return first == "." || first == ":" || first == "_" || CharacterSet.alphanumerics.contains(first)
        }
        func parseOperand() -> Matcher? {
            if token == "-" {
                next()
                return .not(parseOperand())
            }
            if token == "(" {
                next()
                let inner = parseInnerExpression()
                if token == ")" { next() }
                return inner
            }
            if isIdentifier(token) {
                var identifiers: [String] = []
                while isIdentifier(token), let current = token {
                    identifiers.append(current)
                    next()
                }
                return .path(identifiers)
            }
            return nil
        }
        func parseConjunction() -> Matcher {
            var matchers: [Matcher] = []
            while let matcher = parseOperand() { matchers.append(matcher) }
            return .all(matchers)
        }
        func parseInnerExpression() -> Matcher {
            var matchers: [Matcher] = [parseConjunction()]
            while token == "|" || token == "," {
                while token == "|" || token == "," { next() }
                matchers.append(parseConjunction())
            }
            return .any(matchers)
        }

        while token != nil {
            var priority = 0
            if let current = token, current.count == 2, current.hasSuffix(":") {
                priority = current.hasPrefix("R") ? 1 : current.hasPrefix("L") ? -1 : 0
                next()
            }
            alternatives.append(Alternative(priority: priority, matcher: parseConjunction()))
            guard token == "," else { break }
            next()
        }
        self.alternatives = alternatives
    }

    /// `[LR]:`, names (letters, digits, `_`, `.`, `:`, `-` after the first), and the operators `,|-()`.
    static func tokens(_ selector: String) -> [String] {
        var result: [String] = []
        let units = Array(selector.unicodeScalars)
        var index = 0
        func isNameStart(_ c: Unicode.Scalar) -> Bool { c == "." || c == ":" || c == "_" || CharacterSet.alphanumerics.contains(c) }
        while index < units.count {
            let c = units[index]
            if (c == "L" || c == "R"), index + 1 < units.count, units[index + 1] == ":" {
                result.append(String(c) + ":")
                index += 2
            } else if isNameStart(c) {
                var end = index + 1
                while end < units.count, isNameStart(units[end]) || units[end] == "-" { end += 1 }
                result.append(String(String.UnicodeScalarView(units[index..<end])))
                index = end
            } else if c == "," || c == "|" || c == "-" || c == "(" || c == ")" {
                result.append(String(c))
                index += 1
            } else {
                index += 1
            }
        }
        return result
    }

    /// Each identifier matches a scope (equal, or a prefix ending at a dot) after the previous one's.
    static func nameMatches(_ identifiers: [String], _ scopes: [String]) -> Bool {
        guard scopes.count >= identifiers.count else { return false }
        var last = 0
        for identifier in identifiers {
            var found = false
            while last < scopes.count {
                let scope = scopes[last]
                last += 1
                if scopeMatches(scope, identifier) {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    /// "string.quoted.double" is matched by "string" and "string.quoted", not by "str".
    static func scopeMatches(_ scope: String, _ selector: String) -> Bool {
        guard !scope.isEmpty else { return false }
        if scope == selector { return true }
        return scope.utf8.count > selector.utf8.count && scope.hasPrefix(selector) && scope.utf8[scope.utf8.index(scope.utf8.startIndex, offsetBy: selector.utf8.count)] == UInt8(ascii: ".")
    }
}
