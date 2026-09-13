import AppKit
import Observation
import WhiskrKit

/// Settings › Editor: the editor's font (the terminal's unless changed), tab width, wrapping and
/// invisibles, and the last choices made in its views (how Markdown and diffs show). Applied at once,
/// kept in the app's settings.
@Observable
final class EditorPreferences {
    static let shared = EditorPreferences()

    enum MarkdownMode: String, CaseIterable, Identifiable {
        case source, preview, sideBySide
        var id: String { rawValue }
    }

    enum DiffLayout: String, CaseIterable, Identifiable {
        case sideBySide, inline
        var id: String { rawValue }
    }

    /// "" follows the terminal's font.
    var fontFamily: String { didSet { defaults.set(fontFamily, forKey: "editorFontFamily") } }
    /// 0 follows the terminal's size.
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "editorFontSize") } }
    /// How wide a tab is drawn, and the indentation of a file that does not say.
    var tabWidth: Int { didSet { defaults.set(tabWidth, forKey: "editorTabWidth") } }
    var wrapLines: Bool { didSet { defaults.set(wrapLines, forKey: "editorWrapLines") } }
    var showInvisibles: Bool { didSet { defaults.set(showInvisibles, forKey: "editorShowInvisibles") } }
    var markdownMode: MarkdownMode { didSet { defaults.set(markdownMode.rawValue, forKey: "editorMarkdownMode") } }
    var diffLayout: DiffLayout { didSet { defaults.set(diffLayout.rawValue, forKey: "editorDiffLayout") } }

    static let tabWidths = [2, 3, 4, 8]

    @ObservationIgnored private var defaults: UserDefaults { AppPlaces.defaults }

    private init() {
        let defaults = AppPlaces.defaults
        fontFamily = defaults.string(forKey: "editorFontFamily") ?? ""
        fontSize = defaults.double(forKey: "editorFontSize")
        let width = defaults.integer(forKey: "editorTabWidth")
        tabWidth = width > 0 ? width : 4
        wrapLines = defaults.object(forKey: "editorWrapLines") as? Bool ?? true
        showInvisibles = defaults.bool(forKey: "editorShowInvisibles")
        markdownMode = defaults.string(forKey: "editorMarkdownMode").flatMap(MarkdownMode.init(rawValue:)) ?? .preview
        diffLayout = defaults.string(forKey: "editorDiffLayout").flatMap(DiffLayout.init(rawValue:)) ?? .sideBySide
    }

    /// The editor's font: its own if chosen, else the terminal's.
    var font: NSFont {
        let store = ThemeStore.shared
        let size = fontSize > 0 ? CGFloat(fontSize) : store.fontSize
        if !fontFamily.isEmpty, let font = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: size) { return font }
        return store.font(size: size)
    }
}

/// How code is drawn, from the theme and the editor's settings: the text's font and colour, and each
/// token kind's colour as an appearance-aware colour (so light and dark both follow the theme).
@MainActor
final class EditorStyle {
    static let shared = EditorStyle()

    private var cachedTheme: Theme?
    private var colors: [SyntaxKind: NSColor] = [:]
    private var traits: [SyntaxKind: SyntaxStyle] = [:]

    var font: NSFont { EditorPreferences.shared.font }

    var textColor: NSColor { ThemeStore.shared.palette.terminalForeground }
    var background: NSColor { Colors.terminalBackground }

    /// A tab is drawn `tabWidth` spaces wide.
    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        style.defaultTabInterval = space * CGFloat(EditorPreferences.shared.tabWidth)
        style.tabStops = []
        style.lineHeightMultiple = 1.08
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraphStyle]
    }

    /// The colour of a kind of token in the current theme (call `refresh` once before a run of these).
    func color(_ kind: SyntaxKind) -> NSColor {
        colors[kind] ?? textColor
    }

    func style(_ kind: SyntaxKind) -> SyntaxStyle? {
        traits[kind]
    }

    /// A font for a token that is bold or italic (used where text is drawn once: diffs and the preview).
    func font(for kind: SyntaxKind, base: NSFont) -> NSFont {
        refresh()
        guard let style = style(kind), style.bold || style.italic else { return base }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if style.bold { traits.insert(.bold) }
        if style.italic { traits.insert(.italic) }
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: base.pointSize) ?? base
    }

    /// Follows the theme: the colours are worked out again when it has changed.
    func refresh() {
        let theme = ThemeStore.shared.palette.theme
        guard cachedTheme != theme || colors.isEmpty else { return }
        cachedTheme = theme
        let light = SyntaxPalette.styles(for: theme.variant(dark: false).terminal)
        let dark = SyntaxPalette.styles(for: theme.variant(dark: true).terminal)
        traits = light
        colors = [:]
        for kind in SyntaxKind.allCases {
            guard let lightColor = light[kind]?.color, let darkColor = dark[kind]?.color else { continue }
            colors[kind] = NSColor(name: nil) { appearance in
                Palette.nsColor(Palette.isDark(appearance) ? darkColor : lightColor)
            }
        }
    }
}
