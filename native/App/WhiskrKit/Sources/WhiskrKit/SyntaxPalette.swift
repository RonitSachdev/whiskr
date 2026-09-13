import Foundation

/// How a kind of token is drawn: a colour from the theme's terminal palette, so code in the editor, the
/// diffs and the Markdown preview matches the terminals in every theme, light or dark.
public struct SyntaxStyle: Sendable, Equatable {
    public var color: RGBColor
    public var bold: Bool
    public var italic: Bool

    public init(color: RGBColor, bold: Bool = false, italic: Bool = false) {
        self.color = color
        self.bold = bold
        self.italic = italic
    }
}

public enum SyntaxPalette {
    /// Each kind's style for a terminal palette (ANSI: 1 red, 2 green, 3 yellow, 4 blue, 5 magenta,
    /// 6 cyan): keywords magenta, strings green, types cyan, numbers and constants yellow, calls blue,
    /// properties and variables red, comments the foreground faded and in italics. Every colour keeps at
    /// least 3:1 contrast with the background, moved toward the foreground where the theme's own falls
    /// short (yellow on a light background).
    public static func styles(for terminal: TerminalColors) -> [SyntaxKind: SyntaxStyle] {
        let background = terminal.background, foreground = terminal.foreground
        func ansi(_ index: Int) -> RGBColor {
            let color = terminal.ansi.count == 16 ? terminal.ansi[index] : foreground
            return color.ensuring(contrast: 3, with: background, movingTo: foreground)
        }
        let faded = foreground.mixed(with: background, 0.45).ensuring(contrast: 2.6, with: background, movingTo: foreground)
        let quiet = foreground.mixed(with: background, 0.3)
        var styles: [SyntaxKind: SyntaxStyle] = [:]
        for kind in SyntaxKind.allCases {
            styles[kind] = switch kind {
            case .plain: SyntaxStyle(color: foreground)
            case .keyword: SyntaxStyle(color: ansi(5))
            case .type: SyntaxStyle(color: ansi(6))
            case .function: SyntaxStyle(color: ansi(4))
            case .string: SyntaxStyle(color: ansi(2))
            case .number, .constant: SyntaxStyle(color: ansi(3))
            case .comment: SyntaxStyle(color: faded, italic: true)
            case .attribute: SyntaxStyle(color: ansi(3))
            case .property, .variable: SyntaxStyle(color: ansi(1))
            case .tag: SyntaxStyle(color: ansi(4))
            case .escape: SyntaxStyle(color: ansi(6))
            case .heading: SyntaxStyle(color: ansi(4), bold: true)
            case .emphasis: SyntaxStyle(color: foreground, italic: true)
            case .strong: SyntaxStyle(color: foreground, bold: true)
            case .code: SyntaxStyle(color: ansi(2))
            case .link: SyntaxStyle(color: ansi(6))
            case .quote: SyntaxStyle(color: faded, italic: true)
            case .listMarker: SyntaxStyle(color: ansi(5))
            case .punctuation: SyntaxStyle(color: quiet)
            }
        }
        return styles
    }
}
