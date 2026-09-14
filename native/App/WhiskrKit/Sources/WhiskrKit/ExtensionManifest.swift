import Foundation

/// What a VS Code extension's `package.json` contributes that the app can use as data: colour themes,
/// languages (names, file extensions, file names, a first-line pattern, a language configuration) and
/// TextMate grammars. Nothing of an extension is ever run; its code, commands, settings and every other
/// contribution are left alone. Labels written as `%key%` are looked up in `package.nls.json`, as VS Code
/// does for its own built-in extensions.
public struct ExtensionManifest: Sendable, Equatable {
    /// `contributes.themes`: one colour theme file.
    public struct ThemeContribution: Sendable, Equatable {
        public var id: String?
        public var label: String
        /// "vs" (light), "vs-dark", "hc-black" or "hc-light".
        public var uiTheme: String?
        public var path: URL

        public init(id: String?, label: String, uiTheme: String?, path: URL) {
            self.id = id
            self.label = label
            self.uiTheme = uiTheme
            self.path = path
        }

        /// The theme is a dark one, as its `uiTheme` says (nil when it does not say).
        public var isDark: Bool? {
            switch uiTheme {
            case "vs-dark", "hc-black": true
            case "vs", "hc-light": false
            default: nil
            }
        }
    }

    /// `contributes.languages`: a language, or more names and files for one contributed elsewhere.
    public struct LanguageContribution: Sendable, Equatable {
        public var id: String
        public var aliases: [String]
        /// With their leading dot, as written (".md", ".hpp.in").
        public var extensions: [String]
        public var filenames: [String]
        /// Glob patterns over the file's name or path ("tsconfig.*.json", "**/.cursor/**/*.mdc").
        public var filenamePatterns: [String]
        /// A regular expression the first line of a file matches.
        public var firstLine: String?
        /// `language-configuration.json`: comments, brackets, pairs that close themselves.
        public var configuration: URL?

        public init(id: String, aliases: [String] = [], extensions: [String] = [], filenames: [String] = [], filenamePatterns: [String] = [],
                    firstLine: String? = nil, configuration: URL? = nil) {
            self.id = id
            self.aliases = aliases
            self.extensions = extensions
            self.filenames = filenames
            self.filenamePatterns = filenamePatterns
            self.firstLine = firstLine
            self.configuration = configuration
        }
    }

    /// `contributes.grammars`: a TextMate grammar, for a language or only to be included by others.
    public struct GrammarContribution: Sendable, Equatable {
        public var language: String?
        public var scopeName: String
        public var path: URL
        /// Scopes inside this grammar that are another language ("meta.embedded.block.python": "python").
        public var embeddedLanguages: [String: String]
        /// For an injection grammar: the scopes of the grammars it is injected into.
        public var injectTo: [String]
        /// Scopes to treat as "string", "comment" or "other" against their names.
        public var tokenTypes: [String: String]
        /// Scope prefixes in which brackets pair, and in which they do not.
        public var balancedBracketScopes: [String]
        public var unbalancedBracketScopes: [String]

        public init(language: String?, scopeName: String, path: URL, embeddedLanguages: [String: String] = [:], injectTo: [String] = [],
                    tokenTypes: [String: String] = [:], balancedBracketScopes: [String] = [], unbalancedBracketScopes: [String] = []) {
            self.language = language
            self.scopeName = scopeName
            self.path = path
            self.embeddedLanguages = embeddedLanguages
            self.injectTo = injectTo
            self.tokenTypes = tokenTypes
            self.balancedBracketScopes = balancedBracketScopes
            self.unbalancedBracketScopes = unbalancedBracketScopes
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// No `package.json`, or one that is not JSON.
        case notAnExtension(String)
    }

    /// `publisher.name`, or the name alone.
    public var identifier: String
    public var displayName: String
    public var version: String?
    /// The licence the manifest names (an SPDX expression such as "MIT"), as written.
    public var license: String?
    public var folder: URL
    public var themes: [ThemeContribution]
    public var languages: [LanguageContribution]
    public var grammars: [GrammarContribution]

    /// Unpacks a `.vsix` (a zip archive) into `folder`, with the system's `ditto`, and gives the folder to
    /// read with `read(folder:)`. Nothing in it is run.
    public static func unpack(vsix: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", vsix.path, folder.path]
        // No pipes: nothing for other processes started meanwhile to inherit and hold open.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw Failure.notAnExtension("The extension could not be unpacked.")
        }
        // An archive that takes longer than this to unpack is not an extension anyone wrote by hand.
        if exited.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            exited.wait()
            throw Failure.notAnExtension("The extension could not be unpacked.")
        }
        guard process.terminationStatus == 0 else { throw Failure.notAnExtension("The extension could not be unpacked.") }
        return folder
    }

    /// Reads the extension in `folder` (the folder holding `package.json`; a `.vsix` unpacks to an
    /// `extension/` folder inside, which is looked for too).
    public static func read(folder: URL) throws -> ExtensionManifest {
        var root = folder
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: root.appendingPathComponent("package.json").path),
           fileManager.fileExists(atPath: root.appendingPathComponent("extension/package.json").path) {
            root = root.appendingPathComponent("extension", isDirectory: true)
        }
        let manifestURL = root.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw Failure.notAnExtension("There is no package.json in this folder.") }
        let json: [String: Any]
        do {
            json = try JSONC.dictionary(data)
        } catch {
            throw Failure.notAnExtension("Its package.json could not be read.")
        }
        // Built-in extensions name their labels "%key%", with the words in package.nls.json.
        let words = (try? Data(contentsOf: root.appendingPathComponent("package.nls.json"))).flatMap { try? JSONC.dictionary($0) } ?? [:]
        func text(_ value: Any?) -> String? {
            guard let raw = value as? String else { return nil }
            guard raw.count > 2, raw.hasPrefix("%"), raw.hasSuffix("%") else { return raw }
            let key = String(raw.dropFirst().dropLast())
            if let found = words[key] as? String { return found }
            // An entry may be { "message": …, "comment": … }.
            if let found = (words[key] as? [String: Any])?["message"] as? String { return found }
            return raw
        }
        func list(_ value: Any?) -> [String] { (value as? [Any])?.compactMap { $0 as? String } ?? [] }
        func file(_ value: Any?) -> URL? {
            guard let path = value as? String, !path.isEmpty else { return nil }
            return root.appendingPathComponent(path).standardizedFileURL
        }

        let name = json["name"] as? String ?? root.lastPathComponent
        let publisher = json["publisher"] as? String
        let contributes = json["contributes"] as? [String: Any] ?? [:]

        let themes: [ThemeContribution] = (contributes["themes"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let path = file(entry["path"]) else { return nil }
            let label = text(entry["label"]) ?? text(entry["id"]) ?? path.deletingPathExtension().lastPathComponent
            return ThemeContribution(id: entry["id"] as? String, label: label, uiTheme: entry["uiTheme"] as? String, path: path)
        }
        let languages: [LanguageContribution] = (contributes["languages"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            return LanguageContribution(id: id, aliases: list(entry["aliases"]), extensions: list(entry["extensions"]),
                                        filenames: list(entry["filenames"]), filenamePatterns: list(entry["filenamePatterns"]),
                                        firstLine: entry["firstLine"] as? String, configuration: file(entry["configuration"]))
        }
        let grammars: [GrammarContribution] = (contributes["grammars"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let scope = entry["scopeName"] as? String, let path = file(entry["path"]) else { return nil }
            let embedded = (entry["embeddedLanguages"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            return GrammarContribution(language: entry["language"] as? String, scopeName: scope, path: path,
                                       embeddedLanguages: embedded, injectTo: list(entry["injectTo"]),
                                       tokenTypes: (entry["tokenTypes"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String },
                                       balancedBracketScopes: list(entry["balancedBracketScopes"]),
                                       unbalancedBracketScopes: list(entry["unbalancedBracketScopes"]))
        }
        return ExtensionManifest(identifier: publisher.map { "\($0).\(name)" } ?? name,
                                 displayName: text(json["displayName"]) ?? name,
                                 version: json["version"] as? String,
                                 license: json["license"] as? String,
                                 folder: root,
                                 themes: themes, languages: languages, grammars: grammars)
    }
}
