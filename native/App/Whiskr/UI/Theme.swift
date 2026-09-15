import AppKit
import SwiftUI
import WhiskrKit

/// The app's colours, all from the active theme (`ThemeStore`): views never name a colour of their
/// own. Reading one inside a SwiftUI body or an `Observing` block redraws it when the theme changes.
enum Colors {
    private static var palette: Palette { ThemeStore.shared.palette }

    static var surface: NSColor { palette[.surface] }
    static var line: NSColor { palette[.line] }
    static var well: NSColor { palette[.well] }
    static var text: NSColor { palette[.text] }
    static var textTertiary: NSColor { palette[.textTertiary] }
    static var terminalBackground: NSColor { palette.terminalBackground }
    /// The window's chrome: the top bar, the tab row, the status bar and the side panel.
    static var chrome: NSColor { palette[.chrome] }
    static var accent: NSColor { palette[.accent] }
    static var lineStrong: NSColor { palette[.lineStrong] }

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
    /// The window's chrome (`Colors.chrome`).
    static var chrome: SwiftUI.Color { theme(.chrome) }
    /// The content layer: the terminal's own background, which the selected tab shares.
    static var content: SwiftUI.Color { SwiftUI.Color(nsColor: Colors.terminalBackground) }
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

/// The interface's measures (docs/DESIGN.md, "Look of the interface"): one spacing scale, three radii,
/// one height per kind of bar and control, one icon size, and the strengths of the hover, pressed and
/// selected fills. Views use these rather than numbers of their own.
enum Look {
    /// Spacing: 4, 8, 12, 16, 24, 32 (and 2 and 6 inside a control).
    enum Space {
        static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 6, m: CGFloat = 8, l: CGFloat = 12, xl: CGFloat = 16, xxl: CGFloat = 24, xxxl: CGFloat = 32
    }

    /// Corners: small things (badges, key caps), controls (buttons, fields, rows), and floating cards
    /// (the palette, the answer card, popovers). Bars, tabs and panes are square: they meet edge to edge.
    enum Radius {
        static let small: CGFloat = 4, control: CGFloat = 6, card: CGFloat = 10
    }

    /// The bars' heights. The top bar is the compact title bar's band (40 pt on macOS 26, the traffic
    /// lights centred 20 pt down), so the lights sit centred in it.
    enum Height {
        static let topBar: CGFloat = 40, tabRow: CGFloat = 34, statusBar: CGFloat = 24
        /// An icon button or a field in a bar.
        static let control: CGFloat = 26
        /// An icon button's width.
        static let iconButton: CGFloat = 28
    }

    /// Every symbol in the bars is this size and weight; inside a tab or the status bar, `smallIcon`.
    static let icon = Font.system(size: 13, weight: .regular)
    static let smallIcon = Font.system(size: 11, weight: .regular)

    /// The fills of a control on the chrome, over whatever colour is under it.
    enum Fill {
        static let hover = Color.primary.opacity(0.06)
        static let pressed = Color.primary.opacity(0.11)
        static let selected = Color.primary.opacity(0.09)
    }

    /// Where the keys go, on the selected tab and the focused pane: the theme's accent while the window is
    /// the one you are using, a quiet grey while it is not (as the system's own selection greys).
    static func focusLine(active: Bool) -> Color { active ? .accent : .lineStrong }
    static func focusLine(active: Bool) -> NSColor { active ? Colors.accent : Colors.lineStrong }

    /// Width of the line along the selected tab's top, and of the border round the focused pane of a split;
    /// a point wider each with Increase Contrast.
    static var focusLineWidth: CGFloat { increasesContrast ? 3 : 2 }
    static var focusBorderWidth: CGFloat { increasesContrast ? 2.5 : 1.5 }

    /// The system's Increase Contrast (or a high-contrast appearance a debug run draws in).
    static var increasesContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || Palette.isHighContrast(NSApp.effectiveAppearance)
    }

    /// How the interface moves (docs/DESIGN.md, "Motion"): one small set of durations and one curve, so
    /// every transition in the window feels like the same app. The action itself never waits for them: a
    /// tab is chosen or closed at once and only the picture eases. With Reduce Motion, things that would
    /// move or scale cross-fade instead (`Look.Motion.animation(_:)` returns a plain fade's timing, and
    /// callers drop offsets and scales).
    enum Motion {
        /// A control's own feedback: hover and pressed fills, the selected tab's line moving over.
        static let quick: TimeInterval = 0.12
        /// Something appearing or going in place: a tab, the palette and its field, a bar, a card, a list.
        static let standard: TimeInterval = 0.16
        /// A region of the window sliding in or out: the side panel, the meadow, the status bar.
        static let region: TimeInterval = 0.2

        /// The one curve: a quick start that settles (ease-out), as AppKit's own panels do.
        static let curve = CAMediaTimingFunction(controlPoints: 0.2, 0.0, 0.0, 1.0)

        /// SwiftUI's form of `duration` on the same curve.
        static func animation(_ duration: TimeInterval) -> Animation {
            .timingCurve(0.2, 0.0, 0.0, 1.0, duration: duration)
        }

        /// Whether to move at all: false with Reduce Motion (then only fades, or nothing).
        @MainActor static var moves: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }
}

/// A control in the bars: its hover, pressed and selected fills, the same everywhere.
struct ChromeButtonStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = Look.Radius.control

    func makeBody(configuration: Configuration) -> some View {
        ChromeButtonBody(configuration: configuration, selected: selected, radius: radius)
    }

    private struct ChromeButtonBody: View {
        let configuration: Configuration
        let selected: Bool
        let radius: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: radius).fill(fill))
                // The fill eases between rest, hover, pressed and selected (`Look.Motion.quick`); only the
                // picture: the button acts on the click as before.
                .animation(Look.Motion.animation(Look.Motion.quick), value: fill)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            guard enabled else { return .clear }
            if configuration.isPressed { return Look.Fill.pressed }
            if selected { return Look.Fill.selected }
            return hovering ? Look.Fill.hover : .clear
        }
    }
}

extension ControlActiveState {
    /// The window is the one in use: the bars' text and the focus lines go quiet when it is not, as every
    /// Mac window's title bar does. In use is main as well as key (`.active`), as the title bar goes by: a
    /// panel of its own taking the keys (Go to, the command palette) leaves it as it was.
    var inUse: Bool { self == .key || self == .active || WindowChrome.drawsAsKey }
}

extension NSWindow {
    /// The window is the one in use (`ControlActiveState.inUse`, for AppKit views).
    var isInUse: Bool { isMainWindow || isKeyWindow || WindowChrome.drawsAsKey }
}
