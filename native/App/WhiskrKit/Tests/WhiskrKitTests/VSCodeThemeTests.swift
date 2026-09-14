import Foundation
import Testing
@testable import WhiskrKit

/// VS Code colour themes: reading them (includes, `.tmTheme`s, colour forms), turning them into Whiskr's
/// variants, pairing light and dark, importing files, extension folders and `.vsix` files. The fixtures
/// are VS Code's own theme files (MIT), comments and white space removed (`Fixtures/Themes/ThirdParty`).
@Suite("VS Code themes")
struct VSCodeThemeTests {
    static let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Themes", isDirectory: true)

    static func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    static func read(_ name: String) throws -> VSCodeThemeDocument {
        try VSCodeThemeDocument.read(fixture(name), root: fixtures)
    }

    /// A folder of its own for one test, removed after.
    static func withFolder<T>(_ body: (URL) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-vscode-themes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        return try body(folder)
    }

    // MARK: Colours

    @Test("colours read in VS Code's four forms, and translucent ones are laid over their layer")
    func colourForms() {
        #expect(VSCodeColor("#abc") == VSCodeColor(rgb: RGBColor(0xaabbcc)))
        #expect(VSCodeColor("#aabbcc") == VSCodeColor(rgb: RGBColor(0xaabbcc)))
        #expect(VSCodeColor("#AABBCC") == VSCodeColor(rgb: RGBColor(0xaabbcc)))
        #expect(VSCodeColor("#abc8")?.alpha == Double(0x88) / 255)
        #expect(VSCodeColor("#ffffff17")?.alpha == Double(0x17) / 255)
        for bad in ["abc", "#12345", "#1234567", "red", "#ggg", ""] { #expect(VSCodeColor(bad) == nil, "\(bad)") }
        // Over its layer, rounded as a theme file writes it, the same every time.
        let line = VSCodeColor("#ffffff17")!.over(RGBColor(0x181818))
        #expect(line.hex == "#2d2d2d")
        #expect(VSCodeColor("#ffffff17")!.over(RGBColor(0x181818)) == line)
        #expect(VSCodeColor("#00000000")!.over(RGBColor(0x123456)).hex == "#123456")
        #expect(VSCodeColor("#0078d4")!.over(RGBColor(0x123456)).hex == "#0078d4")
    }

    // MARK: Reading

    @Test("an include chain is read parent first: Dark Modern includes Dark+, which includes Dark (Visual Studio)")
    func includeChain() throws {
        let document = try Self.read("dark_modern.json")
        #expect(document.files.map(\.lastPathComponent) == ["dark_modern.json", "dark_plus.json", "dark_vs.json"])
        #expect(document.name == "Dark Modern")
        // The including file's colours win; the included file's others remain.
        #expect(document.colors["editor.background"] == "#1F1F1F")
        #expect(document.colors["editorIndentGuide.background1"] == "#404040")
        // Rules come parent first: dark_vs's own first rule leads.
        let vs = try Self.read("dark_vs.json")
        #expect(document.rules.first == vs.rules.first)
        // Dark Modern adds no rules of its own: Dark (Visual Studio)'s, then Dark+'s.
        #expect(document.rules.count == (try Self.read("dark_plus.json")).rules.count)
        #expect(document.rules.count > vs.rules.count)
    }

    @Test("includes that loop, leave the theme's folder or are missing are refused with a reason")
    func badIncludes() throws {
        try Self.withFolder { folder in
            func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
            try write("a.json", ##"{ "include": "./b.json", "colors": {} }"##)
            try write("b.json", ##"{ "include": "./a.json" }"##)
            try write("out.json", ##"{ "include": "../elsewhere.json" }"##)
            try write("missing.json", ##"{ "include": "./nowhere.json" }"##)
            try write("broken.json", ##"{ "colors": "#fff" "##)
            for name in ["a.json", "out.json", "missing.json", "broken.json"] {
                #expect(throws: ThemeImportError.self, "\(name)") { try VSCodeThemeDocument.read(folder.appendingPathComponent(name), root: folder) }
            }
        }
    }

    @Test("JSON with comments and trailing commas, \"default\" taking back an included colour, semantic colours left out")
    func jsoncAndDefault() throws {
        try Self.withFolder { folder in
            try Data(##"{ "colors": { "editor.background": "#101010", "focusBorder": "#ff0000" }, "tokenColors": [{ "scope": "comment", "settings": { "foreground": "#808080" } }] }"##.utf8)
                .write(to: folder.appendingPathComponent("base.json"))
            let child = """
            {
              // A comment.
              "include": "./base.json",
              "type": "dark",
              "semanticHighlighting": true,
              "semanticTokenColors": { "variable.readonly": "#ff00ff" },
              "colors": { "focusBorder": "default", "editor.foreground": "#eeeeee", },
              "tokenColors": [
                { "name": "no scope", "settings": { "foreground": "#123456" } },
                { "scope": ["string", "constant.other.symbol"], "settings": { "foreground": "#00ff0080", "fontStyle": "italic" } },
              ],
            }
            """
            try Data(child.utf8).write(to: folder.appendingPathComponent("child.jsonc"))
            let document = try VSCodeThemeDocument.read(folder.appendingPathComponent("child.jsonc"), root: folder)
            #expect(document.type == "dark")
            #expect(document.colors["focusBorder"] == nil)
            #expect(document.colors["editor.background"] == "#101010")
            #expect(document.rules.map(\.scopes) == [["comment"], ["string", "constant.other.symbol"]])

            let variant = VSCodeThemeConversion(document, kind: .dark).variant
            // The default rule first (the editor's text on its background), then the theme's, translucent
            // colours laid over the background.
            #expect(variant.tokenColors.first == TokenColorRule(scopes: [], foreground: RGBColor(0xeeeeee), background: RGBColor(0x101010)))
            #expect(variant.tokenColors[2] == TokenColorRule(scopes: ["string", "constant.other.symbol"], foreground: RGBColor(0x088808), fontStyle: .italic))
            #expect(variant.tokenColors.count == 3)
        }
    }

    @Test("a TextMate .tmTheme reads, alone or as a theme's tokenColors, its scope-less settings setting editor colours")
    func textMate() throws {
        try Self.withFolder { folder in
            let plist: [String: Any] = ["name": "Tiny", "settings": [
                ["settings": ["background": "#202020", "foreground": "#e0e0e0", "caret": "#ff8800", "lineHighlight": "#ffffff10", "selection": "#335577"]],
                ["name": "Comment", "scope": "comment", "settings": ["foreground": "#7f7f7f", "fontStyle": "italic"]],
                ["scope": "keyword, storage", "settings": ["foreground": "#cc66ff"]],
            ]]
            let tmTheme = folder.appendingPathComponent("Tiny.tmTheme")
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: tmTheme)
            let alone = try VSCodeThemeDocument.read(tmTheme, root: folder)
            #expect(alone.name == "Tiny")
            #expect(alone.colors["editor.background"] == "#202020")
            #expect(alone.colors["editorCursor.foreground"] == "#ff8800")
            #expect(alone.rules.map(\.scopes) == [["comment"], ["keyword", "storage"]])
            let variant = VSCodeThemeConversion(alone, kind: VSCodeThemeConversion.kind(of: alone, declared: nil)).variant
            #expect(variant.isDark)
            #expect(variant.editor[.cursor].hex == "#ff8800")
            #expect(variant.editor[.lineHighlight].hex == "#2e2e2e")
            #expect(variant.editor[.selection].hex == "#335577")

            try Data(##"{ "name": "Wrapper", "colors": { "editor.background": "#303030" }, "tokenColors": "./Tiny.tmTheme" }"##.utf8)
                .write(to: folder.appendingPathComponent("wrapper.json"))
            let wrapped = try VSCodeThemeDocument.read(folder.appendingPathComponent("wrapper.json"), root: folder)
            #expect(wrapped.files.map(\.lastPathComponent) == ["wrapper.json", "Tiny.tmTheme"])
            #expect(wrapped.rules.count == 2)
            #expect(wrapped.name == "Wrapper")
        }
    }

    // MARK: Mapping

    @Test("Dark Modern maps key by key, and the terminal's sixteen take VS Code's dark defaults")
    func darkModernMapping() throws {
        let document = try Self.read("dark_modern.json")
        #expect(VSCodeThemeConversion.kind(of: document, declared: nil) == .dark)
        let conversion = VSCodeThemeConversion(document, kind: .dark)
        let v = conversion.variant
        // Content: editor.background; text: terminal.foreground.
        #expect(v.terminal.background.hex == "#1f1f1f")
        #expect(v.terminal.foreground.hex == "#cccccc")
        #expect(v.terminal.ansi.map(\.hex) == ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
                                               "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#e5e5e5"])
        // Chrome: titleBar.activeBackground; accent: tab.activeBorderTop; text strengths; "needs you" from errorForeground.
        #expect(v.app[.chrome].hex == "#181818")
        #expect(v.app[.accent].hex == "#0078d4")
        #expect(v.app[.text].hex == "#cccccc")
        #expect(v.app[.textSecondary].hex == "#9d9d9d")
        #expect(v.app[.needsYou].hex == "#f85149")
        // The line: tab.border, strengthened to 1.3:1 (the one repair Dark Modern needs).
        #expect(conversion.repairs == ["line #2b2b2b → #333333"])
        #expect(v.app[.line].hex == "#333333")
        // The editor's.
        #expect(v.editor[.lineNumber].hex == "#6e7681")
        #expect(v.editor[.lineNumberActive].hex == "#cccccc")
        #expect(v.editor[.indentGuide].hex == "#404040")
        #expect(v.editor[.indentGuideActive].hex == "#707070")
        #expect(v.editor[.selection].hex == "#264f78")
        #expect(v.editor[.cursor].hex == "#aeafad")
        #expect(v.editor[.wordHighlight] == VSCodeColor("#ADD6FF26")!.over(RGBColor(0x1f1f1f)))
        #expect(v.editor[.whitespace] == VSCodeColor("#e3e4e229")!.over(RGBColor(0x1f1f1f)))
        // Git: the git extension's dark defaults; diffs: VS Code's, over the content.
        #expect(v.editor[.gitAdded].hex == "#81b88b")
        #expect(v.editor[.gitModified].hex == "#e2c08d")
        #expect(v.editor[.gitDeleted].hex == "#c74e39")
        #expect(v.editor[.gitUntracked].hex == "#73c991")
        #expect(v.editor[.gitConflict].hex == "#e4676b")
        #expect(v.editor[.diffInserted] == VSCodeColor(rgb: RGBColor(0x9bb955), alpha: 0.2).over(RGBColor(0x1f1f1f)))
        #expect(v.editor[.diffRemovedText] == VSCodeColor("#ff000033")!.over(RGBColor(0x1f1f1f)))
        // Code: the default rule, then every scoped rule of the chain.
        #expect(v.tokenColors.first == TokenColorRule(scopes: [], foreground: RGBColor(0xcccccc), background: RGBColor(0x1f1f1f)))
        #expect(v.tokenColors.contains { $0.scopes.contains("comment") && $0.foreground?.hex == "#6a9955" })
        #expect(v.guaranteeFailures.isEmpty)
    }

    @Test("Light Modern and Monokai map their own chrome, accent, lines and cursor")
    func otherMappings() throws {
        let light = VSCodeThemeConversion(try Self.read("light_modern.json"), kind: .light).variant
        #expect(!light.isDark)
        #expect(light.terminal.background.hex == "#ffffff")
        #expect(light.terminal.foreground.hex == "#3b3b3b")
        #expect(light.app[.chrome].hex == "#f8f8f8")
        #expect(light.app[.accent].hex == "#005fb8")
        #expect(light.terminal.cursor.hex == "#005fb8")
        #expect(light.terminal.ansi[2].hex == "#107c10")
        #expect(light.editor[.gitModified].hex == "#895503")
        #expect(light.guaranteeFailures.isEmpty)

        let monokai = VSCodeThemeConversion(try Self.read("monokai-color-theme.json"), kind: .dark)
        let v = monokai.variant
        #expect(v.terminal.background.hex == "#272822")
        #expect(v.terminal.ansi[1].hex == "#c4265e")
        // titleBar.activeBackground is a step below; tab.inactiveBackground (lighter) is passed over.
        #expect(v.app[.chrome].hex == "#1e1f1c")
        // focusBorder, as Monokai has no tab.activeBorderTop.
        #expect(v.app[.accent].hex == "#99947c")
        #expect(v.editor[.lineHighlight].hex == "#3e3d32")
        #expect(v.editor[.selection] == VSCodeColor("#878b9180")!.over(RGBColor(0x272822)))
        #expect(v.terminal.cursor.hex == "#f8f8f0")
        // Its tab.border is its chrome's own colour: no line at all until strengthened.
        #expect(monokai.repairs == ["line #1e1f1c → #3a3b38"])
        #expect(v.guaranteeFailures.isEmpty)
    }

    @Test("a theme that falls short is moved only where it does, and then meets every guarantee")
    func repairs() throws {
        // Bars lighter than the content, a faint line, a dim accent, pale text, a pale error, and a git
        // colour that does not read: each moved, the rest kept.
        let file = """
        { "type": "dark", "colors": {
            "editor.background": "#202020", "editor.foreground": "#d0d0d0",
            "titleBar.activeBackground": "#3a3a3a", "sideBar.background": "#303030",
            "tab.border": "#232323", "focusBorder": "#303050", "foreground": "#d0d0d0",
            "tab.inactiveForeground": "#555555", "errorForeground": "#ffeaea",
            "gitDecoration.modifiedResourceForeground": "#404000",
            "terminal.ansiRed": "#e05050", "terminal.ansiBlue": "#5080e0"
        } }
        """
        let conversion = try Self.withFolder { folder in
            let url = folder.appendingPathComponent("rough.json")
            try Data(file.utf8).write(to: url)
            return VSCodeThemeConversion(try VSCodeThemeDocument.read(url, root: folder), kind: .dark)
        }
        let v = conversion.variant
        #expect(v.guaranteeFailures.isEmpty, "\(v.guaranteeFailures)")
        // Kept as the theme made them.
        #expect(v.terminal.background.hex == "#202020")
        #expect(v.terminal.foreground.hex == "#d0d0d0")
        #expect(v.app[.text].hex == "#d0d0d0")
        // Both bars are lighter than the content: the chrome is Whiskr's own step below it.
        #expect(v.app[.chrome] == AppColors.derived(from: v.terminal)[.chrome])
        let changed = conversion.repairs.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        #expect(changed == ["line", "textSecondary", "accent", "gitModified"])
        // A pale error tint is not taken for "needs you": the stronger of the terminal's two reds is.
        #expect(v.app[.needsYou].hex == "#f14c4c")
        // Each moved just far enough: one step back would fall short.
        #expect(v.app[.accent].contrast(with: v.terminal.background) < 3.15)
    }

    @Test("a high-contrast dark theme on black lifts its content one step so the bars can sit below it")
    func blackContent() throws {
        let document = try Self.withFolder { folder in
            let url = folder.appendingPathComponent("hc.json")
            try Data(##"{ "colors": { "editor.background": "#000000", "editor.foreground": "#ffffff" } }"##.utf8).write(to: url)
            return try VSCodeThemeDocument.read(url, root: folder)
        }
        let conversion = VSCodeThemeConversion(document, kind: .highContrastDark)
        #expect(conversion.variant.app[.chrome].hex == "#000000")
        #expect(conversion.repairs.first?.hasPrefix("content #000000 → ") == true)
        #expect(conversion.variant.guaranteeFailures.isEmpty)
        // VS Code's high-contrast defaults for what it leaves out.
        #expect(conversion.variant.terminal.ansi[4].hex == "#0000ee")
    }

    @Test("the kind of a theme: its extension's word, its own type, its background, its name")
    func kinds() {
        #expect(VSCodeThemeKind(uiTheme: "hc-light") == .highContrastLight)
        #expect(VSCodeThemeKind(uiTheme: "nope") == nil)
        #expect(VSCodeThemeKind(type: "hcLight") == .highContrastLight)
        #expect(VSCodeThemeKind(type: "hc") == .highContrastDark)
        var document = VSCodeThemeDocument()
        #expect(VSCodeThemeConversion.kind(of: document, declared: .light) == .light)
        #expect(VSCodeThemeConversion.kind(of: document, declared: nil) == .dark)
        document.name = "Quiet Light"
        #expect(VSCodeThemeConversion.kind(of: document, declared: nil) == .light)
        document.colors["editor.background"] = "#202020"
        #expect(VSCodeThemeConversion.kind(of: document, declared: nil) == .dark)
        document.type = "light"
        #expect(VSCodeThemeConversion.kind(of: document, declared: nil) == .light)
    }

    // MARK: Pairing

    @Test("light and dark versions of one theme are found by name, else as an extension's only two")
    func pairing() {
        #expect(ThemePairing.family("Dark Modern") == "Modern")
        #expect(ThemePairing.family("Light (Visual Studio)") == "Visual Studio")
        #expect(ThemePairing.family("GitHub Dark Default") == "GitHub Default")
        #expect(ThemePairing.family("Dark+") == "+")
        #expect(ThemePairing.family("Darkula") == "Darkula")

        let defaults: [(name: String, kind: VSCodeThemeKind)] = [
            ("Dark+", .dark), ("Dark Modern", .dark), ("Light+", .light), ("Light Modern", .light),
            ("Dark (Visual Studio)", .dark), ("Light (Visual Studio)", .light),
            ("Dark High Contrast", .highContrastDark), ("Light High Contrast", .highContrastLight), ("Dark 2026", .dark),
        ]
        let pairs = ThemePairing.pairs(defaults, extensionName: "Default Themes")
        #expect(pairs.map(\.name) == ["Light+ / Dark+", "Modern", "Visual Studio", "High Contrast"])
        #expect(pairs[1].light == 3 && pairs[1].dark == 1)

        // Tokyo Night: Night and Light pair by name; Storm stays alone.
        let tokyo = ThemePairing.pairs([("Tokyo Night", .dark), ("Tokyo Night Storm", .dark), ("Tokyo Night Light", .light)], extensionName: "Tokyo Night")
        #expect(tokyo.map(\.name) == ["Tokyo Night"])
        // Names that share nothing: the extension's only light and dark go together.
        let only = ThemePairing.pairs([("Latte", .light), ("Mocha", .dark)], extensionName: "Catppuccin")
        #expect(only.map(\.name) == ["Catppuccin"])
        // Three versions: none is guessed.
        #expect(ThemePairing.pairs([("Latte", .light), ("Frappé", .dark), ("Mocha", .dark)], extensionName: "Catppuccin").isEmpty)
        // A pair's name when made by hand.
        #expect(ThemePairing.name(light: "Catppuccin Latte", dark: "Catppuccin Mocha") == "Catppuccin")
        #expect(ThemePairing.name(light: "Paper", dark: "Ink") == "Paper / Ink")
    }

    @Test("pairing two themes gives one with both versions, and separating gives them back by name")
    func pairAndSeparate() throws {
        let night = BuiltInThemes.theme(id: "nord")!
        var paper = BuiltInThemes.theme(id: "gruvbox")!
        paper.name = "Gruvbox Light"
        paper.dark = nil
        let paired = ThemePairing.pair(light: paper, dark: night)
        #expect(paired.name == "Gruvbox Light / Nord")
        #expect(paired.light?.terminal == paper.light?.terminal)
        #expect(paired.dark?.terminal == night.dark?.terminal)
        #expect(paired.fixedDarkness == nil)
        let back = try Theme.read(try paired.fileData())
        #expect(back.light?.origin?.name == "Gruvbox Light")
        let parts = ThemePairing.separate(back)
        #expect(parts.map(\.name) == ["Gruvbox Light", "Nord"])
        #expect(parts.map(\.fixedDarkness) == [false, true])
        #expect(parts[1].dark?.terminal == night.dark?.terminal)
    }

    // MARK: Importing

    /// An extension folder like VS Code's own theme-defaults, with the six theme files it needs.
    static func makeExtension(in folder: URL) throws {
        let themes = folder.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        for name in ["dark_vs.json", "dark_plus.json", "dark_modern.json", "light_vs.json", "light_plus.json", "light_modern.json"] {
            try FileManager.default.copyItem(at: fixture(name), to: themes.appendingPathComponent(name))
        }
        let manifest = """
        { "name": "theme-defaults", "displayName": "%displayName%", "publisher": "vscode", "license": "MIT",
          "contributes": { "themes": [
            { "id": "Dark Modern", "label": "%darkModern%", "uiTheme": "vs-dark", "path": "./themes/dark_modern.json" },
            { "id": "Light Modern", "label": "%lightModern%", "uiTheme": "vs", "path": "./themes/light_modern.json" },
            { "id": "Dark+", "label": "Dark+", "uiTheme": "vs-dark", "path": "./themes/dark_plus.json" }
          ] } }
        """
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("package.json"))
        try Data(##"{ "displayName": "Default Themes", "darkModern": "Dark Modern", "lightModern": "Light Modern" }"##.utf8)
            .write(to: folder.appendingPathComponent("package.nls.json"))
    }

    static func checkDefaults(_ themes: [Theme], originals: URL) throws {
        #expect(themes.map(\.name) == ["Modern", "Dark+"])
        let modern = themes[0]
        #expect(modern.light?.terminal.background.hex == "#ffffff")
        #expect(modern.dark?.terminal.background.hex == "#1f1f1f")
        #expect(modern.credit == "From Default Themes (vscode.theme-defaults) · MIT licence")
        let origin = try #require(modern.dark?.origin)
        #expect(origin == ThemeOrigin(name: "Dark Modern", folder: "vscode-theme-defaults", file: "themes/dark_modern.json", uiTheme: "vs-dark"))
        // The originals: the manifest, its words, and every theme file read (the includes too).
        let kept = originals.appendingPathComponent("vscode-theme-defaults")
        let files = try FileManager.default.subpathsOfDirectory(atPath: kept.path).filter { $0.hasSuffix(".json") }.sorted()
        #expect(files == ["package.json", "package.nls.json", "themes/dark_modern.json", "themes/dark_plus.json", "themes/dark_vs.json",
                          "themes/light_modern.json", "themes/light_plus.json", "themes/light_vs.json"])
        // Read again from the copy, it converts the same.
        let again = VSCodeThemeConversion(try VSCodeThemeDocument.read(kept.appendingPathComponent(origin.file!), root: kept), kind: .dark, origin: origin)
        #expect(again.variant == modern.dark)
        for theme in themes {
            for variant in [theme.light, theme.dark].compactMap({ $0 }) { #expect(variant.guaranteeFailures.isEmpty) }
            #expect(try Theme.read(try theme.fileData()) == theme)
        }
    }

    @Test("an extension folder's themes import, light and dark paired, with their originals kept")
    func extensionFolder() throws {
        try Self.withFolder { folder in
            let source = folder.appendingPathComponent("theme-defaults", isDirectory: true)
            try Self.makeExtension(in: source)
            let originals = folder.appendingPathComponent("Originals", isDirectory: true)
            try Self.checkDefaults(try ThemeImport.themes(at: source, originals: originals), originals: originals)
            // Its package.json, chosen directly, is the same extension; its originals go to a folder of their own.
            let again = try ThemeImport.themes(at: source.appendingPathComponent("package.json"), originals: originals)
            #expect(again.first?.dark?.origin?.folder == "vscode-theme-defaults-2")
        }
    }

    @Test("a .vsix imports as its extension folder does, and nothing of it is left unpacked")
    func vsix() throws {
        try Self.withFolder { folder in
            let staging = folder.appendingPathComponent("staging", isDirectory: true)
            try Self.makeExtension(in: staging.appendingPathComponent("extension", isDirectory: true))
            let vsix = folder.appendingPathComponent("theme-defaults.vsix")
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zip.arguments = ["-c", "-k", staging.path, vsix.path]
            try zip.run()
            zip.waitUntilExit()
            #expect(zip.terminationStatus == 0)
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("whiskr-vsix-") })
            let originals = folder.appendingPathComponent("Originals", isDirectory: true)
            try Self.checkDefaults(try ThemeImport.themes(at: vsix, originals: originals), originals: originals)
            let after = Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { $0.hasPrefix("whiskr-vsix-") })
            #expect(after == before)

            try Data("not a zip".utf8).write(to: folder.appendingPathComponent("broken.vsix"))
            #expect(throws: ThemeImportError.self) { try ThemeImport.themes(at: folder.appendingPathComponent("broken.vsix"), originals: originals) }
        }
    }

    @Test("VS Code's Monokai, imported, has the built-in Monokai's colours, so it is that theme, not a second")
    func importOfABuiltIn() throws {
        try Self.withFolder { folder in
            let imported = try #require(try ThemeImport.themes(at: Self.fixture("monokai-color-theme.json"), originals: folder).first)
            let builtIn = try #require(BuiltInThemes.theme(id: "monokai"))
            #expect(imported.name == builtIn.name)
            #expect(imported.hasSameColors(as: builtIn))
            #expect(!imported.hasSameColors(as: try #require(BuiltInThemes.theme(id: "dracula"))))
        }
    }

    @Test("a lone theme file imports as one theme with its includes kept; other files go as before")
    func loneFile() throws {
        try Self.withFolder { folder in
            let originals = folder.appendingPathComponent("Originals", isDirectory: true)
            let monokai = try ThemeImport.themes(at: Self.fixture("monokai-color-theme.json"), originals: originals)
            #expect(monokai.map(\.name) == ["Monokai"])
            #expect(monokai.first?.fixedDarkness == true)
            #expect(try FileManager.default.contentsOfDirectory(atPath: originals.appendingPathComponent("monokai").path) == ["monokai-color-theme.json"])

            let modern = try ThemeImport.themes(at: Self.fixture("light_modern.json"), originals: originals)
            #expect(modern.map(\.name) == ["Light Modern"])
            #expect(modern.first?.light?.origin?.file == "light_modern.json")
            #expect(try FileManager.default.contentsOfDirectory(atPath: originals.appendingPathComponent("light-modern").path).sorted()
                    == ["light_modern.json", "light_plus.json", "light_vs.json"])

            // An extension without themes gives none; a folder that is not an extension is refused.
            let empty = folder.appendingPathComponent("grammar-only", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            try Data(##"{ "name": "x", "contributes": { "grammars": [] } }"##.utf8).write(to: empty.appendingPathComponent("package.json"))
            #expect(try ThemeImport.themes(at: empty, originals: originals).isEmpty)
            #expect(throws: ThemeImportError.self) { try ThemeImport.themes(at: originals, originals: originals) }
            #expect(throws: ThemeImportError.self) { try ThemeImport.themes(at: folder.appendingPathComponent("nothing.json"), originals: originals) }

            // Whiskr's own files still import as they are.
            let ours = folder.appendingPathComponent("Nord.whiskrtheme")
            try BuiltInThemes.theme(id: "nord")!.fileData().write(to: ours)
            #expect(try ThemeImport.themes(at: ours, originals: originals).map(\.name) == ["Nord"])
        }
    }

    // MARK: Built-ins

    @Test("every built-in theme meets every guarantee, the ones from VS Code with their code colours")
    func builtIns() {
        for theme in BuiltInThemes.all {
            for variant in [theme.light, theme.dark].compactMap({ $0 }) {
                #expect(variant.guaranteeFailures.isEmpty, "\(theme.name) \(variant.isDark ? "dark" : "light"): \(variant.guaranteeFailures)")
            }
        }
        for id in ["modern", "monokai", "solarized"] {
            let theme = BuiltInThemes.theme(id: id)
            #expect(theme?.isBuiltIn == true)
            #expect(theme.map { [$0.light, $0.dark].compactMap { $0 }.allSatisfy { $0.tokenColors.count > 30 } } == true, "\(id)")
        }
        #expect(BuiltInThemes.theme(id: "modern")?.fixedDarkness == nil)
        #expect(BuiltInThemes.theme(id: BuiltInThemes.defaultID)?.light?.tokenColors.isEmpty == true)
    }
}
