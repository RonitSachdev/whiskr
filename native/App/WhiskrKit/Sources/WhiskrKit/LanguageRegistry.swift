import Foundation

/// Where a TextMate grammar is and what VS Code knows about it beside the file.
public struct GrammarSource: Hashable, Sendable {
    public let scopeName: String
    /// The grammar file (JSON).
    public let url: URL
    /// The language it colours; nil for a grammar only included or injected by others.
    public let languageID: String?
    /// Scopes that are another language inside this one ("meta.embedded.block.python": "python"), its own
    /// and those of the grammars injected into it.
    public let embeddedLanguages: [String: String]
    /// Scopes of the grammars injected into this one, in the order they apply.
    public let injections: [String]
    /// Scopes the grammar marks as code, string or comment against their names ("meta.template.expression":
    /// "other"), as `tokenTypes` in VS Code.
    public let tokenTypes: [String: TokenContext]
    /// Scope prefixes in which brackets pair (`balancedBracketScopes`), and in which they do not.
    public let balancedBracketScopes: [String]
    public let unbalancedBracketScopes: [String]
}

/// Every language and grammar the app knows: the bundle (`Languages/`, from VS Code's built-in extensions
/// and the grammars' upstreams, built by `Scripts/update-languages.py`) and what a person has added (see
/// `install(from:into:)`). The index is read on first use; a grammar file only when it is asked for.
///
/// Which language a file is in follows VS Code exactly (`languagesAssociations.ts`): a file name the
/// language lists, else the longest matching file-name pattern, else the longest matching extension (all
/// ignoring case; among equals the one registered last, so what a person adds wins), else the first line's
/// pattern (a `#!` line), else plain text.
public final class LanguageRegistry: GrammarProvider, @unchecked Sendable {
    /// The bundled languages, and what `loadInstalled(from:)` adds.
    public static let shared = LanguageRegistry(folder: bundledFolder)

    /// The bundle's folder of language data.
    public static var bundledFolder: URL {
        Bundle.module.url(forResource: "Languages", withExtension: nil) ?? Bundle.module.bundleURL.appendingPathComponent("Languages", isDirectory: true)
    }

    // Everything below is guarded by `lock`.
    private let lock = NSLock()
    private let folder: URL
    private var bundledPack: Pack?
    private var installedPacks: [Pack] = []
    private var state: State?
    private var languages: [String: CodeLanguage] = [:]
    private var grammars: [String: RawGrammar] = [:]

    /// A registry of the language data in `folder`, laid out as the bundle's (`index.json`, `grammars/`,
    /// `configurations/`).
    public init(folder: URL) {
        self.folder = folder
    }

    // MARK: Languages

    /// The language with this id, if there is one.
    public func language(id: String) -> CodeLanguage? {
        lock.withLock { resolvedLanguage(id) }
    }

    /// Every language with a name, by name, for a language menu (as VS Code's; languages contributed with
    /// no aliases, such as "jsx-tags", have no name and are left out).
    public var all: [CodeLanguage] {
        lock.withLock {
            resolved().records.values.filter { $0.name != nil }.compactMap { resolvedLanguage($0.id) }
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The language of a file, from its name or path (patterns with a "/" match the whole path) and,
    /// when neither says, its first line; plain text when nothing matches.
    public func detect(fileName: String, firstLine: String? = nil) -> CodeLanguage {
        lock.withLock {
            let state = resolved()
            let id = state.languageID(path: fileName) ?? firstLine.flatMap(state.languageID(firstLine:)) ?? CodeLanguage.plainTextID
            return resolvedLanguage(id) ?? CodeLanguage(id: id, displayName: id)
        }
    }

    /// The language a Markdown fence's info string names ("ts", "py title=x", "c++", "Dockerfile"): the
    /// words VS Code's Markdown grammars colour fenced code by, then a language's id or alias, then a file
    /// name or extension. Nil when nothing matches.
    public func language(forFence info: String) -> CodeLanguage? {
        let word = String(info.trimmingCharacters(in: .whitespaces).prefix { !($0.isWhitespace || ":,{?".contains($0)) }).lowercased()
        guard !word.isEmpty else { return nil }
        return lock.withLock {
            let state = resolved()
            let id = state.fences[word] ?? state.idsByName[word] ?? state.languageID(path: word) ?? state.languageID(path: "file." + word)
            return id.flatMap(resolvedLanguage)
        }
    }

    // MARK: Grammars

    /// Where the grammar for a scope is, and what is known about it.
    public func grammarSource(scopeName: String) -> GrammarSource? {
        lock.withLock {
            let state = resolved()
            guard let grammar = state.grammars[scopeName] else { return nil }
            var embedded = grammar.embeddedLanguages
            for injected in state.injectedEmbeddedLanguages[scopeName] ?? [] {
                embedded.merge(injected) { _, new in new }
            }
            return GrammarSource(scopeName: scopeName, url: grammar.url, languageID: grammar.language, embeddedLanguages: embedded,
                                 injections: state.injections(into: scopeName), tokenTypes: grammar.tokenTypes,
                                 balancedBracketScopes: grammar.balancedBracketScopes, unbalancedBracketScopes: grammar.unbalancedBracketScopes)
        }
    }

    /// The grammar for a scope, read once; nil when there is none or its file cannot be read.
    public func grammar(scopeName: String) -> RawGrammar? {
        let url: URL? = lock.withLock {
            if grammars[scopeName] != nil { return nil }
            return resolved().grammars[scopeName]?.url
        }
        guard let url else { return lock.withLock { grammars[scopeName] } }
        // Read outside the lock; two first readers at once both read, and one result is kept.
        guard let grammar = try? RawGrammar(contentsOf: url) else { return nil }
        return lock.withLock {
            if let earlier = grammars[scopeName] { return earlier }
            grammars[scopeName] = grammar
            return grammar
        }
    }

    /// Scopes of the grammars injected into `scopeName` (their `injectTo`), as VS Code finds them: those
    /// injected into the scope or any of its dotted prefixes ("source" and "source.js" for "source.js").
    public func injections(into scopeName: String) -> [String] {
        lock.withLock { resolved().injections(into: scopeName) }
    }

    // MARK: Installed languages

    /// Reads what a person has added (each a folder `install(from:into:)` wrote in `folder`), over the
    /// bundled languages; what was read before is replaced. A folder that cannot be read is skipped.
    public func loadInstalled(from folder: URL) {
        let packs = Self.installedPacks(in: folder)
        lock.withLock {
            installedPacks = packs
            state = nil
            languages = [:]
            grammars = [:]
        }
    }

    /// What a person has added, in the order it applies.
    public var installed: [InstalledLanguages] {
        lock.withLock {
            installedPacks.map { pack in
                InstalledLanguages(id: pack.base.lastPathComponent, name: pack.name ?? pack.base.lastPathComponent,
                                   languageIDs: Self.unique(pack.languages.map(\.id)), scopeNames: Self.unique(pack.grammars.map(\.scopeName)))
            }
        }
    }

    // MARK: Resolving

    private func resolved() -> State {
        if let state { return state }
        let pack = bundledPack ?? Pack.read(folder: folder)
        bundledPack = pack
        let built = State(packs: [pack].compactMap { $0 } + installedPacks)
        state = built
        return built
    }

    private func resolvedLanguage(_ id: String) -> CodeLanguage? {
        if let language = languages[id] { return language }
        let state = resolved()
        guard let record = state.records[id] else { return nil }
        // VS Code combines a language's configurations field by field, the later one winning.
        var json: [String: Any] = [:]
        for url in record.configurations {
            guard let data = try? Data(contentsOf: url), let fields = try? JSONC.dictionary(data) else { continue }
            json.merge(fields.filter { !($0.value is NSNull) }) { _, new in new }
        }
        let language = CodeLanguage(id: id, displayName: record.name ?? id, aliases: record.aliases, extensions: record.extensions,
                                    filenames: record.filenames, scopeName: state.languageScopes[id], configuration: LanguageConfiguration(json: json))
        languages[id] = language
        return language
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// A set of languages and grammars a person added: one grammar file or one extension.
public struct InstalledLanguages: Hashable, Sendable, Identifiable {
    /// Its folder's name in the folder of installed languages.
    public let id: String
    /// The extension's name, or the grammar's.
    public let name: String
    public let languageIDs: [String]
    public let scopeNames: [String]
}

// MARK: - Index

/// One `index.json` and the folder its paths are relative to: the bundle's, or one installed set.
struct Pack {
    struct Language: Codable {
        var id: String
        var aliases: [String]?
        var extensions: [String]?
        var filenames: [String]?
        var filenamePatterns: [String]?
        var firstLine: String?
        var configuration: String?
    }

    struct Grammar: Codable {
        var scopeName: String
        var file: String
        var language: String?
        var embeddedLanguages: [String: String]?
        var injectTo: [String]?
        var tokenTypes: [String: String]?
        var balancedBracketScopes: [String]?
        var unbalancedBracketScopes: [String]?
    }

    struct Index: Codable {
        /// An installed set's name.
        var name: String?
        var languages: [Language]
        var grammars: [Grammar]
        /// Markdown fence words and their languages (the bundle's only).
        var fences: [String: String]?
    }

    var base: URL
    var name: String?
    var languages: [Language]
    var grammars: [Grammar]
    var fences: [String: String]

    static func read(folder: URL) -> Pack? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
              let index = try? JSONDecoder().decode(Index.self, from: data) else { return nil }
        return Pack(base: folder, name: index.name, languages: index.languages, grammars: index.grammars, fences: index.fences ?? [:])
    }
}

extension LanguageRegistry {
    static func installedPacks(in folder: URL) -> [Pack] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { Pack.read(folder: $0) }
    }
}

// MARK: - Resolved state

/// The packs' contributions combined as VS Code's language and grammar registries combine extensions'.
private struct State {
    struct Record {
        let id: String
        var name: String?
        var aliases: [String] = []
        var extensions: [String] = []
        var filenames: [String] = []
        var configurations: [URL] = []
    }

    struct Grammar {
        let url: URL
        let language: String?
        let embeddedLanguages: [String: String]
        let tokenTypes: [String: TokenContext]
        let balancedBracketScopes: [String]
        let unbalancedBracketScopes: [String]
    }

    enum Match {
        case filename(String)
        case `extension`(String)
        case pattern(PathGlob, onPath: Bool)
        case firstLine(NSRegularExpression)
    }

    struct Association {
        let id: String
        let match: Match
    }

    var records: [String: Record] = [:]
    /// Language ids in the order they were first registered.
    var order: [String] = []
    /// In registration order; the last registered wins among equals.
    var associations: [Association] = []
    /// Lowercased ids and aliases → id (VS Code's `getLanguageIdByLanguageName`).
    var idsByName: [String: String] = [:]
    var grammars: [String: Grammar] = [:]
    var languageScopes: [String: String] = [:]
    var injectionsByTarget: [String: [String]] = [:]
    var injectedEmbeddedLanguages: [String: [[String: String]]] = [:]
    var fences: [String: String] = [:]

    init(packs: [Pack]) {
        for pack in packs {
            for language in pack.languages { register(language, base: pack.base) }
        }
        for pack in packs {
            for grammar in pack.grammars { register(grammar, base: pack.base) }
            fences.merge(pack.fences) { _, new in new }
        }
        // As VS Code builds its name map: languages in registration order, a later one taking a shared name.
        for id in order {
            guard let record = records[id] else { continue }
            for alias in [id] + record.aliases { idsByName[alias.lowercased()] = id }
        }
        // A fence word names only a language that is here.
        fences = fences.filter { records[$0.value] != nil }
    }

    /// `LanguagesRegistry._mergeLanguage` in VS Code.
    private mutating func register(_ language: Pack.Language, base: URL) {
        let id = language.id
        if records[id] == nil { order.append(id) }
        var record = records[id] ?? Record(id: id)
        let extensions = language.extensions ?? []
        // A contribution with a configuration is the language's main one: its extensions come first.
        record.extensions = language.configuration != nil ? extensions + record.extensions : record.extensions + extensions
        associations += extensions.map { Association(id: id, match: .extension($0.lowercased())) }
        for filename in language.filenames ?? [] {
            associations.append(Association(id: id, match: .filename(filename.lowercased())))
            record.filenames.append(filename)
        }
        for pattern in language.filenamePatterns ?? [] {
            if let glob = PathGlob(pattern) { associations.append(Association(id: id, match: .pattern(glob, onPath: pattern.contains("/")))) }
        }
        if let firstLine = language.firstLine, !firstLine.isEmpty {
            let source = firstLine.hasPrefix("^") ? firstLine : "^" + firstLine
            if let expression = try? NSRegularExpression(pattern: source) {
                associations.append(Association(id: id, match: .firstLine(expression)))
            }
        }
        // Aliases given and empty: the language has no name (it is left out of menus).
        if let aliases = language.aliases {
            let named = aliases.filter { !$0.isEmpty }
            record.aliases = LanguageRegistry.unique(record.aliases + named)
            if !aliases.isEmpty { record.name = aliases[0].isEmpty ? id : aliases[0] }
        } else if record.name == nil {
            record.name = id
        }
        if let configuration = language.configuration { record.configurations.append(base.appendingPathComponent(configuration)) }
        records[id] = record
    }

    /// `TMGrammarFactory` in VS Code: the last grammar for a scope or a language wins.
    private mutating func register(_ grammar: Pack.Grammar, base: URL) {
        let types = (grammar.tokenTypes ?? [:]).compactMapValues { type -> TokenContext? in
            switch type {
            case "string": .string
            case "comment": .comment
            case "other": .code
            default: nil
            }
        }
        grammars[grammar.scopeName] = Grammar(url: base.appendingPathComponent(grammar.file), language: grammar.language,
                                              embeddedLanguages: grammar.embeddedLanguages ?? [:], tokenTypes: types,
                                              balancedBracketScopes: grammar.balancedBracketScopes ?? [],
                                              unbalancedBracketScopes: grammar.unbalancedBracketScopes ?? [])
        for target in grammar.injectTo ?? [] {
            injectionsByTarget[target, default: []].append(grammar.scopeName)
            if let embedded = grammar.embeddedLanguages, !embedded.isEmpty { injectedEmbeddedLanguages[target, default: []].append(embedded) }
        }
        if let language = grammar.language { languageScopes[language] = grammar.scopeName }
    }

    func injections(into scopeName: String) -> [String] {
        let parts = scopeName.split(separator: ".")
        var result: [String] = []
        for count in parts.indices.map({ $0 + 1 }) {
            result += injectionsByTarget[parts.prefix(count).joined(separator: ".")] ?? []
        }
        return LanguageRegistry.unique(result).filter { grammars[$0] != nil }
    }

    /// `getAssociationByPath` in VS Code.
    func languageID(path: String) -> String? {
        let path = path.lowercased()
        guard !path.isEmpty else { return nil }
        let filename = path.split(separator: "/").last.map(String.init) ?? path
        var pattern: (id: String, length: Int)?
        var extensionMatch: (id: String, length: Int)?
        for association in associations.reversed() {
            switch association.match {
            case .filename(let name):
                if name == filename { return association.id }
            case .pattern(let glob, let onPath):
                let length = glob.pattern.utf16.count
                if length > pattern?.length ?? -1, glob.matches(onPath ? path : filename) {
                    pattern = (association.id, length)
                }
            case .extension(let suffix):
                let length = suffix.utf16.count
                if length > extensionMatch?.length ?? -1, filename.hasSuffix(suffix) {
                    extensionMatch = (association.id, length)
                }
            case .firstLine:
                break
            }
        }
        return pattern?.id ?? extensionMatch?.id
    }

    /// `getAssociationByFirstline` in VS Code.
    func languageID(firstLine: String) -> String? {
        var line = Substring(firstLine)
        if line.first == "\u{FEFF}" { line = line.dropFirst() }
        line = line.prefix { !$0.isNewline }
        guard !line.isEmpty else { return nil }
        let text = String(line)
        for association in associations.reversed() {
            if case .firstLine(let expression) = association.match,
               expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return association.id
            }
        }
        return nil
    }
}
