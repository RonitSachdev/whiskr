import Foundation
import Testing
@testable import WhiskrKit

@Suite("Themes")
struct ThemingTests {
    @Test("colours read and write as #rrggbb")
    func hex() throws {
        #expect(RGBColor(hex: "#d4433a")?.hex == "#d4433a")
        #expect(RGBColor(hex: "D4433A")?.hex == "#d4433a")
        #expect(RGBColor(hex: "#fff")?.hex == "#ffffff")
        #expect(RGBColor(hex: "#12345") == nil)
        #expect(RGBColor(hex: "red") == nil)
        #expect(RGBColor.black.contrast(with: .white) > 20.9)
        #expect(abs(RGBColor(0x777777).contrast(with: .white) - 4.48) < 0.01)
    }

    @Test("every built-in theme survives a round trip through its file")
    func builtInRoundTrip() throws {
        for theme in BuiltInThemes.all {
            var back = try Theme.read(try theme.fileData())
            back.isBuiltIn = true
            #expect(back == theme, "\(theme.name)")
        }
    }

    @Test("a user theme with edited app colours keeps exactly those edits")
    func editedRoundTrip() throws {
        var theme = BuiltInThemes.theme(id: "nord")!
        theme.id = "my-nord"
        theme.name = "My Nord"
        theme.isBuiltIn = false
        theme.dark!.app[.accent] = RGBColor(0xff8800)
        theme.dark!.terminal.ansi[2] = RGBColor(0x00ff00)
        let data = try theme.fileData()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"accent\" : \"#ff8800\""))
        #expect(!text.contains("\"surface\""))
        #expect(try Theme.read(data) == theme)
    }

    @Test("a short hand-written file fills in the rest, and its id comes from its name")
    func shortFile() throws {
        let file = """
        { "name": "Rosé Paper",
          "light": { "terminal": { "background": "#fafafa", "foreground": "#222222",
            "ansi": ["#000000","#aa0000","#00aa00","#aa5500","#0000aa","#aa00aa","#00aaaa","#aaaaaa",
                     "#555555","#ff5555","#55ff55","#ffff55","#5555ff","#ff55ff","#55ffff","#ffffff"] },
            "app": { "accent": "#ff0066", "sparkle": "#123456" } } }
        """
        let theme = try Theme.read(Data(file.utf8))
        #expect(theme.id == "rose-paper")
        #expect(theme.dark == nil)
        #expect(theme.fixedDarkness == false)
        #expect(theme.variant(dark: true) == theme.light)
        let variant = try #require(theme.light)
        #expect(variant.app[.accent].hex == "#ff0066")
        #expect(variant.app[.needsYou].hex == "#aa0000")
        #expect(variant.terminal.cursor.hex == "#222222")
    }

    @Test("files that are not themes are refused with a reason")
    func refused() {
        let ansi = "[\(Array(repeating: "\"#000000\"", count: 15).joined(separator: ","))]"
        let cases = [
            ##"{ "name": "No variants" }"##,
            ##"{ "format": "something-else", "name": "x", "dark": {} }"##,
            ##"{ "name": "Bad colour", "dark": { "terminal": { "background": "black", "foreground": "#fff", "ansi": [] } } }"##,
            "{ \"name\": \"Short\", \"dark\": { \"terminal\": { \"background\": \"#000\", \"foreground\": \"#fff\", \"ansi\": \(ansi) } } }",
            ##"{ "version": 99, "name": "Future", "dark": {} }"##,
        ]
        for text in cases {
            #expect(throws: DecodingError.self, "\(text)") { try Theme.read(Data(text.utf8)) }
        }
    }

    @Test("an iTerm2 colour file imports as one variant, dark or light by its background")
    func iTerm() throws {
        func entry(_ hex: UInt32) -> [String: Any] {
            let c = RGBColor(hex)
            return ["Red Component": c.red, "Green Component": c.green, "Blue Component": c.blue, "Color Space": "sRGB"]
        }
        var plist: [String: Any] = ["Background Color": entry(0x101010), "Foreground Color": entry(0xe0e0e0), "Cursor Color": entry(0xff0000)]
        for index in 0..<16 { plist["Ansi \(index) Color"] = entry(0x111111 * UInt32(index % 15 + 1)) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let theme = try ThemeImport.iTermColors(data, name: "Night Owl")
        #expect(theme.id == "night-owl")
        #expect(theme.light == nil)
        let dark = try #require(theme.dark)
        #expect(dark.terminal.background.hex == "#101010")
        #expect(dark.terminal.cursor.hex == "#ff0000")
        #expect(dark.terminal.ansi[3].hex == "#444444")

        plist["Ansi 7 Color"] = nil
        let broken = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        #expect(throws: ThemeImportError.self) { try ThemeImport.iTermColors(broken, name: "x") }
        #expect(throws: ThemeImportError.self) { try ThemeImport.iTermColors(Data("nope".utf8), name: "x") }
    }

    @Test("importing a file picks the reader by extension")
    func importFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-themes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ours = folder.appendingPathComponent("Paper.whiskrtheme")
        try BuiltInThemes.theme(id: "gruvbox")!.fileData().write(to: ours)
        #expect(try ThemeImport.file(at: ours).name == "Gruvbox")
        let junk = folder.appendingPathComponent("Junk.whiskrtheme")
        try Data("{}".utf8).write(to: junk)
        #expect(throws: ThemeImportError.self) { try ThemeImport.file(at: junk) }
    }

    @Test("every built-in theme reads well in each of its variants")
    func builtInsAreReadable() {
        for theme in BuiltInThemes.all {
            for variant in [theme.light, theme.dark].compactMap({ $0 }) {
                #expect(variant.readabilityWarnings.isEmpty, "\(theme.name) \(variant.isDark ? "dark" : "light"): \(variant.readabilityWarnings.map(\.message))")
            }
        }
    }

    @Test("Graphite: dark only, neutral greys with no colour cast, every guarantee met as it is")
    func graphite() throws {
        let theme = try #require(BuiltInThemes.theme(id: "graphite"))
        #expect(theme.fixedDarkness == true)
        #expect(BuiltInThemes.defaultID == "whiskr")
        let dark = try #require(theme.dark)
        #expect(dark.guaranteeFailures.isEmpty, "\(dark.guaranteeFailures)")
        #expect(dark.meetingGuarantees().repairs.isEmpty, "\(dark.meetingGuarantees().repairs)")
        let greys = [dark.terminal.background, dark.terminal.foreground] + [AppColorKey.surface, .chrome, .line, .lineStrong, .text, .textSecondary, .textTertiary, .well].map { dark.app[$0] }
        for grey in greys { #expect(grey.red == grey.green && grey.green == grey.blue, "\(grey.hex) has a colour cast") }
        // Near black: the content darker than #1c1c1c, the bars darker still.
        #expect(dark.terminal.background.luminance < RGBColor(0x1c1c1c).luminance)
        // Every colour but black reads on the content (bright black too: hints and autosuggestions).
        for (index, color) in dark.terminal.ansi.enumerated() where index != 0 {
            #expect(color.contrast(with: dark.terminal.background) >= 3, "colour \(index) \(color.hex)")
        }
    }

    @Test("the line between panes reads on the content in every built-in theme, as the theme gives it")
    func paneDivider() {
        for theme in BuiltInThemes.all {
            for variant in [theme.light, theme.dark].compactMap({ $0 }) {
                let name = "\(theme.name) \(variant.isDark ? "dark" : "light")"
                let divider = variant.paneDivider(increasedContrast: false)
                #expect(divider.contrast(with: variant.terminal.background) >= ThemeVariant.paneDividerContrast, "\(name)")
                // A built-in theme's own strong separator already does: nothing is moved.
                #expect(divider == variant.app[.lineStrong], "\(name)")
                #expect(variant.paneDivider(increasedContrast: true).contrast(with: variant.terminal.background) >= 2.5, "\(name), Increase Contrast")
            }
        }
        // An imported theme whose strong separator is the content's own colour gets one that reads.
        var faint = ThemeVariant(terminal: TerminalColors(background: RGBColor(0x202020), foreground: RGBColor(0xdddddd), cursor: nil, selection: nil, ansi: Array(repeating: RGBColor(0x888888), count: 16)))
        faint.app[.lineStrong] = RGBColor(0x222222)
        #expect(faint.paneDivider(increasedContrast: false).contrast(with: RGBColor(0x202020)) >= ThemeVariant.paneDividerContrast)
    }

    @Test("every built-in theme tells its layers apart: chrome a step below the content, a line visible on both")
    func builtInLayers() {
        for theme in BuiltInThemes.all {
            for variant in [theme.light, theme.dark].compactMap({ $0 }) {
                let name = "\(theme.name) \(variant.isDark ? "dark" : "light")"
                let content = variant.terminal.background, chrome = variant.app[.chrome], line = variant.app[.line]
                // A step you see at a glance, never a second, louder colour.
                #expect((1.03...1.25).contains(chrome.contrast(with: content)), "\(name): chrome against content \(chrome.contrast(with: content))")
                // Below the content: darker in both appearances.
                #expect(chrome.luminance < content.luminance, "\(name): chrome is not below the content")
                // Lines at the strong end of what editors use (VS Code's are 1.25:1): the regions must read apart.
                #expect(line.contrast(with: chrome) >= 1.3, "\(name): line on the chrome \(line.contrast(with: chrome))")
                #expect(line.contrast(with: content) >= 1.3, "\(name): line on the content \(line.contrast(with: content))")
                // The focus line (the accent) must stand out on the content and the chrome (WCAG 1.4.11).
                #expect(variant.app[.accent].contrast(with: content) >= 3, "\(name): accent on the content")
            }
        }
    }

    @Test("an older theme file without a chrome colour gets one worked out")
    func chromeDerived() throws {
        let theme = BuiltInThemes.theme(id: "nord")!
        let back = try Theme.read(try theme.fileData())
        #expect(back.dark?.app[.chrome] == AppColors.derived(from: theme.dark!.terminal)[.chrome])
        #expect(!String(decoding: try theme.fileData(), as: UTF8.self).contains("chrome"))
    }

    @Test("a file from when themes had sidebar, hover and pressed colours still opens, keeps its other colours, and drops those when saved again")
    func retiredColours() throws {
        let file = """
        { "format": "whiskr-theme", "version": 1, "name": "Older",
          "dark": { "terminal": { "background": "#101010", "foreground": "#e0e0e0",
            "ansi": ["#000000","#aa0000","#00aa00","#aa5500","#0000aa","#aa00aa","#00aaaa","#aaaaaa",
                     "#555555","#ff5555","#55ff55","#ffff55","#5555ff","#ff55ff","#55ffff","#ffffff"] },
            "app": { "sidebar": "#202020", "hover": "#303030", "press": "#404040", "accent": "#ff8800" } } }
        """
        let theme = try Theme.read(Data(file.utf8))
        let dark = try #require(theme.dark)
        #expect(dark.app[.accent].hex == "#ff8800")
        #expect(dark.app.values.count == AppColorKey.allCases.count)
        let saved = String(decoding: try theme.fileData(), as: UTF8.self)
        for retired in ["sidebar", "hover", "press"] { #expect(!saved.contains("\"\(retired)\"")) }
        #expect(try Theme.read(try theme.fileData()).dark?.app[.accent].hex == "#ff8800")
        #expect(!AppColorKey.allCases.map(\.rawValue).contains { ["sidebar", "hover", "press"].contains($0) })
    }

    @Test("a hard-to-read pair is warned about")
    func warning() {
        var variant = BuiltInThemes.theme(id: BuiltInThemes.defaultID)!.light!
        variant.app[.text] = RGBColor(0xdddddd)
        #expect(variant.readabilityWarnings.map(\.what).contains("Text on the surface"))
    }

    @Test("a theme file's origin cannot name a folder outside Originals, and an imported file keeps none")
    func originFolderStaysInside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-origins-\(UUID().uuidString)")
        let originals = folder.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func origin(folder: String, file: String = "themes/x.json") throws -> ThemeOrigin {
            let json = #"{"name": "x", "folder": \#(String(data: try JSONEncoder().encode(folder), encoding: .utf8)!), "file": \#(String(data: try JSONEncoder().encode(file), encoding: .utf8)!)}"#
            return try JSONDecoder().decode(ThemeOrigin.self, from: Data(json.utf8))
        }
        for hostile in ["../../../../../Documents", "..", ".", "", "a/b", "/Users", "a:b"] {
            let read = try origin(folder: hostile)
            #expect(read.folder == nil, "\(hostile)")
            #expect(read.originalsFolder(in: originals) == nil, "\(hostile)")
        }
        let plain = try origin(folder: "dracula-theme")
        #expect(plain.originalsFolder(in: originals)?.lastPathComponent == "dracula-theme")
        #expect(plain.originalsFolder(in: originals)?.deletingLastPathComponent().path == originals.standardizedFileURL.path)
        #expect(plain.file == "themes/x.json")
        #expect(try origin(folder: "x", file: "../../etc/passwd").file == nil)
        #expect(try origin(folder: "x", file: "/etc/passwd").file == nil)
        // Made directly (not read), a bad name still finds no folder.
        #expect(ThemeOrigin(name: "x", folder: "../x").originalsFolder(in: originals) == nil)

        // A theme file brought in keeps the names, not the folder: its originals did not come with it.
        var theme = BuiltInThemes.theme(id: "gruvbox")!
        theme.dark?.origin = ThemeOrigin(name: "Gruvbox Dark", folder: "someone-elses", file: "t.json", uiTheme: "vs-dark")
        let file = folder.appendingPathComponent("Shared.whiskrtheme")
        try theme.fileData().write(to: file)
        let imported = try ThemeImport.file(at: file)
        #expect(imported.dark?.origin == ThemeOrigin(name: "Gruvbox Dark", uiTheme: "vs-dark"))
    }

    @Test("a theme's id is its slug, numbered when another's comes to the same file name")
    func uniqueIDs() {
        #expect(Theme.uniqueID(for: "Nord Dark", taken: ["nord-dark"]) == "nord-dark-2")
        #expect(Theme.uniqueID(for: "nord-dark", taken: ["Nord Dark", "nord-dark-2"]) == "nord-dark-3")
        #expect(Theme.uniqueID(for: "Paper", taken: ["nord"]) == "paper")
        #expect(Theme.uniqueID(for: "../x", taken: []) == "x")
    }
}
