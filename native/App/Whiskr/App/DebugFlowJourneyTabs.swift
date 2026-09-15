#if DEBUG
import AppKit
import MeadowScene
import SwiftTerm
import WhiskrKit

/// The journey's tabs, splits and workspaces (`Journey`), each by the keys, clicks and menu items a
/// person uses. A drag of a tab along the row and the menus that pop up (the workspace button's, the
/// chevron's) run sessions of their own that a run nobody sees cannot take part in: those are done through
/// what their drop or their item calls.
extension Journey {
    // MARK: Step 3: tabs

    func tabs() async {
        step("tabs: ⌘T four times")
        guard let workspace = workbench.selectedWorkspace else { return check("tabs: a workspace", false) }
        let start = workspace.tabs.count
        var made: [Pane] = []
        for _ in 0..<4 {
            shortcut("cmd+t")
            guard let pane = workbench.focusedPane else { continue }
            made.append(pane)
            // A key typed straight after ⌘T reaches the new tab's terminal and no other.
            typeKeys("echo tab-\(made.count)\r")
        }
        check("⌘T four times: four new tabs, the last one shown with the keyboard",
              workspace.tabs.count == start + 4 && made.last.map(suite.focused) == true, "tabs \(start) → \(workspace.tabs.count)")
        for (index, pane) in made.enumerated() {
            let echoed = await PerfWait.until(4000) { self.suite.screen(pane).contains("tab-\(index + 1)") }
            let elsewhere = made.enumerated().filter { $0.offset != index }.contains { self.suite.screen($0.element).contains("tab-\(index + 1)") }
            check("keys typed straight after ⌘T reach that tab's terminal only (tab \(index + 1))", echoed != nil && !elsewhere)
        }

        step("tabs: rename by a double-click")
        if let tab = workbench.selectedTab, let view = suite.tabView(tab) {
            doubleClick(view, at: NSPoint(x: view.bounds.midX - 20, y: view.bounds.midY))
            let editing = await PerfWait.until(2000) { self.workbench.renamingTabID == tab.id && self.window.firstResponder is NSText }
            check("a double-click on a tab edits its name in place", editing != nil, "renaming \(workbench.renamingTabID == tab.id), first responder \(describe(window.firstResponder))")
            if editing != nil {
                press("a", code: 0, modifiers: .command)
                typeKeys("build\r")
                let renamed = await PerfWait.until(2000) { tab.name == "build" && self.workbench.renamingTabID == nil }
                check("typing a name and Return renames the tab", renamed != nil, "name “\(tab.name ?? "-")”, title “\(workbench.title(of: tab))”")
                let back = await PerfWait.until(2000) { made.last.map(self.suite.focused) == true }
                check("after renaming, the keyboard is back in the tab's terminal", back != nil, "first responder \(describe(window.firstResponder))")
            }
            typeKeys("sleep 0.6\r")
            let titles = await sampleTitles(tab, for: 1500)
            check("a renamed tab keeps its name while programs run", Set(titles) == ["build"], "titles \(Array(Set(titles)).sorted())")
        }
        step("tabs: rename from File › Rename Tab…")
        shortcut("cmd+shift+]")
        if let tab = workbench.selectedTab {
            controller.renameTab(nil)
            let editing = await PerfWait.until(2000) { self.window.firstResponder is NSText }
            press("a", code: 0, modifiers: .command)
            typeKeys("logs\r")
            let renamed = await PerfWait.until(2000) { tab.name == "logs" }
            check("Rename Tab… from the menu edits the name in place", editing != nil && renamed != nil, "name “\(tab.name ?? "-")”")
            controller.renameTab(nil)
            let again = await PerfWait.until(2000) { self.window.firstResponder is NSText }
            press("a", code: 0, modifiers: .command)
            press("\u{7f}", code: 51)
            typeKeys("\r")
            let cleared = await PerfWait.until(2000) { tab.name == nil }
            check("an empty name goes back to the tab's own title", cleared != nil, "title “\(workbench.title(of: tab))”, the field had the keyboard \(again != nil), first responder \(describe(window.firstResponder))")
        }

        step("tabs: reorder")
        if workspace.tabs.count >= 3 {
            let moving = workspace.tabs[workspace.tabs.count - 1]
            // What a drag along the row calls as it enters the second tab (`TabDropTarget`).
            workbench.move(tab: moving, toIndex: 1)
            await PerfWait.sleep(200)
            let order = suite.tabViews.map(\.tab)
            check("a tab dragged to second place is second, in the model and on screen", workspace.tabs[1] === moving && order.dropFirst().first == moving.id,
                  "row \(order.map { id in workspace.tabs.firstIndex { $0.id == id } ?? -1 })")
        }

        step("tabs: close by ×, ⌘W, ⌥⌘W; ⌘Z")
        await closing(workspace)
        step("tabs: middle click")
        if let tab = workspace.tabs.last, let view = suite.tabView(tab) {
            let count = workspace.tabs.count
            let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            PointerStandIn.location = location
            // `NSEvent.mouseEvent` cannot say which button: the event is made (never posted) as the window
            // server makes a middle button's, then handed to the window.
            let screen = window.convertPoint(toScreen: location)
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            func middle(_ type: CGEventType) -> NSEvent? {
                guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: screen.x, y: top - screen.y), mouseButton: .center) else { return nil }
                event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                return NSEvent(cgEvent: event)
            }
            if let down = middle(.otherMouseDown), let up = middle(.otherMouseUp) {
                let arrives = down.window === window ? "the window, at \(down.locationInWindow) (pointer at \(location))" : "no window"
                if down.window === window {
                    window.sendEvent(down)
                    window.sendEvent(up)
                } else {
                    // Made outside the window server, the event names no window: it goes where the window would
                    // send it, the view under the pointer.
                    let target = suite.hit(view, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY))
                    target?.otherMouseDown(with: down)
                    target?.otherMouseUp(with: up)
                }
                let closed = await PerfWait.until(2000) { workspace.tabs.count == count - 1 }
                check("a middle click on a tab closes it", closed != nil, "button \(down.buttonNumber) to \(arrives), tabs \(count) → \(workspace.tabs.count)")
            }
        }
        await overflow()
        await closeAll()
    }

    /// × on a tab not shown, ⌘W on a split pane and on a lone one, ⌥⌘W; ⌘Z brings the last back with its
    /// process; ⇧⌘T reopens one whose moment has passed.
    private func closing(_ workspace: Workspace) async {
        guard workspace.tabs.count >= 4 else { return check("closing: four tabs to close", false) }
        // The pointer resting on a tab's ×, the row laid out again meanwhile (a title changing): its tooltip
        // comes up (it once came up for an owner already gone, and the app crashed).
        if let tab = workbench.selectedTab, let view = suite.tabView(tab) {
            await suite.hover(view, at: view.closePoint)
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            await PerfWait.sleep(2500)
            let tip = view.view(view, stringForToolTip: 0, point: view.closePoint, userData: nil)
            check("the pointer resting on × brings its tooltip, after the row was laid out again", tip.hasPrefix(String(localized: "Close Tab (⌥⌘W)")), "“\(tip)”")
        }
        // × on a tab other than the one shown: it goes, and the one shown stays shown with the keyboard.
        let shown = workbench.selectedTab!
        let shownPane = workbench.focusedPane!
        if let other = workspace.tabs.first(where: { $0 !== shown && $0 !== workspace.tabs.first && $0.tree.panes.allSatisfy { !(workbench.panes[$0]?.agentRunning ?? false) } }),
           let view = suite.tabView(other) {
            await suite.hover(view, at: view.closePoint)
            let hit = suite.click(view, at: view.closePoint)
            endOfEvent()
            let gone = await PerfWait.until(2000) { !workspace.tabs.contains { $0 === other } }
            check("× on a tab not shown closes that tab only", gone != nil && workbench.selectedTab === shown && suite.focused(shownPane),
                  "click went to \(describe(hit)); shown “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")”, first responder \(describe(window.firstResponder))")
        }
        // ⌥⌘W on the tab shown: the next tab is shown, with the keyboard.
        let closingTab = workbench.selectedTab!
        let closingPane = workbench.focusedPane!
        let pid = await hostPID(of: closingPane)
        let index = workspace.tabs.firstIndex { $0 === closingTab } ?? 0
        shortcut("cmd+opt+w")
        let gone = await PerfWait.until(2000) { !workspace.tabs.contains { $0 === closingTab } }
        let next = workbench.selectedTab
        let expected = workspace.tabs[min(index, workspace.tabs.count - 1)]
        check("⌥⌘W closes the tab shown; the tab now in its place is shown, with the keyboard",
              gone != nil && next === expected && workbench.focusedPane.map(suite.focused) == true,
              "shown “\(next.map(workbench.title(of:)) ?? "-")”, first responder \(describe(window.firstResponder))")
        let noted = await PerfWait.until(1000) { self.shownNote("UndoNote") != nil }
        check("closing shows “Closed · Undo ⌘Z”", noted != nil)
        // ⌘Z: back as it was, its process the same.
        shortcut("cmd+z")
        let back = await PerfWait.until(2000) { workspace.tabs.contains { $0 === closingTab } && self.workbench.selectedTab === closingTab }
        let samePID = await hostPID(of: closingPane)
        check("⌘Z brings the tab back where it was, shown, with the same process", back != nil && workspace.tabs.firstIndex { $0 === closingTab } == index
              && pid != nil && samePID == pid && suite.focused(closingPane), "back \(back != nil) at \(workspace.tabs.firstIndex { $0 === closingTab }.map(String.init) ?? "-") (was \(index)), first responder \(describe(window.firstResponder)), pid \(pid.map(String.init) ?? "-") → \(samePID.map(String.init) ?? "-")")
        // ⌘W on a lone pane closes its tab too.
        shortcut("cmd+w")
        _ = await PerfWait.until(2000) { !workspace.tabs.contains { $0 === closingTab } }
        check("⌘W on a tab's only pane closes the tab", !workspace.tabs.contains { $0 === closingTab })
        // A tab whose shell ended by itself (`exit`, no key of the window's), then another closed with ⌥⌘W:
        // ⌘Z brings back the one closed, not both.
        let exiting = workbench.newTab()
        endOfEvent()
        if await suite.shellReady(exiting) {
            let count = workspace.tabs.count
            exiting.type("exit\r")
            _ = await PerfWait.until(4000) { self.workbench.panes[exiting.id] == nil }
            await PerfWait.sleep(300)
            let other = workbench.selectedTab
            shortcut("cmd+opt+w")
            shortcut("cmd+z")
            let one = await PerfWait.until(2000) { other.map { tab in workspace.tabs.contains { $0 === tab } } ?? false }
            await PerfWait.sleep(300)
            check("a shell that exits, then ⌥⌘W, then ⌘Z: the tab closed comes back, the exited one does not", one != nil && workspace.tabs.count == count - 1 && workbench.panes[exiting.id] == nil,
                  "tabs \(count) → \(workspace.tabs.count), exited back \(workbench.panes[exiting.id] != nil)")
        }
        // Its moment for ⌘Z passes; ⇧⌘T opens it again in its folder.
        await PerfWait.sleep((Workbench.undoSeconds + 1) * 1000)
        let ended = await PerfWait.until(4000) { pid.map { kill($0, 0) != 0 } ?? false }
        check("after ten seconds the closed tab's processes end", ended != nil, "pid \(pid.map(String.init) ?? "-")")
        let count = workspace.tabs.count
        shortcut("cmd+shift+t")
        let reopened = await PerfWait.until(2000) { workspace.tabs.count == count + 1 }
        check("⇧⌘T reopens the closed tab in its folder", reopened != nil && workbench.focusedPane?.currentFolder == closingPane.currentFolder,
              "folder \(workbench.focusedPane?.currentFolder ?? "-") (was \(closingPane.currentFolder))")
        if let pane = workbench.focusedPane { _ = await suite.shellReady(pane) }
    }

    /// The process the session host runs for a pane (its shell).
    func hostPID(of pane: Pane) async -> Int32? {
        await workbench.host.terminals().first { $0.id == pane.id }?.pid
    }

    /// Fourteen tabs in a narrow window: the row shows as many as fit, the selected one whole, and the
    /// chevron says how many are out of sight.
    private func overflow() async {
        step("(the run opens ten tabs at once, in a narrower window)")
        guard let workspace = workbench.selectedWorkspace else { return }
        let size = window.frame.size
        window.setContentSize(NSSize(width: 1000, height: size.height - 28))
        var added: [Tab] = []
        while workspace.tabs.count < 14 {
            let pane = workbench.newTab()
            if let tab = workbench.workspace(of: pane.id)?.1 { added.append(tab) }
        }
        await PerfWait.sleep(500)
        step("tabs: more than fit")
        let views = suite.tabViews
        // The chevron: a menu button in the row beside the workspace button.
        let anchors = allViews(in: controller.terminals.tabRow) { ["bar.workspace", "bar.tabs.all"].contains($0.identifier?.rawValue) && !$0.isHiddenOrHasHiddenAncestor }.count
        let selectedWhole = workbench.selectedTab.flatMap(suite.tabView).map { window.contentView!.bounds.contains($0.convert($0.bounds, to: nil).insetBy(dx: 0.5, dy: 0.5)) } ?? false
        check("fourteen tabs: some shown, the selected one whole, and the chevron counts the rest",
              views.count < 14 && selectedWhole && anchors == 2,
              "\(views.count) in sight, menu buttons in the row \(anchors)")
        // ⌘1 goes to the first, out of sight: the row brings it in.
        shortcut("cmd+1")
        _ = await PerfWait.until(1000) { self.workbench.selectedTab === workspace.tabs.first }
        await PerfWait.sleep(200)
        let firstWhole = workspace.tabs.first.flatMap(suite.tabView).map { window.contentView!.bounds.contains($0.convert($0.bounds, to: nil).insetBy(dx: 0.5, dy: 0.5)) } ?? false
        check("⌘1 with the first tab out of sight brings it into the row", firstWhole)
        // Back to the four the journey works with.
        for tab in added { workbench.close(tab: tab) }
        window.setContentSize(size)
        await PerfWait.sleep(300)
    }

    /// Closing every tab of a workspace, one by one with ⌥⌘W and ×, while another workspace is open: Home
    /// comes, never the other workspace's terminal.
    private func closeAll() async {
        step("(the run opens a workspace of four tabs at once)")
        let keep = workbench.selectedWorkspace
        let other = workbench.newWorkspace(folder: suite.folder("journey-throwaway"))
        _ = await suite.shellReady(other)
        guard let throwaway = workbench.selectedWorkspace else { return }
        for _ in 0..<3 { workbench.newTab() }
        await PerfWait.sleep(400)
        step("tabs: close every tab of a workspace")
        var rounds = 0
        while workbench.selectedWorkspace === throwaway, rounds < 10 {
            rounds += 1
            let count = throwaway.tabs.count
            if rounds % 2 == 1 {
                shortcut("cmd+opt+w")
            } else if let tab = workbench.selectedTab, let view = suite.tabView(tab) {
                await suite.hover(view, at: view.closePoint)
                suite.click(view, at: view.closePoint)
                endOfEvent()
            }
            _ = await PerfWait.until(2000) { throwaway.tabs.count == count - 1 || !self.workbench.workspaces.contains { $0 === throwaway } }
            if workbench.workspaces.contains(where: { $0 === throwaway }) {
                check("closing tab \(rounds): the next tab of the same workspace has the keyboard", workbench.selectedWorkspace === throwaway && workbench.focusedPane.map(suite.focused) == true,
                      "shown in “\(workbench.selectedWorkspace?.name ?? "Home")”, first responder \(describe(window.firstResponder))")
            }
        }
        let home = await PerfWait.until(2000) { self.workbench.isHome && self.homeHasKeyboard }
        check("the workspace's last tab closed: Home, with the keyboard, never another workspace's terminal", home != nil && !workbench.workspaces.contains { $0 === throwaway },
              "\(rounds) closes; on \(workbench.selectedWorkspace?.name ?? "Home"), first responder \(describe(window.firstResponder))")
        let titled = await PerfWait.until(1000) { self.window.title == "Whiskr" }
        check("Home's title is “Whiskr”", titled != nil, "“\(window.title)”")
        // ⌘Z brings the workspace back with its tab, and shows it.
        shortcut("cmd+z")
        let undone = await PerfWait.until(2000) { self.workbench.selectedWorkspace?.id == throwaway.id }
        check("⌘Z after the last tab closed brings the workspace back, shown", undone != nil)
        if let back = workbench.selectedWorkspace, back.id == throwaway.id { workbench.close(workspace: back) }
        if let keep { workbench.select(workspace: keep) }
    }

    // MARK: Step 4: splits

    func splits() async {
        step("splits: ⌘D, ⇧⌘D, ⌘\\")
        // In a tab of plain shells (the Claude's waits for the relaunch).
        if let plain = workbench.selectedWorkspace?.tabs.first(where: { $0.tree.panes.allSatisfy { !(workbench.panes[$0]?.agentRunning ?? true) } }) {
            workbench.select(tab: plain)
        }
        guard let tab = workbench.selectedTab, let first = workbench.focusedPane else { return check("splits: a tab", false) }
        shortcut("cmd+d")
        let right = workbench.focusedPane
        shortcut("cmd+shift+d")
        let down = workbench.focusedPane
        shortcut("cmd+\\")
        let third = workbench.focusedPane
        check("⌘D, ⇧⌘D and ⌘\\ each split the focused pane and give the new one the keyboard",
              tab.tree.panes.count == 4 && Set([first.id, right?.id, down?.id, third?.id].compactMap { $0 }).count == 4 && third.map(suite.focused) == true,
              "panes \(tab.tree.panes.count), first responder \(describe(window.firstResponder))")
        for pane in tab.tree.panes.compactMap({ workbench.panes[$0] }) { _ = await suite.shellReady(pane) }
        await sizes(tab, "after splitting")

        step("splits: moving between panes")
        let order = tab.tree.panes
        shortcut("cmd+]")
        let nextOK = workbench.focusedPane?.id == order[(order.firstIndex(of: third!.id)! + 1) % order.count] && workbench.focusedPane.map(suite.focused) == true
        shortcut("cmd+[")
        let backOK = workbench.focusedPane === third && suite.focused(third!)
        check("⌘] and ⌘[ go to the next and previous pane, with the keyboard", nextOK && backOK)
        workbench.focus(pane: first.id)
        shortcut("cmd+opt+right")
        let rightOK = workbench.focusedPane?.id != first.id && workbench.focusedPane.map(suite.focused) == true
        shortcut("cmd+opt+left")
        let leftOK = workbench.focusedPane === first && suite.focused(first)
        check("⌥⌘→ and ⌥⌘← move between panes side by side", rightOK && leftOK, "first responder \(describe(window.firstResponder))")

        step("splits: a divider dragged, then double-clicked")
        if let split = DebugShell.descendant(of: controller.terminals.paneArea, where: { ($0 as? RatioSplitView)?.isVertical == true }) as? RatioSplitView,
           split.subviews.count == 2 {
            let before = split.subviews.map(\.frame.width)
            let start = split.convert(NSPoint(x: split.subviews[0].frame.maxX + 0.5, y: split.bounds.midY), to: nil)
            for step in 1...8 {
                if let drag = mouse(step == 8 ? .leftMouseUp : .leftMouseDragged, at: NSPoint(x: start.x - CGFloat(step * 15), y: start.y)) { NSApp.postEvent(drag, atStart: false) }
            }
            if let down = mouse(.leftMouseDown, at: start) { NSApp.sendEvent(down) }
            await PerfWait.sleep(400)
            let dragged = split.subviews.map(\.frame.width)
            check("a divider dragged moves", abs(dragged[0] - before[0]) > 60, "widths \(before.map { Int($0) }) → \(dragged.map { Int($0) })")
            await sizes(tab, "after a divider was dragged")
            doubleClick(split, at: NSPoint(x: split.subviews[0].frame.maxX + 0.5, y: split.bounds.midY))
            let even = await PerfWait.until(1000) { abs(split.subviews[0].frame.width - split.subviews[1].frame.width) <= 2 }
            check("a double-click on the divider shares the room evenly", even != nil, "widths \(split.subviews.map { Int($0.frame.width) })")
        } else {
            check("splits: a side-by-side divider to drag", false)
        }

        step("splits: zoom")
        workbench.focus(pane: first.id)
        shortcut("cmd+shift+return")
        let zoomed = tab.zoomedPane == first.id
        await PerfWait.sleep(300)
        let says = shownNote("ZoomNote") != nil
        let others = tab.tree.panes.filter { $0 != first.id }.compactMap { workbench.panes[$0] }.allSatisfy { $0.surface.isHiddenOrHasHiddenAncestor || $0.surface.window == nil }
        check("⇧⌘↩ zooms the pane: the others out of sight, the note says so", zoomed && says && others && suite.focused(first), "zoomed \(zoomed), note \(says), others hidden \(others)")
        await sizes(tab, "zoomed")
        // The note's own click brings the others back.
        if let noteView = shownNote("ZoomNote") {
            let point = noteView.convert(NSPoint(x: noteView.bounds.midX, y: noteView.bounds.midY), to: nil)
            if let down = mouse(.leftMouseDown, at: point), let up = mouse(.leftMouseUp, at: point) {
                PointerStandIn.location = point
                NSApp.sendEvent(down)
                NSApp.sendEvent(up)
            }
            let restored = await PerfWait.until(2000) { tab.zoomedPane == nil }
            check("a click on “Zoomed · Show All Panes” brings the others back", restored != nil && suite.focused(first), "first responder \(describe(window.firstResponder))")
        }
        await sizes(tab, "zoom undone")

        step("splits: closing panes")
        workbench.focus(pane: third!.id)
        shortcut("cmd+w")
        let after = await PerfWait.until(2000) { tab.tree.panes.count == 3 }
        let focusedNow = workbench.focusedPane
        check("⌘W closes the focused pane only; the pane focused before it has the keyboard", after != nil && focusedNow.map(suite.focused) == true && focusedNow?.id == first.id,
              "focused “\(focusedNow.map(workbench.name(of:)) ?? "-")”, first responder \(describe(window.firstResponder))")
        shortcut("cmd+w")
        shortcut("cmd+w")
        _ = await PerfWait.until(2000) { tab.tree.panes.count == 1 }
        check("⌘W twice more leaves one pane, with the keyboard", tab.tree.panes.count == 1 && workbench.focusedPane.map(suite.focused) == true)
        await sizes(tab, "back to one pane")
    }

    /// Every pane of the tab on screen: what its program was told (`stty size`), its terminal's grid and the
    /// grid its view has room for agree.
    func sizes(_ tab: Tab, _ when: String) async {
        let shown = tab.tree.panes.compactMap { workbench.panes[$0] }.filter { !$0.surface.isHiddenOrHasHiddenAncestor && $0.surface.window != nil }
        await PerfWait.sleep(300)
        for pane in shown {
            let marker = "SZ\(Int(perfNow()) % 100000)"
            pane.type("echo \(marker) $(stty size)\r")
            let answer = { (row: String) -> String? in
                let parts = row.split(separator: " ")
                // The answer's own line (the command, wrapped in a narrow pane, can start with the marker too).
                return parts.count == 3 && parts[0] == marker && Int(parts[1]) != nil && Int(parts[2]) != nil ? "\(parts[2])x\(parts[1])" : nil
            }
            _ = await PerfWait.until(6000) { self.suite.screen(pane).contains { answer($0) != nil } }
            let told = suite.screen(pane).compactMap(answer).first ?? "?"
            let grid = pane.surface.terminalDimensions
            let room = pane.surface.size(for: pane.surface.frame.size)
            check("\(when): “\(workbench.name(of: pane))” — program, terminal and view agree on the size",
                  told == "\(grid.cols)x\(grid.rows)" && grid.cols == room.columns && grid.rows == room.rows,
                  "program \(told), terminal \(grid.cols)x\(grid.rows), view room \(room.columns)x\(room.rows)")
        }
    }

    // MARK: Step 5: workspaces

    func workspaces() async {
        step("workspaces: a second and a third")
        guard let first = workbench.selectedWorkspace else { return }
        let second = workbench.newWorkspace(folder: suite.folder("journey-api"))
        _ = await suite.shellReady(second)
        let third = workbench.newWorkspace(folder: suite.folder("journey-docs"))
        _ = await suite.shellReady(third)
        guard workbench.workspaces.count >= 3, let secondSpace = workbench.workspace(of: second.id)?.0, let thirdSpace = workbench.workspace(of: third.id)?.0 else {
            return check("workspaces: three open", false)
        }
        // Each remembers where it was left: a second tab in the second workspace, its first one shown.
        workbench.select(workspace: secondSpace)
        let secondTab = workbench.newTab()
        _ = await suite.shellReady(secondTab)
        let shown = { (workspace: Workspace) -> Bool in
            self.workbench.selectedWorkspace === workspace && self.workbench.focusedPane.map(self.suite.focused) == true
                && self.window.title == workspace.name
        }

        step("workspaces: a click on a blanket")
        meadowTakesItsClicks("three workspaces")
        // A blanket with no cat on it: a click on a cat is the cat's (an asking one opens its card).
        let target = workbench.workspaces.first { space in space !== workbench.selectedWorkspace && !space.tabs.flatMap(\.tree.panes).contains { workbench.panes[$0]?.agentRunning ?? false } } ?? first
        if let landed = await clickInMeadow(.blanket(target.id.uuidString)) {
            let went = await PerfWait.until(2000) { shown(target) }
            check("a click on a blanket shows its workspace, with the keyboard in its terminal", went != nil,
                  "the click went to \(describe(landed)); on “\(workbench.selectedWorkspace?.name ?? "Home")”, title “\(window.title)”, first responder \(describe(window.firstResponder))")
        } else {
            check("workspaces: the first blanket laid out in the meadow", false)
        }

        step("workspaces: the workspace button's menu")
        // A click on the button, as a person's: its menu (recorded by `MenuStandIn`, never shown), then the item.
        _ = MenuStandIn.take()
        if let button = suite.barView("bar.workspace") {
            suite.click(button, at: NSPoint(x: button.bounds.midX, y: button.bounds.midY))
        }
        let popped = MenuStandIn.take().first?.menu
        check("a click on the workspace button opens its menu", popped != nil)
        if let popped, let index = popped.items.firstIndex(where: { $0.title == thirdSpace.name }) {
            popped.performActionForItem(at: index)
            check("the workspace menu's item shows that workspace", await PerfWait.until(2000) { shown(thirdSpace) } != nil)
        }

        step("workspaces: ⌥⌘1–3, ⌃⌘] and ⌃⌘[")
        for (index, workspace) in workbench.workspaces.prefix(3).enumerated() {
            shortcut("cmd+opt+\(index + 1)")
            check("⌥⌘\(index + 1) shows “\(workspace.name)”", await PerfWait.until(2000) { shown(workspace) } != nil, "on “\(workbench.selectedWorkspace?.name ?? "Home")”")
        }
        let at = workbench.workspaces.firstIndex { $0 === workbench.selectedWorkspace } ?? 0
        shortcut("cmd+ctrl+]")
        let forward = workbench.workspaces[(at + 1) % workbench.workspaces.count]
        check("⌃⌘] shows the next workspace", await PerfWait.until(2000) { shown(forward) } != nil)
        shortcut("cmd+ctrl+[")
        check("⌃⌘[ shows the one before", await PerfWait.until(2000) { shown(self.workbench.workspaces[at]) } != nil)

        step("workspaces: Go to (⌘P)")
        shortcut("cmd+p")
        if let panel = window.childWindows?.last(where: { $0 is NSPanel && !String(describing: type(of: $0)).contains("Popover") }) {
            let field = await PerfWait.until(1000) { panel.firstResponder is NSText }
            print("journey: Go to's panel \(type(of: panel)) key \(panel.isKeyWindow), first responder \(describe(panel.firstResponder)), field has the keyboard \(field != nil)")
            for character in "journey-api" { press(String(character), code: 0, in: panel) }
            await PerfWait.sleep(300)
            press("\r", code: 36, in: panel)
            check("⌘P, the workspace's name, Return: shown, the palette gone", await PerfWait.until(2000) { shown(secondSpace) && self.controller.palette?.isShown == false } != nil,
                  "on “\(workbench.selectedWorkspace?.name ?? "Home")”, first responder \(describe(window.firstResponder))")
            check("the second workspace comes back on the tab it was left on", workbench.selectedTab?.tree.contains(secondTab.id) == true)
        } else {
            check("⌘P opens Go to", false)
        }

        step("workspaces: Home and back")
        let leftOn = workbench.focusedPane
        shortcut("cmd+shift+h")
        let home = await PerfWait.until(2000) { self.workbench.isHome && self.homeHasKeyboard }
        check("⇧⌘H: Home, with the keyboard", home != nil)
        // Home's rows: New Terminal is highlighted; ↓ once is the first open workspace (Open Folder…, New
        // Terminal, then the workspaces in the meadow's order).
        let rows = workbench.homeRows
        let leftIn = leftOn.flatMap { workbench.workspace(of: $0.id)?.0 }
        if let leftIn, let target = rows.firstIndex(where: { $0.id == leftIn.id }) {
            for _ in 0...target { press(String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), code: 125) }
            press("\r", code: 36)
            let back = await PerfWait.until(2000) { shown(leftIn) && self.workbench.focusedPane === leftOn }
            check("Home's Open row, ↓ and Return: back in exactly where it was left", back != nil,
                  "on “\(workbench.selectedWorkspace?.name ?? "Home")”, pane \(workbench.focusedPane.map(workbench.name(of:)) ?? "-")")
        }
        step("workspaces: ⌘J with nothing waiting but the Claude")
        shortcut("cmd+j")
        let jumped = await PerfWait.until(2000) { self.claudePane.map { self.workbench.focusedPane?.id == $0 } ?? false }
        check("⌘J goes to the waiting Claude, in its workspace", jumped != nil, "on “\(workbench.selectedWorkspace?.name ?? "Home")”")
        shortcut("cmd+j")
        let returned = await PerfWait.until(2000) { self.workbench.focusedPane === leftOn }
        check("⌘J again comes back", returned != nil)
    }
}
#endif
