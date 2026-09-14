import AppKit
import Observation
import SwiftUI
import WhiskrKit

/// The app's look: Light, Dark or the system's appearance, the theme (built-in or your own), and the
/// terminal's font and cursor. Everything on screen takes its colours from here, and the future scene
/// will too (for its flags and rings). Settings are kept in the user defaults; your own themes are
/// `.whiskrtheme` files in `~/Library/Application Support/Whiskr/Themes`.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self { case .system: "Follow system"; case .light: "Light"; case .dark: "Dark" }
        }
    }

    enum CursorShape: String, CaseIterable, Identifiable {
        case block, underline, bar
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var appearance: Appearance { didSet { save(); applyAppearance() } }
    var themeID: String { didSet { save(); rebuild() } }
    /// "" for the system's monospaced font (SF Mono).
    var fontFamily: String { didSet { save() } }
    var fontSize: CGFloat { didSet { save() } }
    /// 1 is the font's own line height; up to 1.6.
    var lineHeight: CGFloat { didSet { save() } }
    var cursorShape: CursorShape { didSet { save() } }
    var cursorBlinks: Bool { didSet { save() } }

    private(set) var userThemes: [Theme] = []
    /// The active theme's colours, as appearance-aware colours. Replaced whenever the theme changes.
    private(set) var palette: Palette

    static let fontSizes: ClosedRange<CGFloat> = 9...28
    static let defaultFontSize: CGFloat = 13
    static let lineHeights: ClosedRange<CGFloat> = 1...1.6

    static var themesFolder: URL { Workbench.supportFolder.appendingPathComponent("Themes", isDirectory: true) }
    /// Copies of the files imported VS Code themes were read from, one folder per import, so they can be
    /// read again (`ThemeOrigin`).
    static var originalsFolder: URL { themesFolder.appendingPathComponent("Originals", isDirectory: true) }

    private enum Key {
        static let appearance = "appearance", theme = "theme", fontFamily = "terminalFontFamily", fontSize = "terminalFontSize"
        static let lineHeight = "terminalLineHeight", cursorShape = "terminalCursorShape", cursorBlinks = "terminalCursorBlinks"
    }

    private init() {
        let defaults = AppPlaces.defaults
        // The app follows the system's appearance (no setting of its own, as Apple asks); a theme with
        // only one version still decides it. Debug runs may set one for a look.
        appearance = .system
        themeID = defaults.string(forKey: Key.theme) ?? BuiltInThemes.defaultID
        fontFamily = defaults.string(forKey: Key.fontFamily) ?? ""
        let size = defaults.double(forKey: Key.fontSize)
        fontSize = size > 0 ? CGFloat(size) : Self.defaultFontSize
        let height = defaults.double(forKey: Key.lineHeight)
        lineHeight = height > 0 ? CGFloat(height) : 1
        cursorShape = defaults.string(forKey: Key.cursorShape).flatMap(CursorShape.init) ?? .block
        cursorBlinks = defaults.object(forKey: Key.cursorBlinks) as? Bool ?? true
        palette = Palette(theme: BuiltInThemes.theme(id: BuiltInThemes.defaultID)!)
        loadUserThemes()
        rebuild()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ThemeStore.shared.applyAppearance() }
        }
    }

    // MARK: Reading

    var themes: [Theme] { BuiltInThemes.all + userThemes }

    var theme: Theme {
        themes.first { $0.id == themeID } ?? BuiltInThemes.theme(id: BuiltInThemes.defaultID)!
    }

    func font(size: CGFloat? = nil) -> NSFont {
        let size = size ?? fontSize
        if !fontFamily.isEmpty, let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Font families whose letters are all one width, for the terminal font menu.
    static var monospacedFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard !family.hasPrefix("."), let font = NSFont(name: family, size: 12) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12) else { return false }
            return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        }
    }

    // MARK: Changing

    func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, Self.fontSizes.lowerBound), Self.fontSizes.upperBound)
    }

    /// Saves a theme of your own (new or edited) and makes it the active one.
    func save(userTheme theme: Theme) throws {
        try write(userTheme: theme)
        if themeID == theme.id { rebuild() } else { themeID = theme.id }
    }

    /// Saves a theme of your own without choosing it.
    private func write(userTheme theme: Theme) throws {
        var theme = theme
        theme.isBuiltIn = false
        try FileManager.default.createDirectory(at: Self.themesFolder, withIntermediateDirectories: true)
        try theme.fileData().write(to: file(for: theme.id), options: .atomic)
        userThemes.removeAll { $0.id == theme.id }
        userThemes.append(theme)
        userThemes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func delete(userTheme theme: Theme) {
        guard !theme.isBuiltIn else { return }
        try? FileManager.default.removeItem(at: file(for: theme.id))
        userThemes.removeAll { $0.id == theme.id }
        if themeID == theme.id { themeID = BuiltInThemes.defaultID }
    }

    /// Removes a theme of your own, with the copy of the original files it was imported from once no
    /// other theme came from them.
    func remove(userTheme theme: Theme) {
        delete(userTheme: theme)
        // Only a folder directly inside Originals (`ThemeOrigin.originalsFolder(in:)`), and to the Trash:
        // the name comes from a file anyone could have written.
        let originals = Self.originalsFolder
        let used = Set(userThemes.flatMap { [$0.light?.origin, $0.dark?.origin] }.compactMap { $0?.originalsFolder(in: originals) })
        for folder in Set([theme.light?.origin, theme.dark?.origin].compactMap { $0?.originalsFolder(in: originals) }) where !used.contains(folder) {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
    }

    /// Reads every theme in a file (ours, iTerm2's, a VS Code colour theme or a TextMate theme), a VS Code
    /// extension's folder or its `.vsix`, keeps them with your themes (and the originals of VS Code's in
    /// `originalsFolder`) and selects the first. Gives what was added; none for an extension without themes.
    @discardableResult
    func importThemes(at url: URL) throws -> [Theme] {
        try add(imported: ThemeImport.themes(at: url, originals: Self.originalsFolder))
    }

    /// Keeps themes read for an import (`ThemeImport.themes`) with your themes and selects the first.
    /// Gives what was added.
    @discardableResult
    func add(imported: [Theme]) throws -> [Theme] {
        var added: [Theme] = []
        for var theme in imported {
            // A theme that is already here (Monokai imported from VS Code is the built-in one) is chosen, not
            // added twice; another of the same name is told apart by a number, as its file is.
            if let existing = themes.first(where: { $0.name == theme.name && $0.hasSameColors(as: theme) }) {
                added.append(existing)
                continue
            }
            theme.id = uniqueID(for: theme.id)
            if themes.contains(where: { $0.name == theme.name }) { theme.name = uniqueName(for: theme.name) }
            try write(userTheme: theme)
            added.append(theme)
        }
        if let first = added.first { if themeID == first.id { rebuild() } else { themeID = first.id } }
        return added
    }

    /// What the last import added, in one line ("Added Monokai and 2 languages."), for Settings to show.
    var importSummary: String?

    /// Themes of your own with only the other appearance, which `theme` (one of yours with only one) can
    /// be paired with.
    func pairCandidates(for theme: Theme) -> [Theme] {
        guard !theme.isBuiltIn, let dark = theme.fixedDarkness else { return [] }
        return userThemes.filter { $0.fixedDarkness == !dark }
    }

    /// Makes one theme of two of yours, one light and one dark, as the built-in themes have both; the two
    /// are replaced by it, and it is chosen.
    func pair(_ theme: Theme, with other: Theme) throws {
        let (light, dark) = theme.fixedDarkness == false ? (theme, other) : (other, theme)
        var paired = ThemePairing.pair(light: light, dark: dark)
        delete(userTheme: theme)
        delete(userTheme: other)
        paired.id = uniqueID(for: paired.id)
        try save(userTheme: paired)
    }

    /// Gives back the two themes a paired theme of yours was made of; the light one is chosen.
    func separate(_ theme: Theme) throws {
        guard !theme.isBuiltIn, theme.light != nil, theme.dark != nil else { return }
        delete(userTheme: theme)
        var first = true
        for var part in ThemePairing.separate(theme) {
            part.id = uniqueID(for: part.id)
            if first { try save(userTheme: part) } else { try write(userTheme: part) }
            first = false
        }
    }

    /// An id for a copy of a theme that clashes with none: "nord", "nord-2", …
    func uniqueName(for name: String) -> String {
        let taken = Set(themes.map(\.name))
        var number = 2
        while taken.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    func uniqueID(for id: String) -> String {
        Theme.uniqueID(for: id, taken: themes.map(\.id))
    }

    func showThemesFolder() {
        try? FileManager.default.createDirectory(at: Self.themesFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([Self.themesFolder])
    }

    // MARK: Internals

    private func file(for id: String) -> URL {
        Self.themesFolder.appendingPathComponent("\(Theme.slug(id)).\(Theme.fileExtension)")
    }

    private func loadUserThemes() {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.themesFolder, includingPropertiesForKeys: nil)) ?? []
        // Ids are slugs, as the files are named (`Theme.uniqueID`). Of two files whose ids come to the same
        // slug, the one named by it is the theme and the other is left out, so deleting the theme removes
        // its own file.
        var taken = Set(BuiltInThemes.all.map(\.id))
        let read: [(url: URL, theme: Theme)] = files.filter { $0.pathExtension == Theme.fileExtension }.compactMap { url in
            (try? Theme.read(Data(contentsOf: url))).map { (url, $0) }
        }
        func order(_ entry: (url: URL, theme: Theme)) -> (Int, String) {
            (entry.url.lastPathComponent == file(for: entry.theme.id).lastPathComponent ? 0 : 1, entry.url.lastPathComponent)
        }
        userThemes = read
            .sorted { order($0) < order($1) }
            .compactMap { _, theme in
                var theme = theme
                guard !taken.contains(Theme.slug(theme.id)) else { return nil }
                if theme.id != Theme.slug(theme.id) {
                    if themeID == theme.id { themeID = Theme.slug(theme.id) }
                    theme.id = Theme.slug(theme.id)
                }
                taken.insert(theme.id)
                theme.isBuiltIn = false
                return theme
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func rebuild() {
        palette = Palette(theme: theme)
        applyAppearance()
    }

    /// A theme with only one variant decides the appearance; otherwise your choice does.
    /// A forced appearance keeps Increase Contrast: the high-contrast one is named then, since a plain
    /// Aqua or Dark Aqua would drop it.
    private func applyAppearance() {
        let dark: Bool? = theme.fixedDarkness ?? (appearance == .system ? nil : appearance == .dark)
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        NSApp?.appearance = dark.map { dark in
            NSAppearance(named: contrast ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : (dark ? .darkAqua : .aqua))!
        }
    }

    private func save() {
        let defaults = AppPlaces.defaults
        defaults.set(appearance.rawValue, forKey: Key.appearance)
        defaults.set(themeID, forKey: Key.theme)
        defaults.set(fontFamily, forKey: Key.fontFamily)
        defaults.set(Double(fontSize), forKey: Key.fontSize)
        defaults.set(Double(lineHeight), forKey: Key.lineHeight)
        defaults.set(cursorShape.rawValue, forKey: Key.cursorShape)
        defaults.set(cursorBlinks, forKey: Key.cursorBlinks)
    }
}

/// A theme's colours as AppKit and SwiftUI colours that follow the appearance they are drawn in.
struct Palette {
    let theme: Theme
    private let app: [AppColorKey: NSColor]
    private let swiftUI: [AppColorKey: SwiftUI.Color]
    /// Text on the "needs you" pill: white or near-black, whichever reads better on the theme's red.
    let onNeedsYou: SwiftUI.Color

    init(theme: Theme) {
        self.theme = theme
        var app: [AppColorKey: NSColor] = [:]
        for key in AppColorKey.allCases {
            app[key] = Palette.dynamic(theme) { $0.app[key] }
        }
        // With Increase Contrast (docs/DESIGN.md), every line between regions reaches 3:1 on the chrome (the
        // hint colour, which the theme keeps at 3:1 there), and each quieter text steps up one level.
        let stronger: [AppColorKey: AppColorKey] = [.line: .textTertiary, .lineStrong: .textTertiary, .textSecondary: .text, .textTertiary: .textSecondary]
        for (key, raised) in stronger {
            app[key] = NSColor(name: nil) { appearance in
                let variant = theme.variant(dark: Palette.isDark(appearance))
                return Palette.nsColor(Palette.isHighContrast(appearance) ? variant.app[raised] : variant.app[key])
            }
        }
        self.app = app
        swiftUI = app.mapValues { SwiftUI.Color(nsColor: $0) }
        onNeedsYou = SwiftUI.Color(nsColor: Palette.dynamic(theme) { variant in
            let red = variant.app[.needsYou], ink = WhiskrKit.RGBColor(0x141414)
            return red.contrast(with: .white) >= red.contrast(with: ink) ? .white : ink
        })
    }

    subscript(key: AppColorKey) -> NSColor { app[key]! }
    func color(_ key: AppColorKey) -> SwiftUI.Color { swiftUI[key]! }

    var terminalBackground: NSColor { Palette.dynamic(theme) { $0.terminal.background } }
    /// One of the editor's, the diffs' or the file list's colours (`EditorColorKey`).
    func editor(_ key: EditorColorKey) -> NSColor { Palette.dynamic(theme) { $0.editor[key] } }
    var terminalForeground: NSColor { Palette.dynamic(theme) { $0.terminal.foreground } }

    nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// The system's Increase Contrast is on (its appearances are the high-contrast ones then).
    nonisolated static func isHighContrast(_ appearance: NSAppearance) -> Bool {
        let name = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        return name == .accessibilityHighContrastAqua || name == .accessibilityHighContrastDarkAqua
    }

    nonisolated static func nsColor(_ color: WhiskrKit.RGBColor) -> NSColor {
        NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    /// A colour that is the theme's light or dark value, whichever the drawing appearance asks for.
    nonisolated static func dynamic(_ theme: Theme, _ pick: @escaping @Sendable (ThemeVariant) -> WhiskrKit.RGBColor) -> NSColor {
        NSColor(name: nil) { appearance in
            nsColor(pick(theme.variant(dark: isDark(appearance))))
        }
    }
}
