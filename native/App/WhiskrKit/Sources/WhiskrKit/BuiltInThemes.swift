import Foundation

/// The themes that come with the app: ours (the default), then well-known terminal schemes that are
/// freely licensed, each credited. The schemes' own terminal palettes are kept as published; app
/// colours are worked out from them unless noted.
public enum BuiltInThemes {
    public static let defaultID = "whiskr"

    public static let all: [Theme] = [
        whiskr, bundled("modern"), catppuccin, tokyoNight, gruvbox, bundled("solarized"), rosePine, dracula, bundled("monokai"), nord,
    ]

    public static func theme(id: String) -> Theme? { all.first { $0.id == id } }

    private static func terminal(_ background: UInt32, _ foreground: UInt32, cursor: UInt32? = nil, selection: UInt32? = nil, _ ansi: [UInt32]) -> TerminalColors {
        TerminalColors(background: RGBColor(background), foreground: RGBColor(foreground),
                       cursor: cursor.map(RGBColor.init), selection: selection.map(RGBColor.init), ansi: ansi.map(RGBColor.init))
    }

    private static func app(_ values: [AppColorKey: UInt32]) -> [AppColorKey: RGBColor] {
        values.mapValues(RGBColor.init)
    }

    /// A theme kept as data in the Kit's `Themes` folder: those made from Visual Studio Code's themes, with
    /// their code colours (converted by `VSCodeThemeConversion`; sources and licences in `Themes/ThirdParty`).
    private static func bundled(_ id: String) -> Theme {
        guard let url = Bundle.module.url(forResource: id, withExtension: Theme.fileExtension, subdirectory: "Themes"),
              let data = try? Data(contentsOf: url), var theme = try? Theme.read(data) else {
            fatalError("The built-in theme \(id) is missing from the Kit's resources")
        }
        theme.isBuiltIn = true
        return theme
    }

    /// Ours: off-white and near-black surfaces with the bars a step below them, charcoal ink in three
    /// strengths, soft grey lines, one red for "needs you" (docs/DESIGN.md).
    static let whiskr = Theme(
        id: defaultID, name: "Whiskr", author: "Whiskr", credit: "The app's own neutral palette",
        light: ThemeVariant(
            terminal: terminal(0xfdfdfc, 0x232327, cursor: 0x5b5b62, selection: 0xccdbf7, [
                0x232327, 0xb3261e, 0x1d6b39, 0x8a6100, 0x2f5596, 0x8e3b8f, 0x1f6f78, 0xbdbdb8,
                0x6b6b72, 0xd4433a, 0x2e8b4f, 0xa87b00, 0x2f6fe4, 0xa855a8, 0x2a8a95, 0xe6e6e2,
            ]),
            app: app([.surface: 0xfcfcfb, .chrome: 0xf3f3f1, .line: 0xd2d2ce, .lineStrong: 0xc4c4bf,
                      .text: 0x232327, .textSecondary: 0x5b5b62, .textTertiary: 0x8a8a91, .well: 0xf1f1ee, .accent: 0x2f6fe4,
                      .working: 0x8a8a91, .needsYou: 0xd4433a, .done: 0x232327, .idle: 0xd4d4cf, .error: 0xd4433a])),
        dark: ThemeVariant(
            terminal: terminal(0x161618, 0xececee, cursor: 0xa9a9b0, selection: 0x45546f, [
                0x2a2a2d, 0xef6b62, 0x6cc488, 0xe6c15a, 0x6fa3f2, 0xc98ee0, 0x5fc4cf, 0xd8d8dc,
                0x6b6b72, 0xff8a80, 0x8fdba6, 0xf5d77e, 0x94bcff, 0xe0b0f2, 0x86dde6, 0xf4f4f6,
            ]),
            app: app([.surface: 0x1e1e20, .chrome: 0x0f0f11, .line: 0x36363b, .lineStrong: 0x4a4a50,
                      .text: 0xececee, .textSecondary: 0xa9a9b0, .textTertiary: 0x7a7a82, .well: 0x0f0f11, .accent: 0x6fa3f2,
                      .working: 0x7a7a82, .needsYou: 0xe5564c, .done: 0xececee, .idle: 0x45454a, .error: 0xe5564c])),
        isBuiltIn: true)

    static let catppuccin = Theme(
        id: "catppuccin", name: "Catppuccin", author: "Catppuccin", credit: "Latte and Mocha · catppuccin.com · MIT licence",
        light: ThemeVariant(terminal: terminal(0xeff1f5, 0x4c4f69, cursor: 0xdc8a78, selection: 0xacb0be, [
            0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xacb0be,
            0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xbcc0cc,
        ])),
        dark: ThemeVariant(terminal: terminal(0x1e1e2e, 0xcdd6f4, cursor: 0xf5e0dc, selection: 0x585b70, [
            0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
            0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8,
        ])),
        isBuiltIn: true)

    static let tokyoNight = Theme(
        id: "tokyo-night", name: "Tokyo Night", author: "enkia", credit: "Day and Night · github.com/enkia/tokyo-night-vscode-theme · MIT licence",
        light: ThemeVariant(terminal: terminal(0xe1e2e7, 0x3760bf, cursor: 0x3760bf, selection: 0xb7c1e3, [
            0xe9e9ed, 0xf52a65, 0x587539, 0x8c6c3e, 0x2e7de9, 0x9854f1, 0x007197, 0x6172b0,
            0xa1a6c5, 0xf52a65, 0x587539, 0x8c6c3e, 0x2e7de9, 0x9854f1, 0x007197, 0x3760bf,
        ])),
        dark: ThemeVariant(terminal: terminal(0x1a1b26, 0xc0caf5, cursor: 0xc0caf5, selection: 0x283457, [
            0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
            0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5,
        ])),
        isBuiltIn: true)

    static let gruvbox = Theme(
        id: "gruvbox", name: "Gruvbox", author: "Pavel Pertsev", credit: "github.com/morhetz/gruvbox · MIT licence",
        light: ThemeVariant(terminal: terminal(0xfbf1c7, 0x3c3836, cursor: 0x3c3836, selection: 0xd5c4a1, [
            0xfbf1c7, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0x7c6f64,
            0x928374, 0x9d0006, 0x79740e, 0xb57614, 0x076678, 0x8f3f71, 0x427b58, 0x3c3836,
        ])),
        dark: ThemeVariant(terminal: terminal(0x282828, 0xebdbb2, cursor: 0xebdbb2, selection: 0x504945, [
            0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
            0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2,
        ])),
        isBuiltIn: true)

    static let rosePine = Theme(
        id: "rose-pine", name: "Rosé Pine", author: "Rosé Pine", credit: "Dawn and main · rosepinetheme.com · MIT licence",
        light: ThemeVariant(terminal: terminal(0xfaf4ed, 0x575279, cursor: 0x9893a5, selection: 0xdfdad9, [
            0xf2e9e1, 0xb4637a, 0x286983, 0xea9d34, 0x56949f, 0x907aa9, 0xd7827e, 0x575279,
            0x9893a5, 0xb4637a, 0x286983, 0xea9d34, 0x56949f, 0x907aa9, 0xd7827e, 0x575279,
        ])),
        dark: ThemeVariant(terminal: terminal(0x191724, 0xe0def4, cursor: 0x524f67, selection: 0x403d52, [
            0x26233a, 0xeb6f92, 0x31748f, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4,
            0x6e6a86, 0xeb6f92, 0x31748f, 0xf6c177, 0x9ccfd8, 0xc4a7e7, 0xebbcba, 0xe0def4,
        ])),
        isBuiltIn: true)

    static let dracula = Theme(
        id: "dracula", name: "Dracula", author: "Dracula Theme", credit: "draculatheme.com · MIT licence",
        light: nil,
        dark: ThemeVariant(terminal: terminal(0x282a36, 0xf8f8f2, cursor: 0xf8f8f2, selection: 0x44475a, [
            0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
            0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff,
        ])),
        isBuiltIn: true)

    static let nord = Theme(
        id: "nord", name: "Nord", author: "Arctic Ice Studio", credit: "nordtheme.com · MIT licence",
        light: nil,
        dark: ThemeVariant(terminal: terminal(0x2e3440, 0xd8dee9, cursor: 0xd8dee9, selection: 0x434c5e, [
            0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
            0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4,
        ])),
        isBuiltIn: true)
}
