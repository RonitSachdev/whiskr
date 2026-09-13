import AppKit
import SwiftUI
import WhiskrKit

/// The app's colours, all from the active theme (`ThemeStore`): views never name a colour of their
/// own. Reading one inside a SwiftUI body or an `Observing` block redraws it when the theme changes.
enum Colors {
    private static var palette: Palette { ThemeStore.shared.palette }

    static var surface: NSColor { palette[.surface] }
    static var sidebar: NSColor { palette[.sidebar] }
    static var line: NSColor { palette[.line] }
    static var well: NSColor { palette[.well] }
    static var text: NSColor { palette[.text] }
    static var textTertiary: NSColor { palette[.textTertiary] }
    static var terminalBackground: NSColor { palette.terminalBackground }
    /// The focused pane's darker frame.
    static var focusFrame: NSColor { palette[.textTertiary] }

    /// Accounts are told apart by colour, as in the meadow: the blanket colours, handed out in the
    /// order the accounts are listed (default first). They identify, so they stay the same in every theme.
    static let accountColors: [UInt32] = [0x2fb39a, 0xf0606e, 0xf2b632, 0x4f9be8, 0x9b7fe8, 0xf08a3c]

    static func accountColor(index: Int) -> SwiftUI.Color {
        let color = WhiskrKit.RGBColor(accountColors[max(index, 0) % accountColors.count])
        return SwiftUI.Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}

extension SwiftUI.Color {
    private static func theme(_ key: AppColorKey) -> SwiftUI.Color { ThemeStore.shared.palette.color(key) }

    static var surface: SwiftUI.Color { theme(.surface) }
    static var sunk: SwiftUI.Color { theme(.sidebar) }
    static var hover: SwiftUI.Color { theme(.hover) }
    static var press: SwiftUI.Color { theme(.press) }
    static var line: SwiftUI.Color { theme(.line) }
    static var lineStrong: SwiftUI.Color { theme(.lineStrong) }
    static var ink: SwiftUI.Color { theme(.text) }
    static var ink2: SwiftUI.Color { theme(.textSecondary) }
    static var ink3: SwiftUI.Color { theme(.textTertiary) }
    static var well: SwiftUI.Color { theme(.well) }
    static var accent: SwiftUI.Color { theme(.accent) }
    static var alert: SwiftUI.Color { theme(.needsYou) }
    static var onAlert: SwiftUI.Color { ThemeStore.shared.palette.onNeedsYou }
    static var working: SwiftUI.Color { theme(.working) }
    static var done: SwiftUI.Color { theme(.done) }
    static var idle: SwiftUI.Color { theme(.idle) }
    static var error: SwiftUI.Color { theme(.error) }
}
