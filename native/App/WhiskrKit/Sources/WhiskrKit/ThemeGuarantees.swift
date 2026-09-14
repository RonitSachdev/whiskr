import Foundation

// What every theme must give the window, whoever made it (docs/DESIGN.md, "Look of the interface"): text
// that reads (`ThemeVariant.readabilityWarnings`), the chrome a step below the content (1.03…1.25:1 and
// darker), a line that shows on both layers (1.3:1), an accent that stands out on the content (3:1), and
// git's colours that read in the file list and on the content (3:1). The built-in themes are made to meet
// them; an imported theme is brought to them by `meetingGuarantees()`, which moves only the colours that
// fall short, each in small steps and only as far as needed, so an import looks as its author made it
// wherever it already reads.

extension ThemeVariant {
    /// The chrome's step below the content, as a contrast ratio.
    public static let chromeStep: ClosedRange<Double> = 1.03...1.25
    /// A line between regions, on either layer.
    public static let lineContrast = 1.3
    /// Marks that must stand out: the accent on the content, git's colours.
    public static let markContrast = 3.0

    /// The git states the file list and the changes show, which must read on both layers.
    static let gitKeys: [EditorColorKey] = [.gitAdded, .gitModified, .gitDeleted, .gitRenamed, .gitUntracked, .gitConflict]

    /// What this variant falls short of, in words (empty when it meets every guarantee).
    public var guaranteeFailures: [String] {
        var failures = readabilityWarnings.map(\.message)
        let content = terminal.background, chrome = app[.chrome], line = app[.line]
        let step = chrome.contrast(with: content)
        if !Self.chromeStep.contains(step) { failures.append(String(format: "The bars against the content are %.2f:1 (1.03 to 1.25 is the step).", step)) }
        if chrome.luminance >= content.luminance { failures.append("The bars are not darker than the content.") }
        for (layer, color) in [("bars", chrome), ("content", content)] where line.contrast(with: color) < Self.lineContrast {
            failures.append(String(format: "The line on the %@ is %.2f:1 (at least 1.3:1).", layer, line.contrast(with: color)))
        }
        if app[.accent].contrast(with: content) < Self.markContrast {
            failures.append(String(format: "The accent on the content is %.2f:1 (at least 3:1).", app[.accent].contrast(with: content)))
        }
        for key in Self.gitKeys {
            for (layer, color) in [("bars", chrome), ("content", content)] where editor[key].contrast(with: color) < Self.markContrast {
                failures.append(String(format: "%@ on the %@ is %.2f:1 (at least 3:1).", key.label, layer, editor[key].contrast(with: color)))
            }
        }
        return failures
    }

    /// This variant with every colour that falls short of a guarantee moved just far enough to meet it,
    /// and what was moved, in words ("chrome #2b2b2b → #1a1a1a"). The order matters: the content and its
    /// text first, then the chrome (a step from the content), then what sits on either.
    public func meetingGuarantees() -> (variant: ThemeVariant, repairs: [String]) {
        var variant = self
        var repairs: [String] = []
        func note(_ what: String, _ from: RGBColor, _ to: RGBColor) {
            if from != to { repairs.append("\(what) \(from.hex) → \(to.hex)") }
        }
        let dark = variant.isDark
        // The far end in each appearance: moving toward it gains contrast against the background.
        let far: RGBColor = dark ? .white : .black

        // Terminal text on its background.
        var bg = variant.terminal.background
        let fg = variant.terminal.foreground
        let readableFg = fg.stepped(toward: far) { $0.contrast(with: bg) >= 4.5 }
        note("terminal text", fg, readableFg)
        variant.terminal.foreground = readableFg

        // The chrome: a step below the content. A theme's own darker bars are kept, brought nearer the
        // content if they are too far; otherwise the content is stepped toward black (dark) or its text
        // (light), as the app's own rule does. Content that is already black has nothing darker below it,
        // so the content itself is lifted one step.
        let chrome = variant.app[.chrome]
        var newChrome = chrome
        if !(Self.chromeStep.contains(chrome.contrast(with: bg)) && chrome.luminance < bg.luminance) {
            if chrome.luminance < bg.luminance, chrome.contrast(with: bg) > Self.chromeStep.upperBound {
                newChrome = chrome.stepped(toward: bg) { $0.contrast(with: bg) <= Self.chromeStep.upperBound }
            } else {
                let below: RGBColor = dark ? .black : readableFg
                newChrome = bg.stepped(toward: below) { $0.luminance < bg.luminance && $0.contrast(with: bg) >= Self.chromeStep.lowerBound }
                if !(newChrome.luminance < bg.luminance && newChrome.contrast(with: bg) >= Self.chromeStep.lowerBound) {
                    newChrome = below
                    let lifted = bg.stepped(toward: readableFg) { $0.contrast(with: below) >= Self.chromeStep.lowerBound }
                    note("content", bg, lifted)
                    bg = lifted
                    variant.terminal.background = lifted
                }
            }
        }
        note("chrome", chrome, newChrome)
        variant.app[.chrome] = newChrome

        // A line on both layers.
        let line = variant.app[.line]
        let newLine = line.stepped(toward: readableFg) { $0.contrast(with: newChrome) >= Self.lineContrast && $0.contrast(with: bg) >= Self.lineContrast }
        note("line", line, newLine)
        variant.app[.line] = newLine

        // Text in its three strengths, on the surface and on the bars; the states drawn in them follow.
        let surface = variant.app[.surface]
        func raise(_ key: AppColorKey, _ chromeMinimum: Double, _ surfaceMinimum: Double) {
            let color = variant.app[key]
            let raised = color.stepped(toward: far) { $0.contrast(with: newChrome) >= chromeMinimum && $0.contrast(with: surface) >= surfaceMinimum }
            note(key.rawValue, color, raised)
            variant.app[key] = raised
        }
        raise(.text, 4.5, 4.5)
        raise(.textSecondary, 4.5, 3)
        raise(.textTertiary, 3, 0)
        if variant.app[.working] == self.app[.textTertiary] { variant.app[.working] = variant.app[.textTertiary] }
        raise(.needsYou, 0, 3)
        if variant.app[.error] == self.app[.needsYou] { variant.app[.error] = variant.app[.needsYou] }

        // Marks that must stand out.
        let accent = variant.app[.accent]
        let newAccent = accent.stepped(toward: far) { $0.contrast(with: bg) >= Self.markContrast }
        note("accent", accent, newAccent)
        variant.app[.accent] = newAccent
        for key in Self.gitKeys {
            let color = variant.editor[key]
            let raised = color.stepped(toward: far) { $0.contrast(with: bg) >= Self.markContrast && $0.contrast(with: newChrome) >= Self.markContrast }
            note(key.rawValue, color, raised)
            variant.editor[key] = raised
        }
        return (variant, repairs)
    }
}

extension RGBColor {
    /// This colour as written in a theme file: each channel to the nearest of 256 steps.
    var quantized: RGBColor { RGBColor(hex: hex) ?? self }

    /// This colour moved toward `target` in steps of 1 % (each step written as a theme file would) until
    /// `good` holds, or `target` itself when no step does. Unchanged when it already holds.
    func stepped(toward target: RGBColor, until good: (RGBColor) -> Bool) -> RGBColor {
        if good(self) { return self }
        for step in 1...100 {
            let color = mixed(with: target, Double(step) / 100).quantized
            if good(color) { return color }
        }
        return target
    }
}
