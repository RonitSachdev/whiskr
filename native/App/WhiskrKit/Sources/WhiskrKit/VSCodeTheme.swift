import Foundation

// VS Code colour themes, read as data and turned into a Whiskr theme variant. Nothing of an extension is
// run: a theme is a JSON file of workbench colours (`colors`) and TextMate scope rules (`tokenColors`),
// which may include another theme file and may take its rules from a TextMate `.tmTheme`.
//
// How the files are read follows VS Code's own loader (`colorThemeData.ts`, `_loadColorTheme`, and
// `themeCompatibility.ts` for `.tmTheme` files), at commit 08e8bbfca63e53b57005f10e97b0fa19f2cf81f1, MIT
// licence: an `include` is read first and the including file's colours win; rules come parent first; a
// rule without a scope is not a rule (VS Code makes the default rule from `editor.foreground` and
// `editor.background`); a `.tmTheme`'s scope-less settings set editor colours. Semantic token colours are
// left out: they need a language server, which the app does not run.

/// Where a variant of a theme came from: the theme's own name there and, for an imported one, the copy of
/// its original files kept beside the app's themes (`folder`, inside the themes folder's `Originals`), so
/// it can be read again; the name also lets a pair be separated into the two themes it was made from.
public struct ThemeOrigin: Hashable, Sendable, Codable {
    /// "Dark Modern".
    public var name: String
    /// The folder under `Originals` holding the copied files.
    public var folder: String?
    /// The theme file inside that folder, as a relative path ("themes/dark_modern.json").
    public var file: String?
    /// "vs", "vs-dark", "hc-black" or "hc-light", as the extension or file said.
    public var uiTheme: String?

    public init(name: String, folder: String? = nil, file: String? = nil, uiTheme: String? = nil) {
        self.name = name
        self.folder = folder
        self.file = file
        self.uiTheme = uiTheme
    }

    private enum Keys: String, CodingKey { case name, folder, file, uiTheme }

    /// A theme file is anyone's to write, and removing a theme removes its `folder`: one that is not a
    /// plain name inside `Originals` ("../../Documents", "", ".") is dropped as it is read, as is a `file`
    /// that would lead out of its folder.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        name = try container.decode(String.self, forKey: .name)
        folder = try container.decodeIfPresent(String.self, forKey: .folder).flatMap { Self.isPlainName($0) ? $0 : nil }
        file = try container.decodeIfPresent(String.self, forKey: .file).flatMap { Self.isInsideFolder($0) ? $0 : nil }
        uiTheme = try container.decodeIfPresent(String.self, forKey: .uiTheme)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(folder, forKey: .folder)
        try container.encodeIfPresent(file, forKey: .file)
        try container.encodeIfPresent(uiTheme, forKey: .uiTheme)
    }

    /// The copy of the original files inside `originals`, only when `folder` names a folder directly in it.
    public func originalsFolder(in originals: URL) -> URL? {
        guard let folder, Self.isPlainName(folder) else { return nil }
        let url = originals.appendingPathComponent(folder, isDirectory: true).standardizedFileURL
        return url.deletingLastPathComponent().path == originals.standardizedFileURL.path ? url : nil
    }

    /// One file or folder name: not empty, not "." or "..", no "/" (or ":", which Finder shows as one).
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains(":") && !name.contains("\0")
    }

    /// A relative path of plain names ("themes/dark.json").
    static func isInsideFolder(_ path: String) -> Bool {
        !path.hasPrefix("/") && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { isPlainName(String($0)) }
    }
}

/// What kind of theme VS Code takes a theme for: its `uiTheme` in an extension, or its own `type`.
public enum VSCodeThemeKind: String, Sendable, CaseIterable {
    case light = "vs", dark = "vs-dark", highContrastDark = "hc-black", highContrastLight = "hc-light"

    public init?(uiTheme: String?) {
        guard let uiTheme, let kind = VSCodeThemeKind(rawValue: uiTheme) else { return nil }
        self = kind
    }

    /// A theme file's `type`: "light", "dark", "hc" or "hcDark", "hcLight".
    public init?(type: String?) {
        switch type?.lowercased() {
        case "light", "vs": self = .light
        case "dark", "vs-dark": self = .dark
        case "hc", "hcdark", "hc-black", "hc-dark": self = .highContrastDark
        case "hclight", "hc-light": self = .highContrastLight
        default: return nil
        }
    }

    public var isDark: Bool { self == .dark || self == .highContrastDark }
    public var isHighContrast: Bool { self == .highContrastDark || self == .highContrastLight }
}

/// A colour as VS Code themes write it ("#rgb", "#rgba", "#rrggbb", "#rrggbbaa"), with its opacity.
struct VSCodeColor: Equatable {
    var rgb: RGBColor
    var alpha: Double

    init(rgb: RGBColor, alpha: Double = 1) {
        self.rgb = rgb
        self.alpha = alpha
    }

    init?(_ text: String) {
        var digits = Substring(text.trimmingCharacters(in: .whitespaces))
        guard digits.first == "#" else { return nil }
        digits.removeFirst()
        if digits.count == 3 || digits.count == 4 { digits = Substring(digits.map { "\($0)\($0)" }.joined()) }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        if digits.count == 8 {
            self.init(rgb: RGBColor(UInt32(value >> 8)), alpha: Double(value & 0xff) / 255)
        } else {
            self.init(rgb: RGBColor(UInt32(value)))
        }
    }

    /// The colour as it shows drawn over `layer`, written as a theme file would ("#rrggbb").
    func over(_ layer: RGBColor) -> RGBColor { alpha >= 1 ? rgb : layer.mixed(with: rgb, alpha).quantized }
}

/// One scope rule as a theme file writes it, before its colours are made opaque.
public struct VSCodeTokenRule: Sendable, Equatable {
    public var scopes: [String]
    public var foreground: String?
    public var background: String?
    public var fontStyle: String?
}

/// A colour theme file as VS Code reads it, with what it includes merged in.
public struct VSCodeThemeDocument: Sendable {
    /// The file's own `name`, if it gives one.
    public var name: String?
    /// The file's own `type` ("dark", "light", "hc", "hcLight"), if it gives one.
    public var type: String?
    /// Workbench colours by id, as written ("#1f1f1f", "#ffffff17"); an including file's win.
    public var colors: [String: String] = [:]
    /// Scope rules, the included file's first.
    public var rules: [VSCodeTokenRule] = []
    /// Every file read: the theme, what it includes, a `.tmTheme` it takes its rules from.
    public var files: [URL] = []

    /// Limits on what one theme may read: how deep includes go, how many files are read in all (a file
    /// that both includes the next and takes its rules from it reads every level twice, so a chain of 30
    /// would be read a billion times), and how large one file may be. Real themes include one or two.
    static let includeDepthLimit = 16
    static let readLimit = 64
    static let fileSizeLimit = 8 * 1024 * 1024

    /// What reading one theme has seen: the files being read (an include must not lead back to one), each
    /// file's contents (read once however often it is included), and how many reads there have been.
    private struct Reading {
        var stack: [URL] = []
        var contents: [URL: Data] = [:]
        var reads = 0
    }

    /// Reads a theme file (`.json`, JSON with comments, or a TextMate `.tmTheme`) and what it includes.
    /// An include must stay inside `root` (the extension's folder, or the theme file's own) and must not
    /// lead back to a file already being read.
    public static func read(_ url: URL, root: URL) throws -> VSCodeThemeDocument {
        var document = VSCodeThemeDocument()
        var reading = Reading()
        try document.load(url, root: root.standardizedFileURL.resolvingSymlinksInPath(), reading: &reading)
        return document
    }

    private mutating func load(_ url: URL, root: URL, reading: inout Reading) throws {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let shown = file.lastPathComponent
        guard file.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/") else {
            throw ThemeImportError.unreadable(String(localized: "\(shown) is outside the theme's folder.", bundle: .module, comment: "Importing a theme: why it could not be read"))
        }
        guard !reading.stack.contains(file) else { throw ThemeImportError.unreadable(String(localized: "\(shown) includes itself.", bundle: .module, comment: "Importing a theme: why it could not be read")) }
        reading.reads += 1
        guard reading.stack.count < Self.includeDepthLimit, reading.reads <= Self.readLimit else {
            throw ThemeImportError.unreadable(String(localized: "\(shown) includes too many files.", bundle: .module, comment: "Importing a theme: why it could not be read"))
        }
        if reading.contents[file] == nil {
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
            guard size <= Self.fileSizeLimit else {
                throw ThemeImportError.unreadable(String(localized: "\(shown) is too large to be a colour theme.", bundle: .module, comment: "Importing a theme: why it could not be read"))
            }
            reading.contents[file] = try? Data(contentsOf: file)
        }
        guard let data = reading.contents[file] else { throw ThemeImportError.unreadable(String(localized: "\(shown) is missing or cannot be read.", bundle: .module, comment: "Importing a theme: why it could not be read")) }
        reading.stack.append(file)
        defer { reading.stack.removeLast() }
        if !files.contains(file) { files.append(file) }

        let ext = file.pathExtension.lowercased()
        guard ext == "json" || ext == "jsonc" else { return try loadTextMate(data, shown: shown) }
        let json: [String: Any]
        do {
            json = try JSONC.dictionary(data)
        } catch {
            throw ThemeImportError.unreadable(String(localized: "\(shown) is not a colour theme (it is not JSON).", bundle: .module, comment: "Importing a theme: why it could not be read"))
        }
        if let include = json["include"] as? String {
            try load(file.deletingLastPathComponent().appendingPathComponent(include), root: root, reading: &reading)
        }
        if let name = json["name"] as? String { self.name = name }
        if let type = json["type"] as? String { self.type = type }
        // A TextMate theme written as JSON.
        if let settings = json["settings"] as? [Any] { return convert(settings) }
        if let colors = json["colors"] as? [String: Any] {
            for (id, value) in colors {
                // "default" takes back what an included theme set.
                if value as? String == "default" { self.colors[id] = nil } else if let text = value as? String { self.colors[id] = text }
            }
        }
        switch json["tokenColors"] {
        case let list as [Any]:
            rules += list.compactMap(Self.rule)
        case let path as String:
            try load(file.deletingLastPathComponent().appendingPathComponent(path), root: root, reading: &reading)
        default:
            break
        }
    }

    private mutating func loadTextMate(_ data: Data, shown: String) throws {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let settings = plist["settings"] as? [Any] else {
            throw ThemeImportError.unreadable(String(localized: "\(shown) is not a colour theme.", bundle: .module, comment: "Importing a theme: why it could not be read"))
        }
        if name == nil, let name = plist["name"] as? String { self.name = name }
        convert(settings)
    }

    /// A `.tmTheme`'s settings: scoped ones are rules; a scope-less one sets editor colours, by the names
    /// VS Code maps them to (`themeCompatibility.ts`).
    private mutating func convert(_ settings: [Any]) {
        for entry in settings {
            guard let entry = entry as? [String: Any] else { continue }
            if let rule = Self.rule(entry) {
                rules.append(rule)
            } else if (entry["scope"] as? String ?? "").isEmpty, let values = entry["settings"] as? [String: Any] {
                for (setting, value) in values {
                    guard let text = value as? String else { continue }
                    for id in Self.textMateSettings[setting] ?? [] { colors[id] = text }
                }
            }
        }
    }

    private static let textMateSettings: [String: [String]] = {
        var map: [String: [String]] = [
            "background": ["editor.background"], "foreground": ["editor.foreground"],
            "selection": ["editor.selectionBackground"], "inactiveSelection": ["editor.inactiveSelectionBackground"],
            "selectionHighlightColor": ["editor.selectionHighlightBackground"],
            "findMatchHighlight": ["editor.findMatchHighlightBackground", "peekViewResult.matchHighlightBackground"],
            "currentFindMatchHighlight": ["editor.findMatchBackground"], "hoverHighlight": ["editor.hoverHighlightBackground"],
            "wordHighlight": ["editor.wordHighlightBackground"], "wordHighlightStrong": ["editor.wordHighlightStrongBackground"],
            "findRangeHighlight": ["editor.findRangeHighlightBackground"], "referenceHighlight": ["peekViewEditor.matchHighlightBackground"],
            "lineHighlight": ["editor.lineHighlightBackground"], "rangeHighlight": ["editor.rangeHighlightBackground"],
            "caret": ["editorCursor.foreground"], "invisibles": ["editorWhitespace.foreground"],
            "guide": ["editorIndentGuide.background1"], "activeGuide": ["editorIndentGuide.activeBackground1"],
        ]
        for name in VSCodeThemeConversion.ansiNames { map[name] = ["terminal." + name] }
        return map
    }()

    /// A rule with a scope and settings (VS Code keeps no other).
    private static func rule(_ value: Any) -> VSCodeTokenRule? {
        guard let entry = value as? [String: Any], let settings = entry["settings"] as? [String: Any] else { return nil }
        let scopes: [String]
        switch entry["scope"] {
        case let text as String: scopes = TokenColorRule.split(text)
        case let list as [Any]: scopes = list.compactMap { $0 as? String }.flatMap(TokenColorRule.split)
        default: return nil
        }
        guard !scopes.isEmpty else { return nil }
        return VSCodeTokenRule(scopes: scopes, foreground: settings["foreground"] as? String,
                               background: settings["background"] as? String, fontStyle: settings["fontStyle"] as? String)
    }
}

/// A VS Code theme turned into one of Whiskr's variants.
///
/// Whiskr has one content layer, shared by terminals, editors and the selected tab, so the content is
/// `editor.background` (where VS Code's terminals sit when they are opened as editors); a theme's
/// `terminal.background` is for its bottom panel and is used only when the editor's is not given. Colours
/// the theme leaves out take VS Code's own defaults for its kind where VS Code has one (the terminal's
/// sixteen, `terminalColorRegistry.ts`; git's, the git extension's `package.json`; the editor's,
/// `editorColors.ts` and `editorColorRegistry.ts`), else Whiskr's rules (`AppColors.derived`,
/// `EditorColors.derived`). Translucent colours are laid over the layer they are drawn on: the content
/// for the editor's, the terminal's and the code's colours and for the accent, the chrome for lines,
/// text and git's colours. Then `meetingGuarantees()` moves what falls short.
public struct VSCodeThemeConversion: Sendable {
    public var variant: ThemeVariant
    /// What was moved to meet the guarantees, in words; empty when the theme met them as it is.
    public var repairs: [String]

    static let ansiNames = ["ansiBlack", "ansiRed", "ansiGreen", "ansiYellow", "ansiBlue", "ansiMagenta", "ansiCyan", "ansiWhite",
                            "ansiBrightBlack", "ansiBrightRed", "ansiBrightGreen", "ansiBrightYellow", "ansiBrightBlue", "ansiBrightMagenta",
                            "ansiBrightCyan", "ansiBrightWhite"]

    /// The kind a theme is: as its extension declares it, else as its file's `type` says, else by its
    /// editor's background, else by "Light" in its name, else dark (VS Code's default).
    public static func kind(of document: VSCodeThemeDocument, declared: VSCodeThemeKind?) -> VSCodeThemeKind {
        if let declared { return declared }
        if let kind = VSCodeThemeKind(type: document.type) { return kind }
        if let background = document.colors["editor.background"].flatMap(VSCodeColor.init) { return background.rgb.luminance < 0.4 ? .dark : .light }
        if document.name?.range(of: "\\blight\\b", options: [.regularExpression, .caseInsensitive]) != nil { return .light }
        return .dark
    }

    public init(_ document: VSCodeThemeDocument, kind: VSCodeThemeKind, origin: ThemeOrigin? = nil) {
        let defaults = VSCodeDefaults(kind)
        let colors = document.colors
        func raw(_ id: String) -> VSCodeColor? { colors[id].flatMap(VSCodeColor.init) }
        func first(_ ids: [String]) -> VSCodeColor? { ids.lazy.compactMap(raw).first }

        // The content and its text.
        let base: RGBColor = kind.isDark ? .black : .white
        let background = first(["editor.background", "terminal.background"])?.over(base) ?? defaults.editorBackground
        let editorForeground = raw("editor.foreground")?.over(background) ?? defaults.editorForeground
        let foreground = (raw("terminal.foreground")?.over(background)) ?? (raw("editor.foreground") != nil ? editorForeground : defaults.terminalForeground)
        let ansi = Self.ansiNames.enumerated().map { index, name in raw("terminal." + name)?.over(background) ?? defaults.ansi[index] }
        let cursor = first(["terminalCursor.foreground", "editorCursor.foreground"])?.over(background)
        let selection = first(["terminal.selectionBackground", "editor.selectionBackground"])?.over(background) ?? defaults.selection
        let terminal = TerminalColors(background: background, foreground: foreground, cursor: cursor, selection: selection, ansi: ansi)
        let derived = AppColors.derived(from: terminal)

        // The chrome: the first of the theme's bars that is a proper step below the content, else the
        // first that is at least below it (brought nearer by the guarantees), else Whiskr's own step.
        let bars = ["titleBar.activeBackground", "editorGroupHeader.tabsBackground", "sideBar.background", "tab.inactiveBackground",
                    "statusBar.background", "panel.background"].compactMap { raw($0)?.over(background) }
        let chrome = bars.first { ThemeVariant.chromeStep.contains($0.contrast(with: background)) && $0.luminance < background.luminance }
            ?? bars.first { $0.luminance < background.luminance } ?? derived[.chrome]

        var app: [AppColorKey: RGBColor] = [.chrome: chrome]
        if let line = first(["tab.border", "editorGroup.border", "sideBar.border", "titleBar.border", "panel.border", "contrastBorder"]) {
            app[.line] = line.over(chrome)
        }
        app[.accent] = (first(["tab.activeBorderTop", "focusBorder", "button.background"]))?.over(background) ?? defaults.focusBorder
        if let text = raw("foreground") { app[.text] = text.over(chrome) }
        if let secondary = first(["tab.inactiveForeground", "descriptionForeground"]) { app[.textSecondary] = secondary.over(chrome) }
        // "Needs you" is an alarm: a theme's error colour only when it is a colour (some themes set a pale
        // tint for error text, which would read as nothing on a pill).
        if let error = [raw("editorError.foreground"), raw("errorForeground")].compactMap({ $0?.over(background) }).first(where: { $0.chroma >= 0.25 }) {
            app[.needsYou] = error
            app[.error] = error
        }

        var editor: [EditorColorKey: RGBColor] = [:]
        func set(_ key: EditorColorKey, _ ids: [String], over layer: RGBColor = background, fallback: RGBColor? = nil) {
            if let value = first(ids)?.over(layer) ?? fallback { editor[key] = value }
        }
        set(.selection, ["editor.selectionBackground"], fallback: selection)
        set(.cursor, ["editorCursor.foreground"], fallback: defaults.cursor)
        set(.lineHighlight, ["editor.lineHighlightBackground"])
        set(.lineNumber, ["editorLineNumber.foreground"], fallback: defaults.lineNumber)
        set(.lineNumberActive, ["editorLineNumber.activeForeground", "editorActiveLineNumber.foreground"], fallback: defaults.lineNumberActive)
        set(.indentGuide, ["editorIndentGuide.background1", "editorIndentGuide.background"])
        set(.indentGuideActive, ["editorIndentGuide.activeBackground1", "editorIndentGuide.activeBackground"])
        set(.whitespace, ["editorWhitespace.foreground"], fallback: defaults.whitespace?.over(background))
        set(.bracketMatch, ["editorBracketMatch.background"])
        set(.wordHighlight, ["editor.wordHighlightBackground", "editor.selectionHighlightBackground"])
        for (key, id) in [(EditorColorKey.gitAdded, "added"), (.gitModified, "modified"), (.gitDeleted, "deleted"), (.gitRenamed, "renamed"),
                          (.gitUntracked, "untracked"), (.gitIgnored, "ignored"), (.gitConflict, "conflicting")] {
            set(key, ["gitDecoration.\(id)ResourceForeground"], over: chrome, fallback: defaults.git[key])
        }
        set(.diffInserted, ["diffEditor.insertedLineBackground"], fallback: defaults.diff[.diffInserted]?.over(background))
        set(.diffRemoved, ["diffEditor.removedLineBackground"], fallback: defaults.diff[.diffRemoved]?.over(background))
        set(.diffInsertedText, ["diffEditor.insertedTextBackground"], fallback: defaults.diff[.diffInsertedText]?.over(background))
        set(.diffRemovedText, ["diffEditor.removedTextBackground"], fallback: defaults.diff[.diffRemovedText]?.over(background))

        // Code: VS Code's default rule first (the editor's text on its background), then the theme's.
        // Token backgrounds are dropped, as VS Code does not draw them.
        var tokenColors = [TokenColorRule(scopes: [], foreground: editorForeground, background: background)]
        for rule in document.rules {
            let foreground = rule.foreground.flatMap(VSCodeColor.init)?.over(background)
            let style = rule.fontStyle.map(FontStyle.init(words:))
            guard foreground != nil || style != nil else { continue }
            tokenColors.append(TokenColorRule(scopes: rule.scopes, foreground: foreground, fontStyle: style))
        }

        let made = ThemeVariant(terminal: terminal, app: app, editor: editor, tokenColors: tokenColors, origin: origin)
        (variant, repairs) = made.meetingGuarantees()
    }
}

/// VS Code's own colours for what a theme leaves out, by kind (commit 08e8bbf).
struct VSCodeDefaults {
    var editorBackground: RGBColor
    var editorForeground: RGBColor
    var terminalForeground: RGBColor
    var selection: RGBColor?
    var cursor: RGBColor
    var lineNumber: RGBColor
    var lineNumberActive: RGBColor?
    var whitespace: VSCodeColor?
    var focusBorder: RGBColor
    var ansi: [RGBColor]
    var git: [EditorColorKey: RGBColor]
    var diff: [EditorColorKey: VSCodeColor]

    init(_ kind: VSCodeThemeKind) {
        func pick<T>(_ light: T, _ dark: T, _ hcDark: T, _ hcLight: T) -> T {
            switch kind { case .light: light; case .dark: dark; case .highContrastDark: hcDark; case .highContrastLight: hcLight }
        }
        editorBackground = RGBColor(pick(0xffffff, 0x1e1e1e, 0x000000, 0xffffff))
        editorForeground = RGBColor(pick(0x333333, 0xbbbbbb, 0xffffff, 0x292929))
        terminalForeground = RGBColor(pick(0x333333, 0xcccccc, 0xffffff, 0x292929))
        // High-contrast selections are drawn with an outline in VS Code; here they are worked out instead.
        selection = pick(RGBColor(0xadd6ff), RGBColor(0x264f78), nil, nil)
        cursor = RGBColor(pick(0x000000, 0xaeafad, 0xffffff, 0x0f4a85))
        lineNumber = RGBColor(pick(0x237893, 0x858585, 0xffffff, 0x292929))
        lineNumberActive = pick(RGBColor(0x0b216f), RGBColor(0xc6c6c6), nil, nil)
        whitespace = VSCodeColor(pick("#33333333", "#e3e4e229", "#e3e4e229", "#cccccc"))
        focusBorder = RGBColor(pick(0x0090f1, 0x007fd4, 0xf38518, 0x006bbd))
        ansi = (kind.isHighContrast
            ? (kind.isDark
                ? [0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5, 0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff]
                : [0x292929, 0xcd3131, 0x136c13, 0x949800, 0x0451a5, 0xbc05bc, 0x0598bc, 0x555555, 0x666666, 0xcd3131, 0x00bc00, 0xb5ba00, 0x0451a5, 0xbc05bc, 0x0598bc, 0xa5a5a5])
            : (kind.isDark
                ? [0x000000, 0xcd3131, 0x0dbc79, 0xe5e510, 0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5, 0x666666, 0xf14c4c, 0x23d18b, 0xf5f543, 0x3b8eea, 0xd670d6, 0x29b8db, 0xe5e5e5]
                : [0x000000, 0xcd3131, 0x107c10, 0x949800, 0x0451a5, 0xbc05bc, 0x0598bc, 0x555555, 0x666666, 0xf14c4c, 0x14ce14, 0xb5ba00, 0x3b8eea, 0xd670d6, 0x29b8db, 0xa5a5a5]))
            .map(RGBColor.init)
        let gitValues: [(EditorColorKey, [UInt32])] = [
            (.gitAdded, [0x587c0c, 0x81b88b, 0xa1e3ad, 0x374e06]), (.gitModified, [0x895503, 0xe2c08d, 0xe2c08d, 0x895503]),
            (.gitDeleted, [0xad0707, 0xc74e39, 0xc74e39, 0xad0707]), (.gitRenamed, [0x007100, 0x73c991, 0x73c991, 0x007100]),
            (.gitUntracked, [0x007100, 0x73c991, 0x73c991, 0x007100]), (.gitIgnored, [0x8e8e90, 0x8c8c8c, 0xa7a8a9, 0x8e8e90]),
            (.gitConflict, [0xad0707, 0xe4676b, 0xc74e39, 0xad0707]),
        ]
        git = Dictionary(uniqueKeysWithValues: gitValues.map { key, values in (key, RGBColor(pick(values[0], values[1], values[2], values[3]))) })
        // High-contrast themes outline their diffs rather than tint them; here they are worked out instead.
        diff = kind.isHighContrast ? [:] : [
            .diffInserted: VSCodeColor(rgb: RGBColor(0x9bb955), alpha: 0.2), .diffRemoved: VSCodeColor(rgb: RGBColor(0xff0000), alpha: 0.2),
            .diffInsertedText: VSCodeColor(rgb: RGBColor(0x9ccc2c), alpha: kind == .light ? 0x40 / 255 : 0x33 / 255),
            .diffRemovedText: VSCodeColor(rgb: RGBColor(0xff0000), alpha: 0x33 / 255),
        ]
    }
}

extension RGBColor {
    /// How coloured it is: the spread between its strongest and weakest channel (0 for a grey).
    var chroma: Double { max(red, green, blue) - min(red, green, blue) }
}
