import Foundation

/// Why languages could not be added.
public enum LanguageInstallError: Error, Equatable, Sendable {
    /// The file or folder could not be read.
    case unreadable
    /// A file that is not a TextMate grammar.
    case notAGrammar
    /// A folder or `.vsix` that is not a VS Code extension.
    case notAnExtension
    /// An extension that contributes no languages or grammars.
    case nothingToInstall

    public var message: String {
        switch self {
        case .unreadable:
            String(localized: "The file could not be read.", bundle: .module, comment: "Importing a theme or adding a language: the chosen file or folder could not be read")
        case .notAGrammar:
            String(localized: "This is not a TextMate grammar (a .tmLanguage.json or .tmLanguage file).", bundle: .module,
                   comment: "Adding a language: the chosen file is not a syntax colouring grammar")
        case .notAnExtension:
            String(localized: "This is not a VS Code extension, or its package.json could not be read.", bundle: .module,
                   comment: "Adding a language: the chosen folder or .vsix is not an editor extension")
        case .nothingToInstall:
            String(localized: "This extension adds no languages or grammars.", bundle: .module,
                   comment: "Adding a language: the extension holds nothing Whiskr can use (only code, themes or settings)")
        }
    }
}

/// Adding languages: a TextMate grammar file (`.tmLanguage.json`, or `.tmLanguage` / `.plist`), or a VS Code
/// extension (a folder, or a `.vsix`) contributing languages and grammars. Only data is copied: grammars
/// (property lists become JSON), language configurations and what `package.json` says about them; nothing
/// of an extension is ever run.
extension LanguageRegistry {
    /// Copies the languages and grammars at `url` into a folder of their own inside `folder` (replacing an
    /// earlier copy of the same grammar or extension), reads `folder` again, and gives the languages that
    /// were added or are now coloured by an added grammar.
    @discardableResult
    public func install(from url: URL, into folder: URL) throws -> [CodeLanguage] {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw LanguageInstallError.unreadable }
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("whiskr-language-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)

        let name: String
        let index: Pack.Index
        if isFolder.boolValue {
            (name, index) = try Self.stageExtension(at: url, into: staged)
        } else if url.pathExtension.lowercased() == "vsix" {
            let unpacked: URL
            do {
                unpacked = try ExtensionManifest.unpack(vsix: url, into: scratch.appendingPathComponent("unpacked", isDirectory: true))
            } catch {
                throw LanguageInstallError.notAnExtension
            }
            (name, index) = try Self.stageExtension(at: unpacked, into: staged)
        } else {
            (name, index) = try stageGrammar(at: url, into: staged)
        }
        let data = try JSONEncoder().encode(index)
        try data.write(to: staged.appendingPathComponent("index.json"))

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: staged, to: target)
        loadInstalled(from: folder)

        let scopes = Set(index.grammars.map(\.scopeName))
        let ids = Set(index.languages.map(\.id))
        return addedLanguages(ids: ids, scopes: scopes)
    }

    /// Removes one installed set (an `InstalledLanguages` id) from `folder`, and reads `folder` again.
    public func remove(_ id: InstalledLanguages.ID, from folder: URL) throws {
        guard !id.isEmpty, !id.contains("/"), id != ".", id != ".." else { return }
        let target = folder.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        loadInstalled(from: folder)
    }

    /// The languages among `ids`, and those whose grammar is one of `scopes`, by name.
    private func addedLanguages(ids: Set<String>, scopes: Set<String>) -> [CodeLanguage] {
        var found: [CodeLanguage] = ids.compactMap { language(id: $0) }
        for language in all where language.scopeName.map(scopes.contains) == true && !ids.contains(language.id) {
            found.append(language)
        }
        return found.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    // MARK: Staging

    /// A grammar file: its grammar, and a language made from what the grammar says about itself unless a
    /// known language already uses its scope (the grammar then replaces that language's).
    private func stageGrammar(at url: URL, into staged: URL) throws -> (String, Pack.Index) {
        guard let data = try? Data(contentsOf: url) else { throw LanguageInstallError.unreadable }
        let grammar = try Self.grammarJSON(data)
        guard let scope = grammar["scopeName"] as? String, !scope.isEmpty else { throw LanguageInstallError.notAGrammar }
        let file = try Self.writeGrammar(grammar, scope: scope, into: staged)
        let name = (grammar["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? scope

        if let existing = all.first(where: { $0.scopeName == scope }) ?? language(id: Self.languageID(scope: scope)), !existing.isPlainText {
            // The scope's language, or the language of the same id: the grammar colours it from now on.
            return (Self.folderName(scope), Pack.Index(name: name, languages: [],
                                                       grammars: [Pack.Grammar(scopeName: scope, file: file, language: existing.id)]))
        }
        // TextMate's file types are extensions without their dot, or whole file names.
        let types = (grammar["fileTypes"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        let id = Self.languageID(scope: scope)
        let language = Pack.Language(id: id, aliases: [name], extensions: types.map { "." + $0 }, filenames: types,
                                     firstLine: grammar["firstLineMatch"] as? String)
        return (Self.folderName(scope), Pack.Index(name: name, languages: [language],
                                                   grammars: [Pack.Grammar(scopeName: scope, file: file, language: id)]))
    }

    /// An extension's languages, their configurations and its grammars.
    private static func stageExtension(at url: URL, into staged: URL) throws -> (String, Pack.Index) {
        let manifest: ExtensionManifest
        do {
            manifest = try ExtensionManifest.read(folder: url)
        } catch {
            throw LanguageInstallError.notAnExtension
        }
        guard !manifest.languages.isEmpty || !manifest.grammars.isEmpty else { throw LanguageInstallError.nothingToInstall }
        let root = manifest.folder.resolvingSymlinksInPath().standardizedFileURL.path

        // Only files inside the extension's own folder are read.
        func inside(_ file: URL) -> Data? {
            let path = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }

        var languages: [Pack.Language] = []
        var configurationNames = Set<String>()
        try FileManager.default.createDirectory(at: staged.appendingPathComponent("configurations", isDirectory: true), withIntermediateDirectories: true)
        for contribution in manifest.languages {
            var language = Pack.Language(id: contribution.id, aliases: contribution.aliases.isEmpty ? nil : contribution.aliases,
                                         extensions: contribution.extensions, filenames: contribution.filenames,
                                         filenamePatterns: contribution.filenamePatterns, firstLine: contribution.firstLine)
            if let url = contribution.configuration, let data = inside(url), (try? JSONC.dictionary(data)) != nil {
                var name = folderName(contribution.id)
                while configurationNames.contains(name) { name += "-" }
                configurationNames.insert(name)
                let path = "configurations/\(name).json"
                try data.write(to: staged.appendingPathComponent(path))
                language.configuration = path
            }
            languages.append(language)
        }

        var grammars: [Pack.Grammar] = []
        for contribution in manifest.grammars {
            guard let data = inside(contribution.path), let grammar = try? grammarJSON(data) else { continue }
            let file = try writeGrammar(grammar, scope: contribution.scopeName, into: staged)
            grammars.append(Pack.Grammar(scopeName: contribution.scopeName, file: file, language: contribution.language,
                                         embeddedLanguages: contribution.embeddedLanguages.isEmpty ? nil : contribution.embeddedLanguages,
                                         injectTo: contribution.injectTo.isEmpty ? nil : contribution.injectTo,
                                         tokenTypes: contribution.tokenTypes.isEmpty ? nil : contribution.tokenTypes,
                                         balancedBracketScopes: contribution.balancedBracketScopes.isEmpty ? nil : contribution.balancedBracketScopes,
                                         unbalancedBracketScopes: contribution.unbalancedBracketScopes.isEmpty ? nil : contribution.unbalancedBracketScopes))
        }
        guard !languages.isEmpty || !grammars.isEmpty else { throw LanguageInstallError.nothingToInstall }
        return (folderName(manifest.identifier), Pack.Index(name: manifest.displayName, languages: languages, grammars: grammars))
    }

    /// A grammar file's contents, from JSON (with comments) or a property list.
    private static func grammarJSON(_ data: Data) throws -> [String: Any] {
        let object: Any?
        if data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) == UInt8(ascii: "<") {
            object = try? PropertyListSerialization.propertyList(from: data, format: nil)
        } else {
            object = try? JSONC.object(data)
        }
        guard let grammar = object as? [String: Any], grammar["scopeName"] is String,
              grammar["patterns"] is [Any] || grammar["injectionSelector"] is String,
              JSONSerialization.isValidJSONObject(grammar) else { throw LanguageInstallError.notAGrammar }
        return grammar
    }

    /// Writes a grammar as JSON under `grammars/`, and gives its path in the set.
    private static func writeGrammar(_ grammar: [String: Any], scope: String, into staged: URL) throws -> String {
        let folder = staged.appendingPathComponent("grammars", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = "grammars/\(folderName(scope)).json"
        try JSONSerialization.data(withJSONObject: grammar).write(to: staged.appendingPathComponent(path))
        return path
    }

    /// A language id from a grammar's scope: "source.nim" → "nim", "text.html.mustache" → "html.mustache".
    static func languageID(scope: String) -> String {
        var parts = scope.lowercased().split(separator: ".").map(String.init)
        if parts.count > 1, parts[0] == "source" || parts[0] == "text" { parts.removeFirst() }
        return parts.joined(separator: ".")
    }

    /// A file or folder name made of letters, digits, ".", "-" and "_" only.
    static func folderName(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let name = String(text.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "-" })
        return name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).isEmpty ? "language" : name
    }
}
