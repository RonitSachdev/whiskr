import Foundation

// Taking themes in: from a file (the app's own, iTerm2's, a VS Code colour theme or a TextMate `.tmTheme`),
// from a VS Code extension's folder, or from its `.vsix`. A VS Code theme becomes a Whiskr theme
// (`VSCodeThemeConversion`), and its original files are copied beside the app's themes so it can be read
// again; an extension's light and dark versions of one theme become one theme with both
// (`ThemePairing`). Nothing of an extension is run.

extension ThemeImport {
    /// The file extensions a VS Code colour theme or a TextMate theme may have.
    public static let vsCodeThemeExtensions: Set<String> = ["json", "jsonc", "tmtheme"]

    /// Every theme in what `url` is, each meeting the guarantees (`ThemeGuarantees.swift`). For VS Code
    /// themes the original files (the theme files and what they include, and an extension's
    /// `package.json` and `package.nls.json`) are copied into a new folder inside `originals`, which
    /// the themes' origins name. An extension with no themes gives none (it may have languages).
    public static func themes(at url: URL, originals: URL) throws -> [Theme] {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isFolder) else { throw ThemeImportError.unreadable(String(localized: "The file could not be read.", bundle: .module, comment: "Importing a theme: why it could not be read")) }
        if isFolder.boolValue { return try extensionThemes(in: url, originals: originals) }
        let ext = url.pathExtension.lowercased()
        if ext == "vsix" {
            let unpacked = fileManager.temporaryDirectory.appendingPathComponent("whiskr-vsix-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: unpacked) }
            do {
                return try extensionThemes(in: ExtensionManifest.unpack(vsix: url, into: unpacked), originals: originals)
            } catch is ExtensionManifest.Failure {
                throw ThemeImportError.unreadable(String(localized: "This .vsix could not be unpacked.", bundle: .module, comment: "Importing a theme: why it could not be read"))
            }
        }
        if url.lastPathComponent == "package.json" { return try extensionThemes(in: url.deletingLastPathComponent(), originals: originals) }
        if vsCodeThemeExtensions.contains(ext) { return [try vsCodeTheme(at: url, originals: originals)] }
        var theme = try file(at: url)
        if ext == "itermcolors" {
            theme.light = theme.light?.meetingGuarantees().variant
            theme.dark = theme.dark?.meetingGuarantees().variant
        }
        return [theme]
    }

    /// One VS Code colour theme file (and what it includes, from its own folder).
    static func vsCodeTheme(at url: URL, originals: URL) throws -> Theme {
        let root = url.deletingLastPathComponent()
        let document = try VSCodeThemeDocument.read(url, root: root)
        let base = url.deletingPathExtension().lastPathComponent
        // Without a name of its own, its file's: "monokai-color-theme.json" → "Monokai".
        let name = document.name ?? base.replacingOccurrences(of: "-color-theme", with: "")
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let kind = VSCodeThemeConversion.kind(of: document, declared: nil)
        let folder = try keep(document.files, from: root, in: originals, named: Theme.slug(name))
        let origin = ThemeOrigin(name: name, folder: folder, file: relative(url, to: root), uiTheme: kind.rawValue)
        let variant = VSCodeThemeConversion(document, kind: kind, origin: origin).variant
        return Theme(id: Theme.slug(name), name: name, credit: "Imported from a VS Code colour theme",
                     light: variant.isDark ? nil : variant, dark: variant.isDark ? variant : nil)
    }

    /// The themes an extension contributes, its light and dark versions of one theme paired.
    static func extensionThemes(in folder: URL, originals: URL) throws -> [Theme] {
        let manifest: ExtensionManifest
        do {
            manifest = try ExtensionManifest.read(folder: folder)
        } catch let ExtensionManifest.Failure.notAnExtension(why) {
            throw ThemeImportError.unreadable(why)
        }
        guard !manifest.themes.isEmpty else { return [] }
        let root = manifest.folder
        var documents: [(contribution: ExtensionManifest.ThemeContribution, document: VSCodeThemeDocument, kind: VSCodeThemeKind)] = []
        for contribution in manifest.themes {
            let document = try VSCodeThemeDocument.read(contribution.path, root: root)
            documents.append((contribution, document, VSCodeThemeConversion.kind(of: document, declared: VSCodeThemeKind(uiTheme: contribution.uiTheme))))
        }
        var files = [root.appendingPathComponent("package.json")]
        let words = root.appendingPathComponent("package.nls.json")
        if FileManager.default.fileExists(atPath: words.path) { files.append(words) }
        for entry in documents { files += entry.document.files.filter { !files.contains($0) } }
        let folderName = try keep(files, from: root, in: originals, named: Theme.slug(manifest.identifier))
        let credit = "From \(manifest.displayName) (\(manifest.identifier))" + (manifest.license.map { " · \($0) licence" } ?? "")

        let themes: [Theme] = documents.map { entry in
            let origin = ThemeOrigin(name: entry.contribution.label, folder: folderName, file: relative(entry.contribution.path, to: root),
                                     uiTheme: entry.kind.rawValue)
            let variant = VSCodeThemeConversion(entry.document, kind: entry.kind, origin: origin).variant
            return Theme(id: Theme.slug(entry.contribution.label), name: entry.contribution.label, credit: credit,
                         light: variant.isDark ? nil : variant, dark: variant.isDark ? variant : nil)
        }
        let pairs = ThemePairing.pairs(documents.map { ($0.contribution.label, $0.kind) }, extensionName: manifest.displayName)
        var result: [Theme] = []
        var paired = Set<Int>()
        for (index, theme) in themes.enumerated() where !paired.contains(index) {
            if let pair = pairs.first(where: { $0.light == index || $0.dark == index }) {
                paired.formUnion([pair.light, pair.dark])
                result.append(ThemePairing.pair(light: themes[pair.light], dark: themes[pair.dark], name: pair.name))
            } else {
                result.append(theme)
            }
        }
        return result
    }

    /// Copies `files` (each inside `root`) into a new folder in `originals`, keeping their places
    /// relative to `root`; gives the folder's name.
    private static func keep(_ files: [URL], from root: URL, in originals: URL, named name: String) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: originals, withIntermediateDirectories: true)
        var folderName = name
        var number = 2
        while fileManager.fileExists(atPath: originals.appendingPathComponent(folderName).path) {
            folderName = "\(name)-\(number)"
            number += 1
        }
        let folder = originals.appendingPathComponent(folderName, isDirectory: true)
        do {
            for file in files {
                let target = folder.appendingPathComponent(relative(file, to: root))
                try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: file, to: target)
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            throw ThemeImportError.unreadable(String(localized: "The theme's files could not be kept: \(error.localizedDescription)", bundle: .module, comment: "Importing a theme: why it could not be read"))
        }
        return folderName
    }

    /// `file`'s path inside `root` ("themes/dark_modern.json").
    static func relative(_ file: URL, to root: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : file.lastPathComponent
    }
}

/// Light and dark versions of one theme, as one theme with both (as the built-in themes have them).
public enum ThemePairing {
    /// A theme's name without "Light" or "Dark": "Dark Modern" → "Modern", "Light (Visual Studio)" →
    /// "Visual Studio", "GitHub Dark Default" → "GitHub Default", "Dark+" → "+".
    public static func family(_ name: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "\\b(light|dark)\\b", options: [.caseInsensitive])
        let stripped = pattern.stringByReplacingMatches(in: name, range: NSRange(name.startIndex..., in: name), withTemplate: " ")
        let words = stripped.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—_·:,()[]")))
    }

    /// Which of an extension's themes go together, by index: two whose names are the same but for
    /// "Light" and "Dark" (one light, one dark, both high-contrast or neither); else, when the extension has
    /// exactly one light and one dark theme that is not high-contrast, those two, named after the extension.
    public static func pairs(_ themes: [(name: String, kind: VSCodeThemeKind)], extensionName: String) -> [(light: Int, dark: Int, name: String)] {
        var result: [(light: Int, dark: Int, name: String)] = []
        let groups = Dictionary(grouping: themes.indices) { "\(family(themes[$0].name).lowercased())|\(themes[$0].kind.isHighContrast)" }
        for key in groups.keys.sorted() {
            let members = groups[key]!
            let lights = members.filter { !themes[$0].kind.isDark }, darks = members.filter { themes[$0].kind.isDark }
            guard lights.count == 1, darks.count == 1 else { continue }
            result.append((lights[0], darks[0], name(light: themes[lights[0]].name, dark: themes[darks[0]].name)))
        }
        if result.isEmpty {
            let plain = themes.indices.filter { !themes[$0].kind.isHighContrast }
            let lights = plain.filter { !themes[$0].kind.isDark }, darks = plain.filter { themes[$0].kind.isDark }
            if lights.count == 1, darks.count == 1 { result.append((lights[0], darks[0], extensionName)) }
        }
        return result.sorted { min($0.light, $0.dark) < min($1.light, $1.dark) }
    }

    /// The name of a pair: what the two share once "Light" and "Dark" are taken out, else the words they
    /// start with ("Catppuccin Latte" and "Catppuccin Mocha" → "Catppuccin"), else both names.
    public static func name(light: String, dark: String) -> String {
        let (a, b) = (family(light), family(dark))
        if a.lowercased() == b.lowercased(), a.contains(where: { $0.isLetter || $0.isNumber }) { return a }
        let common = zip(light.split(separator: " "), dark.split(separator: " ")).prefix { $0 == $1 }.map { String($0.0) }
        if !common.isEmpty { return common.joined(separator: " ") }
        return "\(light) / \(dark)"
    }

    /// One theme with `light`'s light version and `dark`'s dark one. Each version remembers the name of
    /// the theme it came from, so `separate` can give the two back.
    public static func pair(light: Theme, dark: Theme, name: String? = nil) -> Theme {
        var lightVariant = light.variant(dark: false), darkVariant = dark.variant(dark: true)
        if lightVariant.origin == nil { lightVariant.origin = ThemeOrigin(name: light.name) }
        if darkVariant.origin == nil { darkVariant.origin = ThemeOrigin(name: dark.name) }
        let name = name ?? Self.name(light: light.name, dark: dark.name)
        let credit = light.credit == dark.credit ? light.credit : [light.credit, dark.credit].compactMap { $0 }.joined(separator: "; ")
        return Theme(id: Theme.slug(name), name: name, author: light.author ?? dark.author, credit: credit, light: lightVariant, dark: darkVariant)
    }

    /// A theme with both versions as two themes, each named as the theme it came from (or this one's
    /// name with "Light" and "Dark").
    public static func separate(_ theme: Theme) -> [Theme] {
        guard let light = theme.light, let dark = theme.dark else { return [theme] }
        let lightName = light.origin?.name ?? "\(theme.name) Light", darkName = dark.origin?.name ?? "\(theme.name) Dark"
        return [
            Theme(id: Theme.slug(lightName), name: lightName, author: theme.author, credit: theme.credit, light: light, dark: nil),
            Theme(id: Theme.slug(darkName), name: darkName, author: theme.author, credit: theme.credit, light: nil, dark: dark),
        ]
    }
}
