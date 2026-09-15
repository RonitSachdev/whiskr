#if DEBUG
import AppKit
import SwiftUI
import WhiskrKit

/// Opening files (the Files panel's clicks, Go to) and editing them: typing, saving, undo, the disk
/// changing under a clean file and under one with changes, a file deleted or renamed outside, closing one
/// with unsaved changes.
extension FilesFlow {
    // MARK: The Files panel

    /// The selected workspace's file tree once it shows its top folder.
    func fileTree() async -> FileTreeView? {
        _ = await PerfWait.until(5000) {
            guard let tree = self.controller.terminals.sidePanel.fileTree, tree.window != nil, !tree.isHiddenOrHasHiddenAncestor else { return false }
            // Once the panel has slid in: a click aimed at a row while it still moves lands on another (a person
            // does not click into a panel 200 ms after asking for it, a run does).
            return tree.outline.numberOfRows > 3 && !LiveResize.shared.isActive
        }
        return controller.terminals.sidePanel.fileTree
    }

    /// The tree's row showing `relative` (its folders opened first), once it is there.
    func treeRow(_ relative: String, in tree: FileTreeView) async -> Int? {
        tree.reveal(fixture.url(relative))
        var found: Int?
        _ = await PerfWait.until(5000) {
            guard let node = tree.repository.node(for: relative) else { return false }
            let row = tree.outline.row(forItem: tree.row(of: node))
            guard row >= 0 else { return false }
            let rect = tree.outline.rect(ofRow: row)
            // On screen where a click lands: the panel laid out at its width, the row in sight.
            guard self.suite.hit(tree.outline, at: NSPoint(x: rect.minX + 60, y: rect.midY)).map({ $0.isDescendant(of: tree.outline) }) == true else { return false }
            found = row
            return true
        }
        if found == nil, let node = tree.repository.node(for: relative) {
            let row = tree.outline.row(forItem: tree.row(of: node))
            let rect = row >= 0 ? tree.outline.rect(ofRow: row) : .zero
            print("files: no row to click for \(relative): row \(row), rect \(rect), visible \(tree.outline.visibleRect), hit \(suite.hit(tree.outline, at: NSPoint(x: rect.minX + 60, y: rect.midY)).map { String(describing: type(of: $0)) } ?? "nothing")")
        }
        return found
    }

    /// Clicks (one, or two for a double-click) on a row of the tree, each release queued before its press
    /// (a table's press waits for it in a tracking loop).
    func clickRow(_ row: Int, in tree: FileTreeView, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        let rect = tree.outline.rect(ofRow: row)
        let location = tree.outline.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
        PointerStandIn.location = location
        // As a real pointer's move would: a cursor hidden by typing takes the next click to show itself.
        NSCursor.setHiddenUntilMouseMoves(false)
        for number in 1...count {
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: suite.nextEventNumber(), clickCount: number, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: suite.nextEventNumber(), clickCount: number, pressure: 0) else { continue }
            NSApp.postEvent(up, atStart: false)
            NSApp.sendEvent(down)
        }
    }

    var tabCount: Int { workspace.tabs.count }

    // MARK: 1. Opening

    func opening() async {
        // Files (⇧⌘E): a click opens the preview tab, the next click reuses it, a double-click keeps it.
        suite.shortcut("cmd+shift+e")
        guard let tree = await fileTree() else { return check("Files panel (⇧⌘E) shows the tree", false, "panel \(workbench.files.panel(workspace.id))") }
        check("Files panel (⇧⌘E) shows the tree", true, "\(tree.outline.numberOfRows) rows")
        let before = tabCount
        guard let utilRow = await treeRow("src/util.ts", in: tree) else { return check("Files: src/util.ts has a row", false) }
        let rect = tree.outline.rect(ofRow: utilRow)
        print("files: a click on Files' row \(utilRow) lands on \(suite.hit(tree.outline, at: NSPoint(x: rect.minX + 60, y: rect.midY)).map { String(describing: type(of: $0)) } ?? "nothing"), keyboard in \(responderName)")
        clickRow(utilRow, in: tree)
        let previewed = await PerfWait.until(4000) { self.shown("src/util.ts") != nil }
        let previewTab = workbench.selectedTab
        check("Files: a click opens the file in a preview tab", previewed != nil && tabCount == before + 1 && previewTab.map(workbench.isPreview) == true,
              "tabs \(before) → \(tabCount), preview \(previewTab.map(workbench.isPreview) ?? false), page \(workbench.focusedPage.map { "\($0)" } ?? "none")")
        print("files: after a click in Files the keyboard is in \(responderName)")
        guard let configRow = await treeRow("config.json", in: tree) else { return check("Files: config.json has a row", false) }
        clickRow(configRow, in: tree)
        let reused = await PerfWait.until(4000) { self.shown("config.json") != nil }
        check("Files: the next click reuses the preview tab", reused != nil && tabCount == before + 1 && workbench.selectedTab === previewTab
              && previewTab.map(workbench.isPreview) == true && !workbench.pages.values.contains(.file(path: fixture.path("src/util.ts"))),
              "tabs \(tabCount), same tab \(workbench.selectedTab === previewTab), title “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")”")
        guard let pythonRow = await treeRow("tools/build.py", in: tree) else { return check("Files: tools/build.py has a row", false) }
        clickRow(pythonRow, in: tree, count: 2)
        let kept = await PerfWait.until(4000) { self.shown("tools/build.py") != nil && self.workbench.selectedTab.map(self.workbench.isPreview) == false }
        check("Files: a double-click keeps the file (no longer a preview)", kept != nil && tabCount == before + 1,
              "tabs \(tabCount), preview \(workbench.selectedTab.map(workbench.isPreview) ?? true)")
        // A click on another file now opens a new preview, leaving the kept one.
        clickRow(utilRow, in: tree)
        _ = await PerfWait.until(4000) { self.shown("src/util.ts") != nil }
        // Typing in a preview keeps it.
        if let page = shown("src/util.ts") {
            await focusEditor(page)
            suite.typeKeys("x")
            let typedKeeps = await PerfWait.until(2000) { self.workbench.selectedTab.map(self.workbench.isPreview) == false }
            check("Files: typing in a preview tab keeps it", typedKeeps != nil, "preview \(workbench.selectedTab.map(workbench.isPreview) ?? true)")
            page.document.undoManager.undo()
            _ = await PerfWait.until(1000) { !page.document.isEdited }
        }

        // Go to (⌘P) with a name, a name and a line, and ":line" in the file shown.
        await goToCheck()
    }

    /// The overlay's model while it is open.
    var paletteModel: PaletteModel? {
        (controller.palette?.panelForSnapshot?.contentViewController as? NSHostingController<PaletteView>)?.rootView.model
    }

    /// Types into the overlay as a person does (its own window's field takes the keys).
    func typeInPalette(_ text: String) {
        guard let panel = controller.palette?.panelForSnapshot else { return }
        for character in text {
            let (characters, code) = character == "\r" ? ("\r", UInt16(36)) : character == "\u{1b}" ? ("\u{1b}", UInt16(53)) : (String(character), UInt16(0))
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                            isARepeat: false, keyCode: code) {
                panel.sendEvent(event)
            }
        }
    }

    /// ⌘P, `query` typed, then Return on the first row; false when the overlay never took the query.
    @discardableResult
    func goTo(_ query: String, mode: String = "cmd+p", expectFirst: ((PaletteModel.Row) -> Bool)? = nil) async -> (typed: Bool, first: String) {
        suite.shortcut(mode)
        guard await PerfWait.until(2000, { self.paletteModel != nil }) != nil, let model = paletteModel else { return (false, "no overlay") }
        typeInPalette(query)
        let typed = await PerfWait.until(1500) { model.query == query } != nil
        if !typed {
            // The overlay's field did not take the keys (the run's panel never becomes key): the query is set
            // as typing would set it, and said.
            print("files: Go to's field did not take typed keys (first responder \(controller.palette?.panelForSnapshot?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")); set directly")
            model.query = query
        }
        // Files are found off the main thread: wait for the list to settle on what is expected.
        if let expectFirst { _ = await PerfWait.until(3000) { model.rows.first.map(expectFirst) ?? false } } else { await PerfWait.sleep(400) }
        let first = model.rows.first.map { "\($0.entry.title) (\($0.entry.detail))" } ?? "nothing"
        typeInPalette("\r")
        if await PerfWait.until(1000, { self.paletteModel == nil }) == nil {
            print("files: Return in Go to's field did not choose; chosen directly")
            model.choose()
        }
        return (typed, first)
    }

    private func goToCheck() async {
        let (typed, first) = await goTo("build", expectFirst: { $0.entry.title == "build.py" })
        _ = await PerfWait.until(3000) { self.shown("tools/build.py") != nil }
        check("Go to: a name opens the file", shown("tools/build.py") != nil, "first row \(first), typed \(typed)")
        let (_, atLine) = await goTo("index.ts:42", expectFirst: { $0.entry.title == "index.ts" })
        _ = await PerfWait.until(3000) { self.shown("src/index.ts").flatMap(self.place)?.line == 42 }
        let indexPage = shown("src/index.ts")
        check("Go to: `name:42` opens the file at line 42", indexPage.flatMap(place)?.line == 42,
              "first row \(atLine), caret \(indexPage.flatMap(place).map { "\($0.line):\($0.column)" } ?? "-")")
        let (_, lineRow) = await goTo(":120:5")
        _ = await PerfWait.until(3000) { self.shown("src/index.ts").flatMap(self.place).map { $0.line == 120 && $0.column == 5 } ?? false }
        let at = shown("src/index.ts").flatMap(place)
        let visible = shown("src/index.ts")?.editor.map { $0.visibleLines() }
        check("Go to: `:120:5` goes to that line and column of the file shown, in sight", at?.line == 120 && at?.column == 5 && (visible?.contains(119) ?? false),
              "row \(lineRow), caret \(at.map { "\($0.line):\($0.column)" } ?? "-"), lines laid out \(visible.map { "\($0)" } ?? "-")")
        // Every word must match; a quoted word as written.
        suite.shortcut("cmd+p")
        if await PerfWait.until(2000, { self.paletteModel != nil }) != nil, let model = paletteModel {
            model.query = "src util"
            _ = await PerfWait.until(3000) { model.rows.contains { $0.entry.kind == .file && $0.entry.title == "util.ts" } }
            let both = model.rows.first?.entry.title
            print("files: Go to “src util” rows: \(model.rows.prefix(6).map { "\($0.entry.title) [\($0.entry.detail)] \($0.offsets)" })")
            model.query = "\"page.tsx\""
            _ = await PerfWait.until(3000) { model.rows.contains { $0.entry.kind == .file && $0.entry.title == "page.tsx" } }
            let quoted = model.rows.first?.entry.title
            model.query = "nothing-is-called-this"
            await PerfWait.sleep(500)
            let none = model.rows.count
            check("Go to: words all match (“src util” → util.ts), a quoted word as written (“\"page.tsx\"”), nothing for nonsense",
                  both == "util.ts" && quoted == "page.tsx" && none == 0, "first \(both ?? "-"), quoted \(quoted ?? "-"), nonsense rows \(none)")
            // ">" turns Go to into the commands.
            model.query = ">split right"
            await PerfWait.sleep(200)
            check("Go to: `>` lists the commands", model.listMode == .commands && model.rows.first?.entry.title == String(localized: "Split Right"),
                  "list \(model.listMode == .commands ? "commands" : "places"), first \(model.rows.first?.entry.title ?? "-")")
            // Esc closes it and the keyboard goes back.
            let editor = shown("src/index.ts")?.editor?.textView
            typeInPalette("\u{1b}")
            if await PerfWait.until(1000, { self.paletteModel == nil }) == nil {
                print("files: Esc in Go to's field did not reach it; the panel's Cancel sent")
                controller.palette?.panelForSnapshot?.cancelOperation(nil)
                _ = await PerfWait.until(1000) { self.paletteModel == nil }
            }
            check("Go to: Esc closes it, the keyboard back in the editor", paletteModel == nil && editor.map { window.firstResponder === $0 } == true, "keyboard in \(responderName)")
        }
    }

    // MARK: 2. Editing and the disk

    func editing() async {
        guard let page = await open("src/index.ts") else { return check("editing: src/index.ts opens", false) }
        await focusEditor(page)
        let document = page.document
        page.editor?.textView.show(line: 100, column: 3)
        await PerfWait.sleep(200)
        // Typing, then ⌘Z, then typing again and ⌘S.
        suite.typeKeys("abc")
        let edited = await PerfWait.until(1000) { document.isEdited }
        check("editing: typing marks the file edited (the tab's dot)", edited != nil && workbench.selectedTab.map(workbench.hasEditedFile(in:)) == true)
        suite.shortcut("cmd+z")
        let undone = await PerfWait.until(1000) { !document.isEdited && self.text(page) == FilesFixture.longLines.joined(separator: "\n") + "\n" }
        check("editing: ⌘Z takes the typing back (and the file is clean again)", undone != nil, "edited \(document.isEdited)")
        suite.typeKeys("abc")
        _ = await PerfWait.until(1000) { document.isEdited }
        suite.shortcut("cmd+s")
        let saved = await PerfWait.until(2000) { !document.isEdited && self.disk("src/index.ts") == self.text(page) }
        check("editing: ⌘S writes it and the dot goes", saved != nil, "edited \(document.isEdited), disk matches \(disk("src/index.ts") == text(page))")

        // Save All (⌥⌘S): two files with changes, both written.
        if let other = await open("src/util.ts") {
            await focusEditor(other)
            suite.typeKeys("// one\r")
            if let tab = tab(showing: "src/index.ts") { workbench.select(tab: tab) }
            _ = await PerfWait.until(2000) { self.shown("src/index.ts") != nil }
            await focusEditor(page)
            suite.typeKeys("z")
            _ = await PerfWait.until(1000) { document.isEdited && other.document.isEdited }
            suite.shortcut("cmd+opt+s")
            let all = await PerfWait.until(2000) { !document.isEdited && !other.document.isEdited }
            check("editing: Save All (⌥⌘S) writes every file with changes", all != nil && disk("src/util.ts")?.hasPrefix("// one") == true,
                  "index edited \(document.isEdited), util edited \(other.document.isEdited)")
        }

        // The disk changes under a clean file: it follows at once, the caret and the scroll stay.
        page.editor?.textView.show(line: 150, column: 4)
        await PerfWait.sleep(300)
        let top = page.editor?.topLine
        var lines = text(page).components(separatedBy: "\n")
        lines[4] = "export const line5 = 'changed outside';"
        try? Data(lines.joined(separator: "\n").utf8).write(to: fixture.url("src/index.ts"))
        let followed = await PerfWait.until(6000) { self.text(page).contains("changed outside") }
        print("files: after the clean reload: page in window \(page.window != nil), selected “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")”, keyboard in \(responderName)")
        await PerfWait.sleep(300)
        let after = place(page)
        check("disk: a clean file follows a change on disk silently, caret and scroll kept",
              followed != nil && after?.line == 150 && after?.column == 4 && abs((page.editor?.topLine ?? -99) - (top ?? 0)) <= 2 && document.diskChange == nil && window.attachedSheet == nil,
              "followed \(followed != nil), caret \(after.map { "\($0.line):\($0.column)" } ?? "-"), top line \(top ?? -1) → \(page.editor?.topLine ?? -1), bar \(document.diskChange.map { "\($0)" } ?? "none")")

        // … and under unsaved changes: the bar (Reload, Keep Mine), never a dialog.
        await focusEditor(page)
        suite.typeKeys("Q")
        _ = await PerfWait.until(1000) { document.isEdited }
        print("files: before the change under edits: edited \(document.isEdited), keyboard in \(responderName), page in window \(page.window != nil), editor in window \(page.editor?.textView.window != nil), the document the open one \(workbench.files.openDocument(fixture.path("src/index.ts")) === document), focused page this one \(filePage === page), selected “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")”, page \(workbench.focusedPage.map { "\($0)" } ?? "none"), tabs \(workspace.tabs.map(workbench.title(of:))), workspace selected \(workbench.selectedWorkspace === workspace)")
        lines[6] = "export const line7 = 'second change outside';"
        try? Data(lines.joined(separator: "\n").utf8).write(to: fixture.url("src/index.ts"))
        let asked = await PerfWait.until(6000) { document.diskChange == .changed && self.bannerHeight(page) > 0 }
        check("disk: a change under unsaved changes shows the bar, not a dialog", asked != nil && window.attachedSheet == nil && bannerHeight(page) > 0,
              "bar \(document.diskChange.map { "\($0)" } ?? "none"), bar height \(bannerHeight(page)), sheet \(window.attachedSheet != nil)")
        let pressedKeep = pressBar(String(localized: "Keep Mine"), in: page) { document.keepMine() }
        _ = await PerfWait.until(1000) { document.diskChange == nil }
        check("disk: Keep Mine keeps your text and puts the bar away", pressedKeep && document.diskChange == nil && text(page).contains("Q") && document.isEdited,
              "pressed \(pressedKeep), bar \(document.diskChange.map { "\($0)" } ?? "none")")
        // Something else in the folder changes: nothing has changed for this file, so nothing asks again.
        try? Data("touch\n".utf8).write(to: fixture.url("src/neighbour.txt"))
        await PerfWait.sleep(2500)
        check("disk: after Keep Mine, a change elsewhere in the folder does not bring the bar back", document.diskChange == nil,
              "bar \(document.diskChange.map { "\($0)" } ?? "none")")
        try? FileManager.default.removeItem(at: fixture.url("src/neighbour.txt"))
        // The file itself changes again: that is new, so it asks.
        lines[8] = "export const line9 = 'third change outside';"
        try? Data(lines.joined(separator: "\n").utf8).write(to: fixture.url("src/index.ts"))
        let again = await PerfWait.until(6000) { document.diskChange == .changed && self.bannerHeight(page) > 0 }
        check("disk: after Keep Mine, a new change on disk asks again", again != nil)
        let pressedReload = pressBar(String(localized: "Reload"), in: page) { document.revert() }
        let reloaded = await PerfWait.until(3000) { document.diskChange == nil && !document.isEdited && self.text(page).contains("third change outside") && !self.text(page).contains("Q") }
        check("disk: Reload takes the disk's version", pressedReload && reloaded != nil, "pressed \(pressedReload), edited \(document.isEdited)")

        // Deleted outside, then back (a branch switched away and back): the bar comes and goes.
        let saved2 = diskData("src/index.ts") ?? Data()
        try? FileManager.default.removeItem(at: fixture.url("src/index.ts"))
        let gone = await PerfWait.until(6000) { document.diskChange == .deleted && self.bannerHeight(page) > 0 }
        check("disk: a file deleted outside says so (Save, Close), its text kept", gone != nil && bannerHeight(page) > 0 && !text(page).isEmpty && window.attachedSheet == nil,
              "bar \(document.diskChange.map { "\($0)" } ?? "none"), content \(document.content)")
        try? saved2.write(to: fixture.url("src/index.ts"))
        let back = await PerfWait.until(6000) { document.diskChange == nil }
        check("disk: the file back as it was, the bar goes", back != nil, "bar \(document.diskChange.map { "\($0)" } ?? "none")")
        // Deleted while edited, then Save from the bar writes it again.
        await focusEditor(page)
        suite.typeKeys("W")
        _ = await PerfWait.until(1000) { document.isEdited }
        try? FileManager.default.removeItem(at: fixture.url("src/index.ts"))
        _ = await PerfWait.until(6000) { document.diskChange == .deleted && self.bannerHeight(page) > 0 }
        let pressedSave = pressBar(String(localized: "Save"), in: page) { self.workbench.save(document) }
        let rewritten = await PerfWait.until(3000) { self.disk("src/index.ts") == self.text(page) && document.diskChange == nil && !document.isEdited }
        check("disk: deleted under unsaved changes, the bar's Save writes it back", pressedSave && rewritten != nil, "pressed \(pressedSave), on disk \(diskData("src/index.ts") != nil)")

        // Renamed outside: the page says it went; its Close closes the tab.
        if let moved = await open("my file.ts") {
            try? FileManager.default.moveItem(at: fixture.url("my file.ts"), to: fixture.url("my renamed file.ts"))
            let said = await PerfWait.until(6000) { moved.document.diskChange == .deleted && self.bannerHeight(moved) > 0 }
            let count = tabCount
            let pressedClose = pressBar(String(localized: "Close"), in: moved) { if let id = self.workbench.focusedPageID { self.workbench.close(page: id) } }
            let closed = await PerfWait.until(2000) { self.tabCount == count - 1 }
            check("disk: a file renamed outside says it went; Close closes its tab", said != nil && pressedClose && closed != nil, "said \(said != nil), content \(moved.document.content), tabs \(count) → \(tabCount)")
            try? FileManager.default.moveItem(at: fixture.url("my renamed file.ts"), to: fixture.url("my file.ts"))
        }

        await closingDirtyCheck()
    }

    /// One of the bar's buttons: pressed through accessibility when SwiftUI has built its elements, else
    /// what the button does (a background run's hosting views often build none until something asks
    /// for them as VoiceOver does). True once one of the two ran, with the bar on screen.
    func pressBar(_ name: String, in page: FilePageView, action: () -> Void) -> Bool {
        guard bannerHeight(page) > 0 else { return false }
        if DebugScript.accessibilityElement(in: page, named: name)?.accessibilityPerformPress() == true { return true }
        print("files: the bar's “\(name)” is not in the accessibility tree here; its action is run as the button runs it")
        action()
        return true
    }

    /// The bar over a file page (Reload · Keep Mine, a file gone, a line too long): its height, 0 when none.
    func bannerHeight(_ page: FilePageView) -> CGFloat {
        DebugShell.descendant(of: page) { String(describing: type(of: $0)).contains("DiskBanner") }?.frame.height ?? 0
    }

    /// ⌘W on a file with unsaved changes: Save / Don't Save / Cancel as a sheet (transparent in this run),
    /// each answer doing what it says.
    private func closingDirtyCheck() async {
        guard let page = await open("config.json") else { return check("closing: config.json opens", false) }
        let original = disk("config.json")
        await focusEditor(page)
        suite.typeKeys("x")
        _ = await PerfWait.until(1000) { page.document.isEdited }
        let count = tabCount
        suite.shortcut("cmd+w")
        let sheet = await sheet()
        let titles = sheet.map { buttons(of: $0).map(\.title) } ?? []
        check("closing: ⌘W on unsaved changes asks Save / Cancel / Don't Save as a sheet", sheet != nil
              && Set(titles) == Set([String(localized: "Save"), String(localized: "Cancel"), String(localized: "Don’t Save")]),
              "buttons \(titles)")
        await answer(sheet, String(localized: "Cancel"))
        check("closing: Cancel keeps the tab and its changes", tabCount == count && page.document.isEdited && window.attachedSheet == nil)
        suite.shortcut("cmd+w")
        await answer(await self.sheet(), String(localized: "Don’t Save"))
        let discarded = await PerfWait.until(2000) { self.tabCount == count - 1 }
        check("closing: Don't Save closes it, the disk untouched", discarded != nil && disk("config.json") == original, "tabs \(count) → \(tabCount)")
        guard let again = await open("config.json") else { return }
        check("closing: opened again, it reads the disk (the changes not kept)", text(again) == original)
        await focusEditor(again)
        suite.typeKeys("y")
        _ = await PerfWait.until(1000) { again.document.isEdited }
        let typed = text(again)
        suite.shortcut("cmd+w")
        await answer(await self.sheet(), String(localized: "Save"))
        let savedClosed = await PerfWait.until(2000) { self.tabCount == count - 1 && self.disk("config.json") == typed }
        check("closing: Save writes it and closes the tab", savedClosed != nil, "on disk “\(disk("config.json")?.prefix(12) ?? "-")…”")
        try? Data((original ?? "").utf8).write(to: fixture.url("config.json"))
    }
}
#endif
