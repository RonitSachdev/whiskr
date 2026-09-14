import AppKit
import WhiskrKit

/// Settings › General › Import Settings: takes, once and only when asked, what VS Code's or Cursor's
/// `settings.json` says that means the same thing here (`OtherEditorSettings`), and its colour theme when
/// that is one of the built-in themes or an extension installed beside it. Nothing is written back and
/// nothing is sent anywhere; the files are found under `AppPlaces.otherEditorsHome`.
enum OtherEditorImport {
    /// VS Code's names for the themes the app has built in.
    private static let builtInThemes: [String: String] = [
        "Default Dark Modern": "modern", "Dark Modern": "modern", "Default Light Modern": "modern", "Light Modern": "modern",
        "Monokai": "monokai", "Solarized Dark": "solarized", "Solarized Light": "solarized",
    ]

    /// Applies what maps and gives one short summary of what was applied and what was not.
    static func apply(from editor: OtherEditor) -> String {
        let home = AppPlaces.otherEditorsHome
        let file = editor.settingsFile(home: home)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return String(localized: "No \(editor.name) settings were found.", comment: "Settings › General › Import Settings: the editor's settings.json is not there")
        }
        let settings: OtherEditorSettings
        do {
            settings = try OtherEditorSettings(settingsJSON: Data(contentsOf: file))
        } catch let error as ThemeImportError {
            return error.message
        } catch {
            return error.localizedDescription
        }

        var applied: [String] = []
        var skipped: [String] = settings.unmapped
        let preferences = EditorPreferences.shared, store = ThemeStore.shared
        let fonts = ThemeStore.monospacedFamilies
        if !settings.editorFonts.isEmpty {
            if let family = OtherEditorSettings.firstAvailable(settings.editorFonts, in: fonts) {
                preferences.fontFamily = family
                applied.append(String(localized: "editor font (\(family))", comment: "Import Settings summary"))
            } else {
                skipped.append(String(localized: "editor.fontFamily (not installed here)", comment: "Import Settings summary: none of the fonts named is on this Mac"))
            }
        }
        if let size = settings.editorFontSize {
            preferences.fontSize = min(max(size, Double(ThemeStore.fontSizes.lowerBound)), Double(ThemeStore.fontSizes.upperBound))
            applied.append(String(localized: "editor size", comment: "Import Settings summary"))
        }
        if let tabs = settings.tabSize {
            if EditorPreferences.tabWidths.contains(tabs) {
                preferences.tabWidth = tabs
                applied.append(String(localized: "tab width", comment: "Import Settings summary"))
            } else {
                skipped.append("editor.tabSize \(tabs)")
            }
        }
        if let spaces = settings.insertSpaces {
            preferences.insertSpaces = spaces
            applied.append(String(localized: "spaces or tabs", comment: "Import Settings summary: editor.insertSpaces"))
        }
        if let wrap = settings.wordWrap {
            preferences.wrapLines = wrap
            applied.append(String(localized: "wrapping", comment: "Import Settings summary"))
        }
        if let invisibles = settings.renderWhitespace {
            preferences.showInvisibles = invisibles
            applied.append(String(localized: "invisibles", comment: "Import Settings summary"))
        }
        if let trim = settings.trimTrailingWhitespace {
            preferences.trimTrailingWhitespace = trim
            applied.append(String(localized: "trailing whitespace", comment: "Import Settings summary: files.trimTrailingWhitespace"))
        }
        if let newline = settings.insertFinalNewline {
            preferences.insertFinalNewline = newline
            applied.append(String(localized: "final newline", comment: "Import Settings summary: files.insertFinalNewline"))
        }
        if !settings.terminalFonts.isEmpty {
            if let family = OtherEditorSettings.firstAvailable(settings.terminalFonts, in: fonts) {
                store.fontFamily = family
                applied.append(String(localized: "terminal font (\(family))", comment: "Import Settings summary"))
            } else {
                skipped.append(String(localized: "terminal.integrated.fontFamily (not installed here)", comment: "Import Settings summary: none of the fonts named is on this Mac"))
            }
        }
        if let size = settings.terminalFontSize {
            store.setFontSize(CGFloat(size))
            applied.append(String(localized: "terminal size", comment: "Import Settings summary"))
        }
        if let shape = settings.cursorStyle.flatMap(ThemeStore.CursorShape.init) {
            store.cursorShape = shape
            applied.append(String(localized: "cursor", comment: "Import Settings summary"))
        }
        if let blinks = settings.cursorBlinks {
            store.cursorBlinks = blinks
            applied.append(String(localized: "blinking", comment: "Import Settings summary"))
        }
        if let name = settings.colorTheme {
            if let theme = theme(named: name, editor: editor, home: home, settings: settings) {
                store.themeID = theme.id
                applied.append(String(localized: "theme (\(theme.name))", comment: "Import Settings summary"))
            } else {
                skipped.append(String(localized: "theme “\(name)” (not built in, nor installed as an extension)", comment: "Import Settings summary"))
            }
        }

        var lines: [String] = []
        if applied.isEmpty {
            lines.append(String(localized: "Nothing in \(editor.name)’s settings applies here.", comment: "Import Settings summary"))
        } else {
            lines.append(String(localized: "From \(editor.name): \(ListFormatter.localizedString(byJoining: applied)).", comment: "Import Settings summary: what was applied"))
        }
        if !skipped.isEmpty {
            lines.append(String(localized: "Not applied: \(ListFormatter.localizedString(byJoining: skipped)).", comment: "Import Settings summary: what was left as it is"))
        }
        return lines.joined(separator: "\n")
    }

    /// The theme `name` names: one built in, one already imported, or imported now from the extension
    /// installed beside the editor that contributes it. When the editor follows the system's appearance with
    /// a light and a dark theme from extensions, the two are paired.
    private static func theme(named name: String, editor: OtherEditor, home: URL, settings: OtherEditorSettings) -> Theme? {
        let store = ThemeStore.shared
        if let id = builtInThemes[name] { return BuiltInThemes.theme(id: id) }
        func imported(_ name: String) -> Theme? {
            store.userThemes.first { $0.name == name || [$0.light?.origin?.name, $0.dark?.origin?.name].contains(name) }
        }
        func find(_ name: String) -> Theme? {
            if let theme = imported(name) { return theme }
            guard let found = ExtensionManifest.installed(theme: name, in: editor.extensionsFolder(home: home)) else { return nil }
            _ = try? store.importThemes(at: found.extension.folder)
            return imported(found.theme.label)
        }
        guard let theme = find(name) else { return nil }
        // VS Code's light and dark choices, as one theme of both, when they came as two.
        if let lightName = settings.preferredLightTheme, let darkName = settings.preferredDarkTheme,
           [lightName, darkName].contains(name), builtInThemes[lightName] == nil, builtInThemes[darkName] == nil,
           let light = find(lightName), let dark = find(darkName), light.id != dark.id,
           light.fixedDarkness == false, dark.fixedDarkness == true {
            try? store.pair(light, with: dark)
            return store.theme
        }
        return theme
    }
}
