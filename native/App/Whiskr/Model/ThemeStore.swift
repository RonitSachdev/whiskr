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
        var theme = theme
        theme.isBuiltIn = false
        try FileManager.default.createDirectory(at: Self.themesFolder, withIntermediateDirectories: true)
        try theme.fileData().write(to: file(for: theme.id), options: .atomic)
        userThemes.removeAll { $0.id == theme.id }
        userThemes.append(theme)
        userThemes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if themeID == theme.id { rebuild() } else { themeID = theme.id }
    }

    func delete(userTheme theme: Theme) {
        guard !theme.isBuiltIn else { return }
        try? FileManager.default.removeItem(at: file(for: theme.id))
        userThemes.removeAll { $0.id == theme.id }
        if themeID == theme.id { themeID = BuiltInThemes.defaultID }
    }

    /// Reads a theme file (ours, or iTerm2's `.itermcolors`), keeps it with your themes and selects it.
    @discardableResult
    func importTheme(at url: URL) throws -> Theme {
        var theme = try ThemeImport.file(at: url)
        theme.id = uniqueID(for: theme.id)
        try save(userTheme: theme)
        return theme
    }

    /// An id for a copy of a theme that clashes with none: "nord", "nord-2", …
    func uniqueID(for id: String) -> String {
        let taken = Set(themes.map(\.id))
        guard taken.contains(id) else { return id }
        var number = 2
        while taken.contains("\(id)-\(number)") { number += 1 }
        return "\(id)-\(number)"
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
        userThemes = files.filter { $0.pathExtension == Theme.fileExtension }.compactMap { url in
            guard var theme = try? Theme.read(Data(contentsOf: url)), !BuiltInThemes.all.contains(where: { $0.id == theme.id }) else { return nil }
            theme.isBuiltIn = false
            return theme
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func rebuild() {
        palette = Palette(theme: theme)
        applyAppearance()
    }

    /// A theme with only one variant decides the appearance; otherwise your choice does.
    private func applyAppearance() {
        let dark: Bool? = theme.fixedDarkness ?? (appearance == .system ? nil : appearance == .dark)
        NSApp?.appearance = dark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
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
    var terminalForeground: NSColor { Palette.dynamic(theme) { $0.terminal.foreground } }

    nonisolated static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
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
