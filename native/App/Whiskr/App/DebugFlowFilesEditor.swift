#if DEBUG
import AppKit
import WhiskrKit

/// Markdown's preview, the editor's everyday conveniences, and the Files panel's own commands.
extension FilesFlow {
    /// A menu command as the menu sends it, after asking whether it is enabled; false when it was not.
    @discardableResult
    func command(_ action: Selector, tag: Int = 0) -> Bool {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.tag = tag
        guard let target = NSApp.target(forAction: action, to: nil, from: item) as AnyObject? ?? (controller.responds(to: action) ? controller : nil) else { return false }
        let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true
        guard enabled else { return false }
        NSApp.sendAction(action, to: target, from: item)
        return true
    }

    // MARK: 3. Markdown

    func markdown() async {
        guard let page = await open("README.md") else { return check("Markdown: README.md opens", false) }
        check("Markdown: opens as its preview (Settings' default)", page.mode == .preview && page.previewable, "mode \(page.mode)")
        await PerfWait.sleep(600)
        snapshot("markdown-preview")
        // ⌥⌘P and ⇧⌘V: preview and source, back and forth; the item's title says what it does.
        suite.shortcut("cmd+opt+p")
        let source = await PerfWait.until(1000) { page.mode == .source && page.editor != nil }
        suite.shortcut("cmd+shift+v")
        let preview = await PerfWait.until(1000) { page.mode == .preview }
        check("Markdown: ⌥⌘P shows the source, ⇧⌘V the preview again", source != nil && preview != nil, "mode \(page.mode)")
        // Side by side, then Show Preview: the preview, as the item says.
        command(#selector(MainWindowController.togglePreviewSideBySide(_:)))
        let side = await PerfWait.until(1000) { page.mode == .sideBySide && page.editor != nil }
        await PerfWait.sleep(500)
        snapshot("markdown-side-by-side")
        let item = NSMenuItem(title: "", action: #selector(MainWindowController.togglePreview(_:)), keyEquivalent: "")
        _ = controller.validateMenuItem(item)
        suite.shortcut("cmd+opt+p")
        _ = await PerfWait.until(1000) { page.mode != .sideBySide }
        check("Markdown: side by side, then “\(item.title)” (⌥⌘P) does what it says", side != nil && page.mode == (item.title == String(localized: "Show Preview") ? .preview : .source),
              "side by side \(side != nil), item “\(item.title)”, then \(page.mode)")
        // Code blocks are coloured in their fence's language; the picture beside it is found.
        var coloured: [String] = []
        for (fence, code) in [("swift", "let cat = \"black\""), ("ts", "const x: number = 1;"), ("python", "def f(): return 1")] {
            if let tokens = await SyntaxText.tokens(code, fence: fence) {
                let text = SyntaxText.attributed(tokens)
                if text.runs.contains(where: { $0.swiftUI.foregroundColor != nil }) { coloured.append(fence) }
            }
        }
        check("Markdown: code blocks are coloured in their language (swift, ts, python)", coloured == ["swift", "ts", "python"], "coloured \(coloured)")
        check("Markdown: a picture beside the file shows", ImageCache.shared.image("docs/logo.png", relativeTo: fixture.root) != nil)
        // A picture the Markdown names before it exists shows once it is made.
        let early = ImageCache.shared.image("docs/later.png", relativeTo: fixture.root)
        try? FilesFixture.png(color: .systemGreen).write(to: fixture.url("docs/later.png"))
        check("Markdown: a picture made after the preview first looked for it shows", early == nil && ImageCache.shared.image("docs/later.png", relativeTo: fixture.root) != nil)
        try? FileManager.default.removeItem(at: fixture.url("docs/later.png"))
        // A link to a file beside it opens that file in the editor.
        page.openLink(URL(string: "src/util.ts")!)
        let linked = await PerfWait.until(3000) { self.shown("src/util.ts") != nil }
        check("Markdown: a link to a file beside it opens that file", linked != nil, "page \(workbench.focusedPage.map { "\($0)" } ?? "none")")
        // Japanese and emoji, and a file of none of the editor's (a binary) and a picture.
        if let japanese = await open("notes/日本語.md") {
            if japanese.mode == .preview { suite.shortcut("cmd+opt+p") }
            _ = await PerfWait.until(1000) { japanese.editor != nil }
            check("Japanese and emoji: read and shown as written", text(japanese) == disk("notes/日本語.md") && japanese.document.format.encoding == .utf8,
                  "encoding \(japanese.document.format.encoding)")
            suite.shortcut("cmd+opt+p")
        }
        if let binary = await open("bin/blob.bin") {
            check("a binary file shows a calm page, not text", binary.document.content == .binary && binary.editor == nil, "content \(binary.document.content)")
        }
        if let picture = await open("docs/logo.png") {
            check("a picture shows as a picture", picture.document.content == .image)
        }
        snapshot("binary-and-picture")
    }

    // MARK: 7. The editor's everyday conveniences

    func editorBasics() async {
        guard let page = await open("src/util.ts"), let textView = page.editor?.textView else { return check("editor: src/util.ts opens", false) }
        let document = page.document
        await focusEditor(page)
        // Pairs: an opening closes itself, the closing is typed over, a selection is surrounded.
        let lastLine = document.lines.lineCount - 1
        textView.setSelectedRange(NSRange(location: document.lines.starts[max(0, lastLine - 1)], length: 0))
        let start = textView.selectedRange().location
        let after = (text(page) as NSString).substring(from: start)
        suite.typeKeys("call(")
        let closed = (text(page) as NSString).substring(from: start)
        let caretInside = textView.selectedRange().location == start + 5
        suite.typeKeys(")")
        let overtyped = (text(page) as NSString).substring(from: start)
        let caretAfter = textView.selectedRange().location == start + 6
        textView.setSelectedRange(NSRange(location: start, length: 4))
        suite.typeKeys("[")
        let surrounded = (text(page) as NSString).substring(from: start)
        check("editor: brackets close themselves, are typed over, surround a selection",
              closed == "call()" + after && caretInside && overtyped == "call()" + after && caretAfter && surrounded == "[call]()" + after,
              "“\(closed.prefix(8))” caret inside \(caretInside), then “\(overtyped.prefix(8))” caret after \(caretAfter), then “\(surrounded.prefix(10))”")
        suite.shortcut("cmd+z"); suite.shortcut("cmd+z"); suite.shortcut("cmd+z")
        _ = await PerfWait.until(1000) { !document.isEdited }
        if document.isEdited { document.revert(); _ = await PerfWait.until(2000) { !document.isEdited } }
        // Return keeps the indentation, one level more after an opening bracket.
        await PerfWait.sleep(300)
        let opening = (text(page) as NSString).range(of: "{").location
        textView.setSelectedRange(NSRange(location: opening + 1, length: 0))
        let line = document.lines.line(at: opening)
        let indent = String(document.lineText(line).prefix { $0 == " " })
        suite.typeKeys("\r")
        let next = document.lineText(line + 1)
        check("editor: Return after “{” indents one level more", next == indent + String(repeating: " ", count: document.indentation.width), "next line “\(next)” after “\(document.lineText(line))”, edited before \(document.isEdited)")
        document.undoManager.undo()
        _ = await PerfWait.until(1000) { !document.isEdited }
        // Indentation, encoding, line endings, language: what the status bar shows for the file.
        check("editor: indentation found from the file (TypeScript with 2 spaces)", !document.indentation.usesTabs && document.indentation.width == 2,
              "\(document.indentation)")
        if let python = await open("tools/build.py") {
            check("editor: Python's indentation found (4 spaces), its language detected", python.document.indentation.width == 4 && python.document.language.id == "python",
                  "\(python.document.indentation), \(python.document.language.id)")
            // The status bar's position follows the editor shown: going back to a tab shows its caret.
            await focusEditor(python)
            python.editor?.textView.show(line: 7, column: 5)
            await PerfWait.sleep(200)
            if let back = await open("src/util.ts") {
                await focusEditor(back)
                back.editor?.textView.show(line: 4, column: 3)
                await PerfWait.sleep(100)
                if let tab = tab(showing: "tools/build.py") { workbench.select(tab: tab) }
                _ = await PerfWait.until(2000) { self.shown("tools/build.py") != nil && self.window.firstResponder === python.editor?.textView }
                await PerfWait.sleep(200)
                let status = EditorStatus.shared
                check("status bar: switching tabs shows the caret of the file shown (Ln 7, Col 5)",
                      status.documentID == ObjectIdentifier(python.document) && status.line == 7 && status.column == 5,
                      "for this file \(status.documentID == ObjectIdentifier(python.document)), Ln \(status.line), Col \(status.column), keyboard in \(responderName)")
            }
        }
        if let windows = await open("windows.txt") {
            check("status bar: a Windows file says CRLF, UTF-8", windows.document.format.lineEnding == .crlf && windows.document.format.encoding == .utf8,
                  "\(windows.document.format.lineEnding), \(windows.document.format.encoding)")
            // The language menu: colour it as Python, then Auto Detect.
            let python = LanguageRegistry.shared.language(id: "python")
            windows.document.choose(language: python)
            let chosen = windows.document.language.id
            windows.document.choose(language: nil)
            check("status bar: the language menu colours a file as another language, Auto Detect goes back", chosen == "python" && windows.document.language.id != "python",
                  "chosen \(chosen), then \(windows.document.language.id)")
        }
        // Go to Line (⌘L) is offered in an editor.
        let goToLine = NSMenuItem(title: "", action: #selector(CodeTextView.goToLine(_:)), keyEquivalent: "")
        check("editor: Go to Line… (⌘L) is enabled in an editor", (window.firstResponder as? CodeTextView)?.validateUserInterfaceItem(goToLine) == true, "keyboard in \(responderName)")

        // Find in the editor (⌘F): the editor's own find bar, the match selected; Esc gives the keyboard back.
        if let index = await open("src/index.ts"), let editor = index.editor {
            await focusEditor(index)
            editor.textView.show(line: 1)
            suite.shortcut("cmd+f")
            let bar = await PerfWait.until(1500) { editor.scrollView.isFindBarVisible }
            let field = window.firstResponder
            suite.typeKeys("line77 ")
            await PerfWait.sleep(300)
            print("files: the editor's find field holds “\((window.firstResponder as? NSTextView)?.string ?? "-")”, the find text “\(NSPasteboard(name: .find).string(forType: .string) ?? "-")”")
            suite.typeKeys("\r")
            let found = await PerfWait.until(1500) {
                let range = editor.textView.selectedRange()
                return range.length > 0 && (self.text(index) as NSString).substring(with: range) == "line77 "
            }
            check("editor: ⌘F shows the find bar, typing and Return select the match", bar != nil && found != nil,
                  "bar \(bar != nil), keyboard in \(field.map { String(describing: type(of: $0)) } ?? "none"), selected “\((text(index) as NSString).substring(with: editor.textView.selectedRange()))”")
            press(Self.escape.0, code: Self.escape.1)
            let hidden = await PerfWait.until(1500) { !editor.scrollView.isFindBarVisible && self.window.firstResponder === editor.textView }
            check("editor: Esc closes the find bar, the keyboard back in the text", hidden != nil, "bar \(editor.scrollView.isFindBarVisible), keyboard in \(responderName)")
        }

        // A line too long to edit: read-only with a bar; Edit Anyway lets it be edited.
        if let long = await open("long/minified.js"), let textView = long.editor?.textView {
            await focusEditor(long)
            textView.setSelectedRange(NSRange(location: 100, length: 0))
            await PerfWait.sleep(200)
            let guarded = long.document.guardedLine != nil && bannerHeight(long) > 0 && !textView.isEditable
            textView.setSelectedRange(NSRange(location: (text(long) as NSString).length - 3, length: 0))
            await PerfWait.sleep(100)
            let restEditable = textView.isEditable
            check("editor: a line past 80,000 characters is read-only with a bar; the rest of the file edits", guarded && restEditable,
                  "guarded \(long.document.guardedLine.map { "line \($0.line + 1), \($0.length)" } ?? "none"), bar \(bannerHeight(long)), editable there \(textView.isEditable), elsewhere \(restEditable)")
            _ = pressBar(String(localized: "Edit Anyway", comment: "Editor bar: edit an over-long line although typing in it is slow"), in: long) { long.document.allowLongLineEdits() }
            textView.setSelectedRange(NSRange(location: 100, length: 0))
            let anyway = await PerfWait.until(1500) { long.document.guardedLine == nil && textView.isEditable && self.bannerHeight(long) == 0 }
            check("editor: Edit Anyway makes it editable, the bar goes", anyway != nil)
            workbench.close(page: workbench.focusedPageID ?? UUID())
        }
    }

    // MARK: 7. The Files panel

    func filesPanel() async {
        guard let tree = await fileTree() else { return check("Files: the tree shows", false) }
        // Compact folders: a chain of single folders is one row.
        var titles: [String: String] = [:]
        for (relative, expected) in [("Sources", "Sources/App"), ("deep", "deep/a/b/c"), ("app", "app/[id]")] {
            _ = await PerfWait.until(3000) { tree.repository.node(for: relative).map { FileCell.title(tree.chain($0)) == expected } ?? false }
            titles[relative] = tree.repository.node(for: relative).map { FileCell.title(tree.chain($0)) }
        }
        check("Files: a chain of single folders shows as one row (Sources/App, deep/a/b/c, app/[id])",
              titles["Sources"] == "Sources/App" && titles["deep"] == "deep/a/b/c" && titles["app"] == "app/[id]", "\(titles)")
        // Files follows the tab shown, without taking the keyboard.
        if let page = await open("src/index.ts") {
            await focusEditor(page)
            _ = await open("tools/build.py")
            if let tab = tab(showing: "src/index.ts") { workbench.select(tab: tab) }
            let followed = await PerfWait.until(3000) {
                let row = tree.outline.selectedRow
                return row >= 0 && (tree.outline.item(atRow: row) as? FileNode)?.relativePath == "src/index.ts"
            }
            check("Files: follows the tab shown, the keyboard stays in the editor", followed != nil && window.firstResponder is CodeTextView,
                  "selected \((tree.outline.item(atRow: tree.outline.selectedRow) as? FileNode)?.relativePath ?? "none"), keyboard in \(responderName)")
        }
        // New File (⌥⌘N): named in place, then opened.
        let count = tabCount
        if let row = await treeRow("src/util.ts", in: tree) { tree.outline.selectRowIndexes([row], byExtendingSelection: false) }
        suite.shortcut("cmd+opt+n")
        let editing = await PerfWait.until(3000) { (self.window.firstResponder as? NSTextView)?.isFieldEditor == true && FileManager.default.fileExists(atPath: self.fixture.path("src/untitled")) }
        suite.typeKeys("fresh.ts")
        suite.typeKeys("\r")
        let made = await PerfWait.until(3000) { FileManager.default.fileExists(atPath: self.fixture.path("src/fresh.ts")) && self.shown("src/fresh.ts") != nil }
        check("Files: New File (⌥⌘N) is named in place in the selected folder, then opens", editing != nil && made != nil && tabCount == count + 1,
              "editing \(editing != nil), made \(FileManager.default.fileExists(atPath: fixture.path("src/fresh.ts"))), tabs \(count) → \(tabCount), keyboard in \(responderName)")
        // Rename (Return on the row): the file moves, its tab follows.
        if let row = await treeRow("src/fresh.ts", in: tree) {
            window.makeFirstResponder(tree.outline)
            tree.outline.selectRowIndexes([row], byExtendingSelection: false)
            press(Self.returnKey.0, code: Self.returnKey.1)
            let renaming = await PerfWait.until(2000) { (self.window.firstResponder as? NSTextView)?.isFieldEditor == true }
            // The name without its extension is selected: typing replaces it.
            suite.typeKeys("renamed")
            suite.typeKeys("\r")
            let moved = await PerfWait.until(3000) { FileManager.default.fileExists(atPath: self.fixture.path("src/renamed.ts")) && self.tab(showing: "src/renamed.ts") != nil }
            check("Files: Return renames in place (the extension kept); the open tab follows", renaming != nil && moved != nil,
                  "renaming \(renaming != nil), on disk \(FileManager.default.fileExists(atPath: fixture.path("src/renamed.ts"))), tab \(tab(showing: "src/renamed.ts") != nil)")
        }
        // ⌘⌫ moves it to the Trash (the run's own), as Finder would, without asking.
        if let row = await treeRow("src/renamed.ts", in: tree) {
            window.makeFirstResponder(tree.outline)
            tree.outline.selectRowIndexes([row], byExtendingSelection: false)
            press(Self.backspace.0, .command, code: Self.backspace.1)
            let trashed = await PerfWait.until(3000) { !FileManager.default.fileExists(atPath: self.fixture.path("src/renamed.ts")) }
            check("Files: ⌘⌫ moves the file to the Trash without asking", trashed != nil && window.attachedSheet == nil && OutsideStandIn.trashed.contains { $0.lastPathComponent == "renamed.ts" },
                  "trashed \(OutsideStandIn.trashed.map(\.lastPathComponent))")
            if let tab = tab(showing: "src/renamed.ts") {
                workbench.select(tab: tab)
                _ = await PerfWait.until(4000) { self.filePage?.document.diskChange == .deleted }
                check("Files: the trashed file's tab says it went", filePage?.document.diskChange == .deleted)
                workbench.requestClose(tab: tab)
            }
        }
        snapshot("files-panel")
    }
}
#endif
