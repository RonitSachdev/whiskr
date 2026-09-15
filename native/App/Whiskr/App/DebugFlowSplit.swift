#if DEBUG
import AppKit
import WhiskrKit

/// `--perf-flows split` (`make perf`'s checks): a tab split into panes, as the owner used it, with real
/// clicks through `NSApplication.sendEvent` landing wherever the window's views say. A split tab is one tab
/// of segments in the row, one per pane (titles as a single tab's); a click on a segment shows that pane
/// with the keyboard (the meadow follows); a segment's × (and a middle click) closes only its pane, its
/// neighbour and its program running on, and the next click lands on something alive; ⌘W closes the
/// focused pane; Close Tab closes them all, asking nothing about a running program (⌘Z brings it back,
/// still running) and about an unsaved file by its name; "+" follows the last tab (one, several, too many);
/// ⌘D grows a segment; a pane's header × closes it; and in every built-in theme, light and dark, the line
/// between panes reads on the content and the focused pane's header carries the accent.
///
/// `--split-snapshots <folder>`: also the pictures the owner asked for, in Whiskr light and dark and in
/// Graphite (and the line and headers in every theme).
extension PerfSuite {
    func splitCheck() async {
        ActionStandIn.install()
        guard let setup = await splitSetup() else { return }
        await segmentClicks(setup)
        await segmentClose(setup)
        await closePaneKeys(setup)
        await closeWholeTab(setup)
        await growingSegment(setup)
        await headerClose(setup)
        await describedEverywhere(setup)
        await plusPlacement(setup)
        await dividerAndFocus(setup)
        if let folder = DebugScenario.value("--split-snapshots") { await splitSnapshots(setup, to: URL(fileURLWithPath: folder, isDirectory: true)) }
    }

    // MARK: Setting up

    struct SplitSetup {
        let root: URL
        let workspace: Workspace
        /// A plain shell's tab.
        let plain: Tab
        /// The owner's tab: Claude above, a file below.
        let split: Tab
        let claude: Pane
        let file: URL
    }

    /// A folder with a file, a plain tab, and the owner's split: a Claude (a stand-in the hooks speak for)
    /// with a file dropped below it.
    private func splitSetup() async -> SplitSetup? {
        let root = URL(fileURLWithPath: folder("split-repo"), isDirectory: true)
        let file = root.appendingPathComponent(".gitattributes")
        try? Data("* text=auto\n*.png binary\n".utf8).write(to: file)
        try? Data("# Notes\n\nA line to read.\n".utf8).write(to: root.appendingPathComponent("notes.md"))
        let first = workbench.newWorkspace(folder: root.path)
        guard await shellReady(first), let workspace = workbench.selectedWorkspace, let plain = workbench.selectedTab else {
            check("split: the first shell drew its prompt", false)
            return nil
        }
        let claude = workbench.newTab()
        _ = await shellReady(claude)
        claude.debugPretendsClaude = true
        workbench.monitor.simulate(paneID: claude.id, payload: .object(["hook_event_name": "UserPromptSubmit", "session_id": "split-claude", "cwd": .string(root.path)]))
        guard let split = workbench.selectedTab else { return nil }
        workbench.open(file: file.path, mode: .keep)
        guard let fileTab = workbench.selectedTab, fileTab !== split else { return nil }
        // As the owner made it: the file dragged onto the bottom of Claude's pane.
        workbench.dropTab(fileTab, onto: claude.id, side: .down)
        _ = await PerfWait.until(3000) { split.tree.panes.count == 2 && self.tabViews.count == 2 }
        await PerfWait.sleep(400)
        check("split: set up (a plain tab, and a tab of Claude over a file)", split.tree.panes.count == 2 && workspace.tabs.count == 2,
              "tabs \(workspace.tabs.map { workbench.title(of: $0) })")
        return SplitSetup(root: root, workspace: workspace, plain: plain, split: split, claude: claude, file: file)
    }

    /// What has the keyboard, in words, for a check's detail.
    func responderText(_ responder: NSResponder?) -> String {
        responder.map { String(describing: type(of: $0)) } ?? "nothing"
    }

    private func pageID(in tab: Tab) -> UUID? { tab.tree.panes.first { workbench.pages[$0] != nil } }

    /// Puts the file back below Claude, after a check closed it.
    private func restoreSplit(_ setup: SplitSetup) async {
        if setup.split.tree.panes.count == 1 {
            workbench.open(file: setup.file.path, mode: .keep)
            if let tab = workbench.selectedTab, tab !== setup.split { workbench.dropTab(tab, onto: setup.claude.id, side: .down) }
        }
        workbench.select(tab: setup.split, pane: setup.claude.id)
        await rest()
        print("split: the split tab now: \(setup.split.tree.panes.map(workbench.name(ofLeaf:)))")
    }

    /// The pointer away from the bars, over the panes; a moment for the row to draw.
    private func rest() async {
        if let content = window.contentView { await hover(content, at: NSPoint(x: content.bounds.maxX - 200, y: content.bounds.midY)) }
        await PerfWait.sleep(250)
    }

    // MARK: Segments

    /// The owner's complaint: on top there was only the file's name. Now one tab of two segments, and a
    /// click on each shows its pane with the keyboard, the meadow following.
    private func segmentClicks(_ setup: SplitSetup) async {
        guard let view = tabView(setup.split), let page = pageID(in: setup.split) else { return check("split: the split tab on screen", false) }
        check("split: the split tab is one tab of two segments, Claude's then the file's, in the panes' order",
              tabViews.count == 2 && view.slots.map(\.pane) == setup.split.tree.panes && view.slots.allSatisfy(\.titled),
              "\(tabViews.count) tabs on screen, segments \(view.slots.count)")
        for (name, pane) in [("the file's", page), ("Claude's", setup.claude.id)] {
            workbench.select(tab: setup.plain)
            await rest()
            guard let view = tabView(setup.split), let point = view.point(of: pane) else { check("split: \(name) segment on screen", false); continue }
            let before = workbench.choices
            await hover(view, at: point)
            let hit = click(view, at: point)
            let shown = await PerfWait.until(1500) {
                self.workbench.selectedTab === setup.split && setup.split.focusedPane == pane
                    && (self.workbench.pages[pane] != nil ? self.window.firstResponder.map { ($0 as? NSView)?.isDescendant(of: self.controller.terminals.paneArea.pageView(pane) ?? NSView()) == true } == true
                                                         : self.focused(setup.claude))
            }
            check("split: a click on \(name) segment shows its tab with that pane taking the keyboard, and the meadow follows",
                  hit === view && shown != nil && workbench.choices > before,
                  "landed on \(hit.map { String(describing: type(of: $0)) } ?? "nothing"), focused \(setup.split.focusedPane == pane), first responder \(responderText(window.firstResponder)), choices \(before) → \(workbench.choices)")
        }
    }

    /// The owner's complaint: closing one thing closed the whole tab. A segment's × closes its pane only.
    private func segmentClose(_ setup: SplitSetup) async {
        await restoreSplit(setup)
        guard let page = pageID(in: setup.split), let view = tabView(setup.split), let close = view.closePoint(of: page) else { return check("split: the file's ×", false) }
        // Not the focused pane's: its × shows under the pointer.
        await hover(view, at: close)
        let landed = click(view, at: close)
        let closed = await PerfWait.until(2000) { setup.split.tree.panes == [setup.claude.id] && self.workbench.pages[page] == nil }
        check("split: the file segment's × closes the file only: the tab stays, Claude in it, still running",
              landed === view && closed != nil && setup.workspace.tabs.contains { $0 === setup.split } && workbench.panes[setup.claude.id] === setup.claude
                && setup.claude.agentRunning,
              "panes \(setup.split.tree.panes.count), tabs \(setup.workspace.tabs.count), Claude \(workbench.panes[setup.claude.id] != nil)")
        // The next click, where the × was, lands on something alive and does what it shows.
        await PerfWait.sleep(200)
        let next = hit(view, at: close)
        let before = workbench.selectedTab
        if let next { _ = click(next, at: next.convert(view.convert(close, to: nil), from: nil)) }
        let alive = next is TabMouseView || next is BarControlView || next is WindowDragArea.DragView
        check("split: the click after it lands on a live control", alive, "it went to \(next.map { String(describing: type(of: $0)) } ?? "nothing"), shown \(workbench.selectedTab.map(workbench.title(of:)) ?? "-") (was \(before.map(workbench.title(of:)) ?? "-"))")
        // A middle click on a segment closes that pane too.
        await restoreSplit(setup)
        if let page = pageID(in: setup.split), let view = tabView(setup.split), let point = view.point(of: page) {
            let location = view.convert(point, to: nil)
            // AppKit makes an other-button event as button 2's only from Core Graphics' own.
            if let event = NSEvent.mouseEvent(with: .otherMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: 1, pressure: 1),
               let cg = event.cgEvent?.copy() {
                cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                // Core Graphics' place: the screen's, from its top left.
                let screen = window.convertPoint(toScreen: location)
                cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
                PointerStandIn.location = location
                // Wherever this window happens to be on the screens: moved by however far it came out.
                if let first = NSEvent(cgEvent: cg) {
                    cg.location = CGPoint(x: cg.location.x + location.x - first.locationInWindow.x, y: cg.location.y - (location.y - first.locationInWindow.y))
                }
                if let middle = NSEvent(cgEvent: cg) {
                    print("split: middle click as button \(middle.buttonNumber) at \(middle.locationInWindow) in window \(middle.windowNumber == window.windowNumber)")
                    NSApp.sendEvent(middle)
                }
            }
            check("split: a middle click on a segment closes its pane, not the tab",
                  await PerfWait.until(2000) { setup.split.tree.panes == [setup.claude.id] } != nil && setup.workspace.tabs.contains { $0 === setup.split })
        }
        // Its menu: Close Pane for the pane clicked, Close Tab saying how many it closes.
        await restoreSplit(setup)
        if let page = pageID(in: setup.split), let view = tabView(setup.split), let point = view.point(of: page),
           let event = NSEvent.mouseEvent(with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: 1, pressure: 1),
           let menu = view.menu(for: event) {
            let titles = menu.items.map(\.title)
            check("split: a segment's menu offers Close Pane and “Close Tab (2 Panes)”, and chose its pane",
                  titles.contains(String(localized: "Close Pane")) && titles.contains(String(localized: "Close Tab (\(2) Panes)", comment: "A split tab's menu: closes every pane of it"))
                    && setup.split.focusedPane == page, "\(titles)")
            if let index = menu.items.firstIndex(where: { $0.title == String(localized: "Close Pane") }) {
                menu.performActionForItem(at: index)
                check("split: its Close Pane closes that pane", await PerfWait.until(2000) { setup.split.tree.panes == [setup.claude.id] } != nil)
            }
        }
    }

    /// ⌘W closes the focused pane, not the tab; ⌥⌘W the tab.
    private func closePaneKeys(_ setup: SplitSetup) async {
        await restoreSplit(setup)
        guard let page = pageID(in: setup.split) else { return }
        workbench.select(tab: setup.split, pane: page)
        _ = await PerfWait.until(1500) { self.window.firstResponder is NSTextView }
        shortcut("cmd+w")
        check("split: ⌘W in the file closes the file, and Claude's pane takes the keyboard",
              await PerfWait.until(2000) { setup.split.tree.panes == [setup.claude.id] && self.focused(setup.claude) } != nil,
              "panes \(setup.split.tree.panes.count), first responder \(responderText(window.firstResponder))")
        // Two terminals: ⌘W in the second closes it alone.
        workbench.select(tab: setup.split, pane: setup.claude.id)
        shortcut("cmd+d")
        guard let second = workbench.focusedPane, second !== setup.claude else { return check("split: ⌘D split", false) }
        _ = await shellReady(second)
        shortcut("cmd+w")
        check("split: ⌘W in a split terminal closes that pane only",
              await PerfWait.until(2000) { setup.split.tree.panes == [setup.claude.id] && self.workspaceTabs(setup) == 2 } != nil)
    }

    private func workspaceTabs(_ setup: SplitSetup) -> Int { setup.workspace.tabs.count }

    /// Close Tab on a split tab closes every pane. A running program is not asked about (Closing asks
    /// nothing; ⌘Z brings it back, still running); an unsaved file is, by its name.
    private func closeWholeTab(_ setup: SplitSetup) async {
        await restoreSplit(setup)
        setup.claude.type("sleep 1000\r")
        _ = await PerfWait.until(3000) { setup.claude.foreground != nil }
        let count = setup.workspace.tabs.count
        let treeBefore = setup.split.tree.panes
        // The undo group of an earlier close can still be open in this run (keys sent from a task, not as
        // events, whose end would close it): closed here, as the end of a real key press does, so this
        // ⌘Z is this close's alone.
        if let undo = workbench.undoManager, undo.groupingLevel > 0 {
            print("split: an undo group was left open (level \(undo.groupingLevel)); closed as an event's end closes it")
            while undo.groupingLevel > 0 { undo.endUndoGrouping() }
        }
        workbench.select(tab: setup.split, pane: setup.claude.id)
        shortcut("cmd+opt+w")
        let gone = await PerfWait.until(2000) { setup.workspace.tabs.count == count - 1 }
        check("split: Close Tab (⌥⌘W) on a split with a running program closes both panes, asking nothing",
              gone != nil && window.attachedSheet == nil, "tabs \(count) → \(setup.workspace.tabs.count), sheet \(window.attachedSheet != nil)")
        shortcut("cmd+z")
        let back = await PerfWait.until(3000) { setup.workspace.tabs.contains { $0 === setup.split } && setup.split.tree.panes.count == 2 }
        check("split: ⌘Z brings the whole split back as it was (Claude and the file), its program still running",
              back != nil && setup.split.tree.panes == treeBefore && setup.claude.foreground != nil && workbench.panes[setup.claude.id] === setup.claude,
              "panes \(setup.split.tree.panes.count), running \(setup.claude.foreground.map { "\($0)" } ?? "nothing")")
        setup.claude.type("\u{3}")
        // An unsaved file in the split: Close Tab asks by its name, and Cancel keeps everything.
        guard let page = pageID(in: setup.split), case .file(let path)? = workbench.pages[page], let document = workbench.files.openDocument(path) else { return }
        workbench.select(tab: setup.split, pane: page)
        _ = await PerfWait.until(1500) { self.window.firstResponder is NSTextView }
        typeKeys("x")
        _ = await PerfWait.until(1000) { document.isEdited }
        let menu = TabMenu.make(workbench: workbench, tab: setup.split, pane: setup.claude.id)
        if let index = menu.items.firstIndex(where: { $0.title.hasPrefix(String(localized: "Close Tab")) }) { menu.performActionForItem(at: index) }
        let sheet = await PerfWait.until(2000) { self.window.attachedSheet != nil }
        let text = window.attachedSheet.flatMap { DebugShell.descendant(of: $0.contentView!) { ($0 as? NSTextField)?.stringValue.contains(".gitattributes") == true } } != nil
        check("split: Close Tab with an unsaved file in the split asks about it by name", sheet != nil && text)
        if let alert = window.attachedSheet, let cancel = DebugShell.descendant(of: alert.contentView!, where: { ($0 as? NSButton)?.title == String(localized: "Cancel") }) as? NSButton {
            cancel.performClick(nil)
        }
        await PerfWait.sleep(300)
        check("split: Cancel keeps the tab and both panes", setup.split.tree.panes.count == 2 && setup.workspace.tabs.contains { $0 === setup.split })
        document.revert()
    }

    /// ⌘D adds a segment at once, where the click layer is, and its picture opens out.
    private func growingSegment(_ setup: SplitSetup) async {
        await restoreSplit(setup)
        let before = tabView(setup.split)?.slots.count ?? 0
        workbench.select(tab: setup.split, pane: setup.claude.id)
        shortcut("cmd+d")
        guard let added = workbench.focusedPane, added !== setup.claude else { return check("split: ⌘D", false) }
        let grown = await PerfWait.until(1000) { self.tabView(setup.split)?.slots.count == before + 1 }
        check("split: ⌘D adds a segment to the tab for the new pane, at once, with the keyboard in it",
              grown != nil && tabView(setup.split)?.slots.contains { $0.pane == added.id } == true,
              "segments \(before) → \(tabView(setup.split)?.slots.count ?? 0)")
        _ = await shellReady(added)
        print("split: after ⌘D: \(setup.split.tree.panes.map(workbench.name(ofLeaf:))), added \(workbench.name(ofLeaf: added.id))")
        workbench.close(pane: added.id)
        _ = await PerfWait.until(1000) { self.tabView(setup.split)?.slots.count == before }
    }

    /// A pane's header × closes that pane; a tab of one pane has no terminal header.
    private func headerClose(_ setup: SplitSetup) async {
        await restoreSplit(setup)
        guard let page = pageID(in: setup.split) else { return }
        let pageView = controller.terminals.paneArea.pageView(page)
        let close = pageView.flatMap { DebugShell.descendant(of: $0) { $0.identifier?.rawValue == "pane.close" && !$0.isHiddenOrHasHiddenAncestor } }
        let card = DebugShell.descendant(of: controller.terminals.paneArea) { ($0 as? PaneCard)?.pane === setup.claude } as? PaneCard
        let claudeHeader = card.flatMap { DebugShell.descendant(of: $0) { $0.identifier?.rawValue == "pane.close" && !$0.isHiddenOrHasHiddenAncestor } }
        check("split: in a split, both panes have a header with Close Pane (the terminal's too)", close != nil && claudeHeader != nil)
        if let close {
            let hit = click(close, at: NSPoint(x: close.bounds.midX, y: close.bounds.midY))
            let closed = await PerfWait.until(2000) { setup.split.tree.panes == [setup.claude.id] }
            check("split: the file's header × closes the file only", (hit === close || hit?.isDescendant(of: close) == true) && closed != nil,
                  "landed on \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
        }
        await PerfWait.sleep(300)
        let alone = card.flatMap { DebugShell.descendant(of: $0) { $0.identifier?.rawValue == "pane.close" && !$0.isHiddenOrHasHiddenAncestor } }
        check("split: a terminal alone in its tab has no header", alone == nil)
        // A click on a header's empty stretch gives that pane the keyboard.
        await restoreSplit(setup)
        if let page = pageID(in: setup.split), let card = DebugShell.descendant(of: controller.terminals.paneArea, where: { ($0 as? PaneCard)?.pane === setup.claude }) {
            workbench.select(tab: setup.split, pane: page)
            await PerfWait.sleep(200)
            let point = NSPoint(x: card.bounds.midX, y: card.bounds.maxY - FilePageView.headerHeight / 2)
            click(card, at: point)
            check("split: a click on a terminal's header gives its pane the keyboard",
                  await PerfWait.until(1500) { self.focused(setup.claude) && setup.split.focusedPane == setup.claude.id } != nil)
        }
    }

    /// Go to, ⌃Tab, the list of every tab and VoiceOver name a split tab by all its panes.
    private func describedEverywhere(_ setup: SplitSetup) async {
        await restoreSplit(setup)
        let title = workbench.title(of: setup.split)
        let names = setup.split.tree.panes.map(workbench.name(ofLeaf:))
        check("split: a split tab is named by its panes in order (Go to, ⌃Tab, the list of every tab)", title == names.joined(separator: ", ") && title.contains(".gitattributes"), "“\(title)”")
        // A name given to it leads its segments as a label (the segments keep their panes' titles), and a
        // click on the label shows the tab.
        workbench.rename(tab: setup.split, to: "Review")
        await PerfWait.sleep(400)
        if let view = tabView(setup.split), let first = view.slots.first {
            check("split: a split tab you named shows the name leading its segments, and is called by it",
                  first.minX > 20 && workbench.title(of: setup.split) == "Review" && view.slots.count == 2, "segments start at \(Int(first.minX))")
            workbench.select(tab: setup.plain)
            await rest()
            if let again = tabView(setup.split) {
                click(again, at: NSPoint(x: 8, y: again.bounds.midY))
                check("split: a click on the name shows the tab", await PerfWait.until(1000) { self.workbench.selectedTab === setup.split } != nil)
            }
        }
        if let folder = DebugScenario.value("--split-snapshots") {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            WindowChrome.drawsAsKey = true
            await rest()
            DebugShell.snapshot(window: controller, workbench: workbench, to: URL(fileURLWithPath: folder).appendingPathComponent("named-split.png"))
            WindowChrome.drawsAsKey = DebugScenario.has("--key-look")
        }
        workbench.rename(tab: setup.split, to: "")
    }

    // MARK: "+"

    /// "+" directly after the last tab: with one tab, several, and too many (then after the chevron), and a
    /// click on it makes a tab.
    private func plusPlacement(_ setup: SplitSetup) async {
        await restoreSplit(setup)
        func placed(_ name: String) async {
            await PerfWait.sleep(400)
            guard let plus = barControl("bar.tabs.new")?.1 else { return check("split: + on screen (\(name))", false) }
            let last = tabViews.last.map(windowRect)
            let chevron = barControl("bar.tabs.all")?.1
            let after = (chevron ?? last)?.maxX ?? 0
            check("split: “+” sits directly after the \(chevron == nil ? "last tab" : "list of every tab") (\(name))",
                  abs(plus.minX - after - 0) <= Look.Space.xs + 1 && plus.maxX <= windowRect(controller.terminals.tabRow).maxX,
                  "+ at \(Int(plus.minX))…\(Int(plus.maxX)), the last before it ends at \(Int(after))")
            let count = workbench.selectedWorkspace?.tabs.count ?? 0
            press(at: NSPoint(x: plus.midX, y: plus.midY))
            let made = await PerfWait.until(1500) { (self.workbench.selectedWorkspace?.tabs.count ?? 0) == count + 1 }
            check("split: a click on “+” makes a tab (\(name))", made != nil)
            if made != nil, let tab = workbench.selectedTab { workbench.close(tab: tab) }
            await PerfWait.sleep(200)
        }
        let one = workbench.newWorkspace(folder: folder("split-one"))
        _ = await shellReady(one)
        await placed("one tab")
        workbench.select(workspace: setup.workspace)
        await placed("a split tab among others")
        var extra: [Tab] = []
        while setup.workspace.tabs.count < 14 {
            let pane = workbench.newTab()
            if let tab = workbench.workspace(of: pane.id)?.1 { extra.append(tab) }
        }
        await placed("too many to show")
        for tab in extra { workbench.close(tab: tab) }
        if let workspace = workbench.workspaces.first(where: { $0.tabs.contains { $0.tree.contains(one.id) } }) { workbench.close(workspace: workspace) }
        workbench.select(workspace: setup.workspace)
        await rest()
    }

    // MARK: The line between panes, the focused header

    /// In every built-in theme, light and dark: the pixels of the line between the panes against the content
    /// beside it (at least `paneDividerContrast`), and the accent along the foot of the focused pane's header only.
    private func dividerAndFocus(_ setup: SplitSetup) async {
        await restoreSplit(setup)
        let store = ThemeStore.shared
        let before = (store.themeID, store.appearance)
        WindowChrome.drawsAsKey = true
        defer {
            store.themeID = before.0
            store.appearance = before.1
            WindowChrome.drawsAsKey = DebugScenario.has("--key-look")
        }
        workbench.select(tab: setup.split, pane: setup.claude.id)
        var failures: [String] = []
        var measured: [String] = []
        for theme in BuiltInThemes.all {
            for dark in [false, true] where (dark ? theme.dark : theme.light) != nil {
                store.themeID = theme.id
                store.appearance = dark ? .dark : .light
                await PerfWait.sleep(350)
                let name = "\(theme.name) \(dark ? "dark" : "light")"
                guard let look = splitLook(setup) else { failures.append("\(name): not drawn"); continue }
                measured.append(String(format: "%@ %.2f", name, look.divider))
                // The colour the line is drawn in, against the content, as the theme gives them; and on screen, a line
                // that shows (the picture's colours drift a little from the theme's).
                var given = 0.0
                window.effectiveAppearance.performAsCurrentDrawingAppearance {
                    func rgb(_ color: NSColor) -> WhiskrKit.RGBColor {
                        let c = color.usingColorSpace(.sRGB) ?? .black
                        return WhiskrKit.RGBColor(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
                    }
                    let a = rgb(Colors.paneDivider), b = rgb(Colors.terminalBackground)
                    given = a.contrast(with: b)
                }
                measured[measured.count - 1] += String(format: " (given %.2f)", given)
                if given < ThemeVariant.paneDividerContrast || look.divider < 1.3 { failures.append(String(format: "%@: the line between panes %.2f:1 given, %.2f:1 drawn", name, given, look.divider)) }
                if !look.accentOnFocused { failures.append("\(name): no accent along the focused header's foot") }
                if look.accentOnOther { failures.append("\(name): accent along the other pane's header's foot") }
            }
        }
        print("split: the line between panes, measured on screen: \(measured.joined(separator: "; "))")
        check("split: in every built-in theme the line between panes reads on the content, and only the focused pane's header has the accent",
              failures.isEmpty, failures.joined(separator: "; "))
    }

    /// The window drawn, read where the line between the two panes is and along both headers' tops.
    private func splitLook(_ setup: SplitSetup) -> (divider: Double, accentOnFocused: Bool, accentOnOther: Bool)? {
        let url = root.appendingPathComponent("split-look.png")
        DebugShell.snapshot(window: controller, workbench: workbench, to: url)
        guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()),
              let card = DebugShell.descendant(of: controller.terminals.paneArea, where: { ($0 as? PaneCard)?.pane === setup.claude }),
              let page = pageID(in: setup.split), let pageView = controller.terminals.paneArea.pageView(page) else { return nil }
        let scale = window.backingScaleFactor
        let top = card.convert(card.bounds, to: nil), bottom = pageView.convert(pageView.bounds, to: nil)
        // The window's points, y up, to the picture's pixels, y down.
        func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor? {
            rep.colorAt(x: Int(x * scale), y: Int((window.frame.height - y) * scale))?.usingColorSpace(.sRGB)
        }
        func luminance(_ color: NSColor) -> Double {
            func channel(_ c: CGFloat) -> Double { let v = Double(c); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
        }
        // Claude is above the file: the line is between them, at the card's foot (its one point is two pixels;
        // the strongest of the three rows round it). Sampled away from text, on the right.
        let x = top.maxX - 60
        guard let content = pixel(x, top.minY + 40) else { return nil }
        let b = luminance(content)
        let ratio = [top.minY - 0.75, top.minY - 0.25, top.minY + 0.25].compactMap { pixel(x, $0) }.map { line -> Double in
            let a = luminance(line)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }.max() ?? 0
        // The accent as this picture holds it (the picture's colours are not the theme's to the last digit):
        // the selected tab's line in the tab row, drawn in the same colour.
        guard let row = tabView(setup.split), let focusedSlot = row.slots.first(where: { $0.pane == setup.claude.id }) else { return nil }
        let rowRect = windowRect(row)
        guard let accent = pixel(rowRect.minX + focusedSlot.minX + focusedSlot.width / 2, rowRect.maxY - 1) else { return nil }
        func isAccent(_ color: NSColor?) -> Bool {
            guard let color else { return false }
            return abs(color.redComponent - accent.redComponent) + abs(color.greenComponent - accent.greenComponent) + abs(color.blueComponent - accent.blueComponent) < 0.06
        }
        // Along each header's foot.
        let foot = FilePageView.headerHeight - 1
        let focusedTop = isAccent(pixel(top.midX, top.maxY - foot))
        let otherTop = isAccent(pixel(bottom.midX, bottom.maxY - foot))
        return (ratio, focusedTop, otherTop)
    }

    // MARK: Pictures

    /// The pictures the owner asked for, into `folder`.
    private func splitSnapshots(_ setup: SplitSetup, to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ThemeStore.shared
        let before = (store.themeID, store.appearance)
        WindowChrome.drawsAsKey = true
        defer {
            store.themeID = before.0
            store.appearance = before.1
            WindowChrome.drawsAsKey = DebugScenario.has("--key-look")
        }
        let looks: [(String, String, ThemeStore.Appearance)] = [("whiskr-light", BuiltInThemes.defaultID, .light), ("whiskr-dark", BuiltInThemes.defaultID, .dark), ("graphite", "graphite", .dark)]
        for (name, id, appearance) in looks {
            store.themeID = id
            store.appearance = appearance
            await restoreSplit(setup)
            func shot(_ what: String) async {
                await PerfWait.sleep(450)
                DebugShell.snapshot(window: controller, workbench: workbench, to: folder.appendingPathComponent("\(name)-\(what).png"))
            }
            // Claude over the file, as the owner had it.
            await shot("claude-over-file")
            // Side by side.
            if let page = pageID(in: setup.split) {
                workbench.close(page: page)
                workbench.open(file: setup.file.path, mode: .keep)
                if let tab = workbench.selectedTab, tab !== setup.split { workbench.dropTab(tab, onto: setup.claude.id, side: .right) }
                await shot("claude-beside-file")
            }
            // Three panes: a terminal below Claude.
            workbench.select(tab: setup.split, pane: setup.claude.id)
            shortcut("cmd+shift+d")
            let third = workbench.focusedPane
            if let third { _ = await shellReady(third) }
            await shot("three-panes")
            // The pointer on the file segment's ×.
            if let page = pageID(in: setup.split), let view = tabView(setup.split), let close = view.closePoint(of: page) {
                await hover(view, at: close)
                await shot("hover-segment-close")
                await rest()
            }
            if let third { workbench.close(pane: third.id) }
            // Too many tabs: the split one among them, the row overflowing.
            var extra: [Tab] = []
            for _ in 0..<12 {
                let pane = workbench.newTab()
                if let tab = workbench.workspace(of: pane.id)?.1 { extra.append(tab) }
            }
            workbench.select(tab: setup.split)
            await shot("overflow")
            for tab in extra { workbench.close(tab: tab) }
            await rest()
            // A few tabs: "+" after the last.
            let more = workbench.newTab()
            _ = await shellReady(more)
            workbench.select(tab: setup.split)
            await shot("row-with-plus")
            if let tab = workbench.workspace(of: more.id)?.1 { workbench.close(tab: tab) }
        }
        // Graphite: a terminal and the editor.
        store.themeID = "graphite"
        store.appearance = .dark
        setup.claude.type("clear; ls -la; printf '\\033[31mred \\033[32mgreen \\033[33myellow \\033[34mblue \\033[35mmagenta \\033[36mcyan\\033[0m\\n'\r")
        let swift = setup.root.appendingPathComponent("Example.swift")
        try? Data("import Foundation\n\n/// A greeting, said once.\nstruct Greeter {\n    let name: String\n    var count = 3\n\n    func greet() -> String {\n        // Say hello.\n        return \"Hello, \\(name)!\"\n    }\n}\n".utf8).write(to: swift)
        workbench.open(file: swift.path, mode: .keep)
        if let tab = workbench.selectedTab, tab !== setup.split { workbench.dropTab(tab, onto: setup.claude.id, side: .right) }
        await PerfWait.sleep(800)
        DebugShell.snapshot(window: controller, workbench: workbench, to: folder.appendingPathComponent("graphite-terminal-and-editor.png"))
        print("split: pictures in \(folder.path)")
    }
}
#endif
