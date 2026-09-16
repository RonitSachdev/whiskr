#if DEBUG
import AppKit
import ObjectiveC
import SwiftTerm
import WhiskrKit

/// `--perf-flows interactions` (`make perf`'s checks): what a person does to terminals and tabs beyond
/// typing, opening and closing, each through the events their keys and pointer make (`sendEvent`, as the
/// rest of `PerfSuite`); where AppKit would only put something on screen (a context menu) or hand over to
/// the system (a drag session), through the method it would call. Find (⌘F, ⌘G, Esc); command marks (a
/// failed command, ⌘↑, ⇧⌘↑); ⌃Tab; the right-click menu; ⌘ over a link and ⌘-click; the bell; tab
/// titles; the dividers' double-clicks; a diff's Stage and Revert Change; a tab dropped on a pane.
///
/// Two stand-ins, as `KeyStandIn` is one: the keys held (`NSEvent.modifierFlags`, which asks the
/// keyboard itself) are the ones the run's events hold, and the pointer (`mouseLocationOutsideOfEventStream`)
/// is where the run's events put it. Nothing here may make a sound: every check leaves the app no reason
/// to beep (a search that finds, a jump with somewhere to go, a bell only in a tab out of sight). Find's
/// text and the clipboard are the run's own pasteboards (`DebugScript.keepOutOfSight`), not this Mac's.
extension PerfSuite {
    func interactionsCheck() async {
        HeldKeys.install()
        PointerStandIn.install()
        let base = URL(fileURLWithPath: folder("i1"), isDirectory: true)
        try? Data((1...6).map { "note line \($0)" }.joined(separator: "\n").appending("\n").utf8).write(to: base.appendingPathComponent("notes.txt"))
        try? Data((1...4).map { "spaced line \($0)" }.joined(separator: "\n").appending("\n").utf8).write(to: base.appendingPathComponent("my notes.txt"))
        let first = workbench.newWorkspace(folder: base.path)
        guard await shellReady(first) else { return check("interactions: the first shell drew its prompt", false) }
        print("interactions: the window counts as looked at: \(workbench.isLookingAtWindow)")
        await findCheck(first)
        await marksCheck(first)
        await dividersCheck()
        await tabSwitcherCheck()
        await diffAndDropCheck()
        // Last: a crash here (exit 70) leaves every other line said.
        workbench.select(workspace: workbench.workspaces.first { $0.tabs.contains { $0.tree.contains(first.id) } } ?? workbench.workspaces[0])
        let links = workbench.newTab()
        guard await shellReady(links) else { return check("interactions: the links tab's shell drew its prompt", false) }
        await linksCheck(links)
        HeldKeys.flags = nil
        PointerStandIn.location = nil
    }

    // MARK: Helpers (also `DebugFlowFiles`'s)

    /// The pane's rows as drawn, not trimmed (columns stay where they are on screen).
    func drawnRows(_ pane: Pane) -> [String] {
        pane.surface.visibleRowsText(0..<pane.surface.terminalDimensions.rows)
    }

    /// The visible row whose text is exactly `text` (an output line, not the command that printed it).
    func row(_ pane: Pane, showing text: String) -> Int? {
        drawnRows(pane).firstIndex { $0.trimmingCharacters(in: .whitespaces) == text }
    }

    /// The middle of a cell of the terminal's grid, in the terminal view (as `TerminalSurface.cell(at:)` reads it).
    func cellPoint(_ pane: Pane, row: Int, column: Int) -> NSPoint {
        let surface = pane.surface
        let dimensions = surface.terminalDimensions
        let grid = surface.getOptimalFrameSize().size
        let width = grid.width / CGFloat(max(dimensions.cols, 1)), height = grid.height / CGFloat(max(dimensions.rows, 1))
        return NSPoint(x: (CGFloat(column) + 0.5) * width, y: surface.bounds.height - (CGFloat(row) + 0.5) * height)
    }

    /// The top row of the terminal's view, counted from the first line it keeps.
    func topRow(_ pane: Pane) -> Int? { pane.surface.reach?.locked { terminal, _ in terminal.buffer.yDisp } }

    /// ⌃, ⌘ and the rest pressed or let go: the keys held from now on, and the event saying so.
    func hold(_ flags: NSEvent.ModifierFlags, code: UInt16) {
        HeldKeys.flags = flags
        if let event = NSEvent.keyEvent(with: .flagsChanged, location: PointerStandIn.location ?? .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) {
            NSApp.sendEvent(event)
        }
    }

    /// A key pressed with modifiers, through the app's whole event path (its key monitors first).
    func press(_ characters: String, ignoring: String? = nil, modifiers: NSEvent.ModifierFlags, code: UInt16) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: code) {
            NSApp.sendEvent(event)
        }
    }

    func mouse(_ type: NSEvent.EventType, at location: NSPoint, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: count,
                           pressure: [.leftMouseDown, .rightMouseDown].contains(type) ? 1 : 0)
    }

    /// A double-click at a point in `view`: each release queued before its press, since a press on a
    /// divider starts a tracking loop that waits for it. Returns the view the window delivered it to.
    @discardableResult
    func doubleClick(_ view: NSView, at point: NSPoint) -> NSView? {
        let location = view.convert(point, to: nil)
        PointerStandIn.location = location
        let target = hit(view, at: point)
        for count in 1...2 {
            guard let down = mouse(.leftMouseDown, at: location, count: count), let up = mouse(.leftMouseUp, at: location, count: count) else { continue }
            QueuedEvents.post(up)
            NSApp.sendEvent(down)
        }
        return target
    }

    func name(_ view: NSView?) -> String { view.map { String(describing: type(of: $0)) } ?? "nothing" }

    private func waited(_ time: Double?, since start: Double) -> String { time.map { "\(Self.ms($0 - start)) ms" } ?? "never" }

    // MARK: Find

    /// Three lines with the term, then ⌘F: the bar with the keyboard in its field; the term typed: "n of 3";
    /// ⌘G: the next; Esc: the bar gone and the keyboard back in the terminal.
    private func findCheck(_ pane: Pane) async {
        // Printed through a format, so the command line itself never holds the term.
        pane.type("clear; printf 'Z%sX one\\nZ%sX two\\nZ%sX three\\n' Q Q Q\r")
        guard await PerfWait.until(5000, { self.row(pane, showing: "ZQX three") != nil }) != nil else { return check("find: the text printed", false) }
        await PerfWait.sleep(200)
        let surface = pane.surface
        let down = perfNow()
        shortcut("cmd+f")
        let shown = await PerfWait.until(2000) { surface.isFindShown && surface.findBar?.hasKeyboard == true }
        check("find: ⌘F shows the bar with the keyboard in its field", shown != nil, "first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        limit("find: ⌘F to the bar shown with the keyboard, ms", shown.map { $0 - down }, atMost: 50)
        guard shown != nil, let bar = surface.findBar else { return }
        // The bar's count: its one label (the field is the only text it takes).
        let count = { (DebugShell.descendant(of: bar) { ($0 as? NSTextField)?.isEditable == false } as? NSTextField)?.stringValue ?? "" }
        let index = { () -> Int? in
            let parts = count().split(separator: " ")
            return parts.count == 3 && parts[2] == "3" ? Int(parts[0]) : nil
        }
        typeKeys("ZQX")
        let counted = await PerfWait.until(2000) { index() != nil }
        check("find: typing the term shows which match of three", counted != nil, "count “\(count())”")
        if let before = index() {
            press("g", modifiers: .command, code: 5)
            let stepped = await PerfWait.until(1000) { index() == before % 3 + 1 }
            var routed = ""
            if stepped == nil, let item = NSApp.mainMenu.flatMap({ menuItem(in: $0) { $0.keyEquivalent == "g" && $0.keyEquivalentModifierMask == .command } }) {
                let target = DebugScript.target(for: item, window: window)
                routed = "; the menu's ⌘G goes to \(target.map { String(describing: type(of: $0)) } ?? "nothing")"
                    + ", enabled there \((target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? false)"
            }
            check("find: ⌘G in the bar steps to the next match", stepped != nil,
                  "“\(before) of 3” then “\(count())”, keyboard in \(name(window.firstResponder as? NSView))\(routed)")
            // Return in the field steps too.
            typeKeys("\r")
            let returned = await PerfWait.until(1000) { index() != nil && index() != (stepped == nil ? before : before % 3 + 1) }
            check("find: Return in the bar steps to the next match", returned != nil, "count “\(count())”")
        }
        press("\u{1b}", modifiers: [], code: 53)
        let closed = await PerfWait.until(2000) { !surface.isFindShown && self.window.firstResponder === surface }
        check("find: Esc hides the bar and gives the keyboard back to the terminal", closed != nil,
              "shown \(surface.isFindShown), first responder \(name(window.firstResponder as? NSView))")
        surface.selectNone()
    }

    // MARK: Command marks

    /// `true`, `false`, `echo a; echo b`: the failed mark comes with `false` and goes once the pane has been
    /// seen for a second, or with the next command; ⇧⌘↑ selects what the last command printed; ⌘↑ scrolls
    /// to the prompt above the view.
    private func marksCheck(_ pane: Pane) async {
        let surface = pane.surface
        // Whose marks these are: Whiskr's zsh integration steps aside when the prompt already writes OSC 133.
        pane.type("clear; echo MARKS=${precmd_functions[(I)__whiskr_precmd]}\r")
        _ = await PerfWait.until(3000) { self.drawnRows(pane).contains { $0.hasPrefix("MARKS=") } }
        let source = drawnRows(pane).first { $0.hasPrefix("MARKS=") }.map { $0.trimmingCharacters(in: .whitespaces) == "MARKS=0" ? "the shell's own prompt" : "Whiskr's integration" } ?? "unknown"
        print("interactions: command marks written by \(source)")
        pane.type("true\r")
        await PerfWait.sleep(400)
        check("marks: `true` leaves no failed mark", pane.failedCommand == nil, "marks from \(source)")
        // Out of sight (another tab shown), so only the shell's marks change it; the window looked at.
        guard let home = workbench.selectedTab else { return }
        let other = workbench.newTab()
        _ = await shellReady(other)
        let looking = workbench.isLookingAtWindow
        workbench.isLookingAtWindow = true
        defer { workbench.isLookingAtWindow = looking }
        pane.type("false\r")
        var failed = await PerfWait.until(3000) { pane.failedCommand == 1 }
        check("marks: `false` shows the failed mark, status 1", failed != nil, "failedCommand \(pane.failedCommand.map(String.init) ?? "nil"), marks from \(source)")
        await PerfWait.sleep(1200)
        check("marks: out of sight, the failed mark stays", pane.failedCommand == 1)
        pane.type("true\r")
        let cleared = await PerfWait.until(3000) { pane.failedCommand == nil }
        check("marks: the next command clears the failed mark", failed != nil && cleared != nil, "failedCommand \(pane.failedCommand.map(String.init) ?? "nil")")
        pane.type("false\r")
        failed = await PerfWait.until(3000) { pane.failedCommand == 1 }
        let shown = perfNow()
        workbench.select(tab: home)
        let seen = await PerfWait.until(3000) { pane.failedCommand == nil }
        check("marks: shown again, the failed mark clears once seen for a second", failed != nil && seen.map { $0 - shown >= 900 } ?? false,
              "cleared after \(waited(seen, since: shown))")
        _ = await PerfWait.until(2000) { self.focused(pane) }
        pane.type("echo a; echo b\r")
        _ = await PerfWait.until(3000) { self.row(pane, showing: "b") != nil }
        await PerfWait.sleep(400)
        shortcut("cmd+shift+up")
        let selected = await PerfWait.until(2000) { surface.getSelection() != nil }
        let text = surface.getSelection().map { $0.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
            .map { Array($0.reversed().drop { $0.isEmpty }.reversed()).joined(separator: "\n") }
        check("marks: ⇧⌘↑ selects what the last command printed", selected != nil && text == "a\nb", "selected “\(text?.replacingOccurrences(of: "\n", with: "⏎") ?? "nothing")”")
        surface.selectNone()
        // Enough output that the prompts before it are above the view.
        pane.type("seq 1 300\r")
        _ = await PerfWait.until(5000) { self.row(pane, showing: "300") != nil }
        await PerfWait.sleep(400)
        let before = topRow(pane), target = surface.previousSemanticPromptRow()
        shortcut("cmd+up")
        let moved = await PerfWait.until(2000) { self.topRow(pane) != before }
        let after = topRow(pane)
        let height = surface.terminalDimensions.rows
        check("marks: ⌘↑ scrolls back to the prompt above the view", moved != nil && target.map { row in after.map { (row - height + 1...row).contains($0) } ?? false } ?? false,
              "top row \(before.map(String.init) ?? "?") → \(after.map(String.init) ?? "?"), prompt above \(target.map(String.init) ?? "none")")
        let further = surface.previousSemanticPromptRow()
        check("marks: after ⌘↑ the previous prompt is an earlier one", target != nil && further.map { $0 < target! } ?? false,
              "\(target.map(String.init) ?? "none") then \(further.map(String.init) ?? "none")")
        surface.scroll(toPosition: 1)
        pane.type("clear\r")
        await PerfWait.sleep(300)
    }

    // MARK: The right-click menu, ⌘ and links

    private func linksCheck(_ pane: Pane) async {
        let surface = pane.surface
        pane.type("clear; echo hello worldly; echo notes.txt:3:2; echo '\"my notes.txt\", line 2'\r")
        guard await PerfWait.until(5000, { self.row(pane, showing: "\"my notes.txt\", line 2") != nil }) != nil,
              let wordRow = row(pane, showing: "hello worldly"), let pathRow = row(pane, showing: "notes.txt:3:2"),
              let quotedRow = row(pane, showing: "\"my notes.txt\", line 2") else { return check("links: the text printed", false) }
        await PerfWait.sleep(300)
        guard let tab = workbench.selectedTab else { return }

        // No selection: the word under the pointer is selected, and the menu is the terminal's.
        surface.selectNone()
        let word = cellPoint(pane, row: wordRow, column: 8)
        let menu = rightClickMenu(surface, at: word)
        check("right-click: the word under the pointer is selected", surface.getSelection() == "worldly", "selected “\(surface.getSelection() ?? "nothing")”")
        let expected = [String(localized: "Copy"), String(localized: "Paste"), String(localized: "Select All"), "—", String(localized: "Find…"),
                        String(localized: "Clear", comment: "Edit menu: clears the terminal's scrollback"), "—",
                        String(localized: "Split Right"), String(localized: "Split Down"), String(localized: "Zoom Pane")]
        check("right-click: the menu holds the terminal's items in order", menu.map(titles) == expected, menu.map(titles)?.joined(separator: " · ") ?? "no menu")
        surface.selectNone()
        let path = cellPoint(pane, row: pathRow, column: 2)
        let pathMenu = rightClickMenu(surface, at: path)
        let opening = [String(localized: "Open", comment: "Terminal menu: opens the file under the pointer"), String(localized: "Reveal in Files"), String(localized: "Copy Path"), "—"]
        check("right-click: over a printed file the menu starts with Open, Reveal in Files, Copy Path",
              pathMenu.map { Array(titles($0).prefix(4)) } == opening, pathMenu.map(titles)?.joined(separator: " · ") ?? "no menu")
        surface.selectNone()

        // ⌘ held over the path underlines it: pressed while the pointer rests there, or moving with it held.
        await hover(surface, at: path)
        hold(.command, code: 55)
        let byPress = await PerfWait.until(1000) { surface.linkUnderline?.isHidden == false } != nil
        var byMove = false
        if !byPress, let moved = mouse(.mouseMoved, at: surface.convert(path, to: nil), modifiers: .command) {
            window.sendEvent(moved)
            byMove = await PerfWait.until(1000) { surface.linkUnderline?.isHidden == false } != nil
        }
        check("⌘ over a printed path underlines it", byPress || byMove, "by pressing ⌘ there \(byPress), by moving with ⌘ held \(byMove)")
        hold([], code: 55)
        let hidden = await PerfWait.until(1000) { surface.linkUnderline?.isHidden != false }
        check("letting go of ⌘ takes the underline away", hidden != nil)

        // ⌘-click: the file opens in the editor at its line (and column).
        for (point, file, line, column) in [(path, "notes.txt", 3, 2), (cellPoint(pane, row: quotedRow, column: 3), "my notes.txt", 2, 1)] {
            let target = hit(surface, at: point)
            let down = perfNow()
            commandClick(surface, at: point)
            let opened = await PerfWait.until(3000) { self.editorPlace(file: file).map { $0.line == line && $0.column == column } ?? false }
            check("⌘-click on “\(file)” opens it in the editor at line \(line)", opened != nil,
                  "click went to \(name(target)); editor at \(editorPlace(file: file).map { "\($0.line):\($0.column)" } ?? "no editor"), page \(workbench.focusedPage.map { "\($0)" } ?? "none")")
            limit("⌘-click on “\(file)” to its line shown in the editor, ms", opened.map { $0 - down }, atMost: 250)
            workbench.select(tab: tab)
            _ = await PerfWait.until(2000) { self.focused(pane) }
        }

        // Split Right from the menu over the path.
        guard let item = rightClickMenu(surface, at: path)?.items.first(where: { $0.action == #selector(MainWindowController.splitRight(_:)) }),
              let action = item.action, let target = DebugScript.target(for: item, window: window) else { return check("right-click: Split Right has somewhere to go", false) }
        NSApp.sendAction(action, to: target, from: item)
        let split = await PerfWait.until(2000) { tab.tree.panes.count == 2 }
        check("right-click: Split Right from the menu splits the pane", split != nil, "\(tab.tree.panes.count) panes, sent to \(String(describing: type(of: target)))")
        surface.selectNone()
    }

    /// The terminal's menu for a right-click there, as AppKit asks for it before showing it (it is never
    /// shown: a context menu would come up on screen).
    func rightClickMenu(_ surface: TerminalSurface, at point: NSPoint) -> NSMenu? {
        let location = surface.convert(point, to: nil)
        PointerStandIn.location = location
        return mouse(.rightMouseDown, at: location).flatMap { surface.menu(for: $0) }
    }

    /// The first item of a menu or its submenus that passes `test`.
    func menuItem(in menu: NSMenu, where test: (NSMenuItem) -> Bool) -> NSMenuItem? {
        for item in menu.items {
            if test(item) { return item }
            if let found = item.submenu.flatMap({ menuItem(in: $0, where: test) }) { return found }
        }
        return nil
    }

    func titles(_ menu: NSMenu) -> [String] { menu.items.map { $0.isSeparatorItem ? "—" : $0.title } }

    func commandClick(_ view: NSView, at point: NSPoint) {
        let location = view.convert(point, to: nil)
        PointerStandIn.location = location
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = mouse(type, at: location, modifiers: .command) { NSApp.sendEvent(event) }
        }
    }

    /// The focused editor's file is `file`: the line and column of its insertion point.
    func editorPlace(file: String) -> (line: Int, column: Int)? {
        guard case .file(let path) = workbench.focusedPage, URL(fileURLWithPath: path).lastPathComponent == file,
              let id = workbench.focusedPageID, let page = controller.terminals.paneArea.pageView(id),
              let editor = DebugShell.descendant(of: page, where: { $0 is NSTextView }) as? NSTextView else { return nil }
        let before = (editor.string as NSString).substring(to: min(editor.selectedRange().location, (editor.string as NSString).length))
        let lines = before.components(separatedBy: "\n")
        return (lines.count, (lines.last?.count ?? 0) + 1)
    }

    // MARK: Dividers

    /// A double-click on a pane split's divider shares the room evenly; on the meadow's edge, the default
    /// split; on the Files panel's edge, its usual width.
    private func dividersCheck() async {
        guard let workspace = workbench.selectedWorkspace, let tab = workbench.selectedTab else { return }
        // A split of its own (⌘D).
        shortcut("cmd+d")
        _ = await PerfWait.until(2000) { tab.tree.panes.count == 2 }
        await PerfWait.sleep(400)
        if let split = DebugShell.descendant(of: controller.terminals.paneArea, where: { $0 is RatioSplitView }) as? RatioSplitView, split.subviews.count == 2 {
            // Dragged off the middle first, as `sizesCheck` drags.
            let start = split.convert(NSPoint(x: split.subviews[0].frame.maxX + 0.5, y: split.bounds.midY), to: nil)
            for step in 1...8 {
                if let drag = mouse(step == 8 ? .leftMouseUp : .leftMouseDragged, at: NSPoint(x: start.x - CGFloat(step * 15), y: start.y)) { QueuedEvents.post(drag) }
            }
            if let down = mouse(.leftMouseDown, at: start) { NSApp.sendEvent(down) }
            await PerfWait.sleep(400)
            let dragged = split.subviews.map(\.frame.width)
            let target = doubleClick(split, at: NSPoint(x: split.subviews[0].frame.maxX + 0.5, y: split.bounds.midY))
            let even = await PerfWait.until(1000) { abs(split.subviews[0].frame.width - split.subviews[1].frame.width) <= 2 }
            check("double-click on a pane divider shares the room evenly", even != nil && abs(dragged[0] - dragged[1]) > 20,
                  "widths dragged \(dragged.map { Int($0) }), then \(split.subviews.map { Int($0.frame.width) }); clicks went to \(name(target))")
        } else {
            check("double-click on a pane divider: a split to try it on", false)
        }

        // The meadow's edge.
        controller.debugSetLayout { $0.dragDivider(to: 420, window: Double(self.window.frame.width)) }
        await PerfWait.sleep(600)
        let regions = window.contentView.flatMap { DebugShell.descendant(of: $0.superview ?? $0) { $0 is RegionsSplitView } } as? RegionsSplitView
        if let regions, regions.arrangedSubviews.count == 2 {
            let meadow = regions.arrangedSubviews[0]
            let target = doubleClick(regions, at: NSPoint(x: meadow.frame.maxX + 0.5, y: regions.bounds.midY))
            let reset = await PerfWait.until(1000) { self.controller.layout.navigatorWidth == nil && self.controller.layout.mode == .split }
            await PerfWait.sleep(600)
            let expected = WindowLayout().frame(window: Double(regions.bounds.width)).navigator
            check("double-click on the meadow's edge gives back the default split", reset != nil,
                  "meadow \(Int(meadow.frame.width)) pt (default \(Int(expected))), its split view's views \(regions.subviews.map { String(describing: type(of: $0)) }); clicks went to \(name(target))")
        } else {
            check("double-click on the meadow's edge: the edge found", false, regions.map { "its views \($0.subviews.map { "\(type(of: $0)) \(Int($0.frame.width))" })" } ?? "no split view")
        }

        // The Files panel's edge.
        workbench.files.setPanel(workspace.id) { $0.shown = true; $0.width = 420 }
        await PerfWait.sleep(600)
        if let edge = DebugShell.descendant(of: controller.terminals.view, where: { $0 is PanelEdge && !$0.isHiddenOrHasHiddenAncestor }) {
            let before = edge.convert(edge.bounds, to: nil).midX
            let target = doubleClick(edge, at: NSPoint(x: edge.bounds.midX, y: edge.bounds.midY))
            let reset = await PerfWait.until(1000) { self.workbench.files.panel(workspace.id).width == FilesCenter.panelDefault }
            await PerfWait.sleep(300)
            let moved = edge.convert(edge.bounds, to: nil).midX - before
            check("double-click on the Files panel's edge gives back its usual width", reset != nil && abs(moved - CGFloat(420 - FilesCenter.panelDefault)) <= 2,
                  "width \(workbench.files.panel(workspace.id).width), edge moved \(Int(moved)) pt; clicks went to \(name(target))")
        } else {
            check("double-click on the Files panel's edge: the edge found", false)
        }
        workbench.files.setPanel(workspace.id) { $0.shown = false }
        await PerfWait.sleep(400)
    }

    // MARK: ⌃Tab, the bell, tab titles

    /// ⌃Tab pressed, queued for the app as a real key is: the switcher reads ⌃ off the event the run loop
    /// took (`NSApp.currentEvent`). A background app is never active, so its menus are not offered key
    /// equivalents; they are here, from within the event's own dispatch, as the active app's would be.
    private func controlTab() async {
        var taken = false
        let menus = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 48, event.modifierFlags.contains(.control), let self else { return event }
            taken = true
            self.shortcut("ctrl+tab")
            return nil
        }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) {
            QueuedEvents.post(event)
        }
        _ = await PerfWait.until(1000) { taken }
        if let menus { NSEvent.removeMonitor(menus) }
    }

    /// Three tabs shown A, B, C: a ⌃Tab tap goes back to B; ⌃ held, Tab twice, let go: A; the list only
    /// once ⌃ has been held 0.2 s; Esc stays; a key typed with ⌃ still held opens the chosen tab and reaches
    /// its terminal. Then a bell out of sight, and the titles of a command that stays and one that does not.
    private func tabSwitcherCheck() async {
        let a = workbench.newWorkspace(folder: folder("i2"))
        let b = workbench.newTab(), c = workbench.newTab()
        for pane in [a, b, c] { guard await shellReady(pane) else { return check("⌃Tab: three shells ready", false) } }
        guard let workspace = workbench.selectedWorkspace, workspace.tabs.count == 3, let switcher = controller.tabSwitcher else { return }
        let (tabA, tabB, tabC) = (workspace.tabs[0], workspace.tabs[1], workspace.tabs[2])
        for tab in [tabA, tabB, tabC] { workbench.select(tab: tab); await PerfWait.sleep(150) }
        let shown = { (tab: Tab, pane: Pane) in self.workbench.selectedTab === tab && self.focused(pane) }
        // Which of the three, by its letter (all three are titled by the same folder).
        let letter = { (id: UUID?) -> String in [tabA.id: "A", tabB.id: "B", tabC.id: "C"][id ?? UUID()] ?? "none" }
        let state = { "on \(letter(self.workbench.selectedTab?.id)), keyboard in \(self.focused(a) ? "A" : self.focused(b) ? "B" : self.focused(c) ? "C" : self.name(self.window.firstResponder as? NSView)), switching \(switcher.isActive), list \(switcher.debugShowsList)" }

        // A tap: ⌃Tab, ⌃ let go 60 ms later.
        hold(.control, code: 59)
        let tapped = perfNow()
        await controlTab()
        await PerfWait.sleep(60)
        let listDuringTap = switcher.debugShowsList
        hold([], code: 59)
        let back = await PerfWait.until(1000) { shown(tabB, b) }
        check("⌃Tab tap goes back to the tab shown before, with the keyboard, no list", back != nil && !listDuringTap,
              "\(state()), list during the tap \(listDuringTap)")
        limit("⌃Tab tap: ⌃ let go to the tab before shown with the keyboard, ms", back.map { $0 - tapped - 60 }, atMost: 50)
        await PerfWait.sleep(300)

        // Held: the list after 0.2 s; Tab again; let go.
        hold(.control, code: 59)
        let held = perfNow()
        await controlTab()
        await PerfWait.sleep(100)
        let early = switcher.debugShowsList
        let listed = await PerfWait.until(1000) { switcher.debugShowsList }
        check("⌃Tab held: the list shows only once ⌃ has been held 0.2 s", !early && listed.map { $0 - held >= 190 } ?? false,
              "at 100 ms \(early), shown after \(waited(listed, since: held))")
        press("\t", modifiers: .control, code: 48)
        let chosen = switcher.debugChosen
        hold([], code: 59)
        let reached = await PerfWait.until(1000) { shown(tabA, a) }
        check("⌃ held, Tab twice, let go: the tab shown two before", reached != nil && chosen == tabA.id && !switcher.debugShowsList,
              "chosen \(letter(chosen)), \(state())")
        await PerfWait.sleep(300)

        // Esc: nothing changes.
        hold(.control, code: 59)
        await controlTab()
        await PerfWait.sleep(300)
        let begun = state()
        press("\u{1b}", modifiers: .control, code: 53)
        let gone = !switcher.isActive && !switcher.debugShowsList
        hold([], code: 59)
        await PerfWait.sleep(200)
        check("⌃Tab, then Esc: stays on the tab, the list gone", gone && shown(tabA, a), "before Esc \(begun); after \(state())")

        // A key typed with ⌃ still held: the chosen tab opens and its terminal gets the key (⌃U empties the line).
        b.type("echo SWQ")
        _ = await PerfWait.until(2000) { self.drawnRows(b).contains { $0.contains("echo SWQ") } }
        hold(.control, code: 59)
        await controlTab()
        await PerfWait.sleep(80)
        press("\u{15}", ignoring: "u", modifiers: .control, code: 32)
        hold([], code: 59)
        let opened = await PerfWait.until(1000) { shown(tabB, b) }
        let took = await PerfWait.until(2000) { !self.drawnRows(b).contains { $0.contains("echo SWQ") } }
        check("⌃Tab, then a key with ⌃ held: the tab opens and its terminal gets the key", opened != nil && took != nil,
              "\(state()), line emptied \(took != nil)")

        await bellCheck(ringing: c, in: tabC, from: tabB)
        workbench.select(tab: tabA)
        _ = await PerfWait.until(1000) { shown(tabA, a) }
        await titlesCheck(a, in: tabA)
    }

    /// A bell in a tab out of sight marks it; looked at for a second, the mark goes. Never rung in the tab
    /// on show (that one would sound).
    private func bellCheck(ringing pane: Pane, in tab: Tab, from shownTab: Tab) async {
        if workbench.selectedTab !== shownTab {
            workbench.select(tab: shownTab)
            await PerfWait.sleep(300)
        }
        pane.type("sleep 0.3; printf '\\a'\r")
        let rang = await PerfWait.until(3000) { self.workbench.rang(in: tab) }
        check("bell: a tab out of sight shows the bell", rang != nil)
        workbench.isLookingAtWindow = true
        let selected = perfNow()
        workbench.select(tab: tab)
        await PerfWait.sleep(400)
        let stillAt400 = workbench.rang(in: tab)
        let cleared = await PerfWait.until(3000) { !self.workbench.rang(in: tab) }
        workbench.isLookingAtWindow = false
        check("bell: the mark stays a moment on show, then goes after a second", rang != nil && stillAt400 && cleared.map { $0 - selected >= 900 } ?? false,
              "still there at 400 ms \(stillAt400), gone after \(waited(cleared, since: selected))")
    }

    /// `sleep 2` names the tab "sleep" from 0.4 s in, the folder again once it ends; `ls` never retitles it.
    private func titlesCheck(_ pane: Pane, in tab: Tab) async {
        let folder = workbench.folderName(pane.currentFolder)
        func sample(_ milliseconds: Double) async -> [(at: Double, title: String)] {
            let start = perfNow()
            var seen: [(at: Double, title: String)] = []
            while perfNow() - start < milliseconds {
                seen.append((perfNow() - start, workbench.title(of: tab)))
                await PerfWait.sleep(20)
            }
            return seen
        }
        pane.type("sleep 2\r")
        let sleeping = await sample(3200)
        let named = sleeping.filter { $0.title == "sleep" }
        let others = Set(sleeping.map(\.title)).subtracting([folder, "sleep"])
        let first = named.first?.at, last = named.last?.at
        check("titles: `sleep 2` names its tab after 0.4 s, and the folder comes back when it ends",
              others.isEmpty && first.map { $0 >= 380 && $0 <= 900 } ?? false && last.map { $0 >= 1900 && $0 <= 2800 } ?? false && sleeping.last?.title == folder,
              "“sleep” from \(Self.ms(first)) to \(Self.ms(last)) ms, other titles \(others.sorted()), last “\(sleeping.last?.title ?? "-")”")
        pane.type("ls\r")
        let listing = await sample(1500)
        let changed = Set(listing.map(\.title)).subtracting([folder])
        check("titles: `ls` never retitles its tab", changed.isEmpty, "titles seen \(Set(listing.map(\.title)).sorted())")
    }

    // MARK: A diff's changes, and a tab dropped on a pane

    /// A scratch repository with two changes to one file: Stage Change on the first (the pointer over it,
    /// its button pressed) stages it alone; Revert Change on the other reverts it alone. Then a tab dropped
    /// beside a pane, and one dropped in a pane's middle (`dropTab`, what a drop calls: a drag session
    /// cannot be run in a window nobody sees).
    private func diffAndDropCheck() async {
        let repo = URL(fileURLWithPath: folder("repo"), isDirectory: true)
        let file = repo.appendingPathComponent("story.txt")
        var lines = (1...30).map { "line \($0)" }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        guard git(["init", "-q", "-b", "main"], in: repo) != nil, git(["add", "story.txt"], in: repo) != nil,
              git(["-c", "user.name=Whiskr perf", "-c", "user.email=perf@example.invalid", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "first"], in: repo) != nil else {
            return check("diff: a scratch repository", false)
        }
        lines[2] = "line 3, changed"
        lines[25] = "line 26, changed"
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let first = workbench.newWorkspace(folder: repo.path)
        guard await shellReady(first), let workspace = workbench.selectedWorkspace else { return check("diff: the repository's shell ready", false) }
        workbench.openChanges(path: file.path, staged: false, mode: .keep)
        var diff: DiffPageView?
        var table: NSTableView?
        _ = await PerfWait.until(5000) {
            diff = DebugShell.descendant(of: self.controller.terminals.paneArea) { $0 is DiffPageView && !$0.isHiddenOrHasHiddenAncestor } as? DiffPageView
            table = diff.flatMap { DebugShell.descendant(of: $0) { $0 is NSTableView } as? NSTableView }
            return (table?.numberOfRows ?? 0) > 0
        }
        if let diff, let table {
            let staged = await pressChangeAction(String(localized: "Stage Change"), diff: diff, table: table)
            let done = await PerfWait.until(5000) {
                let index = self.git(["diff", "--cached"], in: repo) ?? "", work = self.git(["diff"], in: repo) ?? ""
                return index.contains("+line 3, changed") && !index.contains("+line 26, changed") && work.contains("+line 26, changed") && !work.contains("+line 3, changed")
            }
            check("diff: Stage Change over the first change stages it alone", done != nil, staged)
            // The diff reads the repository again: one change left, the second.
            _ = await PerfWait.until(3000) { table.numberOfRows > 0 }
            await PerfWait.sleep(500)
            let reverted = await pressChangeAction(String(localized: "Revert Change"), diff: diff, table: table)
            let back = await PerfWait.until(5000) {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                return text.contains("line 26\n") && text.contains("line 3, changed") && (self.git(["diff"], in: repo) ?? "x").isEmpty
            }
            check("diff: Revert Change over the other change reverts it alone", back != nil, reverted)
        } else {
            check("diff: the changes shown", false, "page \(workbench.focusedPage.map { "\($0)" } ?? "none")")
        }

        // Dropped beside a pane: its tab leaves the row, its terminal goes on as it was.
        guard let home = workspace.tabs.first(where: { $0.tree.contains(first.id) }) else { return }
        let dropped = workbench.newTab()
        _ = await shellReady(dropped)
        dropped.type("echo DROPPED\r")
        _ = await PerfWait.until(3000) { self.row(dropped, showing: "DROPPED") != nil }
        guard let droppedTab = workbench.selectedTab else { return }
        let count = workspace.tabs.count
        workbench.dropTab(droppedTab, onto: first.id, side: .right)
        let beside = await PerfWait.until(2000) { home.tree.panes == [first.id, dropped.id] && self.focused(dropped) }
        check("a tab dropped on a pane's right edge goes beside it, still running, with the keyboard",
              beside != nil && workspace.tabs.count == count - 1 && workbench.panes[dropped.id] === dropped && row(dropped, showing: "DROPPED") != nil,
              "panes \(home.tree.panes.count), tabs \(count) → \(workspace.tabs.count), its output kept \(row(dropped, showing: "DROPPED") != nil)")
        // Dropped in a pane's middle: the tab takes that tab's place in the row, and shows.
        let moved = workbench.newTab()
        _ = await shellReady(moved)
        guard let movedTab = workbench.selectedTab, let index = workspace.tabs.firstIndex(where: { $0 === home }) else { return }
        workbench.select(tab: home)
        workbench.dropTab(movedTab, onto: first.id, side: nil)
        let placed = await PerfWait.until(2000) { workspace.tabs.firstIndex { $0 === movedTab } == index && self.workbench.selectedTab === movedTab && self.focused(moved) }
        check("a tab dropped in a pane's middle takes its tab's place in the row and shows", placed != nil,
              "at \(workspace.tabs.firstIndex { $0 === movedTab }.map(String.init) ?? "-") (expected \(index)), selected “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")”")
    }

    /// The pointer moved down the diff's rows until a change's buttons show, then the one named clicked.
    /// Says what happened.
    func pressChangeAction(_ title: String, diff: DiffPageView, table: NSTableView) async -> String {
        guard let actions = diff.subviews.first(where: { String(describing: type(of: $0)).contains("ChangeActions") }) else { return "no buttons" }
        // The diff may still be reading the repository: down the rows again for up to three seconds.
        let start = perfNow()
        while perfNow() - start < 3000 {
        for row in 0..<table.numberOfRows {
            let rect = table.rect(ofRow: row)
            guard let moved = mouse(.mouseMoved, at: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)) else { continue }
            PointerStandIn.location = moved.locationInWindow
            window.sendEvent(moved)
            guard !actions.isHidden else { continue }
            await PerfWait.sleep(100)
            // A click on the button, where it is drawn: Revert Change then Stage Change, side by side (Stage
            // alone in a staged diff).
            let point = NSPoint(x: actions.bounds.width * (title == String(localized: "Revert Change") ? 0.25 : 0.75), y: actions.bounds.midY)
            await hover(actions, at: point)
            let landing = click(actions, at: point)
            return "clicked “\(title)” over row \(row), the click went to \(name(landing))\(landing.map { $0.isDescendant(of: actions) } ?? false ? "" : " (not the buttons)")"
        }
        await PerfWait.sleep(200)
        }
        return "no buttons over any of \(table.numberOfRows) rows"
    }

    /// git in the scratch repository only, with none of this Mac's settings: its output, nil if it failed.
    func git(_ arguments: [String], in folder: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}

/// The keys held, as the run's own events say (`NSEvent.modifierFlags` asks the keyboard, which nobody
/// here touches): nil leaves the question to the keyboard.
@MainActor
enum HeldKeys {
    nonisolated(unsafe) static var flags: NSEvent.ModifierFlags?
    private static var installed = false

    static func install() {
        guard !installed, let from = class_getClassMethod(NSEvent.self, NSSelectorFromString("modifierFlags")),
              let to = class_getClassMethod(NSEvent.self, #selector(NSEvent.debugPerfModifierFlags)) else { return }
        installed = true
        method_exchangeImplementations(from, to)
    }
}

/// Where the pointer is, as the run's own events put it (`mouseLocationOutsideOfEventStream` asks the
/// real pointer, which is anywhere): nil leaves the question to it.
@MainActor
enum PointerStandIn {
    /// Moving it also does what the window server does for a real pointer: tracking areas hear it.
    nonisolated(unsafe) static var location: NSPoint? {
        didSet {
            guard let location, let window = KeyStandIn.window else { return }
            MainActor.assumeIsolated { TrackingStandIn.move(from: oldValue, to: location, in: window) }
        }
    }
    private static var installed = false

    static func install() {
        guard !installed, let from = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.mouseLocationOutsideOfEventStream)),
              let to = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.debugPerfMouseLocation)) else { return }
        installed = true
        method_exchangeImplementations(from, to)
    }
}

extension NSEvent {
    /// Asked from any thread (SwiftUI's display link too).
    @objc nonisolated class func debugPerfModifierFlags() -> NSEvent.ModifierFlags { HeldKeys.flags ?? debugPerfModifierFlags() }     // the original, exchanged
}

extension NSWindow {
    @objc func debugPerfMouseLocation() -> NSPoint {
        if self === KeyStandIn.window, let location = PointerStandIn.location { return location }
        return debugPerfMouseLocation()     // the original, exchanged
    }
}
/// What the window server tells tracking areas as a real pointer moves, for the run's own pointer: an
/// area the pointer comes into hears `mouseEntered`, one it leaves `mouseExited`, and one that asked for
/// moves `mouseMoved` (hover marks, the diff's change buttons, a link under ⌘). A covered window's real
/// pointer never moves over it, so without this nothing that follows the pointer could be checked.
///
/// As AppKit does, an area put under a pointer that has not moved (a view laid out anew, a tab that slid
/// under it) starts inside without an entered event, and hears `mouseExited` when the pointer leaves; an
/// area removed hears nothing more (a view that replaces its area under the pointer hears its exit through
/// the new one).
@MainActor
enum TrackingStandIn {
    /// Where the pointer is: each area (held, so its identity is never reused while it counts) and its
    /// owner (held weakly: a view may go meanwhile).
    private struct Inside {
        let area: NSTrackingArea
        weak var owner: NSResponder?
        weak var view: NSView?
        /// Still installed: AppKit sends nothing to an area once it is removed (a view that replaces its
        /// area under the pointer hears no exit for the old one; the new one starts inside).
        var installed: Bool { view?.trackingAreas.contains { $0 === area } ?? false }
    }
    private static var inside: [ObjectIdentifier: Inside] = [:]
    /// `from`: where the pointer was until now, whether or not that reached the window.
    static func move(from last: NSPoint?, to location: NSPoint, in window: NSWindow) {
        guard let root = window.contentView?.superview else { return }
        func areas(at point: NSPoint) -> [ObjectIdentifier: (NSTrackingArea, NSView)] {
            var found: [ObjectIdentifier: (NSTrackingArea, NSView)] = [:]
            func walk(_ view: NSView) {
                guard !view.isHidden else { return }
                for area in view.trackingAreas where area.owner != nil {
                    let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                    if view.convert(rect, to: nil).contains(point) { found[ObjectIdentifier(area)] = (area, view) }
                }
                view.subviews.forEach(walk)
            }
            walk(root)
            return found
        }
        // AppKit's rule for an area added since the last move (a view laid out anew, a tab that slid under the
        // pointer): its first state is where the pointer is, so it starts inside without an entered event,
        // and the move that leaves it sends it an exit.
        if let last {
            for (id, (area, view)) in areas(at: last) where inside[id] == nil {
                inside[id] = Inside(area: area, owner: area.owner as? NSResponder, view: view)
            }
        }
        let now = areas(at: location)
        let flags = HeldKeys.flags ?? []
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            type == .mouseMoved
                ? NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
                : NSEvent.enterExitEvent(with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        }
        for (id, area) in inside where now[id] == nil && area.installed {
            if area.area.options.contains(.mouseEnteredAndExited), let event = event(.mouseExited) { area.owner?.mouseExited(with: event) }
        }
        for (id, (area, _)) in now {
            let owner = area.owner as? NSResponder
            if inside[id] == nil, area.options.contains(.mouseEnteredAndExited), let event = event(.mouseEntered) { owner?.mouseEntered(with: event) }
            if area.options.contains(.mouseMoved), let event = event(.mouseMoved) { owner?.mouseMoved(with: event) }
        }
        inside = now.mapValues { Inside(area: $0.0, owner: $0.0.owner as? NSResponder, view: $0.1) }
    }
}
#endif
