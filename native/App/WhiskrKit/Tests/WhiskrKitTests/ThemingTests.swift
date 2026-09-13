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

    @Test("a hard-to-read pair is warned about")
    func warning() {
        var variant = BuiltInThemes.theme(id: BuiltInThemes.defaultID)!.light!
        variant.app[.text] = RGBColor(0xdddddd)
        #expect(variant.readabilityWarnings.map(\.what).contains("Text on the surface"))
    }
}
