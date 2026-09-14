#if DEBUG
import AppKit
import WhiskrKit

/// `--perf-flows layout` (`make perf`'s checks): the window's regions, sizes, themes, appearance and
/// language, and every pane of Settings. Each region is shown and hidden from every place that does it
/// (its key, its button, the View menu, its edge), at every width from the window's least to one wider than
/// any display; full screen as far as a background run may go (the menu item, and the top bar's inset when
/// the window says it entered); VS Code themes imported from files written here, and a few that must fail;
/// light and dark; every control of Settings pressed through the accessibility tree, its setting kept.
extension PerfSuite {
    func layoutCheck() async {
        let first = workbench.newWorkspace(folder: folder("layout"))
        guard await shellReady(first) else { return check("layout: the first shell drew its prompt", false) }
        print("layout: language \(Bundle.main.preferredLocalizations.first ?? "-"), appearance \(NSApp.effectiveAppearance.name.rawValue)")
        await regionsCheck(first)
        await sizesSweep()
        await fullScreenCheck()
        await themesCheck()
        await appearanceCheck()
        await settingsCheck()
        controller.resetLayout(nil)
        window.setContentSize(NSSize(width: 1440, height: 900))
    }

    // MARK: Looking at the window

    /// The meadow (or the list) is on screen, at least its narrowest.
    var meadowShown: Bool {
        let view = controller.navigator.view
        return !view.isHiddenOrHasHiddenAncestor && view.frame.width >= CGFloat(WindowLayout.navigatorMinimum) - 1
    }

    /// The terminals' region is on screen, at least its least width.
    var terminalsShown: Bool {
        let view = controller.terminals.view
        return !view.isHiddenOrHasHiddenAncestor && view.frame.width >= CGFloat(WindowLayout.terminalMinimum) - 1
    }

    var frameController: FrameController? { window.contentViewController as? FrameController }

    /// The status bar's height on screen (0 while hidden).
    var statusHeight: CGFloat {
        guard let bar = frameController?.statusBar, !bar.isHidden else { return 0 }
        return bar.frame.height
    }

    /// SwiftUI draws the bars' controls itself (no views, and no accessibility elements until an assistive
    /// app asks), so they are found as a person finds them: by what is drawn. The stretches of a bar's middle
    /// row that are not its background, in points from its leading end, each a control (the search field is
    /// the long one: the content's colour inset in the chrome).
    func inkRuns(_ view: NSView, joining gap: CGFloat = 3) -> [ClosedRange<CGFloat>] {
        guard view.bounds.width > 0, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let y = rep.pixelsHigh / 2
        func key(_ x: Int) -> UInt32 {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 0 }
            return UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
        }
        let row = (0..<rep.pixelsWide).map(key)
        // The bar's own colour, at its leading end (under the traffic lights, where nothing of its own is drawn).
        guard let background = row.first else { return [] }
        func differs(_ value: UInt32) -> Bool {
            let parts = { (v: UInt32) in [Int(v >> 16 & 0xff), Int(v >> 8 & 0xff), Int(v & 0xff)] }
            return zip(parts(value), parts(background)).contains { abs($0 - $1) > 4 }
        }
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for x in 0...row.count {
            let ink = x < row.count && differs(row[x])
            if ink, start == nil { start = x }
            if !ink, let from = start {
                let run = CGFloat(from) / scale...CGFloat(x) / scale
                if let last = runs.last, run.lowerBound - last.upperBound < gap { runs[runs.count - 1] = last.lowerBound...run.upperBound } else { runs.append(run) }
                start = nil
            }
        }
        return runs
    }

    var topBar: NSView? { frameController?.topBar }

    /// The middle of the top bar's meadow button: just after the traffic lights.
    var meadowButtonX: CGFloat { (window.standardWindowButton(.zoomButton)?.frame.maxX ?? 72) + Look.Space.s + Look.Height.iconButton / 2 }
    /// The middle of the top bar's Files and Changes button: second from the trailing end.
    var panelButtonX: CGFloat { window.frame.width - Look.Space.m - Look.Height.iconButton - Look.Space.xs - Look.Height.iconButton / 2 }

    /// A click on the top bar, `x` points from its leading end, through the window's own event path.
    func clickTopBar(x: CGFloat) {
        guard let bar = topBar else { return }
        click(bar, at: NSPoint(x: x, y: bar.bounds.midY))
    }

    /// A press and its release, moved in steps between them: a drag through the window's own event path,
    /// the moves and the release queued first for the tracking loop the press starts.
    func dragMouse(from start: NSPoint, to end: NSPoint, steps: Int = 10) {
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let point = NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            if let event = NSEvent.mouseEvent(with: step == steps ? .leftMouseUp : .leftMouseDragged, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: 1, pressure: step == steps ? 0 : 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: 1, pressure: 1) {
            NSApp.sendEvent(down)
        }
    }

    /// A colour as the theme gives it (sRGB, to the hex digit), to compare with what a theme file says.
    static func rgb(_ color: NSColor) -> WhiskrKit.RGBColor {
        let c = color.usingColorSpace(.sRGB) ?? color
        let round = { (v: CGFloat) in (Double(v) * 255).rounded() / 255 }
        return WhiskrKit.RGBColor(red: round(c.redComponent), green: round(c.greenComponent), blue: round(c.blueComponent))
    }

    // MARK: Regions

    /// The meadow, Files and Changes and the status bar, each hidden and shown from each of its places;
    /// the keyboard handed on when its region hides; Reset Layout bringing everything back.
    private func regionsCheck(_ pane: Pane) async {
        guard let workspace = workbench.selectedWorkspace else { return check("regions: a workspace", false) }
        _ = await PerfWait.until(2000) { self.meadowShown && self.terminalsShown }
        check("regions: at 1440 pt the meadow and the terminals are both shown", meadowShown && terminalsShown,
              "meadow \(Int(controller.navigator.view.frame.width)) pt, terminals \(Int(controller.terminals.view.frame.width)) pt")

        // The meadow: ⌃⌘S, ⌘B, the top bar's button, each hiding and showing it again.
        for (way, act) in [("⌃⌘S", { self.shortcut("ctrl+cmd+s") }), ("⌘B", { self.shortcut("cmd+b") }),
                           ("the top bar's button", { self.clickTopBar(x: self.meadowButtonX) })] as [(String, () -> Void)] {
            act()
            let hidden = await PerfWait.until(2000) { !self.meadowShown && self.terminalsShown }
            act()
            let shown = await PerfWait.until(2000) { self.meadowShown && self.terminalsShown }
            check("regions: \(way) hides the meadow and shows it again", hidden != nil && shown != nil)
        }
        // The forms of the window: ⌃⌘2 terminals only, ⌃⌘3 meadow only, ⌃⌘1 both.
        shortcut("ctrl+cmd+2")
        let terminalsOnly = await PerfWait.until(2000) { !self.meadowShown && self.terminalsShown }
        shortcut("ctrl+cmd+3")
        let meadowOnly = await PerfWait.until(2000) { self.meadowShown && !self.terminalsShown }
        // With the terminals out of sight the keyboard is the meadow's.
        let meadowKeys = await PerfWait.until(1000) { (self.window.firstResponder as? NSView)?.isDescendant(of: self.controller.navigator.view) == true }
        shortcut("ctrl+cmd+1")
        let both = await PerfWait.until(2000) { self.meadowShown && self.terminalsShown }
        check("regions: ⌃⌘2, ⌃⌘3 and ⌃⌘1 give the terminals alone, the meadow alone and both",
              terminalsOnly != nil && meadowOnly != nil && both != nil, "\(terminalsOnly != nil) \(meadowOnly != nil) \(both != nil)")
        check("regions: the terminals hidden hand the keyboard to the meadow", meadowKeys != nil,
              "first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        // The meadow hidden with the keyboard in it hands it to the focused terminal.
        controller.navigator.takeKeyboard()
        _ = await PerfWait.until(1000) { (self.window.firstResponder as? NSView)?.isDescendant(of: self.controller.navigator.view) == true }
        shortcut("ctrl+cmd+s")
        let handed = await PerfWait.until(2000) { !self.meadowShown && self.focused(pane) }
        check("regions: hiding the meadow with the keyboard in it hands it to the terminal", handed != nil,
              "first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        shortcut("ctrl+cmd+s")
        _ = await PerfWait.until(2000) { self.meadowShown }

        // Files and Changes: ⇧⌘E, ⇧⌘C, the top bar's button, the edge dragged shut, a double-click on it.
        let panel = { self.workbench.files.panel(workspace.id) }
        let panelOnScreen = { !self.controller.terminals.sidePanel.isHiddenOrHasHiddenAncestor && self.controller.terminals.sidePanel.frame.width >= CGFloat(FilesCenter.panelMinimum) - 1 }
        shortcut("cmd+shift+e")
        let files = await PerfWait.until(2000) { panel().shown && panelOnScreen() }
        shortcut("cmd+shift+e")
        let filesHidden = await PerfWait.until(2000) { !panel().shown && !panelOnScreen() }
        check("regions: ⇧⌘E shows Files and hides it again", files != nil && filesHidden != nil, "\(panel())")
        // At once after the slide shut has begun, as a person switching from Files to Changes does: the
        // panel must not stay hidden when the slide ends.
        shortcut("cmd+shift+c")
        let changes = await PerfWait.until(2000) { panel().shown && panel().mode == .changes && panelOnScreen() }
        let afterChanges = "\(panel()), side panel hidden \(controller.terminals.sidePanel.isHiddenOrHasHiddenAncestor) width \(Int(controller.terminals.sidePanel.frame.width))"
        shortcut("cmd+shift+e")
        let switched = await PerfWait.until(2000) { panel().shown && panel().mode == .files && panelOnScreen() }
        shortcut("cmd+shift+e")
        _ = await PerfWait.until(2000) { !panel().shown && !panelOnScreen() }
        check("regions: ⇧⌘C while Files slides shut shows Changes and keeps it shown; ⇧⌘E then turns the panel to Files", changes != nil && switched != nil,
              "Changes shown \(changes != nil) (\(afterChanges)), then Files \(switched != nil)")
        clickTopBar(x: panelButtonX)
        let byButton = await PerfWait.until(2000) { panel().shown && panelOnScreen() }
        clickTopBar(x: panelButtonX)
        let byButtonHidden = await PerfWait.until(2000) { !panel().shown && !panelOnScreen() }
        check("regions: the top bar's panel button shows and hides the panel", byButton != nil && byButtonHidden != nil,
              "shown \(byButton != nil), hidden \(byButtonHidden != nil); the click went to \(topBar.flatMap { self.hit($0, at: NSPoint(x: self.panelButtonX, y: $0.bounds.midY)) }.map { String(describing: type(of: $0)) } ?? "nothing")")
        // The edge dragged toward the window's edge closes the panel, keeping its width for next time.
        workbench.files.setPanel(workspace.id) { $0.shown = true; $0.width = 320 }
        _ = await PerfWait.until(2000) { panelOnScreen() }
        await PerfWait.sleep(300)
        if let edge = DebugShell.descendant(of: controller.terminals.view, where: { $0 is PanelEdge && !$0.isHiddenOrHasHiddenAncestor }) {
            let start = edge.convert(NSPoint(x: edge.bounds.midX, y: edge.bounds.midY), to: nil)
            dragMouse(from: start, to: NSPoint(x: window.frame.width - 20, y: start.y))
            let shut = await PerfWait.until(2000) { !panel().shown && !panelOnScreen() }
            check("regions: dragging the panel's edge nearly shut closes it and keeps its width", shut != nil && panel().width == 320, "\(panel())")
        } else {
            check("regions: the panel's edge found", false)
        }

        // The status bar: ⌥⌘/ hides and shows it.
        shortcut("cmd+opt+/")
        let barHidden = await PerfWait.until(2000) { self.statusHeight == 0 && !self.controller.layout.showsStatusBar }
        shortcut("cmd+opt+/")
        let barShown = await PerfWait.until(2000) { self.statusHeight == Look.Height.statusBar }
        check("regions: ⌥⌘/ hides the status bar and shows it again", barHidden != nil && barShown != nil, "height \(statusHeight)")

        // Reset Layout: everything put away comes back at its usual size.
        shortcut("ctrl+cmd+2")
        shortcut("cmd+opt+/")
        workbench.files.setPanel(workspace.id) { $0.shown = true; $0.width = 420 }
        controller.debugSetLayout { $0.navigator = .list }
        _ = await PerfWait.until(2000) { !self.meadowShown && self.statusHeight == 0 }
        let item = DebugScript.menuItemForCheck(path: ["View", String(localized: "Reset Layout")])
        if let item, let action = item.action, let target = DebugScript.target(for: item, window: window) { NSApp.sendAction(action, to: target, from: item) }
        let reset = await PerfWait.until(2000) {
            self.meadowShown && self.terminalsShown && self.statusHeight == Look.Height.statusBar && panelOnScreen()
                && Int(self.controller.terminals.sidePanel.frame.width) == Int(FilesCenter.panelDefault)
        }
        check("regions: View › Reset Layout brings back the meadow, the status bar and the panel at its usual width, keeping the list",
              item != nil && reset != nil && controller.layout.navigator == .list,
              "menu item \(item != nil), layout \(controller.layout), panel \(panel()), its width \(Int(controller.terminals.sidePanel.frame.width))")
        controller.debugSetLayout { $0.navigator = .meadow }
        workbench.files.setPanel(workspace.id) { $0.shown = false }
        _ = await PerfWait.until(2000) { !panelOnScreen() }
    }

    // MARK: Sizes

    /// From the least window the app allows to one wider than any display, and short ones: the top bar's
    /// controls inside the window and apart, the search field between them; the tab row's tabs, "+" and the
    /// workspace button in reach; the status bar's items inside it; the meadow's toggle working, and the
    /// regions keeping their least widths.
    private func sizesSweep() async {
        let sizes: [(Double, Double)] = [(720, 440), (720, 900), (800, 600), (880, 700), (1024, 768), (1280, 480), (1440, 900), (2200, 1200), (3400, 1400)]
        for (width, height) in sizes {
            window.setContentSize(NSSize(width: width, height: height))
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            await PerfWait.sleep(250)
            let name = "\(Int(width))×\(Int(height))"
            // The top bar: two controls before the search field, three after it, all inside the window, the
            // field wide enough to read and clear of its neighbours.
            if let bar = topBar {
                let runs = inkRuns(bar)
                // The field is the longest stretch, with its key cap (drawn in a shade close to the chrome's).
                var field = runs.max { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) } ?? 0...0
                for run in runs where run.lowerBound > field.upperBound && run.lowerBound - field.upperBound < 10 { field = field.lowerBound...run.upperBound }
                let before = runs.last { $0.upperBound <= field.lowerBound }, after = runs.first { $0.lowerBound >= field.upperBound }
                let clear = (before.map { field.lowerBound - $0.upperBound } ?? 0) >= Look.Space.m && (after.map { $0.lowerBound - field.upperBound } ?? 0) >= Look.Space.m
                // Each control drawn where it belongs: the meadow and Home buttons, then New, Files and Changes, Settings.
                let width = bar.bounds.width, step = Look.Height.iconButton + Look.Space.xs
                let places = [meadowButtonX, meadowButtonX + step, width - Look.Space.m - Look.Height.iconButton / 2 - 2 * step,
                              width - Look.Space.m - Look.Height.iconButton / 2 - step, width - Look.Space.m - Look.Height.iconButton / 2]
                let drawn = places.map { x in runs.contains { $0.lowerBound <= x + 8 && $0.upperBound >= x - 8 } }
                let inside = (runs.last?.upperBound ?? .infinity) <= width - Look.Space.xs
                let wide = field.upperBound - field.lowerBound
                check("sizes \(name): the top bar's five buttons are drawn inside the window, the search field between them, clear of them", drawn.allSatisfy { $0 } && clear && inside && wide >= 200,
                      "buttons drawn \(drawn), field \(Int(field.lowerBound))–\(Int(field.upperBound)), runs \(runs.map { "\(Int($0.lowerBound))–\(Int($0.upperBound))" })")
            }
            // The tab row: every tab shown whole, the selected one among them, inside the terminals' region.
            let region = controller.terminals.view.convert(controller.terminals.view.bounds, to: nil)
            let tabs = tabViews.map { $0.convert($0.bounds, to: nil) }
            let tabsInside = tabs.allSatisfy { $0.minX >= region.minX - 0.5 && $0.maxX <= region.maxX + 0.5 }
            let selectedWhole = workbench.selectedTab.flatMap { tabView($0) }.map { $0.convert($0.bounds, to: nil) }.map { $0.minX >= region.minX - 0.5 && $0.maxX <= region.maxX + 0.5 } ?? false
            check("sizes \(name): the tab row's tabs are whole and inside the work area, the selected one shown", tabsInside && selectedWhole,
                  "region \(Int(region.minX))–\(Int(region.maxX)), tabs \(tabs.map { "\(Int($0.minX))–\(Int($0.maxX))" })")
            // The status bar: its items inside it, the leading ones and the keys at its end apart.
            if let bar = frameController?.statusBar {
                let runs = inkRuns(bar, joining: 6)
                let widest = zip(runs, runs.dropFirst()).map { $1.lowerBound - $0.upperBound }.max() ?? 0
                let inside = (runs.first?.lowerBound ?? -1) >= Look.Space.xs && (runs.last?.upperBound ?? .infinity) <= bar.bounds.width - Look.Space.xs
                check("sizes \(name): the status bar's items are inside it, the leading ones apart from the keys at its end", runs.count >= 2 && inside && widest >= Look.Space.l,
                      "runs \(runs.map { "\(Int($0.lowerBound))–\(Int($0.upperBound))" }) in \(Int(bar.bounds.width))")
            }
            // The regions keep their least widths; the meadow's toggle works at this width, both ways.
            let wasShown = meadowShown
            shortcut("ctrl+cmd+s")
            let toggled = await PerfWait.until(2000) { self.meadowShown != wasShown && self.terminalsShown }
            let other = (meadow: controller.navigator.view.frame.width, terminals: controller.terminals.view.frame.width)
            shortcut("ctrl+cmd+s")
            let back = await PerfWait.until(2000) { self.meadowShown == wasShown && self.terminalsShown }
            let meadowWidth = meadowShown ? controller.navigator.view.frame.width : other.meadow
            let terminalsWidth = min(controller.terminals.view.frame.width, other.terminals)
            check("sizes \(name): ⌃⌘S hides and shows the meadow, the meadow at least 240 pt and the terminals at least 320 pt",
                  toggled != nil && back != nil && meadowWidth >= CGFloat(WindowLayout.navigatorMinimum) - 1 && terminalsWidth >= CGFloat(WindowLayout.terminalMinimum) - 1,
                  "meadow at first \(wasShown ? "shown" : "stepped aside"), widths meadow \(Int(meadowWidth)) terminals \(Int(terminalsWidth))")
            // Nothing too short to use: the panes keep room under the tab row.
            let panes = controller.terminals.paneArea.frame.height
            check("sizes \(name): the panes keep room under the tab row", panes >= 200, "panes \(Int(panes)) pt tall")
            // Put back the default for the next size.
            controller.debugSetLayout { $0 = WindowLayout() }
        }
        window.setContentSize(NSSize(width: 1440, height: 900))
        await PerfWait.sleep(250)
    }

    // MARK: Full screen

    /// A background run refuses real full screen (it would take over the display). What can be checked: the
    /// View menu's item is there and enabled with ⌃⌘F, and the top bar closes up the room it keeps for the
    /// traffic lights once the window says it entered full screen, and gives it back on leaving.
    private func fullScreenCheck() async {
        // AppKit adds an Enter Full Screen of its own (🌐F) to View and hides the app's; the app's keeps ⌃⌘F.
        let view = DebugScript.menuItemForCheck(path: ["View"])?.submenu
        view.map { $0.delegate?.menuNeedsUpdate?($0) }
        let item = view?.items.first { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask.intersection([.command, .control, .shift, .option]) == [.command, .control] }
        let enabled = item.map { DebugScript.isEnabledForCheck($0, window: window) } ?? false
        check("full screen: View › Enter Full Screen is there with ⌃⌘F, and enabled", item != nil && enabled,
              "\(view?.items.filter { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }.map { "\($0.title) [\($0.keyEquivalent)] hidden \($0.isHidden)" } ?? [])")
        let first = { self.topBar.map { self.inkRuns($0).first?.lowerBound ?? -1 } ?? -1 }
        let windowed = first()
        controller.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: window))
        let closedUp = await PerfWait.until(2000) { first() < windowed - 40 }
        await PerfWait.sleep(300)
        let inFullScreen = first()
        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))
        let back = await PerfWait.until(2000) { abs(first() - windowed) < 1 }
        check("full screen: the top bar's first button moves to the edge in full screen and back after the traffic lights",
              closedUp != nil && back != nil && inFullScreen <= Look.Space.m + 1 && windowed > 60,
              "button at \(Int(windowed)) pt, in full screen \(Int(inFullScreen)) pt")
    }

    // MARK: Themes

    /// VS Code themes written here, in the three forms the app takes (a theme file whose colours come
    /// through an include chain, an extension's folder, its `.vsix`), imported and chosen; and some that must
    /// fail, quickly and leaving nothing behind.
    private func themesCheck() async {
        let store = ThemeStore.shared
        let before = (id: store.themeID, count: store.themes.count)
        let base = URL(fileURLWithPath: folder("themes"), isDirectory: true)
        func write(_ path: String, _ text: String) {
            let url = base.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
        // A dark theme whose background comes from the file it includes, and that file's own include.
        write("file/night-base.json", ##"{ "colors": { "editor.background": "#1e2127", "terminal.background": "#1e2127", "terminal.foreground": "#abb2bf" } }"##)
        write("file/night-syntax.json", ##"{ "include": "./night-base.json", "tokenColors": [ { "scope": "keyword", "settings": { "foreground": "#c678dd" } } ] }"##)
        write("file/harbour-night-color-theme.json", "// with comments, as VS Code allows\n{ \"name\": \"Harbour Night\", \"type\": \"dark\", \"include\": \"./night-syntax.json\", \"colors\": { \"editorLineNumber.foreground\": \"#495162\", }, }")
        // An extension of two themes, one light and one dark: one theme with both.
        write("ext/package.json", ##"{ "name": "lantern", "displayName": "Lantern Themes", "publisher": "example", "contributes": { "themes": [ { "label": "Paper Lantern", "uiTheme": "vs", "path": "./themes/paper.json" }, { "label": "Harbour Dusk", "uiTheme": "vs-dark", "path": "./themes/dusk.json" } ] } }"##)
        write("ext/themes/paper.json", ##"{ "type": "light", "colors": { "editor.background": "#ffffff", "terminal.background": "#ffffff", "terminal.foreground": "#24292f" } }"##)
        write("ext/themes/dusk.json", ##"{ "type": "dark", "colors": { "editor.background": "#202430", "terminal.background": "#202430", "terminal.foreground": "#d0d4dc" } }"##)
        // The same extension as a .vsix (a zip with the extension in `extension/`).
        let staging = base.appendingPathComponent("vsix-staging/extension", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: base.appendingPathComponent("ext"), to: staging)
        let vsix = base.appendingPathComponent("lantern.vsix")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", staging.deletingLastPathComponent().path, vsix.path]
        try? zip.run()
        zip.waitUntilExit()

        func imported(_ path: URL) -> [Theme]? { try? store.importThemes(at: path) }
        let file = imported(base.appendingPathComponent("file/harbour-night-color-theme.json"))
        let night = file?.first
        check("themes: a VS Code theme file with an include chain imports as a dark theme with the included colours, and is chosen",
              night?.dark?.terminal.background == WhiskrKit.RGBColor(0x1e2127) && night?.light == nil && store.themeID == night?.id,
              "\(file?.map(\.name) ?? []), background \(night?.dark.map { "\($0.terminal.background)" } ?? "-")")
        store.appearance = .dark
        await PerfWait.sleep(200)
        let drawn = window.effectiveAppearance
        var background = WhiskrKit.RGBColor(0)
        drawn.performAsCurrentDrawingAppearance { background = Self.rgb(Colors.terminalBackground) }
        check("themes: the chosen theme colours the window", background == WhiskrKit.RGBColor(0x1e2127), "terminal background \(background)")
        let folder = imported(base.appendingPathComponent("ext"))
        check("themes: an extension folder with a light and a dark theme imports as one theme with both",
              folder?.count == 1 && folder?.first?.light?.terminal.background == WhiskrKit.RGBColor(0xffffff) && folder?.first?.dark?.terminal.background == WhiskrKit.RGBColor(0x202430),
              "\(folder?.map { "\($0.name) light \($0.light != nil) dark \($0.dark != nil)" } ?? ["failed"])")
        let packed = imported(vsix)
        check("themes: the same extension as a .vsix imports too", packed?.count == 1 && packed?.first?.light != nil && packed?.first?.dark != nil,
              "\(packed?.map(\.name) ?? ["failed"])")
        // Switching between them, in light and dark.
        if let pair = folder?.first {
            store.themeID = pair.id
            store.appearance = .light
            await PerfWait.sleep(200)
            window.effectiveAppearance.performAsCurrentDrawingAppearance { background = Self.rgb(Colors.terminalBackground) }
            let light = background
            store.appearance = .dark
            await PerfWait.sleep(200)
            window.effectiveAppearance.performAsCurrentDrawingAppearance { background = Self.rgb(Colors.terminalBackground) }
            check("themes: a theme with both versions follows light and dark", light == WhiskrKit.RGBColor(0xffffff) && background == WhiskrKit.RGBColor(0x202430),
                  "light \(light), dark \(background)")
        }

        // What must fail, quickly, adding nothing.
        write("bad/malformed-color-theme.json", ##"{ "name": "Broken", "colors": { "editor.background": "#000" ,, ] "##)
        write("bad/empty-color-theme.json", "")
        write("bad/cycle/a-color-theme.json", ##"{ "name": "Cycle", "include": "./b.json" }"##)
        write("bad/cycle/b.json", ##"{ "include": "./a-color-theme.json" }"##)
        write("bad/outside/inner/out-color-theme.json", ##"{ "name": "Outside", "include": "../../outside.json" }"##)
        write("bad/outside.json", ##"{ "colors": { "editor.background": "#ff0000" } }"##)
        write("bad/garbage.vsix", "not a zip archive")
        write("bad/ext-outside/package.json", ##"{ "name": "o", "publisher": "p", "contributes": { "themes": [ { "label": "Escape", "uiTheme": "vs-dark", "path": "../outside.json" } ] } }"##)
        let count = store.themes.count
        let originals = (try? FileManager.default.contentsOfDirectory(atPath: ThemeStore.originalsFolder.path).count) ?? 0
        for name in ["malformed-color-theme.json", "empty-color-theme.json", "cycle/a-color-theme.json", "outside/inner/out-color-theme.json", "garbage.vsix", "ext-outside"] {
            let start = perfNow()
            var failure = ""
            do {
                let added = try store.importThemes(at: base.appendingPathComponent("bad/\(name)"))
                failure = "imported \(added.map(\.name))"
            } catch let error as ThemeImportError {
                failure = error.message
            } catch {
                failure = "\(error)"
            }
            let took = perfNow() - start
            check("themes: \(name) is refused with a reason, quickly, adding nothing", !failure.hasPrefix("imported") && took < 2000 && store.themes.count == count
                  && ((try? FileManager.default.contentsOfDirectory(atPath: ThemeStore.originalsFolder.path).count) ?? 0) == originals,
                  "\(failure) (\(Int(took)) ms)")
        }
        store.themeID = before.id
        store.appearance = .system
        await PerfWait.sleep(200)
    }

    // MARK: Appearance

    /// Light and dark, as Settings › Terminal sets them: the window draws in it, the chrome a step from the
    /// content in each.
    private func appearanceCheck() async {
        let store = ThemeStore.shared
        for (appearance, dark) in [(ThemeStore.Appearance.light, false), (.dark, true)] {
            store.appearance = appearance
            await PerfWait.sleep(200)
            let drawn = window.effectiveAppearance
            var chrome = WhiskrKit.RGBColor(0), content = WhiskrKit.RGBColor(0)
            drawn.performAsCurrentDrawingAppearance {
                chrome = Self.rgb(Colors.chrome)
                content = Self.rgb(Colors.terminalBackground)
            }
            let ratio = chrome.contrast(with: content)
            check("appearance: \(appearance.rawValue) draws the window \(dark ? "dark" : "light"), the chrome a step from the content",
                  Palette.isDark(drawn) == dark && ratio >= 1.02 && ratio <= 1.3, "chrome \(chrome), content \(content), \(String(format: "%.2f", ratio)):1")
        }
        store.appearance = .system
        await PerfWait.sleep(200)
    }
}

extension DebugScript {
    /// `--script` commands of this flow; true when `command` was one of them.
    ///
    ///   settings <pane>             opens Settings (unseen, as every window of a background run) on general,
    ///                               terminal, editor, alerts or meadow
    ///   help                        opens Help › Whiskr Help
    ///   window-shot <which> <png>   draws the Settings or Help window (`settings`, `help`) into a PNG
    ///   layout-state                the window's layout and a few settings, to compare across a relaunch
    ///   settings-views              every control in the Settings pane shown, by class (what `settingsCheck` works)
    static func layoutCommand(_ command: String, _ argument: String, _ workbench: Workbench, _ controller: MainWindowController) -> Bool {
        switch command {
        case "settings":
            SettingsWindowController.shared.show()
            (SettingsWindowController.shared.window?.contentViewController as? SettingsTabs)?.select(pane: argument)
        case "help":
            HelpWindowController.shared.showHelp(nil)
        case "window-shot":
            let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { print("  window-shot settings|help <png>"); return true }
            let window = parts[0] == "help" ? HelpWindowController.shared.window : SettingsWindowController.shared.window
            guard let window else { print("  no such window"); return true }
            print("  \(parts[0]) window \(window.frame.size): \(DebugLayoutShot.draw(window, to: URL(fileURLWithPath: parts[1])) ? "drawn" : "not drawn")")
        case "settings-views":
            // Every view in Settings' pane, by class, to see what a check can work.
            guard let root = SettingsWindowController.shared.window?.contentView else { return true }
            func walk(_ view: NSView, _ depth: Int) {
                if let control = view as? NSControl { print("  \(type(of: control)) \(control.frame.integral) value \(control.stringValue.prefix(30)) label \(control.accessibilityLabel() ?? "-") title \(control.accessibilityTitle() ?? "-") parent \((control.accessibilityParent() as? NSAccessibilityProtocol)?.accessibilityLabel() ?? "-")") }
                view.subviews.forEach { walk($0, depth + 1) }
            }
            walk(root, 0)
        case "layout-state":
            print("  layout \(controller.layout) theme \(ThemeStore.shared.themeID) appearance \(ThemeStore.shared.appearance.rawValue) resumeClaude \(Preferences.shared.resumeClaude) wrap \(EditorPreferences.shared.wrapLines) language \(Bundle.main.preferredLocalizations.first ?? "-")")
        default:
            return false
        }
        return true
    }

    /// A menu item by its titles, its submenus brought up to date first (as `menu` does).
    static func menuItemForCheck(path: [String]) -> NSMenuItem? {
        var menu = NSApp.mainMenu
        var found: NSMenuItem?
        for title in path {
            if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
            guard let item = menu?.items.first(where: { $0.title == title }) else { return nil }
            found = item
            menu = item.submenu
        }
        return found
    }

    /// Whether the item would be enabled if the window were key (as `menu` prints it).
    static func isEnabledForCheck(_ item: NSMenuItem, window: NSWindow) -> Bool {
        guard item.action != nil, let target = target(for: item, window: window) else { return false }
        if let validating = target as? NSMenuItemValidation { return validating.validateMenuItem(item) }
        if let validating = target as? NSUserInterfaceValidations { return validating.validateUserInterfaceItem(item) }
        return true
    }
}

/// Another of the app's windows drawn as AppKit draws it (its title bar and toolbar too), though nobody can
/// see it in a background run.
@MainActor
enum DebugLayoutShot {
    static func draw(_ window: NSWindow, to url: URL) -> Bool {
        guard let frame = window.contentView?.superview else { return false }
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return false }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let image = rep.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        // The window's own background under what its views draw (a hosting view leaves it to the window).
        frame.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
#endif
