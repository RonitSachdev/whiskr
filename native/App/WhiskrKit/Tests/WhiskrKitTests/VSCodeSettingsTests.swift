import Foundation
import Testing
@testable import WhiskrKit

/// Settings › General › Import Settings: reading VS Code's and Cursor's `settings.json` and finding an
/// installed theme, all inside a home folder of the test's own.
@Suite("Settings from VS Code and Cursor")
struct VSCodeSettingsTests {
    @Test("the settings that mean the same thing here are read; the rest are left alone")
    func mapping() throws {
        let text = """
        {
          // Comments and trailing commas, as VS Code writes it.
          "editor.fontFamily": "'JetBrains Mono', \\"Fira Code\\", Menlo, monospace",
          "editor.fontSize": 14,
          "editor.tabSize": 2,
          "editor.insertSpaces": true,
          "editor.wordWrap": "bounded",
          "editor.renderWhitespace": "selection",
          "files.trimTrailingWhitespace": true,
          "files.insertFinalNewline": false,
          "terminal.integrated.fontFamily": "MesloLGS NF",
          "terminal.integrated.fontSize": 12.5,
          "terminal.integrated.cursorStyle": "line",
          "terminal.integrated.cursorBlinking": true,
          "workbench.colorTheme": "Monokai Pro",
          "workbench.preferredLightColorTheme": "Light Modern",
          "editor.minimap.enabled": false,
          "[python]": { "editor.tabSize": 4 },
        }
        """
        let settings = try OtherEditorSettings(settingsJSON: Data(text.utf8))
        #expect(settings.editorFonts == ["JetBrains Mono", "Fira Code", "Menlo"])
        #expect(settings.editorFontSize == 14)
        #expect(settings.tabSize == 2)
        #expect(settings.insertSpaces == true)
        #expect(settings.wordWrap == true)
        #expect(settings.renderWhitespace == nil)
        #expect(settings.unmapped == ["editor.renderWhitespace “selection”"])
        #expect(settings.trimTrailingWhitespace == true)
        #expect(settings.insertFinalNewline == false)
        #expect(settings.terminalFonts == ["MesloLGS NF"])
        #expect(settings.terminalFontSize == 12.5)
        #expect(settings.cursorStyle == "bar")
        #expect(settings.cursorBlinks == true)
        #expect(settings.colorTheme == "Monokai Pro")
        #expect(settings.preferredLightTheme == "Light Modern")
        #expect(settings.preferredDarkTheme == nil)

        let sparse = try OtherEditorSettings(settingsJSON: Data(##"{ "editor.wordWrap": "off", "editor.renderWhitespace": "all" }"##.utf8))
        #expect(sparse.wordWrap == false)
        #expect(sparse.renderWhitespace == true)
        #expect(sparse.editorFonts.isEmpty && sparse.tabSize == nil && sparse.colorTheme == nil)
        #expect(throws: ThemeImportError.self) { try OtherEditorSettings(settingsJSON: Data("not json".utf8)) }
    }

    @Test("sizes that are not finite numbers are no sizes, and never trap")
    func strangeNumbers() throws {
        let settings = try OtherEditorSettings(settingsJSON: Data(##"{ "editor.tabSize": 1e300, "editor.fontSize": "nan", "terminal.integrated.fontSize": "inf" }"##.utf8))
        #expect(settings.tabSize == nil && settings.editorFontSize == nil && settings.terminalFontSize == nil)
        #expect(try OtherEditorSettings(settingsJSON: Data(##"{ "editor.tabSize": "-inf" }"##.utf8)).tabSize == nil)
        #expect(try OtherEditorSettings(settingsJSON: Data(##"{ "editor.tabSize": 2.0 }"##.utf8)).tabSize == 2)
    }

    @Test("a CSS font list gives its families in order, and the first installed one is chosen")
    func fonts() {
        #expect(OtherEditorSettings.fontFamilies("Menlo, Monaco, 'Courier New', monospace") == ["Menlo", "Monaco", "Courier New"])
        #expect(OtherEditorSettings.fontFamilies("ui-monospace") == [])
        #expect(OtherEditorSettings.firstAvailable(["Fira Code", "menlo"], in: ["Courier", "Menlo"]) == "Menlo")
        #expect(OtherEditorSettings.firstAvailable(["Fira Code"], in: ["Menlo"]) == nil)
    }

    @Test("the standard places, under whatever home folder is given")
    func places() {
        let home = URL(fileURLWithPath: "/scratch/home", isDirectory: true)
        #expect(OtherEditor.vsCode.settingsFile(home: home).path == "/scratch/home/Library/Application Support/Code/User/settings.json")
        #expect(OtherEditor.cursor.settingsFile(home: home).path == "/scratch/home/Library/Application Support/Cursor/User/settings.json")
        #expect(OtherEditor.vsCode.extensionsFolder(home: home).path == "/scratch/home/.vscode/extensions")
        #expect(OtherEditor.cursor.extensionsFolder(home: home).path == "/scratch/home/.cursor/extensions")
    }

    @Test("the installed extension with a theme of that id or label is found, its newest version first")
    func installedTheme() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-other-editor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let extensions = OtherEditor.vsCode.extensionsFolder(home: home)
        func install(_ folder: String, label: String, id: String) throws {
            let root = extensions.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("themes"), withIntermediateDirectories: true)
            let manifest = ##"{ "name": "pro", "publisher": "someone", "contributes": { "themes": [ { "id": "\##(id)", "label": "\##(label)", "uiTheme": "vs-dark", "path": "./themes/pro.json" } ] } }"##
            try Data(manifest.utf8).write(to: root.appendingPathComponent("package.json"))
            try Data(##"{ "colors": { "editor.background": "#222222" } }"##.utf8).write(to: root.appendingPathComponent("themes/pro.json"))
        }
        try install("someone.pro-1.2.0", label: "Monokai Pro", id: "monokai-pro")
        try install("someone.pro-1.10.0", label: "Monokai Pro", id: "monokai-pro")
        try install("other.thing-0.1.0", label: "Other", id: "other")
        let found = try #require(ExtensionManifest.installed(theme: "Monokai Pro", in: extensions))
        #expect(found.extension.folder.lastPathComponent == "someone.pro-1.10.0")
        #expect(found.theme.id == "monokai-pro")
        #expect(ExtensionManifest.installed(theme: "monokai-pro", in: extensions)?.theme.label == "Monokai Pro")
        #expect(ExtensionManifest.installed(theme: "Missing", in: extensions)?.theme == nil)
        #expect(ExtensionManifest.installed(theme: "Monokai Pro", in: home.appendingPathComponent("nowhere"))?.theme == nil)
    }
}
