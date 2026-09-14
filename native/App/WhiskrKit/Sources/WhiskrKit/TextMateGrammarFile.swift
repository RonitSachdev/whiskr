import Foundation

// A TextMate grammar as written (`.tmLanguage.json`, or the property-list `.tmLanguage`): its rules, read
// once and never changed, so one copy serves every document and thread. `TextMateGrammar` compiles them.

/// One rule as a grammar writes it: a `match`, a `begin`/`end` or `begin`/`while` region, or only
/// `patterns`/`include`.
public final class RawRule: Sendable {
    let name: String?
    let contentName: String?
    let match: String?
    let begin: String?
    let end: String?
    let `while`: String?
    let captures: [Int: RawRule]?
    let beginCaptures: [Int: RawRule]?
    let endCaptures: [Int: RawRule]?
    let whileCaptures: [Int: RawRule]?
    let patterns: [RawRule]?
    let include: String?
    let repository: [String: RawRule]?
    let applyEndPatternLast: Bool

    init(name: String? = nil, contentName: String? = nil, match: String? = nil, begin: String? = nil, end: String? = nil,
         while whilePattern: String? = nil, captures: [Int: RawRule]? = nil, beginCaptures: [Int: RawRule]? = nil,
         endCaptures: [Int: RawRule]? = nil, whileCaptures: [Int: RawRule]? = nil, patterns: [RawRule]? = nil,
         include: String? = nil, repository: [String: RawRule]? = nil, applyEndPatternLast: Bool = false) {
        self.name = name
        self.contentName = contentName
        self.match = match
        self.begin = begin
        self.end = end
        self.while = whilePattern
        self.captures = captures
        self.beginCaptures = beginCaptures
        self.endCaptures = endCaptures
        self.whileCaptures = whileCaptures
        self.patterns = patterns
        self.include = include
        self.repository = repository
        self.applyEndPatternLast = applyEndPatternLast
    }

    /// A rule from a grammar file's dictionary.
    init(_ object: [String: Any]) {
        func text(_ key: String) -> String? { object[key] as? String }
        func captures(_ key: String) -> [Int: RawRule]? {
            // A list is also accepted ("captures": [{…}, {…}] counts from 0), as vscode-textmate reads it.
            if let list = object[key] as? [[String: Any]] {
                return Dictionary(uniqueKeysWithValues: list.enumerated().map { ($0.offset, RawRule($0.element)) })
            }
            guard let map = object[key] as? [String: Any] else { return nil }
            var result: [Int: RawRule] = [:]
            for (number, value) in map {
                guard let index = Int(number), let rule = value as? [String: Any] else { continue }
                result[index] = RawRule(rule)
            }
            return result
        }
        name = text("name")
        contentName = text("contentName")
        match = text("match")
        begin = text("begin")
        end = text("end")
        self.while = text("while")
        self.captures = captures("captures")
        beginCaptures = captures("beginCaptures")
        endCaptures = captures("endCaptures")
        whileCaptures = captures("whileCaptures")
        patterns = (object["patterns"] as? [Any])?.compactMap { ($0 as? [String: Any]).map(RawRule.init) }
        include = text("include")
        repository = (object["repository"] as? [String: Any]).map(RawGrammar.rules)
        let last = object["applyEndPatternLast"]
        applyEndPatternLast = (last as? Bool) ?? ((last as? Int).map { $0 != 0 } ?? false)
    }
}

/// A grammar file, read.
public final class RawGrammar: Sendable {
    public let scopeName: String
    let patterns: [RawRule]
    let repository: [String: RawRule]
    /// `injections`: selector → rule, in the file's order.
    let injections: [(selector: String, rule: RawRule)]
    /// For an injection grammar: the scopes it injects into.
    public let injectionSelector: String?
    /// `$self`: the grammar's top level as a rule named after its scope.
    let selfRule: RawRule

    init(scopeName: String, patterns: [RawRule], repository: [String: RawRule], injections: [(selector: String, rule: RawRule)], injectionSelector: String?) {
        self.scopeName = scopeName
        self.patterns = patterns
        self.repository = repository
        self.injections = injections
        self.injectionSelector = injectionSelector
        selfRule = RawRule(name: scopeName, patterns: patterns)
    }

    enum ReadError: Error, Equatable {
        case notAGrammar
    }

    /// A grammar from JSON (comments and trailing commas allowed) or a property list.
    public convenience init(data: Data) throws {
        let object: Any
        if let first = data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }), first == UInt8(ascii: "<") {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } else if let parsed = try? JSONSerialization.jsonObject(with: data) {
            object = parsed
        } else {
            object = try JSONC.object(data)
        }
        guard let grammar = object as? [String: Any] else { throw ReadError.notAGrammar }
        try self.init(grammar, injectionOrder: InjectionOrder.keys(in: data))
    }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    /// `injectionOrder`: the `injections` selectors as the file lists them. Injections of the same priority
    /// are tried in that order, as VS Code does (a JavaScript object keeps its keys' order); Foundation's
    /// readers lose it, so it is read from the text. Selectors it does not name follow, sorted.
    convenience init(_ grammar: [String: Any], injectionOrder: [String] = []) throws {
        guard let scopeName = grammar["scopeName"] as? String else { throw ReadError.notAGrammar }
        var injections: [(selector: String, rule: RawRule)] = []
        if let map = grammar["injections"] as? [String: Any] {
            let listed = injectionOrder.filter { map[$0] != nil }
            let rest = map.keys.filter { !listed.contains($0) }.sorted()
            for selector in listed + rest {
                if let rule = map[selector] as? [String: Any] { injections.append((selector, RawRule(rule))) }
            }
        }
        self.init(
            scopeName: scopeName,
            patterns: (grammar["patterns"] as? [Any])?.compactMap { ($0 as? [String: Any]).map(RawRule.init) } ?? [],
            repository: (grammar["repository"] as? [String: Any]).map(Self.rules) ?? [:],
            injections: injections,
            injectionSelector: grammar["injectionSelector"] as? String)
    }

    static func rules(_ map: [String: Any]) -> [String: RawRule] {
        var result: [String: RawRule] = [:]
        for (key, value) in map {
            if let rule = value as? [String: Any] { result[key] = RawRule(rule) }
        }
        return result
    }
}

/// Where a grammar finds the grammars it includes (`"include": "source.css"`) and the ones injected into
/// it. `LanguageRegistry` is the app's; tests use folders of grammar files.
public protocol GrammarProvider: Sendable {
    /// The grammar for a scope, read on first use; nil when there is none.
    func grammar(scopeName: String) -> RawGrammar?
    /// Scopes of the injection grammars that inject into `scopeName` (an extension's `injectTo`).
    func injections(into scopeName: String) -> [String]
}

/// The keys of a grammar's top-level `injections` object in the order its file writes them: JSON (comments
/// allowed) or an XML property list.
enum InjectionOrder {
    static func keys(in data: Data) -> [String] {
        if let first = data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }), first == UInt8(ascii: "<") {
            return PlistKeys(data).injectionKeys
        }
        return jsonKeys(Array(JSONC.strip(data)))
    }

    /// Walks the JSON text: at depth 1 finds the key "injections", then collects the keys of that object.
    private static func jsonKeys(_ bytes: [UInt8]) -> [String] {
        var index = 0
        var depth = 0
        var expectingKey = false
        var inInjections = false
        var injectionsDepth = 0
        var keys: [String] = []
        var lastKeyAtTop: String?
        func readString() -> String {
            var out = [UInt8]()
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                if bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count {
                    out.append(bytes[index])
                    index += 1
                }
                out.append(bytes[index])
                index += 1
            }
            index += 1
            // Escapes are kept as written; selectors rarely hold any, and a match is only needed for ordering.
            return String(decoding: out, as: UTF8.self)
        }
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"):
                depth += 1
                expectingKey = true
                if depth == 2, lastKeyAtTop == "injections" {
                    inInjections = true
                    injectionsDepth = depth
                }
                index += 1
            case UInt8(ascii: "}"):
                if inInjections, depth == injectionsDepth { return keys }
                depth -= 1
                expectingKey = false
                index += 1
            case UInt8(ascii: "["):
                depth += 1
                expectingKey = false
                index += 1
            case UInt8(ascii: "]"):
                depth -= 1
                index += 1
            case UInt8(ascii: ","):
                // A comma inside an object starts another key; inside an array it does not, which the next
                // value's own opening sorts out.
                expectingKey = true
                index += 1
            case UInt8(ascii: ":"):
                expectingKey = false
                index += 1
            case UInt8(ascii: "\""):
                let isKey = expectingKey
                let text = readString()
                if isKey {
                    if depth == 1 { lastKeyAtTop = text }
                    if inInjections, depth == injectionsDepth { keys.append(text) }
                }
            default:
                index += 1
            }
        }
        return keys
    }

    /// The keys of `<key>injections</key><dict>…</dict>` directly in the root dictionary of a plist.
    private final class PlistKeys: NSObject, XMLParserDelegate {
        private(set) var injectionKeys: [String] = []
        private var dictDepth = 0
        private var text = ""
        private var lastRootKey: String?
        private var injectionsDepth: Int?

        init(_ data: Data) {
            super.init()
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.parse()
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if element == "dict" {
                dictDepth += 1
                if dictDepth == 2, lastRootKey == "injections" { injectionsDepth = dictDepth }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            switch element {
            case "dict":
                if dictDepth == injectionsDepth { injectionsDepth = nil; lastRootKey = nil }
                dictDepth -= 1
            case "key":
                if dictDepth == 1 { lastRootKey = text }
                if let depth = injectionsDepth, dictDepth == depth { injectionKeys.append(text) }
            default:
                break
            }
        }
    }
}
