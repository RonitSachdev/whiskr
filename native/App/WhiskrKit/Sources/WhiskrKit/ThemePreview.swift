import Foundation

// Which version of a theme the app shows, and what a theme's preview in Settings draws. A preview shows
// the theme as it will look once chosen: the version the app will then be in, whatever the app is in now
// (a theme with one version decides the app's appearance, so while Nord is chosen the app is dark, yet
// choosing a theme with both versions on a light Mac makes it light again), and the very colours the
// terminal and the window are given.

extension Theme {
    /// Whether the app is dark while this theme is chosen: a theme with one version decides; one with both
    /// follows `followedDark`, the appearance the app follows (the Mac's, or one a debug run sets).
    public func isDark(following followedDark: Bool) -> Bool {
        fixedDarkness ?? followedDark
    }
}

extension ThemeVariant {
    /// With Increase Contrast (docs/DESIGN.md), every line between regions reaches 3:1 on the chrome (the
    /// hint colour, which the theme keeps at 3:1 there), and each quieter text steps up one level.
    public static let increasedContrastColors: [AppColorKey: AppColorKey] = [
        .line: .textTertiary, .lineStrong: .textTertiary, .textSecondary: .text, .textTertiary: .textSecondary,
    ]

    /// An app colour as the window draws it: with Increase Contrast, the stronger one it steps up to.
    public func appColor(_ key: AppColorKey, increasedContrast: Bool) -> RGBColor {
        app[increasedContrast ? Self.increasedContrastColors[key] ?? key : key]
    }
}

/// The colours a theme's preview draws: the version of the theme the app will show once it is chosen, its
/// terminal's colours exactly as the terminal is given them, and the app's as the window draws them.
public struct ThemePreviewColors: Hashable, Sendable {
    /// The version shown is the dark one.
    public let isDark: Bool
    /// Background, text, cursor, selection and the sixteen colours, as the terminal takes them.
    public let terminal: TerminalColors
    /// The app's colours, as the window draws them (`ThemeVariant.appColor`).
    public let app: [AppColorKey: RGBColor]

    /// `followedDark`: the appearance the app follows when the theme leaves it free (the Mac's);
    /// `increasedContrast`: the system's Increase Contrast.
    public init(theme: Theme, followedDark: Bool, increasedContrast: Bool = false) {
        let dark = theme.isDark(following: followedDark)
        let variant = theme.variant(dark: dark)
        isDark = dark
        terminal = variant.terminal
        app = Dictionary(uniqueKeysWithValues: AppColorKey.allCases.map { ($0, variant.appColor($0, increasedContrast: increasedContrast)) })
    }

    public subscript(key: AppColorKey) -> RGBColor { app[key] ?? .black }

    /// The sixteen colours as a terminal theme shows them: the normal eight (black … white), then the bright.
    public var ansiRows: [[RGBColor]] { [Array(terminal.ansi.prefix(8)), Array(terminal.ansi.dropFirst(8).prefix(8))] }
}
