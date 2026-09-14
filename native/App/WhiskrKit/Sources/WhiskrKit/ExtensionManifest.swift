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

    /// The most a `.vsix` may hold unpacked, and its most files. Theme and language extensions hold a few
    /// megabytes; one that says it is past these is not unpacked at all, and one that
    /// understates it is stopped once that much has reached the disk, so an archive that inflates to
    /// gigabytes (a "zip bomb") never fills it.
    public static let largestUnpacked: UInt64 = 256 * 1024 * 1024
    public static let mostEntries = 20_000

    /// Unpacks a `.vsix` (a zip archive) into `folder`, with the system's `ditto`, and gives the folder to
    /// read with `read(folder:)`. Nothing in it is run. The archive's own list of contents is read first,
    /// and one larger than `largestUnpacked` or with more than `mostEntries` files is refused. `ditto`
    /// keeps every entry inside `folder` (a "../" or absolute name, or a link, lands inside it). Slow: not
    /// on the main thread.
    public static func unpack(vsix: URL, into folder: URL) throws -> URL {
        guard let contents = ZipDirectory.contents(of: vsix), contents.entries <= mostEntries, contents.bytes <= largestUnpacked else {
            throw Failure.notAnExtension("The extension could not be unpacked.")
        }
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
        // The archive's list can understate what its data inflates to, so what lands on the disk is
        // watched too: past the limit (or after a minute, longer than any extension written by hand takes)
        // the unpacking stops.
        let deadline = Date(timeIntervalSinceNow: 60)
        while exited.wait(timeout: .now() + 0.25) == .timedOut {
            guard Date() < deadline, unpackedSize(of: folder) <= largestUnpacked else {
                process.terminate()
                exited.wait()
                throw Failure.notAnExtension("The extension could not be unpacked.")
            }
        }
        guard unpackedSize(of: folder) <= largestUnpacked else { throw Failure.notAnExtension("The extension could not be unpacked.") }
        guard process.terminationStatus == 0 else { throw Failure.notAnExtension("The extension could not be unpacked.") }
        return folder
    }

    /// The bytes of the files under `folder`, as far as `largestUnpacked` and a little past it.
    private static func unpackedSize(of folder: URL) -> UInt64 {
        var total: UInt64 = 0
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [])
        while let file = files?.nextObject() as? URL, total <= largestUnpacked {
            total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
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

/// A zip archive's central directory, read without unpacking anything: how many entries it lists and how
/// large they are unpacked, as the archive declares them (ZIP64 included).
enum ZipDirectory {
    /// nil when `url` is not a zip archive this can read.
    static func contents(of url: URL) -> (entries: Int, bytes: UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 22 else { return nil }
        // The end record is in the last 64 KB and 22 bytes (its comment is at most 65,535 bytes).
        let tailStart = size - min(size, 65_557)
        guard (try? handle.seek(toOffset: tailStart)) != nil, let tail = try? handle.readToEnd(), tail.count >= 22 else { return nil }
        let bytes = [UInt8](tail)
        guard let end = stride(from: bytes.count - 22, through: 0, by: -1).first(where: { read32(bytes, $0) == 0x0605_4b50 }) else { return nil }
        var entries = UInt64(read16(bytes, end + 10))
        var directorySize = UInt64(read32(bytes, end + 12))
        var directoryOffset = UInt64(read32(bytes, end + 16))
        if entries == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // ZIP64: a locator just before the end record says where the larger end record is.
            let locator = end - 20
            guard locator >= 0, read32(bytes, locator) == 0x0706_4b50 else { return nil }
            let recordOffset = read64(bytes, locator + 8)
            guard (try? handle.seek(toOffset: recordOffset)) != nil, let record = try? handle.read(upToCount: 56), record.count == 56 else { return nil }
            let fields = [UInt8](record)
            guard read32(fields, 0) == 0x0606_4b50 else { return nil }
            entries = read64(fields, 32)
            directorySize = read64(fields, 40)
            directoryOffset = read64(fields, 48)
        }
        // A directory larger than this lists far more than `mostEntries` anyway.
        guard directorySize <= 64 * 1024 * 1024, directoryOffset <= size, directorySize <= size - directoryOffset,
              (try? handle.seek(toOffset: directoryOffset)) != nil,
              let directoryData = try? handle.read(upToCount: Int(directorySize)), directoryData.count == Int(directorySize) else { return nil }
        let directory = [UInt8](directoryData)
        var position = 0, count = 0
        var total: UInt64 = 0
        while position + 46 <= directory.count {
            guard read32(directory, position) == 0x0201_4b50 else { return nil }
            var unpacked = UInt64(read32(directory, position + 24))
            let nameLength = Int(read16(directory, position + 28)), extraLength = Int(read16(directory, position + 30))
            let commentLength = Int(read16(directory, position + 32))
            let extraStart = position + 46 + nameLength
            guard extraStart + extraLength + commentLength <= directory.count else { return nil }
            if unpacked == 0xFFFF_FFFF {
                // The real size is the first field of the ZIP64 extra block.
                var field = extraStart
                var found = false
                while field + 4 <= extraStart + extraLength {
                    let id = read16(directory, field), length = Int(read16(directory, field + 2))
                    if id == 0x0001, length >= 8, field + 12 <= directory.count {
                        unpacked = read64(directory, field + 4)
                        found = true
                        break
                    }
                    field += 4 + length
                }
                guard found else { return nil }
            }
            let (sum, overflow) = total.addingReportingOverflow(unpacked)
            guard !overflow else { return nil }
            total = sum
            count += 1
            position = extraStart + extraLength + commentLength
        }
        guard UInt64(count) == entries else { return nil }
        return (count, total)
    }

    private static func read16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func read32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(read16(bytes, at)) | UInt32(read16(bytes, at + 2)) << 16
    }

    private static func read64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        UInt64(read32(bytes, at)) | UInt64(read32(bytes, at + 4)) << 32
    }
}
