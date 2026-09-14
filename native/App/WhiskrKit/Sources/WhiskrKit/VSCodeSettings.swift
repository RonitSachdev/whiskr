import Foundation

// Settings › General › Import Settings: the few settings of VS Code or Cursor that mean the same thing here
// (fonts and sizes, indentation, wrapping, invisibles, saving, the terminal's cursor, the colour theme),
// read once from the user's `settings.json` when asked, never written, never sent anywhere. Everything is
// found from a home folder the caller gives, so tests and isolated runs read only folders of their own.

/// An editor whose settings can be read: VS Code or Cursor (a fork of it, with the same files).
public enum OtherEditor: String, CaseIterable, Sendable {
    case vsCode, cursor

    public var name: String {
        switch self {
        case .vsCode: "VS Code"
        case .cursor: "Cursor"
        }
    }

    /// `~/Library/Application Support/Code/User/settings.json` (or `Cursor`).
    public func settingsFile(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(self == .vsCode ? "Code" : "Cursor", isDirectory: true)
            .appendingPathComponent("User/settings.json")
    }

    /// `~/.vscode/extensions` (or `~/.cursor/extensions`): the extensions installed in it.
    public func extensionsFolder(home: URL) -> URL {
        home.appendingPathComponent(self == .vsCode ? ".vscode" : ".cursor", isDirectory: true).appendingPathComponent("extensions", isDirectory: true)
    }
}

/// What an editor's `settings.json` says that the app can take. Every field is nil (or empty) when the
/// file does not set it.
public struct OtherEditorSettings: Equatable, Sendable {
    /// `editor.fontFamily`, as a CSS list, in order ("'JetBrains Mono', Menlo, monospace" → the two names).
    public var editorFonts: [String] = []
    public var editorFontSize: Double?
    public var tabSize: Int?
    public var insertSpaces: Bool?
    /// `editor.wordWrap`: anything but "off" wraps.
    public var wordWrap: Bool?
    /// `editor.renderWhitespace`: "all" and "boundary" show invisibles, "none" hides them; "selection" and
    /// "trailing" have no equivalent here (`unmapped`).
    public var renderWhitespace: Bool?
    public var trimTrailingWhitespace: Bool?
    public var insertFinalNewline: Bool?
    public var terminalFonts: [String] = []
    public var terminalFontSize: Double?
    /// "block", "underline" or "bar" (VS Code's "line").
    public var cursorStyle: String?
    public var cursorBlinks: Bool?
    /// `workbench.colorTheme`, and the themes for each appearance when the editor follows the system's.
    public var colorTheme: String?
    public var preferredLightTheme: String?
    public var preferredDarkTheme: String?
    /// Settings the file sets that have a counterpart here but a value without one ("editor.renderWhitespace": "selection").
    public var unmapped: [String] = []

    public init() {}

    /// Reads a `settings.json` (JSON with comments). Language-specific blocks (`"[python]": { … }`) are
    /// left out: the app's settings are not per language.
    public init(settingsJSON data: Data) throws {
        let json: [String: Any]
        do {
            json = try JSONC.dictionary(data)
        } catch {
            throw ThemeImportError.unreadable(String(localized: "The settings file is not JSON.", bundle: .module, comment: "Importing VS Code or Cursor settings: why they could not be read"))
        }
        // Only a finite number: "nan", "inf" and 1e300 are no size (and 1e300 would trap as an Int).
        func number(_ key: String) -> Double? {
            ((json[key] as? NSNumber).map(\.doubleValue) ?? (json[key] as? String).flatMap(Double.init)).flatMap { $0.isFinite ? $0 : nil }
        }
        func flag(_ key: String) -> Bool? { json[key] as? Bool }
        func text(_ key: String) -> String? { (json[key] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } }

        editorFonts = text("editor.fontFamily").map(Self.fontFamilies) ?? []
        editorFontSize = number("editor.fontSize")
        tabSize = number("editor.tabSize").flatMap { Int(exactly: $0.rounded(.towardZero)) }
        insertSpaces = flag("editor.insertSpaces")
        wordWrap = text("editor.wordWrap").map { $0 != "off" }
        switch text("editor.renderWhitespace") {
        case "all", "boundary": renderWhitespace = true
        case "none": renderWhitespace = false
        case let other?: unmapped.append("editor.renderWhitespace “\(other)”")
        case nil: break
        }
        trimTrailingWhitespace = flag("files.trimTrailingWhitespace")
        insertFinalNewline = flag("files.insertFinalNewline")
        terminalFonts = text("terminal.integrated.fontFamily").map(Self.fontFamilies) ?? []
        terminalFontSize = number("terminal.integrated.fontSize")
        switch text("terminal.integrated.cursorStyle") {
        case "block": cursorStyle = "block"
        case "underline": cursorStyle = "underline"
        case "line": cursorStyle = "bar"
        case let other?: unmapped.append("terminal.integrated.cursorStyle “\(other)”")
        case nil: break
        }
        cursorBlinks = flag("terminal.integrated.cursorBlinking")
        colorTheme = text("workbench.colorTheme")
        preferredLightTheme = text("workbench.preferredLightColorTheme")
        preferredDarkTheme = text("workbench.preferredDarkColorTheme")
    }

    /// The family names of a CSS font list, in order, without quotes and without the generic families
    /// ("monospace", …) that name no font.
    public static func fontFamilies(_ list: String) -> [String] {
        let generic: Set<String> = ["monospace", "ui-monospace", "serif", "sans-serif", "system-ui", "cursive", "fantasy", "math", "emoji", "fangsong"]
        return list.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "'\""))) }
            .filter { !$0.isEmpty && !generic.contains($0.lowercased()) }
    }

    /// The first of `families` that `available` has (compared without regard to case), as `available` spells it.
    public static func firstAvailable(_ families: [String], in available: [String]) -> String? {
        for family in families {
            if let found = available.first(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) { return found }
        }
        return nil
    }
}

extension ExtensionManifest {
    /// The installed extension, among the folders inside `extensions`, that contributes a colour theme with
    /// this id or label (as `workbench.colorTheme` names it); the newest version when several are there.
    public static func installed(theme name: String, in extensions: URL) -> (extension: ExtensionManifest, theme: ThemeContribution)? {
        let folders = ((try? FileManager.default.contentsOfDirectory(at: extensions, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
        for folder in folders {
            guard let manifest = try? ExtensionManifest.read(folder: folder),
                  let theme = manifest.themes.first(where: { $0.id == name || $0.label == name }) else { continue }
            return (manifest, theme)
        }
        return nil
    }
}
