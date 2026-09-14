import CoreText
import Foundation
import Testing
@testable import WhiskrKit

@Suite("File icons, as VS Code's icon themes give them")
struct FileIconThemeTests {
    /// A small theme in the bundled data's shape.
    static let theme = try! FileIconTheme(data: Data("""
        {"file":"plain",
         "icons":{"plain":"e000","info":"e001","ts":"e002","test":"e003","git":"e004","react":"e005","config":"e006"},
         "fileNames":{"readme.md":"info","config.ts":"config"},
         "fileExtensions":{"ts":"ts","test.ts":"test","gitignore":"git","d.test.ts":"info"},
         "languageIds":{"typescriptreact":"react","typescript":"ts","ignore":"config"}}
        """.utf8))

    func icon(_ name: String, _ language: String? = nil) -> String {
        Self.theme.icon(forFileName: name, languageID: language).name
    }

    @Test("a whole name comes first, then extensions longest first, then the language, then the plain file")
    func precedence() {
        #expect(icon("config.ts", "typescript") == "config")
        #expect(icon("a.test.ts", "typescript") == "test")
        #expect(icon("a.d.test.ts") == "info")
        #expect(icon("index.ts", "typescriptreact") == "ts")
        #expect(icon("App.tsx", "typescriptreact") == "react")
        #expect(icon("App.tsx") == "plain")
        #expect(icon("notes", "plaintext") == "plain")
    }

    @Test("names compare lower-cased; a leading dot starts an extension")
    func names() {
        #expect(icon("README.md") == "info")
        #expect(icon("Index.TS") == "ts")
        #expect(icon(".gitignore", "ignore") == "git")
        #expect(icon("gitignore") == "plain")
        #expect(icon("x.") == "plain")
    }

    @Test("past 255 characters only the whole name and the language count, as in VS Code")
    func longNames() {
        let long = String(repeating: "a.", count: 130) + "ts"
        #expect(icon(long) == "plain")
        #expect(icon(long, "typescript") == "ts")
    }

    @Test("a theme naming an icon it does not define, or a character that is not one, does not load")
    func badThemes() {
        #expect(throws: FileIconTheme.LoadError.unknownIcon("gone")) {
            try FileIconTheme(data: Data(#"{"file":"a","icons":{"a":"e000"},"fileNames":{"x":"gone"},"fileExtensions":{},"languageIds":{}}"#.utf8))
        }
        #expect(throws: FileIconTheme.LoadError.badCharacter(icon: "a", "zz")) {
            try FileIconTheme(data: Data(#"{"file":"a","icons":{"a":"zz"},"fileNames":{},"fileExtensions":{},"languageIds":{}}"#.utf8))
        }
    }

    @Test("Seti's data: the icons VS Code shows for common files")
    func seti() {
        let seti = FileIconTheme.seti
        func icon(_ name: String, _ language: String? = nil) -> String { seti.icon(forFileName: name, languageID: language).name }
        #expect(icon("README.md", "markdown") == "info")
        #expect(icon("CHANGELOG.md", "markdown") == "clock")
        #expect(icon("notes.md", "markdown") == "markdown")
        #expect(icon("LICENSE") == "license")
        #expect(icon("yarn.lock") == "yarn")
        #expect(icon("tsconfig.json", "jsonc") == "tsconfig")
        #expect(icon("Package.swift", "swift") == "swift")
        #expect(icon("index.ts", "typescript") == "typescript")
        #expect(icon("index.test.ts", "typescript") == "typescript")
        #expect(icon("App.tsx", "typescriptreact") == "react")
        #expect(icon("main.py", "python") == "python")
        #expect(icon("Cargo.toml") == "config")
        #expect(icon("config.yaml", "yaml") == "yml")
        #expect(icon("settings.jsonc", "jsonc") == "json")
        #expect(icon("Dockerfile", "dockerfile") == "docker")
        #expect(icon(".gitignore", "ignore") == "git")
        #expect(icon("build.sh", "shellscript") == "shell")
        #expect(icon("logo.png") == "image")
        #expect(icon("lib.h") == "c")
        #expect(icon("data.bin") == "default")
        #expect(icon("notes.txt", "plaintext") == "default")
    }

    @Test("with the language the bundled languages find from the name, as the app asks")
    func setiWithDetectedLanguages() {
        func icon(_ name: String) -> String {
            FileIconTheme.seti.icon(forFileName: name, languageID: LanguageRegistry.shared.detect(fileName: name).id).name
        }
        #expect(icon("Package.swift") == "swift")
        #expect(icon("index.ts") == "typescript")
        #expect(icon("App.tsx") == "react")
        #expect(icon("main.py") == "python")
        #expect(icon("lib.rs") == "rust")
        #expect(icon("main.go") == "go2")
        #expect(icon("main.c") == "c")
        #expect(icon("style.css") == "css")
        #expect(icon("index.html") == "html")
        #expect(icon("package.json") == "json")
        #expect(icon("Dockerfile") == "docker")
        #expect(icon("Makefile") == "makefile")
        #expect(icon(".gitignore") == "git")
        #expect(icon("build.sh") == "shell")
        #expect(icon("notes.md") == "markdown")
        #expect(icon("notes.txt") == "default")
    }

    @Test("every Seti icon is a glyph in the bundled font")
    func setiGlyphs() throws {
        let data = try Data(contentsOf: FileIconTheme.setiFont)
        let descriptors = try #require(CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])
        let font = CTFontCreateWithFontDescriptor(try #require(descriptors.first), 16, nil)
        let icons = FileIconTheme.seti.icons.values
        #expect(icons.count > 100)
        for icon in icons {
            var characters = Array(String(icon.character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            #expect(CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count), "\(icon.name)")
        }
    }
}
