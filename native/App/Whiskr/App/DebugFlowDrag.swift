#if DEBUG
import AppKit
import MeadowScene
import WhiskrKit

/// `--perf-flows drag` (`make perf`'s checks): tabs picked up and dropped with the mouse as a person does
/// it, every event through `NSApplication.sendEvent` (a press on the tab, the pointer moved a frame at a
/// time, the release or Esc): into another place in the row, onto each side of a pane, onto a pane's
/// middle, onto another workspace's blanket, onto nothing, onto its own pane, and given up with Esc; a split
/// tab dragged as one. For each: what the drag showed before the release is what the drop did (the place in
/// the row, the area of the pane within a few points of the pane it became), the held tab trailed the
/// pointer on its spring, swung while moving and settled level, with no jump from one frame to the next
/// and frames on the display's beat; and afterwards nothing is left: no held tab, no tinted area, no veil,
/// and the next click on a tab chooses it.
///
/// `--drag-snapshots <folder>`: a picture in the middle of each kind of drag, in Whiskr light and dark and
/// in Graphite.
extension PerfSuite {
    func dragCheck() async {
        guard let setup = await dragSetup() else { return }
        await dragIntoRow(setup)
        for side in [PaneTree.Direction.right, .left, .up, .down] { await dragSplit(setup, side: side) }
        await dragMoveHere(setup)
        await dragToWorkspace(setup)
        await dragNowhere(setup, escape: false)
        await dragNowhere(setup, escape: true)
        await dragOwnPane(setup)
        await dragSplitTab(setup)
        if let folder = DebugScenario.value("--drag-snapshots") { await dragSnapshots(setup, to: URL(fileURLWithPath: folder, isDirectory: true)) }
    }

    struct DragSetup {
        let workspace: Workspace
        let other: Workspace
    }

    /// Two workspaces (so a blanket to drop on), the first with four tabs of one pane each.
    private func dragSetup() async -> DragSetup? {
        let otherPane = workbench.newWorkspace(folder: folder("drag-other"))
        _ = await shellReady(otherPane)
        guard let other = workbench.selectedWorkspace else { return nil }
        let first = workbench.newWorkspace(folder: folder("drag-here"))
        _ = await shellReady(first)
        guard let workspace = workbench.selectedWorkspace, workspace !== other else { return nil }
        for _ in 0..<3 {
            let pane = workbench.newTab()
            _ = await shellReady(pane)
        }
        if !meadowShown { controller.toggleNavigator(nil) }
        await PerfWait.sleep(600)
        check("drag: set up (a workspace of four tabs, another workspace's blanket in the meadow)", workspace.tabs.count == 4 && meadowShown)
        return DragSetup(workspace: workspace, other: other)
    }

    /// Back to four tabs of one pane each in the first workspace, its first tab shown.
    private func dragReset(_ setup: DragSetup) async {
        if workbench.selectedWorkspace !== setup.workspace { workbench.select(workspace: setup.workspace) }
        // A tab moved to the other workspace comes back; split tabs come apart into tabs again.
        for tab in setup.other.tabs.dropFirst() { workbench.move(tab: tab, to: setup.workspace) }
        for tab in setup.workspace.tabs where tab.tree.panes.count > 1 {
            for pane in tab.tree.panes.dropFirst() { workbench.close(pane: pane) }
        }
        while setup.workspace.tabs.count < 4 {
            let pane = workbench.newTab()
            _ = await shellReady(pane)
        }
        workbench.select(tab: setup.workspace.tabs[0])
        if let content = window.contentView { await hover(content, at: NSPoint(x: content.bounds.maxX - 200, y: content.bounds.midY)) }
        await PerfWait.sleep(300)
    }

    /// What one drag did and showed.
    struct DragRecord {
        let samples: [TabDragOverlay.Sample]
        /// What a drop would have done just before the release.
        let target: TabDragging.Target?
        /// The tab's place among the others the row showed just before the release.
        let slot: Int?
        let grab: NSPoint
        let origin: NSRect
        let released: CFTimeInterval
        let stopped: CFTimeInterval
        let started: CFTimeInterval
    }

    enum DragEnd { case drop, escape }

    /// Presses on `tab` (where its first pane's segment is), moves the pointer to `end` (in the window) a
    /// frame at a time, rests there, and lets go (or presses Esc, then lets go). `midway` runs while it
    /// rests, before the release (a picture).
    func dragTab(_ tab: Tab, to end: NSPoint, steps: Int = 26, finish: DragEnd = .drop, midway: (() async -> Void)? = nil) async -> DragRecord? {
        guard let view = tabView(tab), let local = view.point(of: tab.tree.panes[0]) else { return nil }
        let origin = windowRect(view)
        let start = view.convert(local, to: nil)
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            PointerStandIn.location = point
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { return }
            NSApp.sendEvent(event)
        }
        TabDragOverlay.samples = []
        send(.leftMouseDown, start)
        let started = CACurrentMediaTime()
        for step in 1...steps {
            // Eased, as a hand moves: quick in the middle, slow at the ends.
            let t = Double(step) / Double(steps)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            send(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased))
            await PerfWait.sleep(16)
        }
        let stopped = CACurrentMediaTime()
        await PerfWait.sleep(450)
        await midway?()
        let target = TabDragging.shared.debugTarget
        let slot = TabDragState.shared.slot
        if finish == .escape, let escape = keyEvent("\u{1b}", code: 53) { NSApp.sendEvent(escape) }
        send(.leftMouseUp, end)
        let released = CACurrentMediaTime()
        _ = await PerfWait.until(3000) { !TabDragging.shared.debugActive }
        await PerfWait.sleep(100)
        return DragRecord(samples: TabDragOverlay.samples, target: target, slot: slot, grab: NSPoint(x: start.x - origin.minX, y: start.y - origin.minY),
                          origin: origin, released: released, stopped: stopped, started: started)
    }

    /// The held tab's motion: trailing the pointer while it moves, settled on it within half a second of its
    /// stopping, level at rest, swinging while moving, no frame-to-frame jump, frames on the display's beat.
    private func motionCheck(_ name: String, _ record: DragRecord) {
        let moving = record.samples.filter { $0.at >= record.started && $0.at <= record.stopped }
        let resting = record.samples.filter { $0.at > record.stopped && $0.at < record.released }
        guard moving.count > 5, !resting.isEmpty else { return check("drag: \(name): the held tab was drawn each frame", false, "\(moving.count) frames moving, \(resting.count) resting") }
        let lag = moving.map { hypot($0.position.x - $0.pointer.x, $0.position.y - $0.pointer.y) }.max() ?? 0
        let settledAt = resting.first { hypot($0.position.x - $0.pointer.x, $0.position.y - $0.pointer.y) < 0.75 }?.at
        let swing = moving.map { abs($0.tilt) }.max() ?? 0
        let level = abs(resting.last?.tilt ?? 1) < 0.003
        // While held, before the release (and before Esc): what the hand did, and what the picture did.
        let held = record.samples.filter { $0.at <= record.stopped + 0.4 }
        let steps = zip(held, held.dropFirst()).map { $0 }
        let jumps = steps.map { hypot($1.position.x - $0.position.x, $1.position.y - $0.position.y) }
        let pointerSteps = steps.map { hypot($1.pointer.x - $0.pointer.x, $1.pointer.y - $0.pointer.y) }
        let jump = jumps.max() ?? 0, pointerJump = pointerSteps.max() ?? 0
        let gaps = steps.map { ($1.at - $0.at) * 1000 }.sorted()
        let gap95 = gaps.isEmpty ? 0 : gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))]
        let reduce = !Look.Motion.moves
        print(String(format: "drag: %@: lag up to %.1f pt, settled %@ after the pointer stopped, swing up to %.1f°, largest step %.1f pt (the pointer's %.1f), frames p95 %.1f ms apart",
                     name, lag, settledAt.map { String(format: "%.0f ms", ($0 - record.stopped) * 1000) } ?? "never", swing * 180 / .pi, jump, pointerJump, gap95))
        check("drag: \(name): the held tab trails the pointer on its spring and settles on it within half a second",
              (reduce || lag > 3) && settledAt.map { $0 - record.stopped < 0.5 } == true, String(format: "lag %.1f pt", lag))
        check("drag: \(name): it swings while moving and is level at rest", (reduce || swing > 0.004) && level, String(format: "swing %.2f°", swing * 180 / .pi))
        check("drag: \(name): no jump from one frame to the next", jump <= pointerJump * 1.6 + 3, String(format: "largest %.1f pt, the pointer's %.1f", jump, pointerJump))
        let fast = MachineLoad.shared.others(from: (record.started - 0.2) * 1000, to: record.released * 1000).map { $0 <= MachineLoad.busyCores } ?? true
        if fast { check("drag: \(name): drawn on the display's beat (95 % of frames under 34 ms apart)", gap95 < 34, String(format: "p95 %.1f ms", gap95)) }
        else { print("drag: \(name): frame pacing not judged: the Mac was busy") }
    }

    /// Nothing of the drag left behind, and the row takes the next click.
    private func leftBehindCheck(_ name: String, _ setup: DragSetup) async {
        let overlay = window.contentView.flatMap { DebugShell.descendant(of: $0) { $0 is TabDragOverlay } }
        let state = TabDragState.shared
        var clean = overlay == nil && !TabDragging.shared.debugActive && state.tab == nil && state.landing == nil && state.slot == nil
        var detail = "overlay \(overlay != nil), drag \(TabDragging.shared.debugActive), state \(state.tab != nil)/\(state.landing != nil)/\(state.slot.map(String.init) ?? "-")"
        if let workspace = workbench.selectedWorkspace, let tab = workspace.tabs.first(where: { $0 !== workbench.selectedTab }), let view = tabView(tab),
           let point = view.point(of: tab.tree.panes[0]) {
            let chain = landing(at: view.convert(point, to: nil)).chain
            let hit = click(view, at: point)
            let chosen = await PerfWait.until(1000) { self.workbench.selectedTab === tab }
            clean = clean && hit === view && chosen != nil
            detail += ", the next click went to \(chain), chose \(chosen != nil)"
        }
        check("drag: \(name): nothing left behind, and the next click on a tab chooses it", clean, detail)
    }

    /// The held tab's last place, as the tab's frame (from its grab point).
    private func landedFrame(_ record: DragRecord) -> NSRect? {
        guard let last = record.samples.last else { return nil }
        return NSRect(x: last.position.x - record.grab.x, y: last.position.y - record.grab.y, width: record.origin.width, height: record.origin.height)
    }

    private func near(_ a: NSRect, _ b: NSRect, _ tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    // MARK: Each kind of drop

    private func dragIntoRow(_ setup: DragSetup) async {
        await dragReset(setup)
        let tabs = setup.workspace.tabs
        guard let last = tabView(tabs[3]), let row = controller.terminals.tabRow else { return }
        // The first tab, to just past the last one's middle.
        let end = NSPoint(x: windowRect(last).midX + 20, y: windowRect(row).midY)
        guard let record = await dragTab(tabs[0], to: end) else { return check("drag: into the row", false) }
        let moved = tabs[0]
        let place = setup.workspace.tabs.firstIndex { $0 === moved }
        check("drag: into the row: the row showed its place (after the last tab) and the drop put it there, chosen",
              record.target == .row(3) && record.slot == 3 && place == 3 && workbench.selectedTab === moved,
              "showed \(record.slot.map(String.init) ?? "-"), now at \(place.map(String.init) ?? "-")")
        if let landed = landedFrame(record), let view = tabView(moved) {
            check("drag: into the row: it landed exactly in its place", near(landed, windowRect(view), 2), "\(landed.integral) against \(windowRect(view).integral)")
        }
        motionCheck("into the row", record)
        await leftBehindCheck("into the row", setup)
    }

    /// Where to hold the pointer over the shown pane for a side, or its middle.
    private func panePoint(_ side: PaneTree.Direction?) -> NSPoint? {
        guard let pane = workbench.focusedPane, let card = pane.surface.superview?.superview else { return nil }
        let rect = card.convert(card.bounds, to: nil)
        switch side {
        case .right?: return NSPoint(x: rect.maxX - rect.width * 0.04, y: rect.midY)
        case .left?: return NSPoint(x: rect.minX + rect.width * 0.04, y: rect.midY)
        case .up?: return NSPoint(x: rect.midX, y: rect.maxY - rect.height * 0.04)
        case .down?: return NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.04)
        case nil: return NSPoint(x: rect.midX, y: rect.midY)
        }
    }

    private func dragSplit(_ setup: DragSetup, side: PaneTree.Direction) async {
        await dragReset(setup)
        let shown = setup.workspace.tabs[0], dragged = setup.workspace.tabs[2]
        guard let target = shown.tree.panes.first, let point = panePoint(side) else { return check("drag: split \(side)", false) }
        guard let record = await dragTab(dragged, to: point) else { return check("drag: split \(side)", false) }
        guard case .split(let leaf, let shownSide, let area)? = record.target else {
            return check("drag: split \(side): showed a split", false, "showed \(record.target.map { "\($0)" } ?? "nothing")")
        }
        let zone = record.samples.last { $0.zone != nil && $0.at < record.released }?.zone
        let joined = await PerfWait.until(2000) { shown.tree.panes.count == 2 && !setup.workspace.tabs.contains { $0 === dragged } }
        let newPane = dragged.tree.panes[0]
        let result = (workbench.panes[newPane]?.surface.superview?.superview).map { $0.convert($0.bounds, to: nil) }
        check("drag: split \(side): it showed “split \(side)” on that pane, and the drop split it there",
              leaf == target && shownSide == side && joined != nil && shown.tree.panes.contains(newPane), "panes \(shown.tree.panes.count)")
        if let result {
            check("drag: split \(side): the area shown is the pane it became (within 3 pt; drawn 2 pt inside it)",
                  near(area, result, 2) && zone.map { near($0, result, 3) } == true,
                  "area \(area.integral), drawn \(zone.map { "\($0.integral)" } ?? "-"), the pane \(result.integral)")
        }
        motionCheck("split \(side)", record)
        await leftBehindCheck("split \(side)", setup)
    }

    private func dragMoveHere(_ setup: DragSetup) async {
        await dragReset(setup)
        let shown = setup.workspace.tabs[1], dragged = setup.workspace.tabs[3]
        workbench.select(tab: shown)
        await PerfWait.sleep(200)
        guard let point = panePoint(nil), let record = await dragTab(dragged, to: point) else { return check("drag: move here", false) }
        guard case .move? = record.target else { return check("drag: move here: showed “Move Here”", false, "showed \(record.target.map { "\($0)" } ?? "nothing")") }
        let place = setup.workspace.tabs.firstIndex { $0 === dragged }
        check("drag: move here: the row showed its new place (the shown tab's) and the drop put it there, shown",
              record.slot == 1 && place == 1 && workbench.selectedTab === dragged, "showed \(record.slot.map(String.init) ?? "-"), now \(place.map(String.init) ?? "-")")
        motionCheck("move here", record)
        await leftBehindCheck("move here", setup)
    }

    /// The other workspace's blanket, in the window.
    private func blanketRect(_ workspace: Workspace) -> NSRect? {
        let meadow = controller.navigator.meadow
        return meadow.screenRect(of: .blanket(workspace.id.uuidString)).map { meadow.convert($0, to: nil) }
    }

    private func dragToWorkspace(_ setup: DragSetup) async {
        await dragReset(setup)
        let dragged = setup.workspace.tabs[2]
        guard let blanket = blanketRect(setup.other) else { return check("drag: to a workspace: its blanket in sight", false) }
        guard let record = await dragTab(dragged, to: NSPoint(x: blanket.midX, y: blanket.midY)) else { return check("drag: to a workspace", false) }
        let moved = await PerfWait.until(2000) { setup.other.tabs.contains { $0 === dragged } }
        var showed = false
        if case .workspace(let id, _)? = record.target { showed = id == setup.other.id }
        check("drag: to a workspace: it showed “Move to” that workspace, and the drop moved the tab there", showed && moved != nil,
              "showed \(record.target.map { "\($0)" } ?? "nothing"), moved \(moved != nil)")
        motionCheck("to a workspace", record)
        await leftBehindCheck("to a workspace", setup)
    }

    private func dragNowhere(_ setup: DragSetup, escape: Bool) async {
        await dragReset(setup)
        let name = escape ? "given up with Esc" : "dropped on nothing"
        let before = setup.workspace.tabs.map(\.id)
        let dragged = setup.workspace.tabs[2]
        // Over a pane for Esc (a drop there would split); over the status bar for nothing.
        let end = escape ? panePoint(.right) : NSPoint(x: windowRect(controller.terminals.paneArea).midX, y: 6)
        guard let end, let record = await dragTab(dragged, to: end, finish: escape ? .escape : .drop) else { return check("drag: \(name)", false) }
        let refused = record.samples.last { $0.at < record.released }.map { $0.opacity < 0.7 } ?? false
        check("drag: \(name): nothing changed", setup.workspace.tabs.map(\.id) == before && dragged.tree.panes.count == 1)
        if !escape { check("drag: \(name): the held tab showed it could not be dropped there", record.target == TabDragging.Target.none && refused) }
        if let landed = landedFrame(record), let view = tabView(dragged) {
            check("drag: \(name): it sprang back to its place", near(landed, windowRect(view), 2), "\(landed.integral) against \(windowRect(view).integral)")
        }
        motionCheck(name, record)
        await leftBehindCheck(name, setup)
    }

    private func dragOwnPane(_ setup: DragSetup) async {
        await dragReset(setup)
        let shown = setup.workspace.tabs[0]
        // The tab shown, dragged: its own pane is under the pointer.
        guard let point = panePoint(.right), let record = await dragTab(shown, to: point) else { return check("drag: onto its own pane", false) }
        check("drag: onto its own pane: shown as going nowhere, and nothing changes",
              record.target == .own && setup.workspace.tabs.count == 4 && shown.tree.panes.count == 1, "showed \(record.target.map { "\($0)" } ?? "nothing")")
        await leftBehindCheck("onto its own pane", setup)
    }

    private func dragSplitTab(_ setup: DragSetup) async {
        await dragReset(setup)
        let dragged = setup.workspace.tabs[2]
        workbench.select(tab: dragged)
        shortcut("cmd+d")
        _ = await PerfWait.until(2000) { dragged.tree.panes.count == 2 }
        if let added = workbench.focusedPane { _ = await shellReady(added) }
        workbench.select(tab: setup.workspace.tabs[0])
        await PerfWait.sleep(300)
        let shown = setup.workspace.tabs[0]
        guard let point = panePoint(.right), let record = await dragTab(dragged, to: point) else { return check("drag: a split tab", false) }
        let joined = await PerfWait.until(2000) { shown.tree.panes.count == 3 }
        var split = false
        if case .split? = record.target { split = true }
        check("drag: a split tab is picked up whole and goes beside the pane with both its panes", split && joined != nil, "panes \(shown.tree.panes.count)")
        await leftBehindCheck("a split tab", setup)
    }

    // MARK: Pictures

    private func dragSnapshots(_ setup: DragSetup, to folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = ThemeStore.shared
        let before = (store.themeID, store.appearance)
        WindowChrome.drawsAsKey = true
        defer {
            store.themeID = before.0
            store.appearance = before.1
            WindowChrome.drawsAsKey = DebugScenario.has("--key-look")
        }
        for (name, id, appearance) in [("whiskr-light", BuiltInThemes.defaultID, ThemeStore.Appearance.light), ("whiskr-dark", BuiltInThemes.defaultID, .dark), ("graphite", "graphite", .dark)] {
            store.themeID = id
            store.appearance = appearance
            let shoot = { (what: String) in
                DebugShell.snapshot(window: self.controller, workbench: self.workbench, to: folder.appendingPathComponent("\(name)-drag-\(what).png"))
            }
            await dragReset(setup)
            if let last = tabView(setup.workspace.tabs[2]), let row = controller.terminals.tabRow {
                _ = await dragTab(setup.workspace.tabs[0], to: NSPoint(x: windowRect(last).midX + 10, y: windowRect(row).midY), finish: .escape) { shoot("row-gap") }
            }
            for side in [PaneTree.Direction.left, .right, .up, .down] {
                await dragReset(setup)
                if let point = panePoint(side) { _ = await dragTab(setup.workspace.tabs[2], to: point, finish: .escape) { shoot("split-\(side)") } }
            }
            await dragReset(setup)
            workbench.select(tab: setup.workspace.tabs[1])
            await PerfWait.sleep(200)
            if let point = panePoint(nil) { _ = await dragTab(setup.workspace.tabs[3], to: point, finish: .escape) { shoot("move-here") } }
            await dragReset(setup)
            if let blanket = blanketRect(setup.other) { _ = await dragTab(setup.workspace.tabs[2], to: NSPoint(x: blanket.midX, y: blanket.midY), finish: .escape) { shoot("to-workspace") } }
            await dragReset(setup)
            _ = await dragTab(setup.workspace.tabs[2], to: NSPoint(x: windowRect(controller.terminals.paneArea).midX, y: 6), finish: .escape) { shoot("cannot-drop") }
        }
        print("drag: pictures in \(folder.path)")
    }
}
#endif
