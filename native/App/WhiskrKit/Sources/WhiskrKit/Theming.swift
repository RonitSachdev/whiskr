import Foundation

// Themes, as herdr has them: a named theme, optionally with a light and a dark variant that is chosen
// to match the Mac's appearance, and colours you can change. Unlike herdr's (whose terminal colours
// come from the terminal it runs in), ours also carry the terminal's palette.
//
// A theme file (`.whiskrtheme`) is plain JSON, so it can be shared and edited by hand:
//
//   {
//     "format": "whiskr-theme", "version": 1,
//     "name": "My Theme", "author": "Me", "credit": "Based on …, MIT licence",
//     "light": {
//       "terminal": {
//         "background": "#fdfdfc", "foreground": "#232327",
//         "cursor": "#5b5b62", "selection": "#ccdbf7",          (optional)
//         "ansi": ["#…", … sixteen colours: black, red, green, yellow, blue, magenta, cyan, white,
//                  then the bright eight]
//       },
//       "app": { "accent": "#2f6fe4", "needsYou": "#d4433a" }   (optional; any of AppColorKey)
//     },
//     "dark": { … }                                              (either variant may be left out)
//   }
//
// App colours left out are worked out from the terminal's, so a theme can be as short as a
// background, a foreground and sixteen colours.

/// A colour in sRGB, written "#rrggbb" in theme files.
public struct RGBColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public init(_ hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }

    /// "#rrggbb" or "rrggbb" (also "#rgb"); nil for anything else.
    public init?(hex text: String) {
        var digits = text.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(value)
    }

    public var hex: String {
        String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = RGBColor(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a colour: \(text) (use #rrggbb)"))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    /// This colour moved `amount` (0…1) of the way to `other`.
    public func mixed(with other: RGBColor, _ amount: Double) -> RGBColor {
        RGBColor(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount, blue: blue + (other.blue - blue) * amount)
    }

    /// This colour moved toward `target` in small steps until it has at least `minimum` contrast with
    /// `other` (or has become `target`).
    public func ensuring(contrast minimum: Double, with other: RGBColor, movingTo target: RGBColor) -> RGBColor {
        var color = self
        var step = 0
        while color.contrast(with: other) < minimum, step < 20 {
            step += 1
            color = mixed(with: target, Double(step) / 20)
        }
        return color
    }

    /// Relative luminance, as WCAG defines it.
    public var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The WCAG contrast ratio between two colours, 1…21.
    public func contrast(with other: RGBColor) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    public static let black = RGBColor(0x000000)
    public static let white = RGBColor(0xffffff)
}

/// The terminal's colours.
public struct TerminalColors: Hashable, Sendable, Codable {
    public var background: RGBColor
    public var foreground: RGBColor
    public var cursor: RGBColor
    public var selection: RGBColor
    /// Sixteen: black, red, green, yellow, blue, magenta, cyan, white, then their bright forms.
    public var ansi: [RGBColor]

    public static let ansiNames = ["Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
                                   "Bright black", "Bright red", "Bright green", "Bright yellow", "Bright blue", "Bright magenta", "Bright cyan", "Bright white"]

    public init(background: RGBColor, foreground: RGBColor, cursor: RGBColor? = nil, selection: RGBColor? = nil, ansi: [RGBColor]) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor ?? foreground
        let blue = ansi.count == 16 ? ansi[4] : foreground
        self.selection = selection ?? background.mixed(with: blue, 0.3)
        self.ansi = ansi
    }

    private enum Keys: String, CodingKey { case background, foreground, cursor, selection, ansi }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let ansi = try container.decode([RGBColor].self, forKey: .ansi)
        guard ansi.count == 16 else {
            throw DecodingError.dataCorruptedError(forKey: .ansi, in: container, debugDescription: "ansi needs 16 colours, found \(ansi.count)")
        }
        self.init(background: try container.decode(RGBColor.self, forKey: .background),
                  foreground: try container.decode(RGBColor.self, forKey: .foreground),
                  cursor: try container.decodeIfPresent(RGBColor.self, forKey: .cursor),
                  selection: try container.decodeIfPresent(RGBColor.self, forKey: .selection),
                  ansi: ansi)
    }

    public var isDark: Bool { background.luminance < foreground.luminance }
}

/// The app's own colours: its surfaces, text, lines, accent, and one colour per agent state.
///
/// The window is built from two layers (docs/DESIGN.md, "Look of the interface"): the **content** (the
/// terminal's background: panes, editors, Home, the selected tab) and the **chrome** a step below it (the
/// top bar, the tab row, the status bar, the side panel), with one **line** between any two.
public enum AppColorKey: String, CaseIterable, Codable, Sendable {
    case surface, chrome, sidebar, hover, press, line, lineStrong
    case text, textSecondary, textTertiary
    case well, accent
    case working, needsYou, done, idle, error

    public var label: String {
        switch self {
        case .surface: "Surface"
        case .chrome: "Bars and panels"
        case .sidebar: "Sidebar"
        case .hover: "Hover"
        case .press: "Pressed"
        case .line: "Separator"
        case .lineStrong: "Strong separator"
        case .text: "Text"
        case .textSecondary: "Secondary text"
        case .textTertiary: "Tertiary text"
        case .well: "Behind the panes"
        case .accent: "Accent"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .idle: "Idle"
        case .error: "Error"
        }
    }
}

public struct AppColors: Hashable, Sendable {
    public var values: [AppColorKey: RGBColor]

    public subscript(key: AppColorKey) -> RGBColor {
        get { values[key] ?? .black }
        set { values[key] = newValue }
    }

    /// App colours that go with a terminal palette: surfaces just off its background, text in three
    /// strengths of its foreground, its blue as the accent and its red for "needs you". The chrome sits a
    /// step below the content: a little toward the text in a light theme, toward black in a dark one (as
    /// Cursor's and VS Code's do), so the bars recede and the terminals come forward.
    public static func derived(from terminal: TerminalColors) -> AppColors {
        let bg = terminal.background, fg = terminal.foreground
        let dark = terminal.isDark
        var values: [AppColorKey: RGBColor] = [
            .surface: dark ? bg.mixed(with: fg, 0.03) : bg.mixed(with: .white, 0.4),
            .chrome: dark ? bg.mixed(with: .black, 0.28) : bg.mixed(with: fg, 0.05),
            .sidebar: dark ? bg.mixed(with: .black, 0.12) : bg.mixed(with: fg, 0.04),
            .hover: bg.mixed(with: fg, 0.08),
            .press: bg.mixed(with: fg, 0.12),
            // Lines at the strong end of what editors use (about 1.4:1 on the chrome): the regions must read
            // apart at a glance.
            .line: bg.mixed(with: fg, dark ? 0.18 : 0.2),
            .lineStrong: bg.mixed(with: fg, dark ? 0.3 : 0.32),
            .text: fg,
            .textSecondary: fg.mixed(with: bg, 0.28),
            .textTertiary: fg.mixed(with: bg, 0.45),
            .well: dark ? bg.mixed(with: .black, 0.3) : bg.mixed(with: fg, 0.05),
            .accent: terminal.ansi[4],
        ]
        let surface = values[.surface]!
        // The sidebar must still carry body text well.
        values[.sidebar] = values[.sidebar]!.ensuring(contrast: 4.5, with: fg, movingTo: surface)
        // The bars carry text in all three strengths: secondary as body text, tertiary as hints.
        let chrome = values[.chrome]!
        values[.text] = fg.ensuring(contrast: 4.5, with: chrome, movingTo: dark ? .white : .black)
        // A line reads on both layers, whatever the palette.
        values[.line] = values[.line]!.ensuring(contrast: 1.3, with: chrome, movingTo: fg).ensuring(contrast: 1.3, with: bg, movingTo: fg)
        let ink = values[.text]!
        values[.textSecondary] = values[.textSecondary]!.ensuring(contrast: 4.5, with: chrome, movingTo: ink)
        values[.textTertiary] = values[.textTertiary]!.ensuring(contrast: 3, with: chrome, movingTo: ink)
        // "Needs you" must stand out on the surface: the stronger of the two reds, deepened if need be.
        let red = [terminal.ansi[1], terminal.ansi[9]].max { $0.contrast(with: surface) < $1.contrast(with: surface) }!
        values[.needsYou] = red.ensuring(contrast: 3, with: surface, movingTo: fg)
        values[.error] = values[.needsYou]
        values[.working] = values[.textTertiary]
        values[.done] = fg
        values[.idle] = values[.lineStrong]
        return AppColors(values: values)
    }
}

/// One appearance of a theme: its terminal colours and the app's.
public struct ThemeVariant: Hashable, Sendable, Codable {
    public var terminal: TerminalColors
    public var app: AppColors

    public init(terminal: TerminalColors, app overrides: [AppColorKey: RGBColor] = [:]) {
        self.terminal = terminal
        var app = AppColors.derived(from: terminal)
        for (key, value) in overrides { app[key] = value }
        self.app = app
    }

    public var isDark: Bool { terminal.isDark }

    private enum Keys: String, CodingKey { case terminal, app }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let terminal = try container.decode(TerminalColors.self, forKey: .terminal)
        let given = try container.decodeIfPresent([String: RGBColor].self, forKey: .app) ?? [:]
        // Unknown names are left out rather than refused, so a newer file still opens.
        let overrides = Dictionary(uniqueKeysWithValues: given.compactMap { key, value in AppColorKey(rawValue: key).map { ($0, value) } })
        self.init(terminal: terminal, app: overrides)
    }

    /// Writes only the app colours that differ from what the terminal's would give, so files stay short.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(terminal, forKey: .terminal)
        let derived = AppColors.derived(from: terminal)
        let changed = Dictionary(uniqueKeysWithValues: AppColorKey.allCases.compactMap { key in
            app[key] == derived[key] ? nil : (key.rawValue, app[key])
        })
        if !changed.isEmpty { try container.encode(changed, forKey: .app) }
    }

    /// Pairs that are hard to read, with WCAG's thresholds: 4.5 for text, 3 for secondary text and
    /// for marks that must stand out.
    public var readabilityWarnings: [ReadabilityWarning] {
        let surface = app[.surface]
        let checks: [(String, RGBColor, RGBColor, Double)] = [
            ("Terminal text on its background", terminal.foreground, terminal.background, 4.5),
            ("Text on the surface", app[.text], surface, 4.5),
            ("Secondary text on the surface", app[.textSecondary], surface, 3),
            ("Text in the sidebar", app[.text], app[.sidebar], 4.5),
            ("Text on the bars", app[.text], app[.chrome], 4.5),
            ("Secondary text on the bars", app[.textSecondary], app[.chrome], 4.5),
            ("Hints on the bars", app[.textTertiary], app[.chrome], 3),
            ("The \"needs you\" colour on the surface", app[.needsYou], surface, 3),
        ]
        return checks.compactMap { what, a, b, minimum in
            let ratio = a.contrast(with: b)
            return ratio < minimum ? ReadabilityWarning(what: what, ratio: ratio, minimum: minimum) : nil
        }
    }
}

public struct ReadabilityWarning: Hashable, Sendable {
    public let what: String
    public let ratio: Double
    public let minimum: Double

    public var message: String { String(format: "%@ is hard to read (contrast %.1f:1; at least %.1f:1 is advised).", what, ratio, minimum) }
}

/// A theme: a name, where it comes from, and a light and/or a dark variant.
public struct Theme: Hashable, Sendable, Identifiable, Codable {
    public static let format = "whiskr-theme"
    public static let currentVersion = 1
    public static let fileExtension = "whiskrtheme"
    /// What theme files were called before the app was renamed (it was "Workers Factory"): still read,
    /// never written. `LegacyMigration` renames the ones in the themes folder.
    public static let legacyFormat = "workers-factory-theme"
    public static let legacyFileExtension = "wftheme"
    /// The extensions a theme file of ours may have, the current one first.
    public static let fileExtensions = [fileExtension, legacyFileExtension]

    public var id: String
    public var name: String
    public var author: String?
    /// Where the colours come from and under which licence.
    public var credit: String?
    public var light: ThemeVariant?
    public var dark: ThemeVariant?
    /// Shipped with the app (and so not editable in place).
    public var isBuiltIn = false

    public init(id: String, name: String, author: String? = nil, credit: String? = nil, light: ThemeVariant?, dark: ThemeVariant?, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.author = author
        self.credit = credit
        self.light = light
        self.dark = dark
        self.isBuiltIn = isBuiltIn
    }

    /// The variant for an appearance: the matching one when the theme has both, else the one it has.
    public func variant(dark wantsDark: Bool) -> ThemeVariant {
        let preferred = wantsDark ? dark : light
        // A theme has at least one variant; decoding refuses one with none.
        return preferred ?? light ?? dark!
    }

    /// The theme has only one appearance, which then decides the app's (a dark-only theme makes the
    /// whole window dark).
    public var fixedDarkness: Bool? {
        switch (light, dark) {
        case (nil, .some): true
        case (.some, nil): false
        default: nil
        }
    }

    // MARK: Files

    private enum Keys: String, CodingKey { case format, version, id, name, author, credit, light, dark }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let format = try container.decodeIfPresent(String.self, forKey: .format), format != Self.format, format != Self.legacyFormat {
            throw DecodingError.dataCorruptedError(forKey: .format, in: container, debugDescription: "Not a Whiskr theme (\(format))")
        }
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        guard version <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Made by a newer version of the app (\(version))")
        }
        name = try container.decode(String.self, forKey: .name)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? Self.slug(name)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        credit = try container.decodeIfPresent(String.self, forKey: .credit)
        light = try container.decodeIfPresent(ThemeVariant.self, forKey: .light)
        dark = try container.decodeIfPresent(ThemeVariant.self, forKey: .dark)
        guard light != nil || dark != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A theme needs a light or a dark variant"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(Self.format, forKey: .format)
        try container.encode(Self.currentVersion, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encodeIfPresent(credit, forKey: .credit)
        try container.encodeIfPresent(light, forKey: .light)
        try container.encodeIfPresent(dark, forKey: .dark)
    }

    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func read(_ data: Data) throws -> Theme {
        try JSONDecoder().decode(Theme.self, from: data)
    }

    /// A lowercase, file-safe form of a name: "Rosé Pine Dawn" → "rose-pine-dawn".
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
        let words = folded.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? "theme" : words.joined(separator: "-")
    }
}

// MARK: Importing

public enum ThemeImportError: Error, Equatable, Sendable {
    case unreadable(String)

    public var message: String {
        switch self { case .unreadable(let why): why }
    }
}

public enum ThemeImport {
    /// iTerm2's `.itermcolors` (a property list of "Ansi 0 Color" … "Ansi 15 Color", "Background
    /// Color", "Foreground Color", "Cursor Color", "Selection Color"), as one variant, light or
    /// dark by its background.
    public static func iTermColors(_ data: Data, name: String) throws -> Theme {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ThemeImportError.unreadable("This is not an iTerm2 colour file.")
        }
        func color(_ key: String) -> RGBColor? {
            guard let entry = plist[key] as? [String: Any],
                  let red = (entry["Red Component"] as? NSNumber)?.doubleValue,
                  let green = (entry["Green Component"] as? NSNumber)?.doubleValue,
                  let blue = (entry["Blue Component"] as? NSNumber)?.doubleValue else { return nil }
            return RGBColor(red: red, green: green, blue: blue)
        }
        let ansi = (0..<16).compactMap { color("Ansi \($0) Color") }
        guard ansi.count == 16, let background = color("Background Color"), let foreground = color("Foreground Color") else {
            throw ThemeImportError.unreadable("The iTerm2 colour file is missing some of its sixteen colours or its background and foreground.")
        }
        let terminal = TerminalColors(background: background, foreground: foreground, cursor: color("Cursor Color"), selection: color("Selection Color"), ansi: ansi)
        let variant = ThemeVariant(terminal: terminal)
        return Theme(id: Theme.slug(name), name: name, credit: "Imported from iTerm2 colours",
                     light: variant.isDark ? nil : variant, dark: variant.isDark ? variant : nil)
    }

    /// A theme file of ours or iTerm2's, chosen by its extension.
    public static func file(at url: URL) throws -> Theme {
        guard let data = try? Data(contentsOf: url) else { throw ThemeImportError.unreadable("The file could not be read.") }
        let name = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "itermcolors":
            return try iTermColors(data, name: name)
        default:
            do {
                return try Theme.read(data)
            } catch let error as DecodingError {
                throw ThemeImportError.unreadable("This is not a theme file the app understands: \(describe(error))")
            }
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context), .keyNotFound(_, let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }
}
