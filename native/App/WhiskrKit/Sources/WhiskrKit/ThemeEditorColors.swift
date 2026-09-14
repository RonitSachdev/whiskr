import Foundation

// What a theme says about code beyond the terminal's sixteen colours: the editor's own marks (the cursor's
// line, line numbers, indent guides, a matching bracket, other occurrences of a word), git's states in the
// file list, the diff's added and removed backgrounds, and the colours of code itself as TextMate scope
// rules (`tokenColors`, the form VS Code themes use, so an imported theme colours code as it does there).
//
// In a theme file these sit beside the terminal's and the app's, each optional:
//
//   "editor": { "lineHighlight": "#…", "gitModified": "#…", … }     (any of EditorColorKey)
//   "tokenColors": [ { "scope": "comment, string.quoted", "settings": { "foreground": "#…", "fontStyle": "italic" } }, … ]
//
// Editor colours left out are worked out from the terminal's, as the app's are; a variant without token
// colours has its code coloured from its terminal palette.

/// The editor's, the diffs' and the file list's colours.
public enum EditorColorKey: String, CaseIterable, Codable, Sendable {
    case selection, cursor, lineHighlight, lineNumber, lineNumberActive
    case indentGuide, indentGuideActive, whitespace, bracketMatch, wordHighlight
    case gitAdded, gitModified, gitDeleted, gitRenamed, gitUntracked, gitIgnored, gitConflict
    case diffInserted, diffRemoved, diffInsertedText, diffRemovedText

    public var label: String {
        switch self {
        case .selection: "Selection"
        case .cursor: "Cursor"
        case .lineHighlight: "Current line"
        case .lineNumber: "Line numbers"
        case .lineNumberActive: "Current line number"
        case .indentGuide: "Indent guides"
        case .indentGuideActive: "Current indent guide"
        case .whitespace: "Invisibles"
        case .bracketMatch: "Matching bracket"
        case .wordHighlight: "Other occurrences"
        case .gitAdded: "Added file"
        case .gitModified: "Modified file"
        case .gitDeleted: "Deleted file"
        case .gitRenamed: "Renamed file"
        case .gitUntracked: "Untracked file"
        case .gitIgnored: "Ignored file"
        case .gitConflict: "Conflicted file"
        case .diffInserted: "Added lines"
        case .diffRemoved: "Removed lines"
        case .diffInsertedText: "Added text"
        case .diffRemovedText: "Removed text"
        }
    }
}

public struct EditorColors: Hashable, Sendable {
    public var values: [EditorColorKey: RGBColor]

    public init(values: [EditorColorKey: RGBColor]) {
        self.values = values
    }

    public subscript(key: EditorColorKey) -> RGBColor {
        get { values[key] ?? .black }
        set { values[key] = newValue }
    }

    /// Editor colours that go with a terminal palette: marks as faint steps of the foreground over the
    /// background, git's states in the palette's own colours (green new, yellow modified, red deleted, blue
    /// renamed) kept at 3:1 on the background and on the bars (the file list is on them), and the diff's
    /// tints of its green and red.
    public static func derived(from terminal: TerminalColors) -> EditorColors {
        let bg = terminal.background, fg = terminal.foreground
        let dark = terminal.isDark
        let chrome = AppColors.derived(from: terminal)[.chrome]
        func ansi(_ index: Int) -> RGBColor {
            let color = terminal.ansi.count == 16 ? terminal.ansi[index] : fg
            return color.ensuring(contrast: 3, with: bg, movingTo: fg).ensuring(contrast: 3, with: chrome, movingTo: fg)
        }
        let line = dark ? 0.16 : 0.12
        let green = terminal.ansi.count == 16 ? terminal.ansi[2] : fg
        let red = terminal.ansi.count == 16 ? terminal.ansi[1] : fg
        let blue = terminal.ansi.count == 16 ? terminal.ansi[4] : fg
        return EditorColors(values: [
            .selection: terminal.selection,
            .cursor: terminal.cursor,
            .lineHighlight: bg.mixed(with: fg, dark ? 0.06 : 0.045),
            .lineNumber: fg.mixed(with: bg, 0.62),
            .lineNumberActive: fg.mixed(with: bg, 0.2),
            .indentGuide: bg.mixed(with: fg, dark ? 0.12 : 0.1),
            .indentGuideActive: bg.mixed(with: fg, dark ? 0.3 : 0.28),
            .whitespace: fg.mixed(with: bg, 0.6),
            .bracketMatch: bg.mixed(with: blue, dark ? 0.3 : 0.22),
            .wordHighlight: bg.mixed(with: terminal.selection, 0.55),
            .gitAdded: ansi(2),
            .gitModified: ansi(3),
            .gitDeleted: ansi(1),
            .gitRenamed: ansi(4),
            .gitUntracked: ansi(2),
            .gitIgnored: fg.mixed(with: bg, 0.5),
            .gitConflict: ansi(1),
            .diffInserted: bg.mixed(with: green, line),
            .diffRemoved: bg.mixed(with: red, line),
            .diffInsertedText: bg.mixed(with: green, line * 2.4),
            .diffRemovedText: bg.mixed(with: red, line * 2.4),
        ])
    }
}

// MARK: Token colours

/// How a token's text is set, beyond its colour. A rule may also say "none", which takes back what a
/// broader rule set (`fontStyle: ""` in a VS Code theme).
public struct FontStyle: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let italic = FontStyle(rawValue: 1)
    public static let bold = FontStyle(rawValue: 2)
    public static let underline = FontStyle(rawValue: 4)
    public static let strikethrough = FontStyle(rawValue: 8)

    /// "italic bold", "underline", "" (none): the words VS Code themes use, in any order.
    public init(words: String) {
        var style: FontStyle = []
        for word in words.split(whereSeparator: { $0 == " " || $0 == "," }) {
            switch word.lowercased() {
            case "italic": style.insert(.italic)
            case "bold": style.insert(.bold)
            case "underline": style.insert(.underline)
            case "strikethrough": style.insert(.strikethrough)
            default: break
            }
        }
        self = style
    }

    public var words: String {
        [(FontStyle.italic, "italic"), (.bold, "bold"), (.underline, "underline"), (.strikethrough, "strikethrough")]
            .filter { contains($0.0) }.map(\.1).joined(separator: " ")
    }
}

/// One rule of a theme's token colours: the scope selectors it applies to (as written: "comment",
/// "source.python string - string.quoted.docstring", "meta.tag entity.name"), and what it sets. A theme's
/// rules are kept in their order; the engine decides which applies to a token (the most specific match,
/// later rules winning ties), as TextMate and VS Code do.
public struct TokenColorRule: Hashable, Sendable, Codable {
    /// Each element is one selector; an empty list is the theme's defaults (a rule without a scope).
    public var scopes: [String]
    public var foreground: RGBColor?
    public var background: RGBColor?
    /// nil when the rule does not say.
    public var fontStyle: FontStyle?

    public init(scopes: [String], foreground: RGBColor? = nil, background: RGBColor? = nil, fontStyle: FontStyle? = nil) {
        self.scopes = scopes
        self.foreground = foreground
        self.background = background
        self.fontStyle = fontStyle
    }

    private enum Keys: String, CodingKey { case name, scope, settings }
    private enum SettingsKeys: String, CodingKey { case foreground, background, fontStyle }

    /// VS Code's shape: `{ "scope": "a, b" | ["a", "b"], "settings": { "foreground", "background", "fontStyle" } }`.
    /// Colours must be opaque "#rrggbb" here; an importer blends translucent ones over the editor's
    /// background first.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let list = try? container.decode([String].self, forKey: .scope) {
            scopes = list.flatMap(Self.split)
        } else if let text = try container.decodeIfPresent(String.self, forKey: .scope) {
            scopes = Self.split(text)
        } else {
            scopes = []
        }
        let settings = try container.nestedContainer(keyedBy: SettingsKeys.self, forKey: .settings)
        foreground = try settings.decodeIfPresent(RGBColor.self, forKey: .foreground)
        background = try settings.decodeIfPresent(RGBColor.self, forKey: .background)
        fontStyle = try settings.decodeIfPresent(String.self, forKey: .fontStyle).map(FontStyle.init(words:))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        if !scopes.isEmpty { try container.encode(scopes.joined(separator: ", "), forKey: .scope) }
        var settings = container.nestedContainer(keyedBy: SettingsKeys.self, forKey: .settings)
        try settings.encodeIfPresent(foreground, forKey: .foreground)
        try settings.encodeIfPresent(background, forKey: .background)
        try settings.encodeIfPresent(fontStyle?.words, forKey: .fontStyle)
    }

    /// "a, b ,c" → ["a", "b", "c"].
    public static func split(_ selectors: String) -> [String] {
        selectors.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
