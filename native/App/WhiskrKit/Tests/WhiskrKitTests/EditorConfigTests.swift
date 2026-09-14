import Foundation
import Testing
@testable import WhiskrKit

@Suite("EditorConfig")
struct EditorConfigTests {
    @Test("the format: a root preamble, sections, pairs, comments on their own lines")
    func parsing() {
        let file = EditorConfig.File(parsing: """
        # top
        root = TRUE

        [*]
        indent_style = space
        ; a comment
        Indent_Size=2
        not a pair
        [*.{js,ts}]
        quote_type = single # stays in the value
        """)
        #expect(file.isRoot)
        #expect(file.sections.map(\.glob) == ["*", "*.{js,ts}"])
        #expect(file.sections[0].properties.map(\.name) == ["indent_style", "indent_size"])
        #expect(file.sections[0].properties.map(\.value) == ["space", "2"])
        #expect(file.sections[1].properties.first?.value == "single # stays in the value")
        #expect(!EditorConfig.File(parsing: "[*]\nroot = true").isRoot)
    }

    @Test("globs: *, **, ?, [seq], [!seq], {a,b}, nested braces, number ranges, escapes")
    func globs() {
        let cases: [(String, String, Bool)] = [
            ("*", "a.txt", true), ("*", "dir/a.txt", true),
            ("*.py", "x/y/z.py", true), ("*.py", "z.pyc", false),
            ("/*.py", "z.py", true), ("/*.py", "x/z.py", false),
            ("lib/*.js", "lib/a.js", true), ("lib/*.js", "lib/x/a.js", false), ("lib/*.js", "src/lib/a.js", false),
            ("lib/**.js", "lib/x/a.js", true), ("lib/**/a.js", "lib/a.js", true), ("lib/**/a.js", "lib/x/y/a.js", true),
            ("?.c", "a.c", true), ("?.c", "ab.c", false),
            ("[abc].c", "b.c", true), ("[abc].c", "d.c", false), ("[!abc].c", "d.c", true), ("[!abc].c", "a.c", false),
            ("[a-c].c", "b.c", true),
            ("*.{js,ts}", "a.ts", true), ("*.{js,ts}", "a.rs", false),
            ("{a,{b,c}}.md", "c.md", true), ("{single}.md", "{single}.md", true), ("{single}.md", "single.md", false),
            ("file{1..3}.txt", "file2.txt", true), ("file{1..3}.txt", "file4.txt", false), ("file{-2..2}.txt", "file-1.txt", true),
            ("\\*.txt", "*.txt", true), ("\\*.txt", "a.txt", false),
            ("Makefile", "sub/Makefile", true), ("[Mm]akefile", "makefile", true),
            ("{unclosed.txt", "{unclosed.txt", true), ("[unclosed.txt", "[unclosed.txt", true),
            ("a.txt", "A.TXT", false),
        ]
        for (glob, path, expected) in cases {
            #expect(EditorConfig.matches(glob, path: path) == expected, "\(glob) on \(path)")
        }
    }

    @Test("the nearest file wins, later sections win, `root` stops the search, `unset` takes a value back")
    func resolution() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("editorconfig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let deep = folder.appendingPathComponent("repo/src/deep")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try "[*]\nindent_style = tab\ncharset = latin1\n".write(to: folder.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8)
        try """
        root = true
        [*]
        indent_style = space
        indent_size = 4
        end_of_line = lf
        trim_trailing_whitespace = true
        [*.go]
        indent_style = tab
        [src/**]
        insert_final_newline = true
        """.write(to: folder.appendingPathComponent("repo/.editorconfig"), atomically: true, encoding: .utf8)
        try "[*.swift]\nindent_size = 2\nend_of_line = crlf\ntrim_trailing_whitespace = unset\n".write(to: folder.appendingPathComponent("repo/src/.editorconfig"), atomically: true, encoding: .utf8)

        let swift = EditorConfig.properties(forFileAt: deep.appendingPathComponent("a.swift").path)
        #expect(swift.indentStyle == .space)
        #expect(swift.indentSize == 2)
        #expect(swift.tabWidth == 2)
        #expect(swift.endOfLine == .crlf)
        #expect(swift.trimTrailingWhitespace == nil)
        #expect(swift.insertFinalNewline == true)
        // The root file stops the search: the outer file's charset does not reach.
        #expect(swift.charset == nil)

        let go = EditorConfig.properties(forFileAt: folder.appendingPathComponent("repo/main.go").path)
        #expect(go.indentStyle == .tab)
        #expect(go.indentSize == 4)
        #expect(go.insertFinalNewline == nil)
        #expect(go.trimTrailingWhitespace == true)

        let outside = EditorConfig.properties(forFileAt: folder.appendingPathComponent("other.txt").path)
        #expect(outside.indentStyle == .tab)
        #expect(outside.charset == .latin1)
        #expect(outside.indentSize == nil)
    }

    @Test("the sizes' rules: a tab style indents by a tab, `indent_size = tab` is the tab width")
    func sizes() {
        func properties(_ text: String) -> EditorConfig.Properties {
            EditorConfig.properties(forFileAt: "/p/a.c") { $0 == "/p/.editorconfig" ? "root = true\n[*]\n" + text : nil }
        }
        #expect(properties("indent_style = tab\ntab_width = 8").indentSize == 8)
        #expect(properties("indent_size = tab\ntab_width = 3").indentSize == 3)
        #expect(properties("indent_size = 2").tabWidth == 2)
        #expect(properties("indent_size = 2\ntab_width = 8").tabWidth == 8)
        #expect(properties("indent_size = 0").indentSize == nil)
        #expect(properties("charset = UTF-8-BOM").charset == .utf8WithBOM)
        #expect(properties("end_of_line = CR").endOfLine == .cr)
        #expect(properties("insert_final_newline = maybe").insertFinalNewline == nil)
    }

    @Test("the indentation a file is edited with: EditorConfig, then the file's own lines, then the settings")
    func indentation() {
        var properties = EditorConfig.Properties()
        let detected = Indentation(usesTabs: false, width: 2)
        let fallback = Indentation(usesTabs: false, width: 4)
        #expect(properties.indentation(detected: detected, fallback: fallback) == detected)
        #expect(properties.indentation(detected: nil, fallback: fallback) == fallback)
        properties.indentStyle = .tab
        properties.tabWidth = 8
        #expect(properties.indentation(detected: detected, fallback: fallback) == Indentation(usesTabs: true, width: 8))
        properties = EditorConfig.Properties()
        properties.indentSize = 3
        #expect(properties.indentation(detected: Indentation(usesTabs: true, width: 4), fallback: fallback) == Indentation(usesTabs: true, width: 3))
        #expect(properties.indentation(detected: detected, fallback: fallback) == Indentation(usesTabs: false, width: 3))
    }
}

@Suite("The key table")
struct KeyTableTests {
    @Test("chords read the same however a menu writes them")
    func chords() {
        #expect(KeyChord("⌘?") == KeyChord("⇧⌘/"))
        #expect(KeyChord("⌘+") == KeyChord("⇧⌘="))
        #expect(KeyChord("K", .command) == KeyChord("⇧⌘K"))
        #expect(KeyChord("⌘⇧K") == KeyChord("⇧⌘K"))
        #expect(KeyChord(menuKey: "\u{F700}", [.option]) == KeyChord("⌥↑"))
        #expect(KeyChord(menuKey: "\r", [.command, .shift]) == KeyChord("⇧⌘↩"))
        #expect(KeyChord(menuKey: "|", [.command]) == KeyChord("⇧⌘\\"))
        #expect(KeyChord("⇧⌘K").description == "⇧⌘K")
        #expect(KeyChord("⌥↑").description == "⌥↑")
    }

    @Test("no key does two things where the keyboard is")
    func noCollisions() {
        let collisions = KeyTable.collisions()
        #expect(collisions.isEmpty, "\(collisions.map(\.description).joined(separator: "\n"))")
    }

    @Test("menu keys without ⌘ are only ⌃Tab's; the editor's own keys without ⌘ are scoped to it")
    func terminalKeepsItsKeys() {
        let unscoped = KeyTable.menu.filter { ($0.context == .menu || $0.context == .menuInTerminal) && KeyTable.isTerminals($0.chord) }
        #expect(Set(unscoped.map(\.chord)) == KeyTable.terminalExceptions)
        for chord in ["⌥↑", "⌥↓", "⇧⌥↑", "⇧⌥↓", "⌥Z", "⌃G"] {
            #expect(KeyTable.menu.first { $0.chord == KeyChord(chord) }?.context == .menuInEditor, "\(chord)")
        }
        // The text editing keys the editor takes over are written down as such, and nothing else is.
        let replaced = Set(KeyTable.textEditing.filter { $0.replaces != nil }.map(\.chord))
        let scoped = Set(KeyTable.menu.filter { $0.context == .menuInEditor }.map(\.chord))
        #expect(replaced.isSubset(of: scoped))
    }

    @Test("the rules catch a menu key taken from the terminal, a shared key and an unwritten replacement")
    func catches() {
        let table = [
            KeyBinding("⌥X", "something:", .menu),
            KeyBinding("⌘K", "clear:", .menu),
            KeyBinding("⌘K", "other:", .menuInEditor),
            KeyBinding("⌃A", "lineStart:", .menuInEditor),
            KeyBinding("⌃A", "moveToBeginningOfParagraph:", .textEditing),
            KeyBinding("⌘↑", "previous:", .menuInTerminal),
            KeyBinding("⌘↑", "moveToBeginningOfDocument:", .textEditing),
            KeyBinding("⌘Space", "mine:", .menu),
            KeyBinding("⌘Space", "Spotlight", .system),
        ]
        let found = KeyTable.collisions(in: table).map(\.description)
        #expect(found.count == 4, "\(found)")
        #expect(found.contains { $0.hasPrefix("⌥X") })
        #expect(found.contains { $0.hasPrefix("⌘K") })
        #expect(found.contains { $0.hasPrefix("⌃A") })
        #expect(found.contains { $0.hasPrefix("⌘SPACE") || $0.hasPrefix("⌘Space") })
    }
}
