#if DEBUG
import AppKit
import ObjectiveC
import WhiskrKit

/// `--perf-flows chrome` (`make perf`'s checks): every control of the top bar, the tab row and the status
/// bar, clicked as a person clicks it: a press and a release through `NSApplication.sendEvent` at the
/// control's middle and near each of its edges, landing wherever the window's views say is under that
/// point. Each click must do what the control does: a menu recorded with the right items, the meadow
/// toggled, Home shown, Go to shown, the panel toggled, Settings asked for, a tab chosen or closed.
///
/// It also stands in for the window server, which this run never reaches: a press inside the title bar's
/// band on a view that says the window may move there (`mouseDownCanMoveWindow`) moves the window in a
/// real one, so such a point "would drag the window" and fails, whatever the app does with the click here.
/// Menus are recorded instead of shown (`MenuStandIn`): nothing appears on screen and no menu's modal loop
/// holds the run. Settings and Open Folder… are asked for, not opened (`ActionStandIn`); window drags are
/// counted, not begun (`DragStandIn`).
extension PerfSuite {
    func chromeCheck() async {
        ActionStandIn.install()
        DragStandIn.install()
        KeyWindowStandIn.install()
        PointerStandIn.install()
        ActionStandIn.swallowing = [#selector(AppDelegate.showSettings(_:)), #selector(MainWindowController.openFolder(_:))]
        DragStandIn.swallows = true
        defer {
            ActionStandIn.swallowing = []
            DragStandIn.swallows = false
        }
        guard let setup = await chromeSetup() else { return }
        chromeBandCheck()
        // `--chrome-only <part>`: one part (top, tabs, overflow, home, status), when working on it.
        let only = DebugScenario.value("--chrome-only")
        if only == nil || only == "top" { await topBarSweep(setup) }
        if only == nil || only == "tabs" { await tabRowSweep(setup) }
        if only == nil || only == "overflow" { await overflowSweep(setup) }
        if only == nil || only == "home" { await homeSweep(setup) }
        if only == nil || only == "status" { await statusBarSweep(setup) }
        if only == nil || only == "changes" { await hitsAfterChanges(setup) }
        if only == nil || only == "edit" {
            await editBarSweep()
            await chromeRestore(setup)
        }
        check("chrome: no menu was shown for real (every one went to the stand-in)", MenuStandIn.tracked.isEmpty,
              MenuStandIn.tracked.joined(separator: "; "))
        await chromeRestore(setup)
    }

    // MARK: Setting up

    /// A repository with a commit (so the status bar shows its branch), a second workspace, a Claude in a
    /// tab of its own with a to-do list and a request waiting (the tab's progress ring, the status bar's
    /// "need you"), and a Swift file in the editor (the status bar's file details and menus).
    struct ChromeSetup {
        let repo: Workspace
        let other: Workspace
        let fileTab: Tab
        let claudeTab: Tab
    }

    private func chromeSetup() async -> ChromeSetup? {
        let root = URL(fileURLWithPath: folder("chrome-repo"), isDirectory: true)
        let file = root.appendingPathComponent("main.swift")
        try? Data("struct Main {\n    func run() {\n        print(\"chrome\")\n    }\n}\n".utf8).write(to: file)
        _ = git(["init", "-q", "-b", "main"], in: root)
        _ = git(["add", "."], in: root)
        _ = git(["-c", "user.name=Whiskr", "-c", "user.email=whiskr@example.invalid", "commit", "-qm", "start"], in: root)
        let shell = workbench.newWorkspace(folder: root.path)
        guard await shellReady(shell), let repo = workbench.selectedWorkspace else {
            check("chrome: the first shell drew its prompt", false)
            return nil
        }
        // A Claude (a stand-in the hooks speak for): a to-do list half done, and a request waiting.
        let claude = workbench.newTab()
        _ = await shellReady(claude)
        claude.debugPretendsClaude = true
        let events: [(String, [String: JSONValue])] = [
            ("UserPromptSubmit", [:]),
            ("TaskCreated", ["task_id": "1", "task_subject": "Read the bars"]),
            ("TaskCreated", ["task_id": "2", "task_subject": "Fix the buttons"]),
            ("TaskCompleted", ["task_id": "1", "task_subject": "Read the bars"]),
            ("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "make test"]]),
        ]
        for (event, extra) in events {
            var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": "chrome-claude", "cwd": .string(root.path)]
            payload.merge(extra) { _, new in new }
            workbench.monitor.simulate(paneID: claude.id, payload: .object(payload))
        }
        guard let claudeTab = workbench.selectedTab else { return nil }
        workbench.open(file: file.path)
        _ = await PerfWait.until(3000) { self.workbench.focusedDocument != nil }
        guard let fileTab = workbench.selectedTab, fileTab !== claudeTab else {
            check("chrome: the file opened in a tab of its own", false)
            return nil
        }
        let otherPane = workbench.newWorkspace(folder: folder("chrome-other"))
        _ = await shellReady(otherPane)
        guard let other = workbench.selectedWorkspace, other !== repo else { return nil }
        let setup = ChromeSetup(repo: repo, other: other, fileTab: fileTab, claudeTab: claudeTab)
        await chromeRestore(setup)
        let ready = await PerfWait.until(10000) {
            repo.branch != nil && self.workbench.agentRows.contains { $0.status == .blocked }
                && self.workbench.session(of: claude).flatMap { self.workbench.monitor.progress(sessionID: $0.id) } != nil
        }
        check("chrome: set up (a branch, a Claude asking with a to-do list, a file in the editor, two workspaces)", ready != nil,
              "branch \(repo.branch ?? "none"), requests \(workbench.agentRows.filter { $0.status == .blocked }.count), document \(workbench.focusedDocument != nil)")
        print("chrome: language \(Bundle.main.preferredLocalizations.first ?? "-"), appearance \(NSApp.effectiveAppearance.name.rawValue), window \(window.frame.size)")
        return setup
    }

    /// Back to the state every control is tried from: the repository's workspace with its file shown, no
    /// palette, no side panel, the meadow shown, nothing being renamed, the pointer away from the bars.
    private func chromeRestore(_ setup: ChromeSetup) async {
        if controller.palette?.isShown == true { controller.palette?.close() }
        popoverWindow?.close()
        workbench.renamingWorkspaceID = nil
        if workbench.selectedWorkspace !== setup.repo { workbench.select(workspace: setup.repo) }
        if workbench.selectedTab !== setup.fileTab { workbench.select(tab: setup.fileTab) }
        if workbench.files.panel(setup.repo.id).shown { workbench.setPanelShown(false) }
        if !meadowShown { controller.toggleNavigator(nil) }
        await restPointer()
        _ = await PerfWait.until(1500) { self.meadowShown && self.controller.palette?.isShown != true && self.workbench.focusedDocument != nil }
        await PerfWait.sleep(150)
        _ = MenuStandIn.take()
        ActionStandIn.sent = []
    }

    /// The pointer away from the bars, over the terminals.
    private func restPointer() async {
        guard let content = window.contentView else { return }
        await hover(content, at: NSPoint(x: content.bounds.maxX - 200, y: content.bounds.midY))
    }

    // MARK: The title bar's band

    /// What the window server treats as the title bar: the strip it may drag the window by. AppKit's own
    /// account when it gives one (`_draggableFrame`), else the window's height above its content layout rect.
    var titleBand: NSRect {
        let selector = NSSelectorFromString("_draggableFrame")
        if window.responds(to: selector) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
            let frame = unsafeBitCast(window.method(for: selector), to: Getter.self)(window, selector)
            if frame.height > 0 { return frame }
        }
        let layout = window.contentLayoutRect
        return NSRect(x: 0, y: layout.maxY, width: window.frame.width, height: window.frame.height - layout.maxY)
    }

    /// Whether AppKit tells the window server that a press at `point` (in the window) belongs to a view
    /// that takes it, rather than to the window's drag region (`_regionForOpaqueViewsBlockingDraggableFrame:`).
    func appKitBlocksDrag(at point: NSPoint) -> Bool? {
        let selector = NSSelectorFromString("_regionForOpaqueViewsBlockingDraggableFrame:")
        guard window.responds(to: selector) else { return nil }
        typealias Region = @convention(c) (AnyObject, Selector, NSRect) -> Unmanaged<AnyObject>?
        let region = unsafeBitCast(window.method(for: selector), to: Region.self)(window, selector, NSRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1))
        guard let text = region.map({ String(describing: $0.takeUnretainedValue()) }) else { return false }
        return text.contains("[") && !text.contains("empty")
    }

    /// Where a press at `point` (in the window) lands, and what a real window would do with it.
    struct Landing {
        let hit: NSView?
        let chain: String
        let wouldDrag: Bool
        let note: String
    }

    func landing(at point: NSPoint) -> Landing {
        let hit = window.contentView?.superview?.hitTest(point)
        var names: [String] = []
        var view = hit
        while let each = view, names.count < 3 {
            names.append("\(Self.typeName(each))\(each.mouseDownCanMoveWindow ? " (window moves)" : "")")
            view = each.superview
        }
        let inBand = titleBand.contains(point)
        let blocks = inBand ? appKitBlocksDrag(at: point) : nil
        let note = !inBand ? "below the title bar" : blocks == true ? "in the title bar, kept from the window server's drag region"
            : blocks == false ? "in the title bar, in the window server's drag region" : "in the title bar"
        return Landing(hit: hit, chain: names.joined(separator: " < "), wouldDrag: inBand && (hit?.mouseDownCanMoveWindow ?? true), note: note)
    }

    static func typeName(_ view: NSView) -> String {
        let name = String(describing: type(of: view))
        return name.count > 40 ? String(name.prefix(40)) + "…" : name
    }

    private func chromeBandCheck() {
        let band = titleBand
        let row = windowRect(controller.terminals.tabRow)
        let container = DebugShell.descendant(of: window.contentView!.superview!) { String(describing: type(of: $0)) == "NSTitlebarContainerView" }
        print("chrome: title bar band \(band) (\(band.height) pt): the window's height less its content layout rect's, "
              + "\(window.frame.height - window.contentLayoutRect.height) pt; the title bar's view \(container.map(windowRect) ?? .zero); "
              + "the top bar \(topBar.map(windowRect) ?? .zero); the tab row \(row)")
        check("chrome: the title bar's band holds the top bar only (the tab row starts below it)", row.maxY <= band.minY + 0.5,
              "band \(band.minY)…\(band.maxY), tab row up to \(row.maxY)")
    }

    // MARK: Clicking a control

    /// The middle of `rect` and a point near each of its edges (`inset` in).
    func chromePoints(_ rect: NSRect, inset: CGFloat = 2) -> [(String, NSPoint)] {
        [("middle", NSPoint(x: rect.midX, y: rect.midY)),
         ("left edge", NSPoint(x: rect.minX + inset, y: rect.midY)), ("right edge", NSPoint(x: rect.maxX - inset, y: rect.midY)),
         ("top edge", NSPoint(x: rect.midX, y: rect.maxY - inset)), ("bottom edge", NSPoint(x: rect.midX, y: rect.minY + inset))]
    }

    /// Clicks a control at its middle and near each edge, each from `reset`'s state, and checks `effect`
    /// after each: nil when the control did what it does, else what went wrong. `locate` finds it after the
    /// reset: the view that must take the click when the control has one, and its rect in the window. A
    /// click must never land where a real window would drag instead.
    func sweep(_ name: String, inset: CGFloat = 2, count: Int = 1, locate: () -> (NSView?, NSRect)?, reset: () async -> Void,
               effect: () async -> String?) async {
        var failures: [String] = []
        for place in ["middle", "left edge", "right edge", "top edge", "bottom edge"] {
            await reset()
            guard let (own, rect) = locate(), let point = chromePoints(rect, inset: inset).first(where: { $0.0 == place })?.1 else {
                failures.append("\(place): not on screen")
                continue
            }
            let landing = landing(at: point)
            _ = MenuStandIn.take()
            ActionStandIn.sent = []
            press(at: point, count: count)
            var problems: [String] = []
            if landing.wouldDrag { problems.append("would drag the window") }
            if let own, let hit = landing.hit, hit !== own, !hit.isDescendant(of: own) { problems.append("the click went to \(Self.typeName(hit)), not the control") }
            if let wrong = await effect() { problems.append(wrong) }
            print("chrome: \(name), \(place) \(point): lands on \(landing.chain); \(landing.note); \(problems.isEmpty ? "ok" : problems.joined(separator: ", "))")
            if !problems.isEmpty { failures.append("\(place): \(problems.joined(separator: ", "))") }
        }
        check("chrome: \(name), clicked at its middle and near each edge, does what it does", failures.isEmpty, failures.joined(separator: "; "))
    }

    /// A control of the bars by its identifier (`BarControl`'s), on screen.
    func barView(_ id: String) -> NSView? {
        guard let root = window.contentView?.superview else { return nil }
        return DebugShell.descendant(of: root) { $0.identifier?.rawValue == id && !$0.isHiddenOrHasHiddenAncestor }
    }

    /// A click at `point` (in the window) through the app's event path, its release queued before the press:
    /// whatever the press begins (a window's resize or drag loop, a control's own tracking) ends with it, as
    /// a person's click does, instead of waiting for a release that would never come.
    func press(at point: NSPoint, count: Int = 1) {
        PointerStandIn.location = point
        for number in 1...count {
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: number, pressure: 1),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: number, pressure: 0) else { continue }
            QueuedEvents.post(up)
            NSApp.sendEvent(down)
        }
    }

    /// A control by its identifier, with its rect in the window.
    func barControl(_ id: String) -> (NSView?, NSRect)? {
        barView(id).map { ($0, windowRect($0)) }
    }

    func windowRect(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }

    /// The one menu a click just popped, from `view`; nil, with what was recorded, otherwise.
    func poppedMenu(from view: NSView) -> (MenuStandIn.Popped?, String) {
        let popped = MenuStandIn.take()
        guard popped.count == 1, let menu = popped.first else { return (nil, "\(popped.count) menus popped") }
        if menu.view !== view { return (nil, "a menu popped in \(menu.view.map(Self.typeName) ?? "no view"), not the control") }
        return (menu, "")
    }

    /// What is drawn at `point` (in the window), as one shade (0 black … 1 white), by the hosting view that
    /// draws the control (its fills are SwiftUI's).
    func shade(at point: NSPoint, in control: NSView) -> Double? {
        var host: NSView? = control
        while let view = host, !String(describing: type(of: view)).contains("HostingView") { host = view.superview }
        guard let host else { return nil }
        let local = host.convert(point, from: nil)
        let rect = NSRect(x: local.x - 1, y: local.y - 1, width: 2, height: 2)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        host.cacheDisplay(in: rect, to: rep)
        guard let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { return nil }
        return Double(0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent)
    }

    /// Where a control's fills show and no label is drawn: just inside its leading edge.
    func fillPoint(_ control: NSView) -> NSPoint {
        let rect = windowRect(control)
        return NSPoint(x: rect.minX + 3, y: rect.midY)
    }

    /// The control's hover fill: the pointer resting on it changes its shade.
    func hoverLook(_ name: String, _ control: NSView) async {
        let point = fillPoint(control)
        await restPointer()
        await PerfWait.sleep(150)
        let before = shade(at: point, in: control)
        await hover(window.contentView!.superview!, at: point)
        await PerfWait.sleep(200)
        let over = shade(at: point, in: control)
        await restPointer()
        let change = before.flatMap { a in over.map { abs($0 - a) } } ?? 0
        check("chrome: \(name) shows the hover fill under the pointer", change > 0.015,
              String(format: "shade %.3f → %.3f", before ?? -1, over ?? -1))
    }

    /// The stand-in looks at the control while its menu is open; returns its shade at rest.
    func watchPressedLook(_ control: NSView) -> Double? {
        let point = fillPoint(control)
        let base = shade(at: point, in: control)
        MenuStandIn.whileOpen = { [weak self] _ in self?.shade(at: point, in: control) }
        return base
    }

    /// Clicks a menu control in its middle and checks the menu it pops: under the control and aligned to it,
    /// `expected` titles there in that order (`first` leading it), `checked` ticked, every item with an
    /// action enabled and reaching something that takes it, and the control pressed while it is open.
    func menuCheck(_ name: String, _ control: NSView, expected: [String], first: [String] = [], checked: String?) -> MenuStandIn.Popped? {
        let base = watchPressedLook(control)
        let rect = windowRect(control)
        press(at: NSPoint(x: rect.midX, y: rect.midY))
        MenuStandIn.whileOpen = nil
        let (popped, why) = poppedMenu(from: control)
        guard let popped else {
            check("chrome: \(name)'s menu pops", false, why)
            return nil
        }
        let titles = popped.items.filter { !$0.separator }.map(\.title)
        var problems: [String] = []
        var at = 0
        for title in expected {
            guard let found = titles[at...].firstIndex(of: title) else { problems.append("“\(title)” missing or out of order"); continue }
            at = found + 1
        }
        if !first.isEmpty, Array(titles.prefix(first.count)) != first { problems.append("starts \(titles.prefix(first.count)), not \(first)") }
        let ticked = popped.items.filter(\.on).map(\.title)
        if let checked, ticked != [checked] { problems.append("ticked \(ticked), not “\(checked)”") }
        let dead = popped.items.filter { !$0.separator && !$0.header && $0.action != nil && (!$0.enabled || $0.target == nil) }
        if !dead.isEmpty { problems.append("disabled or reaching nothing: \(dead.map { "\($0.title) (\($0.action ?? "-") → \($0.target ?? "nothing"))" })") }
        let under = popped.location.y >= control.bounds.height - 0.5 && abs(popped.location.x) < 0.5 && popped.positioning == nil && control.isFlipped
        if !under { problems.append("popped at \(popped.location) of the control, not under it and aligned to it") }
        if let look = popped.lookWhileOpen, let base {
            if abs(look - base) < 0.03 { problems.append(String(format: "not pressed while open (shade %.3f, at rest %.3f)", look, base)) }
        } else {
            problems.append("its look while open not seen")
        }
        print("chrome: \(name)'s menu: " + popped.items.map { item in
            item.separator ? "—" : (item.header ? "[\(item.title)]" : "\(item.on ? "✓ " : "")\(item.title)\(item.enabled ? "" : " (disabled)")\(item.target.map { " → \($0)" } ?? "")")
        }.joined(separator: " | "))
        check("chrome: \(name)'s menu: under it, the right items, each enabled and reaching its target, the control pressed while open",
              problems.isEmpty, problems.joined(separator: "; "))
        return popped
    }

    // MARK: The top bar

    private func topBarSweep(_ setup: ChromeSetup) async {
        guard let bar = topBar else { return check("chrome: the top bar", false) }
        let frame = windowRect(bar)
        let size = Look.Height.iconButton, height = Look.Height.control, gap = Look.Space.xs
        // Where the bar's buttons are drawn: after the traffic lights, and from the trailing end.
        func icon(_ x: CGFloat) -> NSRect { NSRect(x: frame.minX + x - size / 2, y: frame.midY - height / 2, width: size, height: height) }
        let lead = (window.standardWindowButton(.zoomButton)?.frame.maxX ?? 72) + Look.Space.s
        let meadow = icon(lead + size / 2)
        let home = icon(lead + size + gap + size / 2)
        let settings = icon(frame.width - Look.Space.m - size / 2)
        let panel = icon(frame.width - Look.Space.m - size - gap - size / 2)
        let new = icon(frame.width - Look.Space.m - 2 * (size + gap) - size / 2)
        let fieldWidth = min(480, frame.width - 2 * 168)
        let field = NSRect(x: frame.midX - fieldWidth / 2, y: frame.midY - 12, width: fieldWidth, height: 24)
        let restore = { await self.chromeRestore(setup) }

        await sweep("the meadow button", locate: { (self.barView("bar.sidebar.left"), meadow) }, reset: restore) {
            await PerfWait.until(1500) { !self.meadowShown } == nil ? "the meadow stayed" : nil
        }
        await sweep("the top bar's Home button", locate: { (self.barView("bar.house"), home) }, reset: restore) {
            await PerfWait.until(1500) { self.workbench.isHome } == nil ? "Home not shown" : nil
        }
        await sweep("the Go to field", inset: 4, locate: { (nil, field) }, reset: restore) {
            await PerfWait.until(1500) { self.controller.palette?.isShown == true } == nil ? "Go to not shown" : nil
        }
        await sweep("the top bar's +", locate: { (self.barView("bar.new"), new) }, reset: restore) {
            MenuStandIn.popped.count == 1 ? nil : "no menu"
        }
        await sweep("the panel button", locate: { (self.barView("bar.panel"), panel) }, reset: restore) {
            await PerfWait.until(1500) { self.workbench.files.panel(setup.repo.id).shown } == nil ? "Files and Changes not shown" : nil
        }
        await sweep("the Settings button", locate: { (self.barView("bar.gearshape"), settings) }, reset: restore) {
            await PerfWait.until(1500) { ActionStandIn.sent.contains(#selector(AppDelegate.showSettings(_:))) } == nil ? "Settings not asked for" : nil
        }
        // The empty stretch between Home and the field belongs to the window, as a title bar's does.
        await restore()
        let stretch = NSPoint(x: (home.maxX + field.minX) / 2, y: frame.midY)
        let drags = DragStandIn.drags
        let landed = landing(at: stretch)
        press(at: stretch)
        print("chrome: the top bar's empty stretch \(stretch): lands on \(landed.chain); \(landed.note)")
        check("chrome: the top bar's empty stretch moves the window", landed.wouldDrag && DragStandIn.drags > drags, landed.chain)

        await restore()
        if let plus = barView("bar.new") {
            _ = menuCheck("the top bar's +", plus, expected: [String(localized: "New Tab"), String(localized: "New Workspace"), String(localized: "Open Folder…"),
                                                              String(localized: "New Worktree…")], checked: nil)
        } else {
            check("chrome: the top bar's + is a control of its own", false, "no view under it: the hosting view takes the click")
        }
        for (name, id) in [("the meadow button", "bar.sidebar.left"), ("the top bar's Home button", "bar.house"), ("the top bar's +", "bar.new"),
                           ("the panel button", "bar.panel"), ("the Settings button", "bar.gearshape")] {
            await restore()
            // The meadow's button shows the selected fill while the meadow is shown: its hover, with it hidden.
            if id == "bar.sidebar.left" {
                controller.toggleNavigator(nil)
                _ = await PerfWait.until(1500) { !self.meadowShown }
            }
            if let view = barView(id) { await hoverLook(name, view) } else { check("chrome: \(name) is a control of its own", false) }
        }
        await restore()
    }

    // MARK: The tab row

    private func tabRowSweep(_ setup: ChromeSetup) async {
        let restore = { await self.chromeRestore(setup) }
        let workspaceName = { setup.repo.name }

        await sweep("the workspace button", locate: { self.barControl("bar.workspace") }, reset: restore) {
            MenuStandIn.popped.count == 1 ? nil : "no menu"
        }
        await restore()
        if let button = barView("bar.workspace") {
            let home = String(localized: "Home", comment: "Go menu and the workspace menu: no workspace selected")
            let popped = menuCheck("the workspace button", button,
                                   expected: [String(localized: "New Workspace"), String(localized: "Open Folder…"), home, workspaceName(), setup.other.name,
                                              String(localized: "New Worktree…"), String(localized: "Open Worktree…"), String(localized: "Go to…"),
                                              String(localized: "Rename Workspace…"), String(localized: "Close Workspace")],
                                   first: [String(localized: "New Workspace"), String(localized: "Open Folder…")], checked: workspaceName())
            // Choosing the other workspace in it shows that workspace.
            if let popped, let index = popped.menu.items.firstIndex(where: { $0.title == setup.other.name }) {
                popped.menu.performActionForItem(at: index)
                check("chrome: the workspace menu's other workspace shows it", await PerfWait.until(2000) { self.workbench.selectedWorkspace === setup.other } != nil)
            }
            // A double-click renames it in place.
            await restore()
            if let rect = barControl("bar.workspace")?.1 {
                let point = NSPoint(x: rect.midX, y: rect.midY)
                press(at: point, count: 2)
                check("chrome: a double-click on the workspace button renames the workspace in place",
                      await PerfWait.until(1500) { self.workbench.renamingWorkspaceID == setup.repo.id } != nil)
            }
            await restore()
            if let again = barView("bar.workspace") { await hoverLook("the workspace button", again) }
        } else {
            check("chrome: the workspace button is a control of its own", false, "no view under it: the hosting view takes the click")
        }

        // Each tab, chosen from another one.
        let tabs = setup.repo.tabs
        for (index, tab) in tabs.enumerated() {
            let other = tabs[(index + 1) % tabs.count]
            await sweep("tab \(index + 1)", locate: {
                guard let view = self.tabView(tab) else { return nil }
                let rect = self.windowRect(view)
                return (view, NSRect(x: rect.minX, y: rect.minY, width: rect.width - TabMouseView.closeReach - 2, height: rect.height))
            }, reset: {
                await restore()
                self.workbench.select(tab: other)
                await PerfWait.sleep(100)
            }) {
                await PerfWait.until(1500) { self.workbench.selectedTab === tab } == nil ? "not chosen" : nil
            }
        }
        // A tab's close button: its middle and near its edges, each on a new tab of its own.
        var closing: Tab?
        await sweep("a tab's close button", locate: {
            guard let closing, let view = self.tabView(closing) else { return nil }
            let middle = view.convert(view.closePoint, to: nil), half = TabMouseView.closeSize / 2
            return (view, NSRect(x: middle.x - half, y: middle.y - half, width: 2 * half, height: 2 * half))
        }, reset: {
            await restore()
            _ = self.workbench.newTab()
            closing = self.workbench.selectedTab
            await PerfWait.sleep(300)
        }) {
            await PerfWait.until(1500) { !setup.repo.tabs.contains { $0 === closing } } == nil ? "not closed" : nil
        }

        // The row's "+", after the last tab (`DebugFlowSplit` checks where).
        var count = 0
        await sweep("the tab row's +", locate: { self.barControl("bar.tabs.new") }, reset: {
            await restore()
            count = setup.repo.tabs.count
        }) {
            let made = await PerfWait.until(1500) { setup.repo.tabs.count == count + 1 }
            if made != nil, let tab = setup.repo.tabs.last { self.workbench.close(tab: tab) }
            return made == nil ? "no new tab" : nil
        }
        await restore()
        if let view = barView("bar.tabs.new") { await hoverLook("the tab row's +", view) } else { check("chrome: the tab row's + is a control of its own", false) }

        // The Claude's to-do ring, on its tab, between the title and the close button: a click opens its
        // list, a second closes it. The tab's view takes the click, where the tab is now (`TabMouseView`).
        let ring = { () -> (NSView?, NSRect)? in
            guard let view = self.tabView(setup.claudeTab), let ring = view.ringRect(of: setup.claudeTab.focusedPane) else { return nil }
            return (view, view.convert(ring, to: nil))
        }
        let ringReset = {
            await restore()
            self.workbench.select(tab: setup.claudeTab)
            // Its to-do list is kept once its tab is on screen (the workbench's next tick).
            _ = await PerfWait.until(3000) {
                setup.claudeTab.tree.panes.compactMap { self.workbench.panes[$0].flatMap(self.workbench.session(of:)) }
                    .contains { self.workbench.monitor.details[$0.id]?.tasks.isEmpty == false }
            }
            await PerfWait.sleep(200)
        }
        await sweep("the to-do progress button", locate: ring, reset: ringReset) {
            guard await PerfWait.until(1500, { self.popoverWindow != nil }) != nil else { return "the to-do list not shown" }
            guard let rect = ring()?.1 else { return "the ring gone once its list was shown" }
            self.press(at: NSPoint(x: rect.midX, y: rect.midY))
            return await PerfWait.until(1500) { self.popoverWindow == nil } == nil ? "the to-do list not closed by a second click" : nil
        }
        // Clicked again while its list is still closing, it opens the list anew, and the list stays up.
        await ringReset()
        if let rect = ring()?.1 {
            let middle = NSPoint(x: rect.midX, y: rect.midY)
            press(at: middle)
            let opened = await PerfWait.until(1500) { self.popoverWindow != nil } != nil
            press(at: middle)
            // Each press's release comes through the run loop before the next press.
            await PerfWait.sleep(20)
            press(at: middle)
            await PerfWait.sleep(600)
            let stayed = popoverWindow != nil
            press(at: middle)
            let closed = await PerfWait.until(1500) { self.popoverWindow == nil } != nil
            check("chrome: the to-do list, closed and at once opened again, stays up until the ring closes it", opened && stayed && closed,
                  "opened \(opened), up after reopening \(stayed), closed after \(closed)")
        } else {
            check("chrome: the to-do list, closed and at once opened again, stays up until the ring closes it", false, "no ring on the Claude's tab")
        }
        // Its hover fill, a bar button's, just inside the ring's button (outside the ring's stroke).
        await ringReset()
        if let (view, rect) = ring(), let view {
            let point = NSPoint(x: rect.minX + 1.5, y: rect.midY)
            let before = shade(at: point, in: view)
            await hover(window.contentView!.superview!, at: NSPoint(x: rect.midX, y: rect.midY))
            await PerfWait.sleep(200)
            let over = shade(at: point, in: view)
            await restPointer()
            let change = before.flatMap { a in over.map { abs($0 - a) } } ?? 0
            check("chrome: the to-do ring shows the hover fill under the pointer", change > 0.015, String(format: "shade %.3f → %.3f", before ?? -1, over ?? -1))
        }

        // The row's empty stretch, after the tabs (a wider window, so the tabs leave one): the window's, as
        // the top bar's.
        await restore()
        let size = window.contentView!.frame.size
        window.setContentSize(NSSize(width: 1800, height: size.height))
        await PerfWait.sleep(300)
        let wide = windowRect(controller.terminals.tabRow)
        let stretch = NSPoint(x: ((barControl("bar.tabs.new")?.1.maxX ?? wide.minX) + wide.maxX) / 2, y: wide.midY)
        let drags = DragStandIn.drags
        let landed = landing(at: stretch)
        press(at: stretch)
        print("chrome: the tab row's empty stretch \(stretch): lands on \(landed.chain); \(landed.note)")
        check("chrome: the tab row's empty stretch moves the window", DragStandIn.drags > drags, landed.chain)
        window.setContentSize(size)
        await restore()
    }

    /// The popover a tab's to-do ring shows, while it is up.
    var popoverWindow: NSWindow? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
    }

    /// Too many tabs for the row: the chevron's menu lists every tab, the one shown ticked.
    private func overflowSweep(_ setup: ChromeSetup) async {
        await chromeRestore(setup)
        let size = window.contentView!.frame.size
        window.setContentSize(NSSize(width: 1000, height: size.height))
        var added: [Tab] = []
        while setup.repo.tabs.count < 14 {
            let pane = workbench.newTab()
            if let tab = workbench.workspace(of: pane.id)?.1 { added.append(tab) }
        }
        let reset = {
            if self.workbench.selectedTab !== setup.fileTab { self.workbench.select(tab: setup.fileTab) }
            await self.restPointer()
            await PerfWait.sleep(300)
            _ = MenuStandIn.take()
        }
        await reset()
        await sweep("the tab row's chevron", locate: { self.barControl("bar.tabs.all") }, reset: reset) {
            MenuStandIn.popped.count == 1 ? nil : "no menu"
        }
        await reset()
        if let chevron = barView("bar.tabs.all") {
            let popped = menuCheck("the tab row's chevron", chevron, expected: setup.repo.tabs.map { workbench.title(of: $0) }, checked: workbench.title(of: setup.fileTab))
            if let popped, let first = setup.repo.tabs.first {
                popped.menu.performActionForItem(at: 0)
                check("chrome: the chevron's first item shows the first tab", await PerfWait.until(1500) { self.workbench.selectedTab === first } != nil)
            }
            await reset()
            if let again = barView("bar.tabs.all") { await hoverLook("the tab row's chevron", again) }
        } else {
            check("chrome: the tab row's chevron is a control of its own", false, "no view under it: the hosting view takes the click")
        }
        for tab in added { workbench.close(tab: tab) }
        window.setContentSize(size)
        await chromeRestore(setup)
    }

    // MARK: Home

    private func homeSweep(_ setup: ChromeSetup) async {
        let reset = {
            await self.chromeRestore(setup)
            self.workbench.goHome()
            _ = await PerfWait.until(1500) { self.workbench.isHome }
            await PerfWait.sleep(200)
        }
        await sweep("the tab row's Home button", locate: { self.barControl("bar.place-home") }, reset: reset) {
            MenuStandIn.popped.count == 1 ? nil : "no menu"
        }
        await reset()
        if let button = barView("bar.place-home") {
            let home = String(localized: "Home", comment: "Go menu and the workspace menu: no workspace selected")
            let popped = menuCheck("the tab row's Home button", button,
                                   expected: [String(localized: "New Workspace"), String(localized: "Open Folder…"), home, setup.repo.name, setup.other.name, String(localized: "Go to…")],
                                   first: [String(localized: "New Workspace"), String(localized: "Open Folder…")], checked: home)
            if let popped {
                let titles = popped.items.map(\.title)
                check("chrome: on Home the workspace menu offers no Rename or Close",
                      !titles.contains(String(localized: "Rename Workspace…")) && !titles.contains(String(localized: "Close Workspace")))
                // New Workspace and Open Folder… go to the window, which takes them (Open Folder…'s sheet is not opened here).
                for title in [String(localized: "New Workspace"), String(localized: "Open Folder…")] {
                    guard let index = popped.menu.items.firstIndex(where: { $0.title == title }), let action = popped.menu.items[index].action else { continue }
                    ActionStandIn.sent = []
                    popped.menu.performActionForItem(at: index)
                    check("chrome: the Home menu's “\(title)” is sent and reaches the window's controller",
                          ActionStandIn.sent.contains(action) && NSApp.target(forAction: action, to: nil, from: nil) is MainWindowController,
                          "sent \(ActionStandIn.sent.map(NSStringFromSelector))")
                }
            }
            await reset()
            if let again = barView("bar.place-home") { await hoverLook("the tab row's Home button", again) }
        } else {
            check("chrome: the tab row's Home button is a control of its own", false, "no view under it: the hosting view takes the click")
        }
        await chromeRestore(setup)
    }

    // MARK: Right after the bars change

    /// Every control of the bars takes a click at its middle at once after the bars change under it (a tab
    /// opened, closed, split, dropped beside a pane; Home and back), in the same turn and a frame later:
    /// what a press lands on, as the window delivers it, is the control, never SwiftUI's drawing over it.
    private func hitsAfterChanges(_ setup: ChromeSetup) async {
        await chromeRestore(setup)
        var failures: [String] = []
        var looked = 0
        func controls() -> [NSView] {
            var found: [NSView] = []
            func walk(_ view: NSView) {
                if (view is BarControlView || view is TabMouseView) && !view.isHiddenOrHasHiddenAncestor { found.append(view) }
                view.subviews.forEach(walk)
            }
            // The bars' own (a pane's header lies under Home while Home is shown, rightly out of reach).
            for root in [topBar, controller.terminals.tabRow, frameController?.statusBar].compactMap({ $0 }) { walk(root) }
            return found
        }
        func look(_ moment: String) {
            for control in controls() {
                let rect = windowRect(control)
                guard rect.width > 4, rect.height > 4, window.contentView?.bounds.contains(NSPoint(x: rect.midX, y: rect.midY)) == true else { continue }
                looked += 1
                let hit = landing(at: NSPoint(x: rect.midX, y: rect.midY)).hit
                if hit !== control && hit?.isDescendant(of: control) != true {
                    failures.append("\(moment): \(control.identifier?.rawValue ?? Self.typeName(control)) → \(hit.map(Self.typeName) ?? "nothing")")
                }
                // A tab's to-do rings are its view's to click, where the tab is now.
                guard let tab = control as? TabMouseView else { continue }
                for ring in tab.slots.compactMap({ tab.ringRect(of: $0.pane) }).map({ tab.convert($0, to: nil) }) {
                    looked += 1
                    let hit = landing(at: NSPoint(x: ring.midX, y: ring.midY)).hit
                    if hit !== tab { failures.append("\(moment): a to-do ring → \(hit.map(Self.typeName) ?? "nothing")") }
                }
            }
        }
        let changes: [(String, () -> Void)] = [
            ("a tab opened", { _ = self.workbench.newTab() }),
            ("a split", { self.workbench.split(.horizontal) }),
            ("a pane closed", { if let pane = self.workbench.focusedPane, (self.workbench.selectedTab?.tree.panes.count ?? 0) > 1 { self.workbench.close(pane: pane.id) } }),
            ("a tab dropped beside a pane", {
                if let tab = self.workbench.selectedTab, let other = setup.repo.tabs.first(where: { $0 !== tab && self.workbench.panes[$0.focusedPane] != nil }) {
                    self.workbench.dropTab(tab, onto: other.focusedPane, side: .right)
                }
            }),
            ("a tab closed", { if let tab = self.workbench.selectedTab, setup.repo.tabs.count > 2 { self.workbench.close(tab: tab) } }),
            ("Home", { self.workbench.goHome() }),
            ("back from Home", { self.workbench.select(workspace: setup.repo) }),
        ]
        for round in 0..<6 {
            for (name, change) in changes {
                change()
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                look("round \(round + 1), \(name), at once")
                await PerfWait.sleep(17)
                look("round \(round + 1), \(name), a frame later")
            }
        }
        print("chrome: right after the bars changed, \(looked) presses looked at, \(failures.count) not on their control\(failures.isEmpty ? "" : ": " + failures.prefix(8).joined(separator: "; "))")
        check("chrome: right after the bars change (tabs opened, split, closed, dropped; Home and back), every control takes a press at its middle",
              failures.isEmpty, "\(failures.count) of \(looked): " + failures.prefix(6).joined(separator: "; "))
        await chromeRestore(setup)
    }

    // MARK: The status bar

    private func statusBarSweep(_ setup: ChromeSetup) async {
        let restore = { await self.chromeRestore(setup) }
        await restore()
        await sweep("the status bar's branch", locate: { self.barControl("status.branch") }, reset: restore) {
            let panel = { self.workbench.files.panel(setup.repo.id) }
            return await PerfWait.until(1500) { panel().shown && panel().mode == .changes } == nil ? "Changes not shown" : nil
        }
        await restore()
        if let branch = barView("status.branch") { await hoverLook("the status bar's branch", branch) }
        await sweep("the status bar's “need you”", locate: { self.barControl("status.requests") }, reset: restore) {
            await PerfWait.until(1500) { self.workbench.selectedTab === setup.claudeTab } == nil ? "the request's tab not shown" : nil
        }
        for (id, name, title) in [("status.indentation", "indentation", String(localized: "Spaces: \(2)")),
                                  ("status.line-ending", "line endings", LineEnding.crlf.label),
                                  ("status.language", "language", "Python")] {
            await sweep("the status bar's \(name) menu", locate: { self.barControl(id) }, reset: restore) {
                MenuStandIn.popped.count == 1 ? nil : "no menu"
            }
            await restore()
            guard let view = barView(id) else { continue }
            let popped = menuCheck("the status bar's \(name)", view, expected: [title], checked: nil)
            if let popped, let index = popped.menu.items.firstIndex(where: { $0.title == title }), let document = workbench.focusedDocument {
                let before = (document.indentation, document.format.lineEnding, document.language.displayName)
                popped.menu.performActionForItem(at: index)
                await PerfWait.sleep(200)
                let after = (document.indentation, document.format.lineEnding, document.language.displayName)
                check("chrome: the status bar's \(name) menu's “\(title)” takes effect", before.0 != after.0 || before.1 != after.1 || before.2 != after.2,
                      "\(before) → \(after)")
                document.indentation = before.0
                document.setLineEnding(before.1)
                document.choose(language: nil)
            }
            await restore()
            if let again = barView(id) { await hoverLook("the status bar's \(name) menu", again) }
        }
        for (id, name, action) in [("status.go-to", "⌘P Go to", #selector(MainWindowController.goTo(_:))),
                                   ("status.commands", "⇧⌘P Commands", #selector(MainWindowController.showCommandPalette(_:)))] {
            await sweep("the status bar's \(name)", locate: { self.barControl(id) }, reset: restore) {
                let shown = await PerfWait.until(1500) { self.controller.palette?.isShown == true }
                return shown != nil && ActionStandIn.sent.contains(action) ? nil : "the palette not shown (sent \(ActionStandIn.sent.map(NSStringFromSelector)))"
            }
        }
        await restore()
    }
}

/// Menus in a background run: recorded instead of shown (`DebugScript.keepOutOfSight` installs it). A real
/// pop-up menu would appear on this Mac's screen and hold the run in its modal loop until someone chose an
/// item. Kept for the checks: the menu's items, which AppKit enables (validated as just before showing) and
/// what each reaches, where it was to appear, and what the control drew while it was open (the run loop
/// runs for a moment as the menu's own tracking would before that is looked at). A menu that begins
/// tracking some other way is closed at once and noted.
@MainActor
enum MenuStandIn {
    struct Item {
        let title: String
        let enabled: Bool
        let on: Bool
        let separator: Bool
        let header: Bool
        let action: String?
        /// What the item's action reaches: its own target, else the first in the responder chain to take it.
        let target: String?
    }

    struct Popped {
        let menu: NSMenu
        let view: NSView?
        let location: NSPoint
        let positioning: NSMenuItem?
        let items: [Item]
        let lookWhileOpen: Double?
    }

    private(set) static var popped: [Popped] = []
    /// Menus that began tracking for real: each a failure of the stand-in.
    private(set) static var tracked: [String] = []
    /// Looks at the control while its menu is open (`PerfSuite.watchPressedLook`).
    static var whileOpen: ((NSView?) -> Double?)?
    private static var installed = false

    static func take() -> [Popped] {
        defer { popped = [] }
        return popped
    }

    static func install() {
        guard !installed, let from = class_getInstanceMethod(NSMenu.self, #selector(NSMenu.popUp(positioning:at:in:))),
              let to = class_getInstanceMethod(NSMenu.self, #selector(NSMenu.debugRecordedPopUp(positioning:at:in:))) else { return }
        installed = true
        method_exchangeImplementations(from, to)
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            // Posted on the main thread, by the menu's own tracking.
            nonisolated(unsafe) let menu = note.object as? NSMenu
            MainActor.assumeIsolated {
                guard let menu else { return }
                menu.cancelTrackingWithoutAnimation()
                tracked.append("“\(menu.items.prefix(3).map(\.title).joined(separator: ", "))…”")
                print("menu stand-in: a menu began tracking for real and was closed: \(tracked.last ?? "")")
            }
        }
    }

    fileprivate static func record(_ menu: NSMenu, positioning: NSMenuItem?, at location: NSPoint, in view: NSView?) {
        menu.update()
        let items = menu.items.map { item in
            let target: String? = item.target.map { String(describing: type(of: $0)) }
                ?? item.action.flatMap { NSApp.target(forAction: $0, to: nil, from: item) }.map { String(describing: type(of: $0)) }
            return Item(title: item.title, enabled: item.isEnabled, on: item.state == .on, separator: item.isSeparatorItem, header: item.isSectionHeader,
                        action: item.action.map(NSStringFromSelector), target: target)
        }
        // The run loop runs as a menu's tracking would while it is open, so what the control draws then is drawn.
        let until = Date().addingTimeInterval(0.15)
        while Date() < until { _ = RunLoop.current.run(mode: .eventTracking, before: until) }
        let look = whileOpen?(view)
        popped.append(Popped(menu: menu, view: view, location: location, positioning: positioning, items: items, lookWhileOpen: look))
        print("menu stand-in: recorded a menu of \(items.count) items in \(view.map { String(describing: type(of: $0)) } ?? "no view") at \(location)")
    }
}

extension NSMenu {
    /// Stands in for `popUp(positioning:at:in:)` (`MenuStandIn`): recorded, and closed as if nothing was chosen.
    @objc func debugRecordedPopUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        MainActor.assumeIsolated { MenuStandIn.record(self, positioning: item, at: location, in: view) }
        return false
    }
}

/// Actions sent through the app (`NSApplication.sendAction`), noted; those in `swallowing` go no further
/// (Settings would open its window, Open Folder… its sheet).
@MainActor
enum ActionStandIn {
    static var sent: [Selector] = []
    static var swallowing: Set<Selector> = []
    private static var installed = false

    static func install() {
        guard !installed, let from = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.sendAction(_:to:from:))),
              let to = class_getInstanceMethod(NSApplication.self, #selector(NSApplication.debugRecordedSendAction(_:to:from:))) else { return }
        installed = true
        method_exchangeImplementations(from, to)
    }

    fileprivate static func note(_ action: Selector) -> Bool {
        sent.append(action)
        return swallowing.contains(action)
    }
}

extension NSApplication {
    @objc func debugRecordedSendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
        if MainActor.assumeIsolated({ ActionStandIn.note(action) }) { return true }
        return debugRecordedSendAction(action, to: target, from: sender)     // the original, exchanged
    }
}

/// The app's key and main window, as a window in front has them: the run's window (`KeyStandIn`) when the
/// app, never active here, has none. An action sent to no one in particular (the Settings button's, Go
/// to's, a menu item's) goes up the key window's responder chain to the window's controller, as it does in
/// front of a person; without this it found nobody and did nothing, in the run only.
@MainActor
enum KeyWindowStandIn {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        for (original, replacement) in [(#selector(getter: NSApplication.keyWindow), #selector(NSApplication.debugStandInKeyWindow)),
                                        (#selector(getter: NSApplication.mainWindow), #selector(NSApplication.debugStandInMainWindow))] {
            guard let from = class_getInstanceMethod(NSApplication.self, original), let to = class_getInstanceMethod(NSApplication.self, replacement) else { continue }
            method_exchangeImplementations(from, to)
        }
    }
}

extension NSApplication {
    @objc func debugStandInKeyWindow() -> NSWindow? { debugStandInKeyWindow() ?? KeyStandIn.window }     // the original, exchanged
    @objc func debugStandInMainWindow() -> NSWindow? { debugStandInMainWindow() ?? KeyStandIn.window }
}

/// Window drags begun by the app (`NSWindow.performDrag(with:)`), counted; while `swallows`, not begun.
@MainActor
enum DragStandIn {
    static var drags = 0
    static var swallows = false
    private static var installed = false

    static func install() {
        guard !installed, let from = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.performDrag(with:))),
              let to = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.debugRecordedPerformDrag(with:))) else { return }
        installed = true
        method_exchangeImplementations(from, to)
    }
}

extension NSWindow {
    @objc func debugRecordedPerformDrag(with event: NSEvent) {
        let swallow = MainActor.assumeIsolated {
            DragStandIn.drags += 1
            return DragStandIn.swallows
        }
        if !swallow { debugRecordedPerformDrag(with: event) }     // the original, exchanged
    }
}
#endif
