#if DEBUG
import AppKit
import MeadowFile
@_spi(Diagnostics) import MeadowScene
import WhiskrKit
import WhiskrMeadow

/// `--perf-flows editor` (`make perf`'s checks): editing the meadow (docs/DESIGN.md, "Edit Meadow"), driven
/// as a person drives it, every press, drag, release and key through `NSApplication.sendEvent`.
///
/// - Every way in (View › Edit Meadow's key, the menu, the grass's menu, Settings › Meadow's button, Go to's
///   commands) and out (Done, ⌘↩, Esc step by step, the menu again, ⌘T, ⌘J): the meadow fills the window
///   between the bars with the terminals gone and the blankets in their rows, the view lifts to 55°, and
///   leaving brings back exactly the layout, the view and the keyboard.
/// - The Select tool: click, ⇧-click, ⌘-click, a marquee, drags that move (and with ⌥ copy), drops refused
///   with their reasons and springing back, arrows, R, `[` `]`, ⌘D, ⌘C ⌘V, ⌫, the selection's bar, the
///   keyboard's cursor, Esc during a drag; each a step ⌘Z and ⇧⌘Z take back and do again.
/// - The first edit makes My Meadow from the Default (undone, the Default is back and the copy gone); it is
///   saved a second after the last change, read back as it is; Revert to Default shows the Default again.
/// - Terminals keep running and a request arriving meanwhile changes nothing on screen but the status
///   bar; the meadow rests again once editing ends, and nothing of the editor is left behind.
/// - Pictures of edit mode in whiskr-light, whiskr-dark and graphite, wide and narrow: the picnic ground,
///   the selection's bar, a marquee, a refused drop.
/// - `--editor-phase relaunch` (the second run on the same folder, `Scripts/perf.sh`): the meadow edited
///   and quit in the first run is back, as it was saved at quit.
extension PerfSuite {
    func editorCheck() async {
        if DebugScenario.value("--editor-phase") == "relaunch" { return await editorRelaunched() }
        let flow = EditorFlow(suite: self)
        await flow.run()
    }

    /// The second run: My Meadow is shown, with the oak where the first run left it just before quitting.
    private func editorRelaunched() async {
        let library = MeadowLibrary.shared
        let meadow = controller.navigator.meadow
        _ = await PerfWait.until(3000) { meadow.scenery == library.scenery }
        let file = library.active
        let reading = file.flatMap { try? library.folder.read($0) }
        check("editor relaunch: the meadow shown is My Meadow, from its file", file == "My Meadow.whiskrmeadow" && reading != nil && library.unreadable == nil,
              "active \(file ?? "Default"), read \(reading != nil), unreadable \(library.unreadable ?? "none"), files \(library.files), settings \(WorldStore.shared.settings.meadow ?? "none")")
        let marker = library.session.document.items.first { $0.asset == "tree.young" && $0.at.x == EditorFlow.quitMarker.x && $0.at.z == EditorFlow.quitMarker.y }
        check("editor relaunch: the move made just before quitting was saved at quit", marker != nil)
        check("editor relaunch: the meadow draws what the file holds", meadow.scenery == MeadowScenery(library.session.document))
    }
}

extension PerfSuite {
    /// The chrome flow's part for the top bar while the meadow is edited: its name's menu, Undo, Redo and
    /// Done, each clicked at its middle and near each edge, as every control of the bars is.
    func editBarSweep() async {
        let library = MeadowLibrary.shared
        let editor = controller.meadowEditor
        /// Editing, with a step to undo (a stone moved a little and back, as needed).
        func editing() async {
            if !controller.meadowEditing { editor.enter() }
            _ = await PerfWait.until(2000) { self.controller.meadowEditing }
            if library.undoManager.canRedo { library.undoManager.redo() }
            if !library.undoManager.canUndo, let stone = library.session.drawnIDs.first(where: { library.session.item($0)?.asset == "stone.stone" }) {
                library.edit(MeadowWords.move(["stone.stone"])) { $0.move([stone], by: SIMD2(0.25, 0)) }
            }
            editor.updateBar()
            await PerfWait.sleep(250)
        }
        await sweep("the meadow's name while editing", locate: { self.barControl("bar.meadow.name") }, reset: editing) {
            MenuStandIn.popped.count == 1 ? nil : "no menu"
        }
        await sweep("Undo while editing", locate: { self.barControl("bar.arrow.uturn.backward") }, reset: editing) {
            await PerfWait.until(1500) { library.undoManager.canRedo } == nil ? "nothing undone" : nil
        }
        await sweep("Redo while editing", locate: { self.barControl("bar.arrow.uturn.forward") }, reset: {
            await editing()
            library.undoManager.undo()
            editor.updateBar()
            await PerfWait.sleep(250)
        }) {
            await PerfWait.until(1500) { !library.undoManager.canRedo } == nil ? "nothing done again" : nil
        }
        await sweep("Done", locate: { self.barControl("bar.meadow.done") }, reset: editing) {
            await PerfWait.until(2000) { !self.controller.meadowEditing } == nil ? "still editing" : nil
        }
        if controller.meadowEditing { editor.leave() }
        _ = await PerfWait.until(2000) { !self.controller.meadowEditing }
        await PerfWait.sleep(400)
    }
}

@MainActor
final class EditorFlow {
    let suite: PerfSuite
    var controller: MainWindowController { suite.controller }
    var window: NSWindow { suite.window }
    var meadow: MeadowView { controller.navigator.meadow }
    var editor: EditModeController { controller.meadowEditor }
    let library = MeadowLibrary.shared
    var folder: URL { library.folder.url }
    let pictures: URL
    /// Where the young tree is moved just before the first run quits (`--editor-phase relaunch` looks for it).
    static let quitMarker = SIMD2<Double>(-46, 12)

    init(suite: PerfSuite) {
        self.suite = suite
        pictures = URL(fileURLWithPath: DebugScenario.value("--editor-pictures") ?? suite.folder("editor-pictures"), isDirectory: true)
        try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
    }

    func check(_ name: String, _ passed: Bool, _ detail: String = "") { suite.check("editor: \(name)", passed, detail) }

    // MARK: The run

    private var shell: Pane!
    private var claude: Pane!


    func run() async {
        window.setContentSize(NSSize(width: 1440, height: 900))
        await PerfWait.sleep(300)
        guard await setUp() else { return }
        await waysInAndOut()
        await firstEdit()
        await choosing()
        await moving()
        await keys()
        await copying()
        await theSelectionBar()
        await theTray()
        await placing()
        await brushing()
        await erasing()
        await painting()
        await steppingStones()
        await newThings()
        await garden()
        await lamps()
        await limits()
        await carryingOn()
        await revert()
        await pictures(looks: true)
        await leftBehind()
        await rests()
        await beforeQuitting()
    }

    /// Three workspaces in a row (the sidebar's column), a Claude in one, a terminal printing all along.
    private func setUp() async -> Bool {
        for i in 0..<3 {
            let pane = suite.workbench.newWorkspace(folder: suite.folder("editor-\(i)"))
            guard await suite.shellReady(pane) else { check("three shells ready", false); return false }
            if i == 0 { shell = pane }
            if i == 2 { claude = pane }
        }
        claude.debugPretendsClaude = true
        hook(claude, "UserPromptSubmit", [:])
        suite.workbench.select(workspace: suite.workbench.workspace(of: shell.id)!.0)
        _ = await PerfWait.until(2000) { self.window.firstResponder === self.shell.surface }
        // A terminal that keeps printing: four lines a second, counted as they reach it.
        // (On the terminal's own connection thread: the log takes it with its lock.)
        let log = suite.log
        shell.surface.setOutputHandler { log.output() }
        suite.typeKeys("while true; do echo tick; sleep 0.25; done\r")
        await PerfWait.sleep(1500)
        let ok = library.active == nil && library.files.isEmpty && meadow.scenery == library.scenery
        check("set up: the Default shown, no meadow of yours yet, a shell with the keyboard", ok && window.firstResponder === shell.surface,
              "active \(library.active ?? "Default"), files \(library.files), keyboard \(String(describing: window.firstResponder.map { type(of: $0) }))")
        return true
    }

    // MARK: Ways in and out

    /// What leaving must bring back.
    private struct Before {
        let layout: WindowLayout
        let collapsed: (meadow: Bool, terminals: Bool)
        let meadowWidth: CGFloat
        let camera: (x: Float, z: Float, distance: Float, pitch: Float, bearing: Float)
        let keyboard: NSResponder?
        let rows: Int
    }

    private func before() async -> Before {
        await still()
        return Before(layout: controller.layout, collapsed: controller.debugCollapsed, meadowWidth: meadow.bounds.width, camera: meadow.cameraView,
                      keyboard: window.firstResponder, rows: meadow.blanketsPerRow)
    }

    /// The meadow has stopped moving (the view landed, regions settled).
    func still() async {
        _ = await PerfWait.until(4000) { !self.meadow.cameraMoving }
        await PerfWait.sleep(350)
        _ = await PerfWait.until(2000) { !self.meadow.cameraMoving }
    }

    private func checkEditing(_ way: String, _ was: Before) async {
        let editing = await PerfWait.until(2000) { self.controller.meadowEditing && self.editor.isEditing }
        await still()
        let frame = window.contentView!.bounds
        let between = frame.height - Look.Height.topBar - (controller.layout.showsStatusBar ? Look.Height.statusBar : 0)
        let fills = abs(meadow.bounds.width - frame.width) < 1.5 && abs(meadow.bounds.height - between) < 1.5
        let camera = meadow.cameraView
        check("\(way): edit mode: the meadow fills the window between the bars, the terminals gone, the keyboard in the meadow",
              editing != nil && fills && controller.debugCollapsed.terminals && window.firstResponder === meadow,
              "meadow \(Int(meadow.bounds.width))×\(Int(meadow.bounds.height)) of \(Int(frame.width))×\(Int(between)), terminals collapsed \(controller.debugCollapsed.terminals)")
        check("\(way): the view lifts to about 55° and the blankets keep their rows", abs(camera.pitch - 55 * .pi / 180) < 0.02 && meadow.blanketsPerRow == was.rows,
              String(format: "pitch %.1f°, rows %d (were %d)", camera.pitch * 180 / .pi, meadow.blanketsPerRow, was.rows))
        check("\(way): the top bar shows the meadow's name, Undo, Redo and Done",
              suite.barView("bar.meadow.name") != nil && suite.barView("bar.meadow.done") != nil && suite.barView("bar.arrow.uturn.backward") != nil)
    }

    private func checkLeft(_ way: String, _ was: Before, keyboard expected: NSResponder? = nil) async {
        let left = await PerfWait.until(2000) { !self.controller.meadowEditing && !self.editor.isEditing }
        await still()
        await PerfWait.sleep(300)
        let c = meadow.cameraView, b = was.camera
        // A meadow out of sight before (Terminals Only, the list) frames itself afresh when it shows again:
        // only what is on screen must come back.
        let hidden = was.collapsed.meadow || was.layout.navigator == .list
        let camera = hidden || (abs(c.x - b.x) < 1e-3 && abs(c.z - b.z) < 1e-3 && abs(c.distance - b.distance) < 1e-3 && abs(c.pitch - b.pitch) < 1e-4 && abs(c.bearing - b.bearing) < 1e-4)
        let layout = controller.layout == was.layout && controller.debugCollapsed == was.collapsed && (hidden || abs(meadow.bounds.width - was.meadowWidth) < 1)
        let keyboard = window.firstResponder === (expected ?? was.keyboard)
        check("\(way): leaving brings back exactly the layout, the meadow's width, the view and the keyboard", left != nil && camera && layout && keyboard,
              "keyboard before \(String(describing: was.keyboard.map { type(of: $0) })); layout \(controller.layout == was.layout ? "same" : "\(was.layout) → \(controller.layout)"); camera \(b) → \(c); width \(Int(was.meadowWidth)) → \(Int(meadow.bounds.width)); collapsed \(was.collapsed) → \(controller.debugCollapsed); keyboard \(String(describing: window.firstResponder.map { type(of: $0) }))")
        check("\(way): the go to field is back and the blankets in their rows", suite.barView("bar.meadow.done") == nil && meadow.blanketsPerRow == was.rows)
    }

    private func waysInAndOut() async {
        // ⌃⌘E in, Done out.
        var was = await before()
        suite.shortcut("cmd+ctrl+e")
        await checkEditing("⌃⌘E", was)
        if let done = suite.barView("bar.meadow.done") {
            let rect = suite.windowRect(done)
            suite.press(at: NSPoint(x: rect.midX, y: rect.midY))
        }
        await checkLeft("Done", was)

        // View › Edit Meadow, out with ⌘↩.
        was = await before()
        menu(["View", "Edit Meadow"])
        await checkEditing("View › Edit Meadow", was)
        let checked = item(["View", "Edit Meadow"]).map { controller.validateMenuItem($0) && $0.state == .on } ?? false
        check("View › Edit Meadow is checked while editing", checked)
        suite.shortcut("cmd+return")
        await checkLeft("⌘↩", was)

        // The grass's menu, out with View › Edit Meadow again.
        was = await before()
        if let menu = meadow.onContextMenu?(nil), let entry = menu.items.first(where: { $0.title == String(localized: "Edit Meadow…", comment: "The grass's menu: begins editing the meadow") }),
           let action = entry.action {
            NSApp.sendAction(action, to: entry.target, from: entry)
        } else {
            check("the grass's menu offers Edit Meadow…", false)
        }
        await checkEditing("the grass's menu", was)
        menu(["View", "Edit Meadow"])
        await checkLeft("View › Edit Meadow again", was)

        // Settings › Meadow's Edit Meadow…, out with Esc.
        was = await before()
        NSApp.sendAction(#selector(AppDelegate.editMeadow(_:)), to: nil, from: nil)
        await checkEditing("Settings › Meadow", was)
        suite.shortcut("esc")
        await checkLeft("Esc", was)

        // Go to's commands.
        was = await before()
        await commandPalette(String(localized: "Edit Meadow"))
        await checkEditing("Go to's commands", was)
        suite.shortcut("esc")
        await checkLeft("Esc after Go to", was)

        // The keyboard in the meadow before (⌥⌘0): it comes back there.
        suite.shortcut("cmd+opt+0")
        _ = await PerfWait.until(1000) { self.window.firstResponder === self.meadow }
        was = await before()
        suite.shortcut("cmd+ctrl+e")
        await checkEditing("⌃⌘E from the meadow's keyboard", was)
        suite.shortcut("cmd+ctrl+e")
        await checkLeft("⌃⌘E again", was, keyboard: meadow)
        suite.shortcut("esc")
        _ = await PerfWait.until(1000) { self.window.firstResponder === self.shell.surface }

        // The meadow hidden (Terminals Only), and the workspaces as a list: editing shows the meadow, and
        // leaving puts both back.
        controller.showTerminalsOnly(nil)
        await PerfWait.sleep(500)
        was = await before()
        suite.shortcut("cmd+ctrl+e")
        await checkEditing("⌃⌘E with the meadow hidden", was)
        suite.shortcut("cmd+return")
        await checkLeft("⌘↩ back to Terminals Only", was)
        controller.showMeadowAndTerminals(nil)
        controller.toggleWorkspacesAsList(nil)
        await PerfWait.sleep(800)
        // The keyboard on the terminal, as working there.
        suite.workbench.onFocusPane?(shell)
        _ = await PerfWait.until(1000) { self.window.firstResponder === self.shell.surface }
        was = await before()
        suite.shortcut("cmd+ctrl+e")
        let meadowShown = await PerfWait.until(2000) { !self.meadow.isHiddenOrHasHiddenAncestor }
        check("⌃⌘E with the workspaces as a list: the meadow is what is edited", meadowShown != nil && controller.navigator.kind == .meadow)
        // (The list takes the keyboard back from the terminal now and then on its own; what had it as
        // editing began has it again.)
        let atEntry = editor.debugKeyboardAtEntry
        suite.shortcut("cmd+return")
        await checkLeft("⌘↩ back to the list", was, keyboard: atEntry)
        check("the list is back", controller.navigator.kind == .list)
        controller.toggleWorkspacesAsList(nil)
        await PerfWait.sleep(400)
        _ = await PerfWait.until(1000) { self.window.firstResponder === self.shell.surface }
    }

    // MARK: The first edit

    func enter() async {
        // Settled first: a choice still arriving (the keyboard reaching a terminal) would end it at once.
        await PerfWait.sleep(300)
        if !controller.meadowEditing { suite.shortcut("cmd+ctrl+e") }
        let entered = await PerfWait.until(2000) { self.controller.meadowEditing }
        if entered == nil { check("⌃⌘E enters edit mode", false, "keyboard \(String(describing: window.firstResponder.map { type(of: $0) }))") }
        await still()
    }

    private func firstEdit() async {
        await enter()
        let undoBefore = library.undoManager.canUndo
        guard let stone = visible(kind: "stone.stone") else { return check("a stone in view", false) }
        let at = library.session.item(stone)!.at
        guard let spot = freeSpot(near: SIMD2(Float(at.x), Float(at.z)), big: false) else { return check("a free spot near the stone", false) }
        await drag(from: stone, toGround: spot)
        let moved = library.session.item(stone)!.at
        let file = "My Meadow.whiskrmeadow"
        check("the first edit makes My Meadow from the Default and shows it, in the same step",
              library.active == file && WorldStore.shared.settings.meadow == file && library.session.document.name == "My Meadow" && !undoBefore
                  && library.undoManager.undoActionName == MeadowWords.move(["stone.stone"]),
              "active \(library.active ?? "Default"), step \(library.undoManager.undoActionName)")
        check("…and the stone stands where it was let go", abs(moved.x - Double(spot.x)) < 0.4 && abs(moved.z - Double(spot.y)) < 0.4,
              "at \(moved), let go at \(spot)")
        let early = FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
        let saved = await PerfWait.until(2500) { (try? self.library.folder.read(file).document) == self.library.session.document }
        check("saved a second after the change, in the meadows folder (inside this run's own folder), and it reads back as it is",
              saved != nil && folder.path.hasPrefix(AppPlaces.supportFolder.path) && AppPlaces.isIsolated,
              "on disk at once \(early), read back \(saved != nil), folder in the run's own \(folder.path.hasPrefix(AppPlaces.supportFolder.path))")
        // Undone: the Default again, the copy gone; done again: My Meadow back.
        suite.shortcut("cmd+z")
        let undone = await PerfWait.until(2000) { self.library.active == nil }
        await PerfWait.sleep(300)
        check("⌘Z of the first edit: the Default again, as it was, and My Meadow gone",
              undone != nil && library.session.document == MeadowDocument.standard && meadow.scenery == library.scenery
                  && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) && WorldStore.shared.settings.meadow == nil)
        suite.shortcut("cmd+shift+z")
        let redone = await PerfWait.until(2000) { self.library.active == file }
        check("⇧⌘Z: My Meadow back, the stone moved again", redone != nil && library.session.item(stone)?.at == moved && meadow.scenery == library.scenery)
        _ = await PerfWait.until(2500) { (try? self.library.folder.read(file).document) == self.library.session.document }
    }

    // MARK: Choosing

    private func choosing() async {
        await enter()
        editor.debugChoose([])
        guard let oak = visible(kind: "tree.young") ?? visible(kind: "tree.oak"), let stone = visible(kind: "stone.stone", other: oak) else {
            return check("things in view to choose", false)
        }
        await clickThing(oak)
        check("a click chooses one thing; the selection's bar shows", editor.debugSelection == [oak] && editor.debugSelectionBarShown && meadow.editMarks.selected == [library.session.thingIndex(of: oak)!])
        await clickThing(stone, flags: .shift)
        check("⇧-click adds", editor.debugSelection == [oak, stone])
        await clickThing(oak, flags: .shift)
        check("⇧-click again lets go of it", editor.debugSelection == [stone])
        if let daisy = visible(kind: "flower.daisy") {
            await clickThing(daisy, flags: .command)
            let like = library.session.ids(like: daisy, within: EditModeController.nearby)
            check("⌘-click chooses everything of its kind nearby", editor.debugSelection.count == like.count && like.count > 1 && Set(editor.debugSelection) == Set(like),
                  "\(editor.debugSelection.count) chosen, \(like.count) daisies nearby")
        }
        if let grass = grassPoint() {
            click(at: grass)
            await PerfWait.sleep(150)
            check("a click on the grass lets go of everything; the bar goes", editor.debugSelection.isEmpty && !editor.debugSelectionBarShown)
        }
        // A marquee round a few things.
        let center = NSPoint(x: meadow.bounds.midX, y: meadow.bounds.midY)
        // Its first corner on the grass, nothing under it.
        let corners = (0..<12).map { NSPoint(x: center.x - 220 + CGFloat($0 % 4) * 23, y: center.y + 150 + CGFloat($0 / 4) * 19) }
        let corner = corners.first { meadow.sceneryThing(at: $0) == nil } ?? corners[0]
        let rect = NSRect(x: corner.x, y: corner.y - 300, width: 440, height: 300)
        let inside = meadow.sceneryThings(in: rect).compactMap(library.session.id(ofThing:))
        let from = NSPoint(x: rect.minX, y: rect.maxY), to = NSPoint(x: rect.maxX, y: rect.minY)
        if meadow.sceneryThing(at: from) == nil {
            await dragPointer(from: from, to: to) {
                self.check("a marquee draws while dragging and chooses what stands inside it as it goes",
                           self.editor.marquee.rect != nil && !self.editor.debugSelection.isEmpty)
                await self.picture("marquee")
            }
            check("…let go, exactly what stands inside it is chosen, and the marquee goes", Set(editor.debugSelection) == Set(inside) && !inside.isEmpty && editor.marquee.rect == nil,
                  "\(editor.debugSelection.count) chosen, \(inside.count) inside")
        } else {
            check("a marquee's corner on the grass", false)
        }
        // ⌘A, Esc.
        suite.shortcut("cmd+a")
        check("⌘A chooses everything", editor.debugSelection.count == library.session.drawnIDs.count)
        suite.shortcut("esc")
        check("Esc lets go of everything first", editor.debugSelection.isEmpty && controller.meadowEditing)
        suite.shortcut("esc")
        _ = await PerfWait.until(2000) { !self.controller.meadowEditing }
        check("Esc again leaves", !controller.meadowEditing)
    }

    // MARK: Moving

    private func moving() async {
        await enter()
        guard let stone = visible(kind: "stone.stone"), let tree = visible(kind: "tree.young") ?? visible(kind: "tree.oak") ?? visible(kind: "tree.birch") else {
            return check("a stone and a tree in view", false)
        }
        let undoName = library.undoManager.undoActionName
        // Onto the tree: refused, with the reason by the pointer, and back where it was.
        let treeAt = library.session.item(tree)!.at, stoneAt = library.session.item(stone)!.at
        let onto = SIMD2(Float(treeAt.x) + 0.6, Float(treeAt.z) + 0.6)
        await drag(from: stone, toGround: onto) {
            let reason = self.editor.debugReason ?? ""
            self.check("dragged onto a tree: a dashed ring and the reason by the pointer, before letting go",
                       self.meadow.editMarks.refused == [self.library.session.thingIndex(of: stone)!] && reason.contains(MeadowWords.name(self.library.session.item(tree)!.asset).lowercased()),
                       "refused \(self.meadow.editMarks.refused), reason “\(reason)”")
            await self.picture("refused-drop")
        }
        let sprung = await PerfWait.until(1500) { !self.editor.debugGestureUnderWay }
        check("let go there: it springs back where it was, the reason stays a moment, nothing is a step",
              sprung != nil && library.session.item(stone)!.at == stoneAt && meadow.scenery == library.scenery && library.undoManager.undoActionName == undoName
                  && editor.debugReason != nil, "at \(library.session.item(stone)!.at), reason \(editor.debugReason ?? "none")")
        // A big thing onto the picnic ground.
        await drag(from: tree, toGround: SIMD2(0, 30)) {
            self.check("a tree over the picnic ground: refused, kept for the workspaces",
                       self.editor.debugReason == MeadowWords.refusal(.keptForWorkspaces), self.editor.debugReason ?? "no reason")
            await self.picture("picnic-ground-refused")
        }
        _ = await PerfWait.until(1500) { !self.editor.debugGestureUnderWay }
        check("…and it springs back", library.session.item(tree)!.at == treeAt)
        // Esc mid-drag: back, nothing changed.
        if let spot = freeSpot(near: SIMD2(Float(stoneAt.x), Float(stoneAt.z)), big: false) {
            await drag(from: stone, toGround: spot, finish: .escape)
            _ = await PerfWait.until(1500) { !self.editor.debugGestureUnderWay }
            check("Esc during a drag: it goes back, nothing changed, still chosen and still editing",
                  library.session.item(stone)!.at == stoneAt && controller.meadowEditing && editor.debugSelection == [stone])
        }
        // A tree moved to a free spot, measured: its frames while dragged.
        guard let spot = freeSpot(near: SIMD2(Float(treeAt.x), Float(treeAt.z)), big: true) else { return check("a free spot for the tree", false) }
        let started = perfNow()
        await drag(from: tree, toGround: spot, steps: 150)
        let ended = perfNow()
        let at = library.session.item(tree)!.at
        check("a tree dragged to free ground stands there; one step, “\(MeadowWords.move([library.session.item(tree)!.asset]))”",
              abs(at.x - Double(spot.x)) < 0.4 && abs(at.z - Double(spot.y)) < 0.4 && library.undoManager.undoActionName == MeadowWords.move([library.session.item(tree)!.asset]))
        // The meadow's own count of frames drawn each second while dragged (its first second, the press, apart).
        let timings = suite.log.meadow(from: started + 1100, to: ended - 200)
        let quiet = MachineLoad.shared.others(from: started, to: ended).map { $0 <= MachineLoad.busyCores } ?? true
        let fps = timings.map(\.framesPerSecond).min() ?? 0, dropped = timings.map(\.droppedFrames).reduce(0, +)
        let target = timings.map(\.targetFramesPerSecond).max() ?? 0
        print(String(format: "editor: dragging a tree: %.0f frames a second at the least (asked %d), %d dropped, %d seconds measured", fps, target, dropped, timings.count))
        if quiet {
            check("while a thing is dragged the meadow draws at the full rate", !timings.isEmpty && target >= 60 && fps >= Double(target) * 0.85,
                  String(format: "%.0f of %d", fps, target))
        } else {
            print("editor: frame pacing not judged: the Mac was busy")
        }
        // Undo and redo, by key and by the top bar's buttons.
        suite.shortcut("cmd+z")
        check("⌘Z puts it back", library.session.item(tree)!.at == treeAt && meadow.scenery == library.scenery)
        // The bar's buttons take the new step once the bar is drawn again.
        await PerfWait.sleep(250)
        if let redo = suite.barView("bar.arrow.uturn.forward") {
            let rect = suite.windowRect(redo)
            suite.press(at: NSPoint(x: rect.midX, y: rect.midY))
        }
        _ = await PerfWait.until(1000) { self.library.session.item(tree)!.at == at }
        check("the top bar's Redo moves it again", library.session.item(tree)!.at == at)
        await PerfWait.sleep(250)
        if let undo = suite.barView("bar.arrow.uturn.backward") {
            let rect = suite.windowRect(undo)
            suite.press(at: NSPoint(x: rect.midX, y: rect.midY))
        }
        _ = await PerfWait.until(1000) { self.library.session.item(tree)!.at == treeAt }
        check("the top bar's Undo puts it back", library.session.item(tree)!.at == treeAt)
        suite.shortcut("cmd+shift+z")
        check("⇧⌘Z again", library.session.item(tree)!.at == at)
        // ⌥-drag: a copy where it is let go, the original where it was.
        let count = library.session.document.entries.count
        if let copySpot = freeSpot(near: SIMD2(Float(stoneAt.x), Float(stoneAt.z)), big: false) {
            await drag(from: stone, toGround: copySpot, flags: .option)
            let copies = library.session.document.items.filter { $0.asset == "stone.stone" && abs($0.at.x - Double(copySpot.x)) < 0.5 && abs($0.at.z - Double(copySpot.y)) < 0.5 }
            check("⌥-drag leaves the original and puts a copy where it is let go, chosen; one step",
                  library.session.document.entries.count == count + 1 && library.session.item(stone)!.at == stoneAt && copies.count == 1
                      && library.undoManager.undoActionName == MeadowWords.duplicate(["stone.stone"]) && editor.debugSelection.count == 1 && editor.debugSelection != [stone])
            suite.shortcut("cmd+z")
            check("⌘Z takes the copy away", library.session.document.entries.count == count)
        }
    }

    // MARK: Keys

    private func keys() async {
        await enter()
        guard let stone = visible(kind: "stone.stone"), let daisy = visible(kind: "flower.daisy") else { return check("a stone and a daisy in view", false) }
        await clickThing(stone)
        let at = library.session.item(stone)!.at
        let axes = meadow.groundAxes
        suite.shortcut("right")
        var now = library.session.item(stone)!.at
        check("→ nudges a quarter unit along the view's right", abs(now.x - (at.x + Double(axes.right.x) * 0.25)) < 0.002 && abs(now.z - (at.z + Double(axes.right.y) * 0.25)) < 0.002,
              "\(at) → \(now)")
        suite.shortcut("shift+up")
        let then = library.session.item(stone)!.at
        check("⇧↑ a whole unit toward the top of the view", abs(then.x - (now.x + Double(axes.forward.x))) < 0.002 && abs(then.z - (now.z + Double(axes.forward.y))) < 0.002)
        now = then
        let turn = library.session.item(stone)!.turn
        suite.shortcut("r")
        let turned = library.session.item(stone)!.turn
        check("R turns 15° clockwise, as a step", abs(MeadowEditSession.normalTurnForTests(turned - (turn - .pi / 12))) < 1e-3
              && library.undoManager.undoActionName == MeadowWords.turn(["stone.stone"]))
        suite.shortcut("opt+r")
        check("⌥R turns 1°", abs(MeadowEditSession.normalTurnForTests(library.session.item(stone)!.turn - (turned - .pi / 180))) < 1e-3)
        suite.shortcut("shift+r")
        check("⇧R turns back 15°", abs(MeadowEditSession.normalTurnForTests(library.session.item(stone)!.turn - (turned - .pi / 180 + .pi / 12))) < 1e-3)
        suite.shortcut("]")
        check("] on a stone: refused, only living things change size", editor.debugReason == MeadowWords.refusal(.keepsItsSize("stone.stone")) && library.session.item(stone)!.size == library.session.item(stone)!.size)
        await clickThing(daisy)
        let size = library.session.item(daisy)!.size ?? [1, 1, 1]
        suite.shortcut("]")
        let grown = library.session.item(daisy)!.size ?? [1, 1, 1]
        check("] grows a daisy a step", abs(grown[1] - size[1] * EditModeController.sizeStep) < 1e-3 && library.undoManager.undoActionName == MeadowWords.resize(["flower.daisy"]))
        suite.shortcut("[")
        check("[ shrinks it back", zip(library.session.item(daisy)!.size ?? [1, 1, 1], size).allSatisfy { abs($0 - $1) < 2e-4 })
        let count = library.session.document.entries.count
        suite.shortcut("cmd+d")
        check("⌘D duplicates beside it (not Split Right), the copy chosen", library.session.document.entries.count == count + 1 && controller.meadowEditing
              && editor.debugSelection.count == 1 && editor.debugSelection != [daisy] && library.undoManager.undoActionName == MeadowWords.duplicate(["flower.daisy"]))
        suite.shortcut("delete")
        check("⌫ deletes it", library.session.document.entries.count == count && editor.debugSelection.isEmpty && library.undoManager.undoActionName == MeadowWords.delete(["flower.daisy"]))
        suite.shortcut("cmd+z")
        check("⌘Z brings it back, chosen", library.session.document.entries.count == count + 1 && editor.debugSelection.count == 1)
        suite.shortcut("cmd+z")
        check("⌘Z again takes the duplicate away", library.session.document.entries.count == count)
        // With nothing chosen: the keyboard's cursor, Return, [ ].
        editor.debugChoose([])
        suite.shortcut("left")
        check("an arrow with nothing chosen shows the keyboard's cursor", editor.cursor != nil && meadow.editMarks.cursor != nil)
        suite.shortcut("return")
        let nearest = editor.cursor.flatMap { c in library.session.idsByDistance(from: SIMD2(Double(c.x), Double(c.y))).first }
        check("Return chooses the thing nearest the cursor", editor.debugSelection.count == 1 && editor.debugSelection.first == nearest)
        suite.shortcut("esc")
        suite.shortcut("]")
        let first = editor.focused
        suite.shortcut("]")
        check("] with nothing chosen goes from thing to thing round the cursor, ringed, without choosing",
              first != nil && editor.focused != nil && editor.focused != first && editor.debugSelection.isEmpty
                  && meadow.editMarks.hovered == editor.focused.flatMap(library.session.thingIndex(of:)))
        suite.shortcut("[")
        check("[ goes back", editor.focused == first)
        suite.shortcut("return")
        check("Return chooses the thing gone to", first != nil && editor.debugSelection == [first!])
        // The view: , and . turn it, 0 frames it again.
        suite.shortcut("esc")
        let bearing = meadow.cameraView.bearing
        suite.shortcut(".")
        await still()
        check(". turns the view 45°", abs(meadow.cameraView.bearing - (bearing - .pi / 4)) < 0.01)
        // With a pointer alone: View › Editor View (the grass's menu holds the same).
        menu(["View", "Editor View", "Face North"])
        await still()
        check("View › Editor View › Face North turns the view back to north", abs(meadow.cameraView.bearing.truncatingRemainder(dividingBy: 2 * .pi)) < 0.01, "\(meadow.cameraView.bearing)")
        menu(["View", "Editor View", "Turn View Left"])
        await still()
        let left = meadow.cameraView.bearing
        menu(["View", "Editor View", "Turn View Right"])
        await still()
        check("…Turn View Left and Turn View Right turn it 45° each way", abs(left - .pi / 4) < 0.01 && abs(meadow.cameraView.bearing) < 0.01,
              "\(left), \(meadow.cameraView.bearing)")
        suite.shortcut(",")
        await still()
        suite.shortcut("0")
        await still()
        check(", turns the view, 0 frames the picnic ground again", abs(meadow.cameraView.pitch - 55 * .pi / 180) < 0.02)
        // VoiceOver: one element per tree and log, clumps for the rest; Press chooses.
        let elements = (meadow.accessibilityChildren() ?? []).compactMap { $0 as? SceneryAccessibilityElement }
        let labels = elements.compactMap { $0.accessibilityLabel() }
        check("VoiceOver reads the meadow as its trees and the log, and clumps of plants and stones",
              elements.count > 12 && elements.count < library.session.drawnIDs.count / 2 && labels.allSatisfy { !$0.isEmpty },
              "\(elements.count) elements for \(library.session.drawnIDs.count) things; e.g. \(labels.prefix(4))")
        if let clump = elements.first(where: { ($0.accessibilityLabel() ?? "").contains(",") && $0.accessibilityLabel()!.last!.isNumber }) {
            _ = clump.accessibilityPerformPress()
            check("pressing a clump chooses it", editor.debugSelection.count > 1, clump.accessibilityLabel() ?? "")
        }
        editor.debugChoose([])
    }

    // MARK: Copying

    private func copying() async {
        await enter()
        guard let stone = visible(kind: "stone.mossy") ?? visible(kind: "stone.stone"), let poppy = visible(kind: "flower.poppy", other: stone) else {
            return check("two things in view to copy", false)
        }
        await clickThing(stone)
        await clickThing(poppy, flags: .shift)
        suite.shortcut("cmd+c")
        let data = NSPasteboard.general.data(forType: EditModeController.pasteboardType)
        check("⌘C puts the chosen things on the pasteboard as a meadow file of them", data.flatMap { MeadowEditSession.pasted($0) }.map(\.count) == 2)
        let count = library.session.document.entries.count
        guard let grass = grassPoint() else { return check("grass to paste on", false) }
        await suite.hover(meadow, at: grass)
        suite.shortcut("cmd+v")
        let pasted = editor.debugSelection
        let ground = meadow.groundPoint(at: grass)!
        let middle = library.session.middle(of: pasted)
        check("⌘V pastes them at the pointer, chosen; one step", library.session.document.entries.count == count + 2 && pasted.count == 2
              && middle.map { hypot($0.x - Double(ground.x), $0.y - Double(ground.y)) < 6 } == true
              && library.undoManager.undoActionName == MeadowWords.paste(pasted.compactMap { library.session.item($0)?.asset }),
              "middle \(String(describing: middle)), pointer at \(ground)")
        suite.shortcut("cmd+x")
        check("⌘X cuts them", library.session.document.entries.count == count && NSPasteboard.general.data(forType: EditModeController.pasteboardType) != nil)
        suite.shortcut("cmd+z")
        suite.shortcut("cmd+z")
        check("⌘Z twice: the cut and the paste undone", library.session.document.entries.count == count)
    }

    // MARK: The selection's bar

    private func theSelectionBar() async {
        await enter()
        guard let tree = visible(kind: "tree.young") ?? visible(kind: "tree.oak") else { return check("a tree in view", false) }
        await clickThing(tree)
        await PerfWait.sleep(300)
        let bar = editor.selectionBar.frame.insetBy(dx: SelectionBar.margin, dy: SelectionBar.margin)
        let index = library.session.thingIndex(of: tree)!
        let thing = meadow.screenRect(ofScenery: [index]) ?? .zero, rings = meadow.screenRect(ofGroundMarks: [index]) ?? .zero
        check("the selection's bar hangs just under the rings round what is chosen (or over it, without room), inside the meadow and clear of the tray",
              editor.debugSelectionBarShown && (abs(rings.minY - bar.maxY - Look.Space.l) < 2 || abs(bar.minY - thing.maxY - Look.Space.l) < 2) && meadow.bounds.contains(bar)
                  && !bar.intersects(trayCard), "bar \(bar), rings \(rings), thing \(thing)")
        check("a chosen tree is ringed round its trunk and, more lightly, round its crown's shade, and lit a little", meadow.editMarks.selected == [index]
              && meadow.screenRect(ofGroundMarks: [index]).map { $0.width > (meadow.screenRect(ofScenery: [index])?.width ?? 0) * 0.6 } == true)
        await picture("selection-bar")
        // It follows the view.
        meadow.simulateDrag(dx: 0, dy: 60, slide: true)
        await still()
        let moved = editor.selectionBar.frame.insetBy(dx: SelectionBar.margin, dy: SelectionBar.margin)
        let ringsNow = meadow.screenRect(ofGroundMarks: [library.session.thingIndex(of: tree)!]) ?? .zero
        check("…and follows it as the view moves", abs(moved.midX - ringsNow.midX) < 2 || !meadow.bounds.contains(ringsNow), "bar \(moved), rings \(ringsNow)")
        suite.shortcut("0")
        await still()
        // Its buttons, clicked.
        let turn = library.session.item(tree)!.turn
        await clickBarButton(index: 1)
        check("its Turn Right button turns it 15° clockwise", abs(MeadowEditSession.normalTurnForTests(library.session.item(tree)!.turn - (turn - .pi / 12))) < 1e-3)
        let count = library.session.document.entries.count
        await clickBarButton(index: 5)
        check("its Duplicate button copies it", library.session.document.entries.count == count + 1)
        await clickBarButton(index: 6)
        check("its Delete button deletes the copy", library.session.document.entries.count == count)
        await clickThing(tree)
        await PerfWait.sleep(300)
        _ = MenuStandIn.take()
        await clickBarButton(index: 7)
        let more = MenuStandIn.take().first?.items.map(\.title) ?? []
        check("More: Select All Like This, Copy, Paste", more == [String(localized: "Select All Like This", comment: "Meadow editor: chooses everything of the kind nearby"), String(localized: "Copy"), String(localized: "Paste")],
              "\(more)")
        suite.shortcut("esc")
    }

    // MARK: What carries on while editing

    private func carryingOn() async {
        await enter()
        // The terminal printing all along.
        let from = perfNow()
        await PerfWait.sleep(1500)
        let printed = suite.log.outputs(from: from, to: perfNow()).count
        check("terminals keep running while the meadow is edited", printed >= 3 && shell.surface.isHiddenOrHasHiddenAncestor, "\(printed) outputs in 1.5 s")
        // A request arrives: the status bar counts it; nothing on screen moves.
        let camera = meadow.cameraView
        hook(claude, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "make test"]])
        let asked = await PerfWait.until(3000) { self.suite.workbench.status(of: self.claude) == .blocked }
        await PerfWait.sleep(800)
        let now = meadow.cameraView
        check("a request arriving while editing: counted, and nothing else changes (still editing, the view where it was)",
              asked != nil && controller.meadowEditing && abs(now.x - camera.x) < 1e-3 && abs(now.z - camera.z) < 1e-3 && abs(now.distance - camera.distance) < 1e-3
                  && suite.workbench.agentRows.contains { $0.status == .blocked })
        await picture("request-while-editing")
        // ⌘J leaves edit mode and goes there.
        suite.shortcut("cmd+j")
        let went = await PerfWait.until(3000) { !self.controller.meadowEditing && self.suite.workbench.focusedPane === self.claude }
        check("⌘J leaves edit mode and goes to the request", went != nil)
        hook(claude, "PostToolUse", ["tool_name": "Bash"])
        // ⌘T leaves first, then opens a tab.
        await enter()
        let tabs = suite.workbench.selectedWorkspace?.tabs.count ?? 0
        suite.shortcut("cmd+t")
        let opened = await PerfWait.until(3000) { !self.controller.meadowEditing && (self.suite.workbench.selectedWorkspace?.tabs.count ?? 0) == tabs + 1 }
        check("⌘T leaves edit mode first, then opens a tab", opened != nil)
        if let pane = suite.workbench.focusedPane, pane !== claude { _ = await suite.shellReady(pane); suite.workbench.close(pane: pane.id) }
        await PerfWait.sleep(500)
        suite.workbench.select(workspace: suite.workbench.workspace(of: shell.id)!.0)
        _ = await PerfWait.until(2000) { self.window.firstResponder === self.shell.surface }
    }

    // MARK: Revert to Default

    private func revert() async {
        await enter()
        let mine = library.session.document
        guard let name = suite.barView("bar.meadow.name") else {
            return check("the meadow's name in the top bar", false,
                         "editing \(controller.meadowEditing), keyboard \(String(describing: window.firstResponder.map { type(of: $0) })), sheet \(window.attachedSheet != nil)")
        }
        _ = MenuStandIn.take()
        let rect = suite.windowRect(name)
        suite.press(at: NSPoint(x: rect.midX, y: rect.midY))
        guard let popped = MenuStandIn.take().first else { return check("the name's menu pops", false) }
        let titles = popped.items.map(\.title)
        let revertTitle = String(localized: "Revert to Default")
        check("the name's menu: Use Another Meadow and Revert to Default", titles.contains(String(localized: "Use Another Meadow", comment: "Meadow editor: the name menu's list of meadows")) && titles.contains(revertTitle), "\(titles)")
        if let item = popped.menu.items.first(where: { $0.title == revertTitle }), let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        _ = await PerfWait.until(1500) { self.library.active == nil }
        await PerfWait.sleep(200)
        check("Revert to Default: the Default is shown as it always was; My Meadow stays in the folder",
              library.active == nil && meadow.scenery == MeadowScenery(MeadowDocument.standard) && library.files.contains("My Meadow.whiskrmeadow")
                  && WorldStore.shared.settings.meadow == nil && editor.bar.name == library.displayName(nil))
        await picture("default-again")
        suite.shortcut("cmd+z")
        _ = await PerfWait.until(1500) { self.library.active != nil }
        check("⌘Z: My Meadow back, as it was", library.active == "My Meadow.whiskrmeadow" && library.session.document.entries == mine.entries && meadow.scenery == library.scenery)
        suite.shortcut("cmd+return")
        _ = await PerfWait.until(2000) { !self.controller.meadowEditing }
    }

    // MARK: Pictures

    private func pictures(looks: Bool) async {
        let store = ThemeStore.shared
        let before = (store.themeID, store.appearance)
        defer {
            store.themeID = before.0
            store.appearance = before.1
        }
        for (name, id, appearance) in [("whiskr-light", BuiltInThemes.defaultID, ThemeStore.Appearance.light), ("whiskr-dark", BuiltInThemes.defaultID, .dark), ("graphite", "graphite", .dark)] {
            store.themeID = id
            store.appearance = appearance
            for (size, wide) in [(NSSize(width: 1440, height: 900), "wide"), (NSSize(width: 900, height: 700), "narrow")] {
                window.setContentSize(size)
                await PerfWait.sleep(400)
                await enter()
                if let tree = visible(kind: "tree.young") ?? visible(kind: "tree.oak") { await clickThing(tree) }
                await PerfWait.sleep(400)
                await picture("\(name)-\(wide)")
                await toolPictures("\(name)-\(wide)", wide: wide == "wide")
                suite.shortcut("cmd+return")
                _ = await PerfWait.until(2000) { !self.controller.meadowEditing }
                await still()
            }
        }
        window.setContentSize(NSSize(width: 1440, height: 900))
        await PerfWait.sleep(400)
        // Increase Contrast's look: rings, the tray's line and the circles stronger.
        store.themeID = BuiltInThemes.defaultID
        store.appearance = .light
        Look.debugIncreasesContrast = true
        await PerfWait.sleep(400)
        await enter()
        if let tree = visible(kind: "tree.young") ?? visible(kind: "tree.oak") { await clickThing(tree) }
        await PerfWait.sleep(300)
        check("with Increase Contrast the marks are drawn stronger", meadow.editMarks.highContrast)
        await picture("high-contrast")
        await toolPictures("high-contrast", wide: true)
        suite.shortcut("cmd+return")
        _ = await PerfWait.until(2000) { !self.controller.meadowEditing }
        Look.debugIncreasesContrast = false
        await still()
    }

    func picture(_ name: String) async {
        DebugShell.snapshot(window: controller, workbench: suite.workbench, to: pictures.appendingPathComponent("editor-\(name).png"))
    }

    // MARK: After

    private func leftBehind() async {
        await enter()
        suite.shortcut("cmd+return")
        _ = await PerfWait.until(2000) { !self.controller.meadowEditing }
        await still()
        let overlays = [editor.selectionBar, editor.marquee].filter { $0.superview != nil }
        check("nothing of the editor is left behind: no marks, no overlays, no gesture, the meadow's own handlers back",
              overlays.isEmpty && meadow.editMarks == MeadowEditMarks() && !meadow.isEditing && !editor.debugGestureUnderWay
                  && meadow.onEditPointer == nil && meadow.scenery == library.scenery && controller.navigator.kind == controller.layout.navigator,
              "overlays \(overlays.count), marks \(meadow.editMarks)")
        // The sidebar's own VoiceOver elements, one per workspace.
        let elements = meadow.accessibilityChildren()?.count ?? 0
        check("VoiceOver reads the workspaces again", elements == suite.workbench.workspaces.count, "\(elements)")
    }

    private func rests() async {
        // As the idle flow holds it: within 12 s of nothing new (a Claude's own news ends a rest, so it waits
        // for a quiet stretch of the agents too).
        let started = perfNow()
        let rested = await PerfWait.until(20000) { self.meadow.isResting }
        check("the meadow rests again once editing has ended", rested != nil,
              "\(rested.map { String(format: "after %.1f s", ($0 - started) / 1000) } ?? "not in 20 s"); camera moving \(meadow.cameraMoving), editing \(meadow.isEditing); \(meadow.restBlockers)")
    }

    /// The young tree moved to `quitMarker` a moment before quitting: written at quit, not a second later.
    private func beforeQuitting() async {
        await enter()
        guard let young = library.session.drawnIDs.first(where: { library.session.item($0)?.asset == "tree.young" }), let at = library.session.item(young)?.at else {
            return check("a young tree to move before quitting", false)
        }
        let result = library.edit(MeadowWords.move(["tree.young"])) { $0.move([young], by: SIMD2(EditorFlow.quitMarker.x - at.x, EditorFlow.quitMarker.y - at.z)) }
        check("a move just before quitting (to be found by the relaunch)", (try? result.get()) != nil, "\(result)")
        suite.shortcut("cmd+return")
        _ = await PerfWait.until(2000) { !self.controller.meadowEditing }
    }

    // MARK: Pieces

    func hook(_ pane: Pane, _ event: String, _ extra: [String: JSONValue]) {
        var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string("editor-\(pane.id.uuidString)"), "cwd": .string(pane.folder)]
        payload.merge(extra) { _, new in new }
        suite.workbench.monitor.simulate(paneID: pane.id, payload: .object(payload))
    }

    func item(_ path: [String]) -> NSMenuItem? {
        var menu = NSApp.mainMenu
        var found: NSMenuItem?
        for title in path {
            found = menu?.items.first { $0.title == title || $0.title == String(localized: String.LocalizationValue(title)) }
            menu = found?.submenu
        }
        return found
    }

    /// A menu item chosen as the menu bar would: validated, then sent through the responder chain.
    func menu(_ path: [String]) {
        guard let entry = item(path), let action = entry.action else { return check("the menu item \(path.joined(separator: " › "))", false) }
        // Through the window's own controller, as the menu bar reaches it (a window nobody sees is never key).
        NSApp.sendAction(action, to: entry.target ?? controller, from: entry)
    }

    /// Go to's commands (⇧⌘P): `text` typed into its field, then Return.
    func commandPalette(_ text: String) async {
        suite.shortcut("cmd+shift+p")
        let panel = { self.window.childWindows?.last { $0 is NSPanel && $0.firstResponder is NSText } }
        guard await PerfWait.until(1500, { panel() != nil }) != nil, let panel = panel() else { return check("⇧⌘P opens the commands", false) }
        func key(_ characters: String, _ code: UInt16) {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                panel.sendEvent(event)
            }
        }
        for character in text { key(String(character), 0) }
        await PerfWait.sleep(300)
        key("\r", 36)
    }

    /// A drawn thing of a kind well inside the view (not `other`), by id.
    func visible(kind: String, other: Int? = nil) -> Int? {
        let session = library.session
        let inset = meadow.bounds.insetBy(dx: 120, dy: 110)
        let candidates = session.drawnIDs.filter { id in
            guard id != other, let item = session.item(id), item.asset == kind, let point = meadow.viewPoint(ofGround: SIMD2(Float(item.at.x), Float(item.at.z))) else { return false }
            return inset.contains(point) && meadow.sceneryThing(at: grabPoint(id) ?? point) == session.thingIndex(of: id)
        }
        // The one nearest the view's middle.
        let middle = NSPoint(x: meadow.bounds.midX, y: meadow.bounds.midY)
        let distances = candidates.map { id in (id, grabPoint(id).map { hypot($0.x - middle.x, $0.y - middle.y) } ?? .infinity) }
        return distances.min { $0.1 < $1.1 }?.0
    }

    /// Where to press on a thing: a little above where it stands, on its body.
    func grabPoint(_ id: Int) -> NSPoint? {
        guard let item = library.session.item(id), let base = meadow.viewPoint(ofGround: SIMD2(Float(item.at.x), Float(item.at.z))) else { return nil }
        return NSPoint(x: base.x, y: base.y + 4)
    }

    /// A point of the view on grass, with nothing within a few units.
    func grassPoint() -> NSPoint? {
        for y in stride(from: meadow.bounds.midY, to: meadow.bounds.maxY - 80, by: 23) {
            for x in stride(from: meadow.bounds.midX, to: meadow.bounds.maxX - 80, by: 31) {
                let point = NSPoint(x: x, y: y)
                guard meadow.sceneryThing(at: point) == nil, let ground = meadow.groundPoint(at: point) else { continue }
                let near = library.session.idsByDistance(from: SIMD2(Double(ground.x), Double(ground.y))).first.flatMap { library.session.item($0)?.at }
                if near.map({ hypot($0.x - Double(ground.x), $0.z - Double(ground.y)) > 5 }) ?? true { return point }
            }
        }
        return nil
    }

    /// Free ground near a spot, in view, where a thing may stand (off the picnic ground for a big one).
    func freeSpot(near spot: SIMD2<Float>, big: Bool) -> SIMD2<Float>? {
        let field = SceneryRules.Field(library.scenery)
        for ring in stride(from: Float(6), through: 40, by: 2) {
            for k in 0..<16 {
                let a = Float(k) / 16 * 2 * .pi
                let p = spot + SIMD2(cos(a), sin(a)) * ring
                guard let view = meadow.viewPoint(ofGround: p), meadow.bounds.insetBy(dx: 80, dy: 80).contains(view) else { continue }
                let probe = MeadowScenery.Thing(id: big ? "tree.oak" : "stone.stone", x: p.x, z: p.y, size: SIMD3(1.3, 1.3, 1.3))
                if field.refusal(for: probe) == nil { return p }
            }
        }
        return nil
    }

    func send(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = [], count: Int = 1) {
        let location = meadow.convert(point, to: nil)
        PointerStandIn.location = location
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: suite.nextEventNumber(), clickCount: count,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.sendEvent(event)
    }

    /// A click at a point of the meadow, with modifiers held.
    func click(at point: NSPoint, flags: NSEvent.ModifierFlags = []) {
        send(.leftMouseDown, at: point, flags: flags)
        send(.leftMouseUp, at: point, flags: flags)
    }

    func clickThing(_ id: Int, flags: NSEvent.ModifierFlags = []) async {
        guard let point = grabPoint(id) else { return check("thing \(id) in view to click", false) }
        click(at: point, flags: flags)
        await PerfWait.sleep(120)
    }

    /// A press, a drag in steps a frame apart, a rest (`midway` runs then), and a release (or Esc).
    func dragPointer(from: NSPoint, to: NSPoint, steps: Int = 24, flags: NSEvent.ModifierFlags = [], finish: PerfSuite.DragEnd = .drop,
                             midway: (() async -> Void)? = nil) async {
        send(.leftMouseDown, at: from, flags: flags)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps), eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            send(.leftMouseDragged, at: NSPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased), flags: flags)
            await PerfWait.sleep(16)
        }
        await PerfWait.sleep(200)
        await midway?()
        if finish == .escape, let escape = suite.keyEvent("\u{1b}", code: 53) { NSApp.sendEvent(escape) }
        send(.leftMouseUp, at: to, flags: flags)
        await PerfWait.sleep(150)
    }

    /// Picks up a thing and drops it so its spot lands on `ground`.
    func drag(from id: Int, toGround ground: SIMD2<Float>, steps: Int = 24, flags: NSEvent.ModifierFlags = [], finish: PerfSuite.DragEnd = .drop,
                      midway: (() async -> Void)? = nil) async {
        guard let item = library.session.item(id), let start = grabPoint(id), let base = meadow.viewPoint(ofGround: SIMD2(Float(item.at.x), Float(item.at.z))),
              let pressGround = meadow.groundPoint(at: start), let target = meadow.viewPoint(ofGround: ground + (pressGround - SIMD2(Float(item.at.x), Float(item.at.z)))) else {
            return check("thing \(id) in view to drag", false)
        }
        _ = base
        if !editor.debugSelection.contains(id) { await clickThing(id, flags: flags.contains(.shift) ? .shift : []) }
        await dragPointer(from: start, to: target, steps: steps, flags: flags, finish: finish, midway: midway)
    }

    /// Clicks the selection's bar's `index`th button (0: Turn Left …).
    /// (8: Straighten, 9: Add or Remove Gate, for a fence; 10: Colour.)
    func clickBarButton(index: Int) async {
        let host = editor.selectionBar
        let model = editor.barModel
        // Buttons are 28 wide with 2 between, and a separator (1 + 4) after Turn Right, after Shuffle, before Colour,
        // after Delete; a fence's bar: Straighten, Add Gate, a separator, Delete, a separator, More.
        var x = SelectionBar.margin + Look.Space.xs
        let order: [Int] = model.fence ? [8, 9, -1, 6, -1, 7]
            : [0, 1] + (model.grows ? [-1, 2, 3, 4] : []) + (model.swatches.isEmpty ? [] : [-1, 10]) + [-1, 5, 6, -1, 7]
        for slot in order {
            if slot == index { break }
            x += slot == -1 ? 1 + 2 * Look.Space.xxs + Look.Space.xxs : Look.Height.iconButton + Look.Space.xxs
        }
        let local = NSPoint(x: x + Look.Height.iconButton / 2, y: host.bounds.midY)
        let point = host.convert(local, to: meadow)
        click(at: point)
        await PerfWait.sleep(200)
    }
}

extension MeadowEditSession {
    /// A difference of turns brought to (−π, π] (the checks' comparisons of turns).
    static func normalTurnForTests(_ radians: Double) -> Double {
        var t = radians.truncatingRemainder(dividingBy: 2 * .pi)
        if t > .pi { t -= 2 * .pi } else if t <= -.pi { t += 2 * .pi }
        return t
    }
}
#endif
