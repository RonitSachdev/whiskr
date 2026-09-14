#if DEBUG
import AppKit
import SwiftUI
import WhiskrKit

/// Changes and diffs: staging, unstaging, discarding, committing, sections folding, and one change at a
/// time (Revert Change with its undo, Stage and Unstage Change) on files of several hunks, Windows line
/// breaks, a last line without its line break, a renamed file, a new file, a binary.
extension FilesFlow {
    var repository: Repository? { workbench.files.repository(for: workspace) }

    /// git's own answer, in the scratch repository.
    func git(_ arguments: [String]) -> String? { fixture.git(arguments) }

    /// The Changes panel's SwiftUI host, once it shows.
    var changesHost: NSView? {
        DebugShell.descendant(of: controller.terminals.sidePanel) { String(describing: type(of: $0)).contains("ChangesView") && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// A click at a point of the Changes panel (from its top left), the pointer resting there first so
    /// SwiftUI's hover shows the row's buttons.
    func clickChanges(at point: NSPoint, in host: NSView) async {
        let local = NSPoint(x: point.x, y: host.isFlipped ? point.y : host.bounds.height - point.y)
        await suite.hover(host, at: local)
        await PerfWait.sleep(150)
        let location = host.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: suite.nextEventNumber(), clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) { NSApp.sendEvent(event) }
        }
        await PerfWait.sleep(200)
    }

    /// Where a file's row is in the panel (its middle, from the panel's top), by the panel's own layout:
    /// the branch line (30), each section's header (30) and rows (26), folded sections without rows.
    func changesRowY(_ path: String, section: String, status: GitStatus) -> CGFloat? {
        var y: CGFloat = 30
        for (key, entries) in [("staged", status.staged), ("changes", status.unstaged), ("untracked", status.untracked)] where !entries.isEmpty {
            y += 30
            let folded = FoldedSections.shared.keys.contains(key)
            if key == section, !folded, let index = entries.firstIndex(where: { $0.path == path }) { return y + CGFloat(index) * 26 + 13 }
            if !folded { y += CGFloat(entries.count) * 26 }
        }
        return nil
    }

    func changesHeaderY(_ section: String, status: GitStatus) -> CGFloat? {
        var y: CGFloat = 30
        for (key, entries) in [("staged", status.staged), ("changes", status.unstaged), ("untracked", status.untracked)] where !entries.isEmpty {
            if key == section { return y + 20 }
            y += 30 + (FoldedSections.shared.keys.contains(key) ? 0 : CGFloat(entries.count) * 26)
        }
        return nil
    }

    // MARK: 4. Changes

    func changes() async {
        guard let repository else { return check("Changes: the repository", false) }
        // Work to review: three changes far apart, Windows line breaks, a last line without its line break, a
        // rename, a new file, a changed picture and a new one, and a file to discard.
        var multi = (1...60).map { "line \($0)" }
        multi[2] = "line 3, changed"; multi[29] = "line 30, changed"; multi[56] = "line 57, changed"
        try? Data((multi.joined(separator: "\n") + "\n").utf8).write(to: fixture.url("multi.txt"))
        var rows = (1...40).map { "row \($0)" }
        rows[4] = "row 5, changed"; rows[29] = "row 30, changed"
        try? Data((rows.joined(separator: "\r\n") + "\r\n").utf8).write(to: fixture.url("windows.txt"))
        try? Data(((1...9).map { "item \($0)" } + ["item ten"]).joined(separator: "\n").utf8).write(to: fixture.url("nonl.txt"))
        _ = git(["mv", "old-name.txt", "renamed.txt"])
        try? Data("brand new\nsecond line\n".utf8).write(to: fixture.url("new.txt"))
        try? FilesFixture.png(color: .systemPink).write(to: fixture.url("docs/logo.png"))
        try? FilesFixture.png(color: .systemYellow).write(to: fixture.url("docs/new.png"))
        try? Data("import sys\n# to be thrown away\n".utf8).write(to: fixture.url("tools/build.py"))
        _ = git(["checkout", "--", "src/util.ts", "src/index.ts", "config.json"])

        suite.shortcut("cmd+shift+c")
        let expected: (GitStatus) -> Bool = { status in
            Set(status.unstaged.map(\.path)).isSuperset(of: ["multi.txt", "windows.txt", "nonl.txt", "docs/logo.png", "tools/build.py"])
                && status.staged.contains { $0.path == "renamed.txt" } && Set(status.untracked.map(\.path)).isSuperset(of: ["new.txt", "docs/new.png"])
        }
        let read = await PerfWait.until(6000) { repository.status.map(expected) == true && self.changesHost != nil }
        guard read != nil, let host = changesHost, var status = repository.status else {
            return check("Changes (⇧⌘C) lists staged, changed and untracked files", false,
                         "staged \(repository.status?.staged.map(\.path) ?? []), changed \(repository.status?.unstaged.map(\.path) ?? []), untracked \(repository.status?.untracked.map(\.path) ?? [])")
        }
        check("Changes (⇧⌘C) lists staged, changed and untracked files", true, "\(status.staged.count) staged, \(status.unstaged.count) changed, \(status.untracked.count) untracked")
        await PerfWait.sleep(500)
        snapshot("changes-panel")

        // Stage with the row's "+" (shown under the pointer), unstage with the staged row's "−".
        if let y = changesRowY("multi.txt", section: "changes", status: status) {
            await clickChanges(at: NSPoint(x: host.bounds.width - 42, y: y), in: host)
            let staged = await PerfWait.until(3000) { repository.status?.staged.contains { $0.path == "multi.txt" } == true }
            check("Changes: a row's + stages the file", staged != nil, "staged \(repository.status?.staged.map(\.path) ?? [])")
            _ = await PerfWait.until(2000) { self.changesRowY("multi.txt", section: "staged", status: repository.status ?? status) != nil }
            status = repository.status ?? status
            if staged != nil, let y = changesRowY("multi.txt", section: "staged", status: status) {
                await clickChanges(at: NSPoint(x: host.bounds.width - 42, y: y), in: host)
                let unstaged = await PerfWait.until(3000) { repository.status?.staged.contains { $0.path == "multi.txt" } == false }
                check("Changes: a staged row's − unstages it, the changes kept", unstaged != nil && disk("multi.txt") == multi.joined(separator: "\n") + "\n")
            }
        }
        // Discard: asks first (a sheet, transparent in this run), and Cancel keeps the changes.
        status = repository.status ?? status
        if let y = changesRowY("tools/build.py", section: "changes", status: status) {
            await clickChanges(at: NSPoint(x: host.bounds.width - 64, y: y), in: host)
            let sheet = await sheet()
            let titles = sheet.map { buttons(of: $0).map(\.title) } ?? []
            check("Changes: Discard Changes… asks first", sheet != nil && titles.contains(String(localized: "Discard Changes")), "buttons \(titles)")
            await answer(sheet, String(localized: "Cancel"))
            await PerfWait.sleep(300)
            check("Changes: Cancel keeps the changes", disk("tools/build.py")?.contains("to be thrown away") == true)
            await clickChanges(at: NSPoint(x: host.bounds.width - 64, y: y), in: host)
            await answer(await self.sheet(), String(localized: "Discard Changes"))
            let discarded = await PerfWait.until(3000) { self.disk("tools/build.py")?.contains("to be thrown away") == false }
            check("Changes: Discard Changes puts the file back", discarded != nil)
        }
        // An untracked file's discard is a move to the Trash (the run's own), asked first.
        _ = await PerfWait.until(2000) { repository.status?.unstaged.contains { $0.path == "tools/build.py" } == false }
        status = repository.status ?? status
        if let y = changesRowY("new.txt", section: "untracked", status: status) {
            // A new file is backed up and put back after: the diff checks below look at it.
            let saved = diskData("new.txt")
            await clickChanges(at: NSPoint(x: host.bounds.width - 64, y: y), in: host)
            let sheet = await sheet()
            let titles = sheet.map { buttons(of: $0).map(\.title) } ?? []
            await answer(sheet, String(localized: "Move to Trash"))
            let trashed = await PerfWait.until(3000) { !FileManager.default.fileExists(atPath: self.fixture.path("new.txt")) }
            check("Changes: discarding an untracked file asks, then moves it to the Trash", titles.contains(String(localized: "Move to Trash")) && trashed != nil, "buttons \(titles)")
            try? saved?.write(to: fixture.url("new.txt"))
        }
        // Sections fold under their chevrons, remembered.
        _ = await PerfWait.until(3000) { repository.status?.untracked.contains { $0.path == "new.txt" } == true }
        status = repository.status ?? status
        if let y = changesHeaderY("untracked", status: status) {
            await clickChanges(at: NSPoint(x: 24, y: y), in: host)
            let folded = FoldedSections.shared.keys.contains("untracked")
            await clickChanges(at: NSPoint(x: 24, y: y), in: host)
            check("Changes: a section folds and opens under its chevron", folded && !FoldedSections.shared.keys.contains("untracked"))
        }

        await commitCheck(repository, host: host)
        await undoAfterCommitCheck(repository)
        await diffCheck(repository)
    }

    /// The message, ⌘↩ from a terminal (nothing), ⌘↩ from the message (a commit).
    private func commitCheck(_ repository: Repository, host: NSView) async {
        try? Data("{\n  \"name\": \"committed\"\n}\n".utf8).write(to: fixture.url("config.json"))
        _ = git(["add", "config.json"])
        _ = await PerfWait.until(3000) { repository.status?.staged.contains { $0.path == "config.json" } == true }
        let head = git(["rev-parse", "HEAD"])
        guard let field = DebugShell.descendant(of: host, where: { $0 is NSTextView }) as? NSTextView else { return check("Changes: the message field", false) }
        window.makeFirstResponder(field)
        _ = await PerfWait.until(1000) { self.window.firstResponder === field }
        suite.typeKeys("Rename a file")
        let written = await PerfWait.until(1000) { repository.commitMessage == "Rename a file" }
        // From a terminal: ⌘↩ is the terminal's.
        workbench.focus(pane: shell.id)
        _ = await PerfWait.until(1000) { self.suite.focused(self.shell) }
        suite.shortcut("cmd+return")
        await PerfWait.sleep(800)
        let fromTerminal = git(["rev-parse", "HEAD"]) == head
        window.makeFirstResponder(field)
        _ = await PerfWait.until(1000) { self.window.firstResponder === field }
        await PerfWait.sleep(200)
        press(Self.returnKey.0, .command, code: Self.returnKey.1)
        let committed = await PerfWait.until(5000) { self.git(["rev-parse", "HEAD"]) != head && repository.commitMessage.isEmpty }
        let subject = git(["log", "-1", "--format=%s"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        check("Changes: ⌘↩ commits only from the message field", written != nil && fromTerminal && committed != nil && subject == "Rename a file" && repository.commitMessage.isEmpty,
              "typed \(written != nil), from a terminal nothing \(fromTerminal), from the field \(committed != nil), subject “\(subject ?? "-")”, message left “\(repository.commitMessage)”, error \(repository.lastError ?? "none")")
    }

    /// After a commit the message's typing is still on the window's undo stack: ⌘Z elsewhere must not
    /// reach into the cleared field.
    private func undoAfterCommitCheck(_ repository: Repository) async {
        let title = window.undoManager?.undoMenuItemTitle ?? "-"
        workbench.focus(pane: shell.id)
        _ = await PerfWait.until(1000) { self.suite.focused(self.shell) }
        print("files: after the commit, with a terminal's keyboard, Edit › Undo is “\(title)”")
        suite.shortcut("cmd+z")
        await PerfWait.sleep(500)
        check("Changes: ⌘Z after a commit does not bring the sent message back into the field", repository.commitMessage.isEmpty,
              "undo was “\(title)”, message now “\(repository.commitMessage)”")
        repository.commitMessage = ""
    }

    // MARK: Diffs

    /// The diff page with its table, once its rows are read.
    func openDiff(_ relative: String, staged: Bool = false) async -> (DiffPageView, NSTableView)? {
        workbench.openChanges(path: fixture.path(relative), staged: staged, mode: .keep)
        var found: (DiffPageView, NSTableView)?
        _ = await PerfWait.until(5000) {
            guard let page = self.diffPage, page.path == self.fixture.url(relative).standardizedFileURL.path, page.staged == staged,
                  let table = DebugShell.descendant(of: page, where: { $0 is NSTableView }) as? NSTableView, table.numberOfRows > 0 || !self.diffEmptyText(page).isEmpty else { return false }
            found = (page, table)
            return true
        }
        await PerfWait.sleep(300)
        return found
    }

    /// Whether the diff page's "nothing to compare" view shows (no changes, a binary, a conflict).
    func diffEmptyText(_ page: DiffPageView) -> String {
        DebugShell.descendant(of: page) { String(describing: type(of: $0)).contains("DiffEmpty") && !$0.isHidden } != nil ? "shown" : ""
    }

    /// Each row's accessibility label (what it shows, in words).
    func labels(_ table: NSTableView) -> [String] {
        (0..<table.numberOfRows).map { row in (table.view(atColumn: 0, row: row, makeIfNecessary: true)?.accessibilityLabel()) ?? "" }
    }

    private func diffCheck(_ repository: Repository) async {
        // Room for side by side (a narrow pane shows a diff inline whatever is chosen): the panel put away.
        workbench.setPanelShown(false)
        EditorPreferences.shared.diffLayout = .sideBySide
        guard let (page, table) = await openDiff("multi.txt") else { return check("diff: multi.txt's changes show", false) }
        await focusTable(table)
        let sideRows = table.numberOfRows
        let gaps = labels(table).filter { $0.hasSuffix("folded") }
        snapshot("diff-side-by-side")
        EditorPreferences.shared.diffLayout = .inline
        _ = await PerfWait.until(2000) { table.numberOfRows != sideRows }
        let inlineRows = table.numberOfRows
        snapshot("diff-inline")
        check("diff: side by side and inline (inline shows each changed line twice)", inlineRows == sideRows + 3, "rows side by side \(sideRows), inline \(inlineRows)")
        check("diff: unchanged stretches fold into “⋯ N unchanged lines” rows", gaps.count == 2, "\(gaps)")
        // A click on a fold opens it.
        if let gapRow = labels(table).firstIndex(where: { $0.contains("folded") }) {
            let before = table.numberOfRows
            let rect = table.rect(ofRow: gapRow)
            suite.click(table, at: NSPoint(x: rect.midX, y: rect.midY))
            let opened = await PerfWait.until(2000) { table.numberOfRows > before }
            check("diff: a click on a fold shows its lines", opened != nil, "rows \(before) → \(table.numberOfRows)")
        }
        // Next and previous change scroll from one change to the next.
        let clip = (table.enclosingScrollView ?? NSScrollView()).contentView
        clip.scroll(to: .zero)
        var tops: [CGFloat] = []
        for _ in 0..<3 {
            command(#selector(MainWindowController.nextChange(_:)))
            await PerfWait.sleep(150)
            tops.append(clip.bounds.minY)
        }
        command(#selector(MainWindowController.previousChange(_:)))
        await PerfWait.sleep(150)
        let back = clip.bounds.minY
        check("diff: Next Change steps down from change to change, Previous Change back", tops == tops.sorted() && (tops.last ?? 0) > 0 && back < (tops.last ?? 0),
              "tops \(tops.map { Int($0) }), back \(Int(back)), document \(Int(table.frame.height)), visible \(Int(clip.bounds.height))")
        clip.scroll(to: .zero)

        // Revert the middle change alone, then Edit › Undo Revert Change, then Redo.
        EditorPreferences.shared.diffLayout = .sideBySide
        await PerfWait.sleep(400)
        let original = disk("multi.txt")
        let said = await revertNth(1, page: page, table: table)
        let reverted = await PerfWait.until(4000) { self.disk("multi.txt").map { $0.contains("line 30\n") && $0.contains("line 3, changed") && $0.contains("line 57, changed") } ?? false }
        check("diff: Revert Change reverts that change alone", reverted != nil, said)
        await focusTable(table)
        // The undo is registered when git has finished, a moment after the file on disk has changed.
        _ = await PerfWait.until(2000) { self.window.undoManager?.undoActionName == String(localized: "Revert Change") }
        let undoTitle = window.undoManager?.undoMenuItemTitle ?? "-"
        print("files: before ⌘Z in the diff the window's undo says “\(undoTitle)”")
        suite.shortcut("cmd+z")
        let undone = await PerfWait.until(4000) { self.disk("multi.txt") == original }
        check("diff: Edit › \(undoTitle) puts it back", undone != nil && undoTitle == String(localized: "Undo") + " " + String(localized: "Revert Change"), "undo item “\(undoTitle)”")
        suite.shortcut("cmd+shift+z")
        let redone = await PerfWait.until(4000) { self.disk("multi.txt")?.contains("line 30\n") == true }
        check("diff: Redo reverts it again", redone != nil)
        suite.shortcut("cmd+z")
        let undoneAgain = await PerfWait.until(4000) { self.disk("multi.txt") == original }
        check("diff: after Redo, ⌘Z puts the change back again", undoneAgain != nil, "the window's undo now “\(window.undoManager?.undoMenuItemTitle ?? "-")”")

        // Stage the first change alone; then, in the staged diff, unstage it.
        _ = await PerfWait.until(3000) { table.numberOfRows > 0 }
        await PerfWait.sleep(500)
        let staging = await suite.pressChangeAction(String(localized: "Stage Change"), diff: page, table: table)
        let stagedOne = await PerfWait.until(4000) {
            let index = self.git(["diff", "--cached", "--", "multi.txt"]) ?? ""
            return index.contains("+line 3, changed") && !index.contains("+line 30, changed") && !index.contains("+line 57, changed")
        }
        check("diff: Stage Change stages that change alone", stagedOne != nil, staging)
        if stagedOne != nil, let (stagedPage, stagedTable) = await openDiff("multi.txt", staged: true) {
            let unstaging = await suite.pressChangeAction(String(localized: "Unstage Change"), diff: stagedPage, table: stagedTable)
            let unstaged = await PerfWait.until(4000) { (self.git(["diff", "--cached", "--", "multi.txt"]) ?? "x").isEmpty }
            check("diff: Unstage Change in the staged diff takes it out of the index, the file kept", unstaged != nil && disk("multi.txt") == original,
                  "\(unstaging); file as before \(disk("multi.txt") == original); index \(git(["diff", "--cached", "--stat", "--", "multi.txt"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"), error \(repository.lastError ?? "none")")
        }

        // A last line without its line break: Revert Change gives back exactly what was committed.
        if let (nonlPage, nonlTable) = await openDiff("nonl.txt", staged: false) {
            let said = await suite.pressChangeAction(String(localized: "Revert Change"), diff: nonlPage, table: nonlTable)
            let exact = await PerfWait.until(4000) { self.git(["diff", "--", "nonl.txt"])?.isEmpty == true }
            check("diff: a change to a last line without a line break reverts exactly", exact != nil, "\(said); now “\(disk("nonl.txt")?.suffix(12) ?? "-")”")
        } else {
            print("files: nonl.txt has no unstaged changes left (committed above)")
        }
        // Windows line breaks: staging one change of it (owned by the fixes agent: observed here, not checked).
        if let (crlfPage, crlfTable) = await openDiff("windows.txt") {
            print("files: windows.txt diff rows \(crlfTable.numberOfRows): \(labels(crlfTable).prefix(6))")
            let said = await suite.pressChangeAction(String(localized: "Stage Change"), diff: crlfPage, table: crlfTable)
            await PerfWait.sleep(1500)
            print("files: OBSERVED Stage Change on a CRLF file: \(said); index now \(git(["diff", "--cached", "--stat", "--", "windows.txt"]) ?? "-"), error \(repository.lastError ?? "none")")
            _ = git(["reset", "-q", "--", "windows.txt"])
        }
        // A renamed file, a new file, a changed picture, a new picture.
        _ = git(["mv", "renamed.txt", "renamed-again.txt"])
        _ = await PerfWait.until(3000) { repository.status?.staged.contains { $0.path == "renamed-again.txt" } == true }
        if let (renamed, renamedTable) = await openDiff("renamed-again.txt", staged: true) {
            print("files: OBSERVED a staged rename's diff: \(renamedTable.numberOfRows) rows, first \(labels(renamedTable).prefix(2)), title “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")”, empty \(diffEmptyText(renamed))")
        }
        if let (_, newTable) = await openDiff("new.txt") {
            let rows = labels(newTable)
            check("diff: a new file shows every line as added", rows.count == 2 && rows.allSatisfy { $0.hasPrefix("Added line") },
                  "\(rows)")
        }
        if let (logo, logoTable) = await openDiff("docs/logo.png") {
            check("diff: a changed picture says it is binary, no rows", logoTable.numberOfRows == 0 && !diffEmptyText(logo).isEmpty, "rows \(logoTable.numberOfRows)")
            snapshot("diff-binary")
        }
        if let (fresh, freshTable) = await openDiff("docs/new.png") {
            snapshot("diff-new-binary")
            let binaryText = String(localized: "A binary file: there is no text to compare.")
            let says = DebugShell.descendant(of: fresh) { String(describing: type(of: $0)).contains("DiffEmpty") && !$0.isHidden }
            check("diff: a new picture says it is binary (not “No changes”)", freshTable.numberOfRows == 0 && says != nil && fresh.debugSaysBinary,
                  "rows \(freshTable.numberOfRows), empty page \(diffEmptyText(fresh)), says binary \(fresh.debugSaysBinary) (\(binaryText); files-diff-new-binary.png)")
        }
    }

    func focusTable(_ table: NSTableView) async {
        window.makeFirstResponder(table)
        _ = await PerfWait.until(1000) { self.window.firstResponder === table }
    }

    /// Revert Change over the `index`th change (0-based) of a diff: the pointer moved there, its button pressed.
    private func revertNth(_ index: Int, page: DiffPageView, table: NSTableView) async -> String {
        // The rows of each change, as the diff counts them (side by side: one row a changed line).
        let starts = (0..<table.numberOfRows).filter { row in
            let all = labels(table)
            func isChange(_ label: String) -> Bool { label.contains("changed from") || label.hasPrefix("Added line") || label.hasPrefix("Removed line") }
            return isChange(all[row]) && (row == 0 || !isChange(all[row - 1]))
        }
        guard starts.indices.contains(index), let actions = page.subviews.first(where: { String(describing: type(of: $0)).contains("ChangeActions") }) else { return "no change \(index) among \(starts)" }
        let rect = table.rect(ofRow: starts[index])
        await suite.hover(table, at: NSPoint(x: rect.midX, y: rect.midY))
        if let moved = suite.mouse(.mouseMoved, at: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)) { window.sendEvent(moved) }
        _ = await PerfWait.until(1000) { !actions.isHidden }
        let point = NSPoint(x: actions.bounds.width * 0.25, y: actions.bounds.midY)
        await suite.hover(actions, at: point)
        let landing = suite.click(actions, at: point)
        return "clicked Revert Change over row \(starts[index]), the click went to \(landing.map { String(describing: type(of: $0)) } ?? "nothing")"
    }
}
#endif

#if DEBUG
extension DiffPageView {
    /// Whether the page's model says the file is binary (read by reflection: the model is the page's own).
    var debugSaysBinary: Bool {
        (Mirror(reflecting: self).children.first { $0.label == "model" }?.value as? DiffModel)?.isBinary ?? false
    }
}
#endif
