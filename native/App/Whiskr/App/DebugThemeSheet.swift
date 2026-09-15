#if DEBUG
import AppKit
import SwiftTerm
import SwiftUI
import WhiskrKit

/// Debug builds only: the themes' previews in Settings against what a terminal really draws with each theme.
/// Both are read from pixels: the previews from Settings › Terminal as the window draws it (each card found
/// by its accessibility element), the terminal from a `TerminalSurface` (the panes' own class, so its colours
/// come the way a pane's do) printing every colour of its palette as cell backgrounds. A preview is right
/// when it draws, for every theme, the colours the terminal and the window then have once that theme is
/// chosen, whichever theme is chosen while it is looked at (one with a single version holds the app dark or
/// light) and whichever appearance the Mac is in (`ThemeStore.appearance` stands in for it).
///
///   theme-sheets <folder>   imports a few themes, then writes previews.png (Settings › Terminal with Whiskr
///                           and with Nord chosen, on a light and on a dark Mac) and terminals.png (each
///                           theme in a terminal, light and dark), and prints every colour that differs
@MainActor
enum DebugThemeSheet {
    /// A colour read off the screen, to the hex digit, in sRGB.
    struct Sample: Equatable, CustomStringConvertible {
        var red, green, blue: Int
        init(_ color: NSColor) {
            let c = color.usingColorSpace(.sRGB) ?? color
            (red, green, blue) = (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
        init(_ color: WhiskrKit.RGBColor) {
            (red, green, blue) = (Int((color.red * 255).rounded()), Int((color.green * 255).rounded()), Int((color.blue * 255).rounded()))
        }
        /// Within six steps a channel: what drawing through the window's colour space (8 bits a channel) may move a
        /// saturated colour by; a wrong colour is far further off.
        func matches(_ other: Sample) -> Bool { abs(red - other.red) <= 6 && abs(green - other.green) <= 6 && abs(blue - other.blue) <= 6 }
        var description: String { String(format: "#%02x%02x%02x", red, green, blue) }
    }

    /// An sRGB bitmap something was drawn into, read by the pixel from its top left.
    struct Pixels {
        let width, height: Int
        private let context: CGContext

        init?(width: Int, height: Int, _ draw: (NSRect) -> Void) {
            guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            (self.width, self.height, self.context) = (width, height, context)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            draw(NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }

        var image: CGImage? { context.makeImage() }

        func sample(x: Int, y: Int) -> Sample {
            guard (0..<width).contains(x), (0..<height).contains(y), let data = context.data else { return Sample(WhiskrKit.RGBColor.black) }
            let pixel = data.advanced(by: y * context.bytesPerRow + x * 4).assumingMemoryBound(to: UInt8.self)
            return Sample(WhiskrKit.RGBColor(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255))
        }
    }

    /// What one theme looks like: its terminal's background, its sixteen colours, the window's chrome.
    struct Look: CustomStringConvertible {
        var background: Sample
        var ansi: [Sample]
        var chrome: Sample
        /// The terminal's own: its text, and what it tells a program that asks whether it is light or dark.
        var foreground: Sample? = nil
        var saysDark: Bool? = nil

        /// Each difference from `truth`, in words.
        func differences(from truth: Look) -> [String] {
            var found: [String] = []
            if !background.matches(truth.background) { found.append("background \(background) ≠ \(truth.background)") }
            if !chrome.matches(truth.chrome) { found.append("chrome \(chrome) ≠ \(truth.chrome)") }
            for index in ansi.indices where index < truth.ansi.count && !ansi[index].matches(truth.ansi[index]) {
                found.append("\(TerminalColors.ansiNames[index].lowercased()) \(ansi[index]) ≠ \(truth.ansi[index])")
            }
            return found
        }

        var description: String { "background \(background), chrome \(chrome), ansi \(ansi.map(\.description).joined(separator: " "))" }
    }

    // MARK: The terminal

    /// What the terminal prints for a look: every colour of its palette as a cell background, then a few
    /// lines in them.
    private static let palettePrint: String = {
        var text = "\u{1b}[0m"
        for index in 0..<16 { text += "\u{1b}[\(index < 8 ? 40 + index : 92 + index)m   " }
        text += "\u{1b}[0m\r\n\r\n"
        text += "\u{1b}[32m$ \u{1b}[39mnpm test\r\n\u{1b}[32m✓ 13 passing\r\n\u{1b}[31m✗ 1 failing\r\n"
        text += "\u{1b}[33mwarn \u{1b}[34msrc/cart.ts\r\n\u{1b}[36m~/shop \u{1b}[35mmain\u{1b}[0m\r\n"
        text += "\u{1b}[30mblack \u{1b}[37mwhite \u{1b}[90mbright-black \u{1b}[97mbright-white\u{1b}[0m\r\n> "
        return text
    }()

    /// The colours a terminal answers with when a program asks (OSC 4 for each of the sixteen, 10 and 11 for
    /// its text and background, `CSI ? 996 n` for light or dark): SwiftTerm's own palette, as the app gave it.
    private static let paletteQuestions = "\u{1b}]4;" + (0..<16).map { "\($0);?" }.joined(separator: ";") + "\u{7}\u{1b}]10;?\u{7}\u{1b}]11;?\u{7}\u{1b}[?996n"

    /// Keeps what a terminal answers (it would go to the program).
    private final class Answers: TerminalSurfaceDelegate {
        var text = ""
        func surface(_ surface: TerminalSurface, typed bytes: ArraySlice<UInt8>) { text += String(decoding: bytes, as: UTF8.self) }
        func surface(_ surface: TerminalSurface, resizedTo size: TerminalSize) {}
        func surfaceShown(_ surface: TerminalSurface) {}
        func surface(_ surface: TerminalSurface, titled title: String) {}
        func surface(_ surface: TerminalSurface, movedTo directory: String?) {}
        func surface(_ surface: TerminalSurface, programStatus records: [TerminalProgramStatus]) {}
        func surfaceRang(_ surface: TerminalSurface) {}
        func surface(_ surface: TerminalSurface, command: TerminalCommandMark) {}

        /// The colour answered for an OSC code ("4;7", "10", "11"), from its "rgb:rrrr/gggg/bbbb".
        func color(_ code: String) -> Sample? {
            guard let range = text.range(of: "]\(code);rgb:") else { return nil }
            let parts = text[range.upperBound...].prefix(14).split(separator: "/").prefix(3).map { Int($0.prefix(4), radix: 16) ?? 0 }
            guard parts.count == 3 else { return nil }
            return Sample(WhiskrKit.RGBColor(red: Double(parts[0]) / 65535, green: Double(parts[1]) / 65535, blue: Double(parts[2]) / 65535))
        }

        /// What the terminal says it is when asked light or dark: true for dark.
        var saysDark: Bool? { text.contains("[?997;1n") ? true : text.contains("[?997;2n") ? false : nil }
    }

    /// A terminal made now (the panes' own class), with the chosen theme as the app shows it now: the colours
    /// it answers with, and a picture of it. With Core Graphics terminals (`--cg-terminals`) the picture is
    /// what it draws, in a window of its own (unseen, as every window of a background run); with Metal, whose
    /// frames cannot be read back here, it is drawn from the colours it answered.
    static func terminalLook() async -> (look: Look, image: CGImage)? {
        let surface = TerminalSurface()
        let answers = Answers()
        surface.surfaceDelegate = answers
        let size = NSSize(width: 520, height: 150)
        var holder: NSWindow?
        if !TerminalSurface.drawsWithMetal {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = surface
            window.orderBack(nil)
            holder = window
        } else {
            surface.setFrameSize(size)
        }
        defer { holder?.orderOut(nil) }
        surface.feed(text: palettePrint + paletteQuestions)
        _ = await PerfWait.until(1000) { answers.color("11") != nil && answers.saysDark != nil }
        guard let background = answers.color("11"), let foreground = answers.color("10") else { return nil }
        let ansi = (0..<16).map { answers.color("4;\($0)") ?? Sample(WhiskrKit.RGBColor.black) }
        var chrome = Sample(WhiskrKit.RGBColor.black)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance { chrome = Sample(Colors.chrome) }
        let look = Look(background: background, ansi: ansi, chrome: chrome, foreground: foreground, saysDark: answers.saysDark)
        if holder != nil {
            await PerfWait.sleep(150)
            if let rep = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) {
                surface.cacheDisplay(in: surface.bounds, to: rep)
                // Its own background is the layer's, under what draw(_:) paints.
                let drawn = rep.cgImage.flatMap { image in
                    Pixels(width: image.width, height: image.height) { rect in
                        NSColor(srgbRed: CGFloat(background.red) / 255, green: CGFloat(background.green) / 255, blue: CGFloat(background.blue) / 255, alpha: 1).setFill()
                        rect.fill()
                        NSGraphicsContext.current?.cgContext.draw(image, in: rect)
                    }?.image
                }
                if let drawn { return (look, drawn) }
            }
        }
        return Pixels(width: Int(size.width * 2), height: Int(size.height * 2)) { rect in draw(look, in: rect) }?.image.map { (look, $0) }
    }

    /// The colours a terminal answered with, drawn as it would show them: its background, the sixteen as
    /// cell backgrounds, its text and the names of black and white in their own colours.
    private static func draw(_ look: Look, in rect: NSRect) {
        func color(_ sample: Sample) -> NSColor { NSColor(srgbRed: CGFloat(sample.red) / 255, green: CGFloat(sample.green) / 255, blue: CGFloat(sample.blue) / 255, alpha: 1) }
        color(look.background).setFill()
        rect.fill()
        let cell = rect.width / 48
        for (index, sample) in look.ansi.enumerated() {
            color(sample).setFill()
            NSRect(x: CGFloat(index) * 3 * cell, y: rect.height - cell * 2, width: cell * 3, height: cell * 2).fill()
        }
        let font = NSFont.monospacedSystemFont(ofSize: cell * 1.6, weight: .regular)
        let lines: [[(String, Sample)]] = [
            [("$ ", look.ansi[2]), ("npm test", look.foreground ?? look.ansi[7])], [("✓ 13 passing", look.ansi[2])], [("✗ 1 failing", look.ansi[1])],
            [("warn ", look.ansi[3]), ("src/cart.ts", look.ansi[4])], [("~/shop ", look.ansi[6]), ("main", look.ansi[5])],
            [("black ", look.ansi[0]), ("white ", look.ansi[7]), ("bright-black ", look.ansi[8]), ("bright-white", look.ansi[15])],
        ]
        for (row, line) in lines.enumerated() {
            let text = NSMutableAttributedString()
            for (words, sample) in line { text.append(NSAttributedString(string: words, attributes: [.font: font, .foregroundColor: color(sample)])) }
            text.draw(at: NSPoint(x: cell, y: rect.height - cell * 2 - CGFloat(row + 1) * cell * 2.4))
        }
    }

    /// Every theme chosen in turn, on a light and on a dark Mac: what the terminal and the window then show.
    /// Keyed by theme id, then by the Mac's darkness.
    static func truth(themes: [Theme]) async -> [String: [Bool: (look: Look, image: CGImage)]] {
        let store = ThemeStore.shared
        var found: [String: [Bool: (look: Look, image: CGImage)]] = [:]
        for macDark in [false, true] {
            store.appearance = macDark ? .dark : .light
            for theme in themes {
                store.themeID = theme.id
                await PerfWait.sleep(60)
                if let look = await terminalLook() { found[theme.id, default: [:]][macDark] = look }
            }
        }
        return found
    }

    /// Each theme whose terminal tells a program it is light when its background is dark, or the other
    /// way (a program that asks, `CSI ? 996 n`, then picks colours for the wrong background).
    static func schemeProblems(themes: [Theme], truth: [String: [Bool: (look: Look, image: CGImage)]]) -> [String] {
        themes.flatMap { theme in
            [false, true].compactMap { macDark -> String? in
                guard let look = truth[theme.id]?[macDark]?.look, let foreground = look.foreground else { return "\(theme.name): no answer" }
                let darkBackground = WhiskrKit.RGBColor(red: Double(look.background.red) / 255, green: Double(look.background.green) / 255, blue: Double(look.background.blue) / 255).luminance
                    < WhiskrKit.RGBColor(red: Double(foreground.red) / 255, green: Double(foreground.green) / 255, blue: Double(foreground.blue) / 255).luminance
                return look.saysDark == darkBackground ? nil
                    : "\(theme.name) on a \(macDark ? "dark" : "light") Mac: background \(look.background) but the terminal says \(look.saysDark.map { $0 ? "dark" : "light" } ?? "nothing")"
            }
        }
    }

    // MARK: Settings

    /// Settings › Terminal as the window draws it, tall enough for every card, and what each card's preview
    /// shows, by theme id.
    static func settingsLooks(themes: [Theme]) async -> (looks: [String: Look], image: CGImage?) {
        let settings = SettingsWindowController.shared
        settings.show()
        guard let window = settings.window, let tabs = window.contentViewController as? SettingsTabs else { return ([:], nil) }
        tabs.select(pane: "terminal")
        // Tall enough for every card (the pane's preferred size decides the window's).
        let pane = tabs.tabViewItems.first { ($0.identifier as? String) == "terminal" }?.viewController
        pane?.preferredContentSize = NSSize(width: 720, height: 1500)
        window.setContentSize(NSSize(width: 720, height: 1500))
        await PerfWait.sleep(700)
        guard let frame = window.contentView?.superview else { return ([:], nil) }
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return ([:], nil) }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        // In sRGB, as theme files write colours (the window's own colour space may be the display's).
        guard let drawn = rep.cgImage, let pixels = Pixels(width: drawn.width, height: drawn.height, { rect in
            NSGraphicsContext.current?.cgContext.draw(drawn, in: rect)
        }) else { return ([:], nil) }
        let scale = CGFloat(pixels.width) / frame.bounds.width
        var looks: [String: Look] = [:]
        var lowest: CGFloat = 0
        // Each card's place, from the view it carries in Debug builds (SwiftUI makes no accessibility
        // elements until an assistive app asks).
        var anchors: [String: NSView] = [:]
        func walk(_ view: NSView) {
            if let id = view.identifier?.rawValue, id.hasPrefix(Anchor.prefix) { anchors[String(id.dropFirst(Anchor.prefix.count))] = view }
            view.subviews.forEach(walk)
        }
        walk(frame)
        for theme in themes {
            guard let card = anchors[theme.id] else { continue }
            // The card's frame in the window's frame view, from its top.
            let inFrame = frame.convert(card.bounds, from: card)
            let top = frame.isFlipped ? inFrame.minY : frame.bounds.height - inFrame.maxY
            lowest = max(lowest, top + inFrame.height)
            let size = CGSize(width: inFrame.width, height: ThemePreview.cardHeight)
            func sample(_ point: CGPoint) -> Sample {
                pixels.sample(x: Int((inFrame.minX + point.x) * scale), y: Int((top + point.y) * scale))
            }
            looks[theme.id] = Look(background: sample(ThemePreview.backgroundPoint(in: size)),
                                   ansi: (0..<16).map { sample(ThemePreview.swatchCenter($0, in: size)) },
                                   chrome: sample(CGPoint(x: ThemePreview.chromeWidth - 3, y: size.height / 2)))
        }
        let image = pixels.image.flatMap { full in
            full.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(full.width), height: min(CGFloat(full.height), (lowest + 16) * scale)))
        }
        pane?.preferredContentSize = NSSize(width: 720, height: 640)
        window.setContentSize(NSSize(width: 720, height: 640))
        return (looks, image)
    }

    /// For each Mac appearance and each of `chosen`, every card that does not show what its theme will:
    /// "on a light Mac with Nord chosen, Whiskr: background #161618 ≠ #fdfdfc". Empty when all do.
    static func compare(themes: [Theme], chosen: [String], truth: [String: [Bool: (look: Look, image: CGImage)]],
                        shot: ((Bool, String, CGImage) -> Void)? = nil) async -> [String] {
        let store = ThemeStore.shared
        var problems: [String] = []
        for macDark in [false, true] {
            store.appearance = macDark ? .dark : .light
            for id in chosen {
                store.themeID = id
                await PerfWait.sleep(150)
                let (looks, image) = await settingsLooks(themes: themes)
                if let image { shot?(macDark, id, image) }
                let place = "on a \(macDark ? "dark" : "light") Mac with \(store.theme.name) chosen"
                for theme in themes {
                    guard let look = looks[theme.id] else { problems.append("\(place), \(theme.name): no card found"); continue }
                    guard let real = truth[theme.id]?[macDark]?.look else { problems.append("\(place), \(theme.name): the terminal drew nothing"); continue }
                    let differences = look.differences(from: real)
                    if !differences.isEmpty { problems.append("\(place), \(theme.name): \(differences.joined(separator: ", "))") }
                }
            }
        }
        return problems
    }

    /// A view behind each card in Settings, named by its theme, so a check can find where the card is.
    struct Anchor: NSViewRepresentable {
        static let prefix = "theme-card:"
        let id: String
        func makeNSView(context: Context) -> NSView {
            let view = NSView()
            view.identifier = NSUserInterfaceItemIdentifier(Self.prefix + id)
            return view
        }
        func updateNSView(_ view: NSView, context: Context) {
            view.identifier = NSUserInterfaceItemIdentifier(Self.prefix + id)
        }
    }

    // MARK: The sheets

    /// A few themes from files, as people add them: a VS Code theme whose text is too faint (brought to the
    /// guarantees), an extension with a light and a dark version, and an iTerm2 light scheme.
    static func importFixtures(into folder: URL) -> [Theme] {
        func write(_ path: String, _ text: String) -> URL {
            let url = folder.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
            return url
        }
        let faint = write("faint-color-theme.json", ##"{ "name": "Faint Night", "type": "dark", "colors": { "editor.background": "#20242c", "terminal.background": "#20242c", "terminal.foreground": "#3a404c", "terminal.ansiBlack": "#101318", "terminal.ansiWhite": "#c8ccd4", "terminal.ansiBrightBlack": "#5c6370", "terminal.ansiBrightWhite": "#ffffff" } }"##)
        _ = write("lantern/package.json", ##"{ "name": "lantern", "displayName": "Lantern Themes", "publisher": "example", "contributes": { "themes": [ { "label": "Paper Lantern", "uiTheme": "vs", "path": "./themes/paper.json" }, { "label": "Harbour Dusk", "uiTheme": "vs-dark", "path": "./themes/dusk.json" } ] } }"##)
        _ = write("lantern/themes/paper.json", ##"{ "type": "light", "colors": { "editor.background": "#ffffff", "terminal.background": "#ffffff", "terminal.foreground": "#24292f", "terminal.ansiWhite": "#6e7781", "terminal.ansiBlack": "#24292f" } }"##)
        _ = write("lantern/themes/dusk.json", ##"{ "type": "dark", "colors": { "editor.background": "#202430", "terminal.background": "#202430", "terminal.foreground": "#d0d4dc", "terminal.ansiWhite": "#d0d4dc", "terminal.ansiBlack": "#30343f" } }"##)
        var plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>"
        let colors: [(String, UInt32)] = [("Background Color", 0xfafaf8), ("Foreground Color", 0x2a2a2a), ("Cursor Color", 0x2a2a2a), ("Selection Color", 0xc8d8f0)]
            + [0x000000, 0xc91b00, 0x00a600, 0xa0a000, 0x0225c7, 0xc930c7, 0x00a5b2, 0xc7c7c7,
               0x686868, 0xff6e67, 0x5ffa68, 0xc0c000, 0x6871ff, 0xff77ff, 0x60fdff, 0xffffff].enumerated().map { ("Ansi \($0.offset) Color", UInt32($0.element)) }
        for (key, value) in colors {
            let component = { (shift: UInt32) in String(Double((value >> shift) & 0xff) / 255) }
            plist += "<key>\(key)</key><dict><key>Red Component</key><real>\(component(16))</real><key>Green Component</key><real>\(component(8))</real><key>Blue Component</key><real>\(component(0))</real></dict>"
        }
        plist += "</dict></plist>"
        let iterm = write("Paper Terminal.itermcolors", plist)
        let store = ThemeStore.shared
        return [faint, folder.appendingPathComponent("lantern"), iterm].flatMap { (try? store.importThemes(at: $0)) ?? [] }
    }

    /// `theme-sheets <folder>`.
    static func writeSheets(to folder: URL) async {
        let store = ThemeStore.shared
        let before = (id: store.themeID, appearance: store.appearance)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imported = importFixtures(into: folder.appendingPathComponent("fixtures", isDirectory: true))
        print("  imported \(imported.map(\.name))")
        let themes = store.themes
        let truth = await truth(themes: themes)
        var shots: [(String, CGImage)] = []
        let problems = await compare(themes: themes, chosen: [BuiltInThemes.defaultID, "nord"], truth: truth) { macDark, id, image in
            shots.append(("\(macDark ? "Dark" : "Light") Mac, \(ThemeStore.shared.themes.first { $0.id == id }?.name ?? id) chosen", image))
        }
        for problem in problems { print("  differs: \(problem)") }
        for problem in schemeProblems(themes: themes, truth: truth) { print("  terminal: \(problem)") }
        print("  \(problems.isEmpty ? "every preview shows what its theme will" : "\(problems.count) previews differ from their theme")")
        write(sheet(columns: shots.count, cells: shots), to: folder.appendingPathComponent("previews.png"))
        var cells: [(String, CGImage)] = []
        for theme in themes {
            for macDark in [false, true] {
                guard let found = truth[theme.id]?[macDark] else { continue }
                cells.append(("\(theme.name), \(macDark ? "dark" : "light") Mac\(theme.fixedDarkness != nil ? " (\(theme.fixedDarkness! ? "dark" : "light") only)" : "")", found.image))
            }
        }
        write(sheet(columns: 2, cells: cells), to: folder.appendingPathComponent("terminals.png"))
        store.themeID = before.id
        store.appearance = before.appearance
    }

    /// Images in a grid, each under its label, on a neutral grey.
    private static func sheet(columns: Int, cells: [(String, CGImage)]) -> CGImage? {
        guard !cells.isEmpty, columns > 0 else { return nil }
        let label: CGFloat = 36, gap: CGFloat = 24
        let width = cells.map { CGFloat($0.1.width) }.max()!, height = cells.map { CGFloat($0.1.height) }.max()!
        let rows = (cells.count + columns - 1) / columns
        let size = CGSize(width: gap + CGFloat(columns) * (width + gap), height: gap + CGFloat(rows) * (label + height + gap))
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        for (index, (title, image)) in cells.enumerated() {
            let x = gap + CGFloat(index % columns) * (width + gap)
            let top = size.height - gap - CGFloat(index / columns) * (label + height + gap)
            (title as NSString).draw(at: NSPoint(x: x, y: top - label + 8),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.white])
            context.draw(image, in: CGRect(x: x, y: top - label - CGFloat(image.height), width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return print("  could not draw \(url.lastPathComponent)") }
        try? data.write(to: url)
        print("  wrote \(url.path)")
    }
}

extension DebugScript {
    /// `--script` commands of the theme sheets; true when `command` was one of them.
    static func themeSheetCommand(_ command: String, _ argument: String, _ workbench: Workbench, _ controller: MainWindowController) -> Bool {
        guard command == "theme-sheets" else { return false }
        Task { await DebugThemeSheet.writeSheets(to: URL(fileURLWithPath: argument, isDirectory: true)) }
        return true
    }
}

extension PerfSuite {
    /// Every theme's preview in Settings › Terminal against what a terminal and the window show once that
    /// theme is chosen: on a light and on a dark Mac, with a theme of both versions chosen and with one that
    /// holds the app dark (Nord), every card's background, sixteen colours and chrome.
    func themePreviewsCheck() async {
        let store = ThemeStore.shared
        let before = (id: store.themeID, appearance: store.appearance)
        let themes = store.themes
        let truth = await DebugThemeSheet.truth(themes: themes)
        let problems = await DebugThemeSheet.compare(themes: themes, chosen: [BuiltInThemes.defaultID, "nord"], truth: truth)
        check("themes: every preview in Settings shows the colours its theme gives the terminal and the window once chosen, whichever theme is chosen, on a light and a dark Mac",
              problems.isEmpty, problems.isEmpty ? "\(themes.count) themes, 4 ways" : problems.prefix(6).joined(separator: "; "))
        let schemes = DebugThemeSheet.schemeProblems(themes: themes, truth: truth)
        check("themes: a terminal tells a program that asks whether it is light or dark what its theme's background is",
              schemes.isEmpty, schemes.isEmpty ? "\(themes.count) themes, light and dark" : schemes.prefix(6).joined(separator: "; "))
        SettingsWindowController.shared.window?.orderOut(nil)
        store.themeID = before.id
        store.appearance = before.appearance
        await PerfWait.sleep(200)
    }
}
#endif
