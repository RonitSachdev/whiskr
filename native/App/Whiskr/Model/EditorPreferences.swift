import AppKit
import Observation
import WhiskrKit

/// Settings › Editor: the editor's font (the terminal's unless changed), the indentation of a file that
/// does not say, wrapping and invisibles, what saving tidies, and the last choices made in its views (how
/// Markdown and diffs show). Applied at once, kept in the app's settings.
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
    /// How wide a tab is drawn, and the indentation's width for a file that does not say.
    var tabWidth: Int { didSet { defaults.set(tabWidth, forKey: "editorTabWidth") } }
    /// A file that does not say indents with spaces (VS Code's `editor.insertSpaces`), or with tabs.
    var insertSpaces: Bool { didSet { defaults.set(insertSpaces, forKey: "editorInsertSpaces") } }
    /// Saving takes trailing spaces and tabs off every line (VS Code's `files.trimTrailingWhitespace`).
    var trimTrailingWhitespace: Bool { didSet { defaults.set(trimTrailingWhitespace, forKey: "editorTrimTrailingWhitespace") } }
    /// Saving ends the file with a line break (VS Code's `files.insertFinalNewline`).
    var insertFinalNewline: Bool { didSet { defaults.set(insertFinalNewline, forKey: "editorInsertFinalNewline") } }
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
        insertSpaces = defaults.object(forKey: "editorInsertSpaces") as? Bool ?? true
        trimTrailingWhitespace = defaults.bool(forKey: "editorTrimTrailingWhitespace")
        insertFinalNewline = defaults.bool(forKey: "editorInsertFinalNewline")
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

/// How code is drawn, from the theme and the editor's settings: the text's font and colour, and how
/// each token looks, from the theme's scope rules (`SyntaxTheme`: an imported VS Code theme's own, or
/// rules made from the terminal palette), as appearance-aware colours so light and dark both follow it.
@MainActor
final class EditorStyle {
    static let shared = EditorStyle()

    /// How text in one scope stack looks, light and dark.
    struct Look {
        /// nil where it is the text's own colour in both.
        var color: NSColor?
        var background: NSColor?
        var light: FontStyle
        var dark: FontStyle

        var isPlain: Bool { color == nil && background == nil && light.isEmpty && dark.isEmpty }
        func fontStyle(dark isDark: Bool) -> FontStyle { isDark ? dark : light }

        /// Draws the same: colours with the same values are one colour object (`EditorStyle.color`).
        func looksLike(_ other: Look) -> Bool {
            color === other.color && background === other.background && light == other.light && dark == other.dark
        }
    }

    private var cachedTheme: Theme?
    private var light = SyntaxTheme(rules: [], foreground: .black, background: .white)
    private var dark = SyntaxTheme(rules: [], foreground: .white, background: .black)
    private var looks: [UInt32: Look] = [:]
    /// One colour object per light and dark value, so tokens that look alike can be drawn as one run.
    private var colors: [ColorKey: NSColor] = [:]

    private struct ColorKey: Hashable {
        var light: WhiskrKit.RGBColor?
        var dark: WhiskrKit.RGBColor?
    }

    private func color(light: WhiskrKit.RGBColor?, dark: WhiskrKit.RGBColor?, fallback: NSColor = .clear) -> NSColor {
        let key = ColorKey(light: light, dark: dark)
        if let known = colors[key] { return known }
        let made = NSColor(name: nil) { appearance in (Palette.isDark(appearance) ? dark : light).map(Palette.nsColor) ?? fallback }
        colors[key] = made
        return made
    }
    private var fonts: [FontKey: NSFont] = [:]

    private struct FontKey: Hashable {
        var base: NSFont
        var style: UInt8
    }

    var font: NSFont { EditorPreferences.shared.font }

    var textColor: NSColor { ThemeStore.shared.palette.terminalForeground }
    var background: NSColor { Colors.terminalBackground }

    /// A tab is drawn `tabWidth` spaces wide (Settings › Editor's, unless a file says otherwise).
    func paragraphStyle(tabWidth: Int = EditorPreferences.shared.tabWidth) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        style.defaultTabInterval = space * CGFloat(tabWidth)
        style.tabStops = []
        style.lineHeightMultiple = 1.08
        return style
    }

    var paragraphStyle: NSParagraphStyle { paragraphStyle() }

    func baseAttributes(tabWidth: Int) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraphStyle(tabWidth: tabWidth)]
    }

    var baseAttributes: [NSAttributedString.Key: Any] { baseAttributes(tabWidth: EditorPreferences.shared.tabWidth) }

    /// How text in `scopes` looks in the current theme (call `refresh` once before a run of these).
    func look(_ scopes: ScopeStack) -> Look {
        if let known = looks[scopes.id] { return known }
        let lightStyle = light.style(for: scopes), darkStyle = dark.style(for: scopes)
        let lightDefault = light.defaultStyle.foreground, darkDefault = dark.defaultStyle.foreground
        let lightColor = lightStyle.foreground == lightDefault ? nil : lightStyle.foreground
        let darkColor = darkStyle.foreground == darkDefault ? nil : darkStyle.foreground
        var color: NSColor?
        if lightColor != nil || darkColor != nil {
            color = self.color(light: lightColor ?? lightDefault, dark: darkColor ?? darkDefault)
        }
        var background: NSColor?
        if lightStyle.background != nil || darkStyle.background != nil {
            background = self.color(light: lightStyle.background, dark: darkStyle.background)
        }
        let look = Look(color: color, background: background, light: lightStyle.fontStyle, dark: darkStyle.fontStyle)
        looks[scopes.id] = look
        return look
    }

    /// The colour the theme gives a scope on its own ("markup.inserted" for a diff's added lines), else
    /// the text's.
    func color(scope: String) -> NSColor {
        refresh()
        return look(ScopeStack(["source", scope])!).color ?? textColor
    }

    /// `base` in bold, italics or both, as `style` says (underline and strikethrough are drawn, not set).
    func font(_ base: NSFont, _ style: FontStyle) -> NSFont {
        let traits = style.intersection([.bold, .italic])
        guard !traits.isEmpty else { return base }
        let key = FontKey(base: base, style: traits.rawValue)
        if let known = fonts[key] { return known }
        var symbolic: NSFontDescriptor.SymbolicTraits = []
        if traits.contains(.bold) { symbolic.insert(.bold) }
        if traits.contains(.italic) { symbolic.insert(.italic) }
        let font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(symbolic), size: base.pointSize) ?? base
        fonts[key] = font
        return font
    }

    /// The editor's font in its four faces, each drawn once off the main thread: Core Text reads a face's
    /// tables (and those of the fonts it falls back to) the first time it draws with it, tens of milliseconds
    /// that would otherwise land in the first frame with an italic comment, a bold heading or an arrow (as the terminal's shaders are compiled ahead,
    /// `TerminalShaderWarmup`). Once per font.
    func warmFonts() {
        let faces = self.faces
        guard warmed != faces.fonts.first else { return }
        warmed = faces.fonts.first
        DispatchQueue.global(qos: .utility).async { faces.warm(Faces.commonText) }
    }

    private var warmed: NSFont?

    /// The editor's font in its four faces, to warm from another thread (`Faces.warm`).
    var faces: Faces {
        let base = font
        return Faces(fonts: [base] + [FontStyle.italic, .bold, [.italic, .bold]].map { font(base, $0) })
    }

    /// The editor font's faces. Core Text fonts are immutable and safe to use from any thread.
    nonisolated struct Faces: @unchecked Sendable {
        let fonts: [NSFont]

        /// Letters, and the symbols code and its comments often hold that a monospaced font lacks, so the
        /// fonts Core Text falls back to for them are read ahead too.
        static let commonText = "Ag_{}/*0 …→←↑↓⇒⌘⌥⇧⌃•·×✓✗—–‘’“”éü€°≤≥≠λ 日本語"

        /// Draws `text` once in each face, into a small bitmap nobody sees.
        func warm(_ text: String) {
            guard !text.isEmpty, let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            for face in fonts {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: face]))
                context.textPosition = CGPoint(x: 0, y: 8)
                CTLineDraw(line, context)
            }
        }

        /// The characters beyond ASCII in `text`, once each: what a file's first screen will ask of the fonts
        /// Core Text falls back to.
        static func unusual(in text: Substring) -> String {
            var seen = Set<Character>()
            return String(text.filter { !$0.isASCII && seen.insert($0).inserted })
        }
    }

    /// Follows the theme: how scopes look is worked out again when it has changed.
    func refresh() {
        let theme = ThemeStore.shared.palette.theme
        guard cachedTheme != theme else { return }
        cachedTheme = theme
        light = SyntaxTheme(variant: theme.variant(dark: false))
        dark = SyntaxTheme(variant: theme.variant(dark: true))
        looks = [:]
        colors = [:]
    }
}
