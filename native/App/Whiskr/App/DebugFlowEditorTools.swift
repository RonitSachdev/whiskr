#if DEBUG
import AppKit
import MeadowFile
@_spi(Diagnostics) import MeadowScene
import WhiskrKit
import WhiskrMeadow

/// The editor flow's part for the tray and its tools (`DebugFlowEditor.swift`), every press, drag, release and key
/// through `NSApplication.sendEvent`:
/// - the tray: where it floats, the things it offers (exactly what the scene draws) with their pictures, the
///   tools, the categories, the filter (⌘F), the shelf with the keyboard (Tab, ← →, Return), folding (⌥⌘T), the
///   picnic ground framed above it;
/// - placing: a ghost under the pointer, refused where a thing may not stand with the reason, R turning it, a
///   click placing it (one step, chosen, settling), ⇧-click placing more, Esc putting it back, a tile dragged out
///   onto the meadow or back, a double-click, and the keys alone;
/// - the Brush: clumps along a stroke (one step, never overlapping, at the full frame rate), ⌥-drag clearing,
///   the size and density, the wildflower mix, Return at the cursor;
/// - the Eraser: a click, a sweep (never a tree), one kind only;
/// - the caps, said before they are reached and kindly when they are; Reduce Motion; pictures of every state
///   (the Ground tool and stepping stones among them).
extension EditorFlow {
    var tray: EditorTray { editor.tray }
    var count: Int { library.session.document.entries.count }
    var undoName: String { library.undoManager.undoActionName }

    // MARK: Pieces

    /// A tile of the tray's shelf, by item id.
    func tile(_ id: String) -> NSView? { suite.barView("tray.item.\(id)") }

    /// A control of the tray (or a tile), once SwiftUI has drawn it (a shelf just shown is drawn a moment later).
    func trayControl(_ id: String) async -> NSView? {
        _ = await PerfWait.until(1500) { self.suite.barView(id) != nil }
        return suite.barView(id)
    }

    /// A click on a control of the tray (or a tile) at its middle, through the window.
    func pressTray(_ id: String, count: Int = 1) async {
        guard let view = await trayControl(id) else { return check("the tray's \(id) is there to click", false) }
        let rect = suite.windowRect(view)
        sendWindow(.leftMouseDown, at: NSPoint(x: rect.midX, y: rect.midY), count: 1)
        sendWindow(.leftMouseUp, at: NSPoint(x: rect.midX, y: rect.midY), count: 1)
        if count == 2 {
            sendWindow(.leftMouseDown, at: NSPoint(x: rect.midX, y: rect.midY), count: 2)
            sendWindow(.leftMouseUp, at: NSPoint(x: rect.midX, y: rect.midY), count: 2)
        }
        await PerfWait.sleep(150)
    }

    func sendWindow(_ type: NSEvent.EventType, at location: NSPoint, flags: NSEvent.ModifierFlags = [], count: Int = 1) {
        PointerStandIn.location = location
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: suite.nextEventNumber(), clickCount: count,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        NSApp.sendEvent(event)
    }

    /// A press on a tile, dragged a frame at a time to `to` (in the meadow), and let go.
    func dragTile(_ id: String, to: NSPoint, midway: (() async -> Void)? = nil) async {
        guard let view = await trayControl("tray.item.\(id)") else { return check("the tile \(id) to drag", false) }
        let rect = suite.windowRect(view)
        let from = NSPoint(x: rect.midX, y: rect.midY), end = meadow.convert(to, to: nil)
        sendWindow(.leftMouseDown, at: from)
        for step in 1...20 {
            let t = CGFloat(step) / 20
            sendWindow(.leftMouseDragged, at: NSPoint(x: from.x + (end.x - from.x) * t, y: from.y + (end.y - from.y) * t))
            await PerfWait.sleep(16)
        }
        await PerfWait.sleep(150)
        await midway?()
        sendWindow(.leftMouseUp, at: end)
        await PerfWait.sleep(200)
    }

    /// The pointer moved over the meadow to `point`.
    func hoverMeadow(_ point: NSPoint) async {
        await suite.hover(meadow, at: point)
        await PerfWait.sleep(80)
    }

    /// Whether a picture shows something on its round of grass: a tenth of its middle half unlike its corner.
    static func hasSubject(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let i = y * image.bytesPerRow + x * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        let corner = pixel(2, 2), w = image.width, h = image.height
        var unlike = 0, all = 0
        for y in (h / 4)..<(3 * h / 4) {
            for x in (w / 4)..<(3 * w / 4) {
                let p = pixel(x, y)
                all += 1
                if abs(corner.0 - p.0) + abs(corner.1 - p.1) + abs(corner.2 - p.2) > 60 { unlike += 1 }
            }
        }
        return Double(unlike) / Double(max(all, 1)) > 0.1
    }

    /// The tray's card, in the meadow's coordinates.
    var trayCard: NSRect {
        meadow.convert(editor.trayHost.frame.insetBy(dx: EditorTrayView.margin, dy: EditorTrayView.margin), from: editor.trayHost.superview)
    }

    /// A free spot in view (off the picnic ground) for a big thing, round the first young tree or oak in view.
    func freeSpotInView(big: Bool) -> SIMD2<Float>? {
        guard let near = visible(kind: "tree.young") ?? visible(kind: "tree.oak") ?? visible(kind: "stone.stone"), let at = library.session.item(near)?.at else { return nil }
        return freeSpot(near: SIMD2(Float(at.x), Float(at.z)), big: big).flatMap { spot in
            meadow.viewPoint(ofGround: spot).map { trayCard.insetBy(dx: -20, dy: -20).contains($0) } == true ? nil : spot
        }
    }

    // MARK: The tray

    func theTray() async {
        await enter()
        editor.debugChoose([])
        let card = trayCard
        check("the tray floats along the meadow's bottom edge, inside it", editor.trayHost.superview != nil && meadow.bounds.contains(card)
              && card.minY >= Look.Space.xl - 1 && card.minY <= Look.Space.xl + 1, "card \(card) in \(meadow.bounds)")
        let ids = EditorTray.things.map(\.id)
        let drawn = MeadowCatalog.current.assets.filter { $0.inTray && MeadowScenery.draws($0.id) }.map(\.id)
        check("the shelf offers every thing the scene draws, in the catalog's order, and nothing it cannot (\(ids.count))",
              ids == drawn && ids.count == 43 && Set(ids) == MeadowScenery.drawnIds, "\(ids)")
        check("the categories are those that hold something: Trees, Flowers, Stones & Wood, the Ground tool's paints, Garden, Workplace and Cat Things",
              EditorTray.categories == [.trees, .flowers, .stonesAndWood, .ground, .garden, .workplace, .catThings] && suite.barView("tray.category.ground") != nil
                  && suite.barView("tray.tool.ground") != nil)
        let scale = window.backingScaleFactor
        let pictured = ids + [EditorTray.wildflowers] + EditorTray.paints.map(\.id)
        let pictures = pictured.compactMap { tray.pictures[$0] }
        check("every tile has its picture, drawn by the scene in its own clay (the paints as real turf), crisp at the screen's scale",
              pictures.count == pictured.count && pictures.allSatisfy { $0.width == Int(EditorTray.tile * scale) && Self.hasSubject($0) },
              "\(pictures.count) pictures of \(pictured.count), widths \(Set(pictures.map(\.width)))")
        // The blankets framed above the tray.
        let blankets = suite.workbench.workspaces.compactMap { meadow.screenRect(of: .blanket($0.id.uuidString)) }
        check("the picnic ground's blankets are framed in the meadow above the tray", !blankets.isEmpty && blankets.allSatisfy { $0.minY > card.maxY && $0.maxY < meadow.bounds.maxY },
              "tray top \(Int(card.maxY)), blankets \(blankets.map { Int($0.minY) })")

        // The tools: clicked, and by key.
        for (tool, id) in [(EditorTray.Tool.brush, "tray.tool.brush"), (.erase, "tray.tool.erase"), (.select, "tray.tool.select")] {
            await pressTray(id)
            check("the tray's \(tool.rawValue) button chooses that tool", tray.tool == tool)
        }
        suite.shortcut("b")
        let brush = tray.tool == .brush
        suite.shortcut("e")
        let erase = tray.tool == .erase
        suite.shortcut("v")
        check("B, E and V choose the Brush, the Eraser and Select", brush && erase && tray.tool == .select)
        menu(["View", "Editor Tools", "Brush"])
        check("View › Editor Tools › Brush chooses the Brush", tray.tool == .brush)
        suite.shortcut("v")
        // Categories.
        suite.shortcut("2")
        let flowers = tray.category == .flowers && tray.shelf.allSatisfy { $0.category == .flowers }
        await pressTray("tray.category.stonesAndWood")
        check("2 and the category's tab show that shelf", flowers && tray.category == .stonesAndWood
                  && tray.shelf.map(\.id) == ["stone.stone", "stone.mossy", "stone.boulder", "stone.stepping", "wood.fallenLog", "wood.stump", "wood.logPile"],
              "\(tray.shelf.map(\.id))")
        suite.shortcut("7")
        let catThings = tray.category == .catThings
        suite.shortcut("1")
        check("7: Cat Things; 1: the trees again", catThings && tray.category == .trees && tray.shelf.count == 6)

        // ⌘F: the filter.
        suite.shortcut("cmd+f")
        await PerfWait.sleep(300)
        let inField = (window.firstResponder as? NSView)?.isDescendant(of: editor.trayHost) == true && window.firstResponder is NSText
        suite.typeKeys("mossy")
        await PerfWait.sleep(200)
        check("⌘F takes the keyboard to the tray's filter; typing finds across categories", inField && tray.filter == "mossy" && tray.shelf.map(\.id) == ["stone.mossy"],
              "keyboard \(String(describing: window.firstResponder.map { type(of: $0) })), filter “\(tray.filter)”, shelf \(tray.shelf.map(\.id))")
        await picture("tray-filter")
        suite.typeKeys("\r")
        await PerfWait.sleep(200)
        check("Return in the filter arms what it found and gives the meadow the keyboard", tray.armed == "stone.mossy" && window.firstResponder === meadow && tray.filter.isEmpty)
        suite.shortcut("esc")
        check("Esc puts it back, still editing", tray.armed == nil && controller.meadowEditing)

        // The shelf with the keyboard: Tab, → , Return; the ghost waits at the cursor, arrows move it, Return places.
        suite.shortcut("tab")
        await PerfWait.sleep(150)
        let onShelf = window.firstResponder === editor.trayKeys && tray.shelfHasKeyboard && tray.highlighted == "tree.oak"
        suite.shortcut("right")
        suite.shortcut("right")
        let highlighted = tray.highlighted
        await picture("tray-keyboard")
        suite.shortcut("return")
        await PerfWait.sleep(150)
        check("Tab gives the shelf the keyboard (on its first thing), → goes along it, Return arms it and hands the meadow the keyboard",
              onShelf && highlighted == "tree.cherry" && tray.armed == "tree.cherry" && window.firstResponder === meadow && meadow.editMarks.ghost != nil,
              "on shelf \(onShelf), highlighted \(highlighted ?? "none"), armed \(tray.armed ?? "none")")
        let ghost = meadow.editMarks.ghost
        let axes = meadow.groundAxes
        suite.shortcut("shift+left")
        let moved = meadow.editMarks.ghost
        check("arrows move the ghost with the keyboard's cursor", ghost != nil && moved.map { abs($0.x - (ghost!.x - axes.right.x * 2)) < 0.01 && abs($0.z - (ghost!.z - axes.right.y * 2)) < 0.01 } == true)
        let before = count
        suite.shortcut("return")
        await PerfWait.sleep(200)
        let placed = library.session.drawnIDs.last.flatMap { library.session.item($0) }
        check("Return places it at the cursor, or the nearest spot round it where it may stand: one step, chosen",
              count == before + 1 && placed?.asset == "tree.cherry" && undoName == MeadowWords.place(["tree.cherry"]) && editor.debugSelection == [library.session.drawnIDs.last!] && tray.armed == nil,
              "\(count - before) placed, step “\(undoName)”")
        suite.shortcut("cmd+z")
        check("⌘Z takes it away", count == before)

        // Folding.
        let height = card.height, cover = meadow.editingCover
        suite.shortcut("cmd+opt+t")
        await PerfWait.sleep(400)
        let folded = trayCard
        check("⌥⌘T folds the tray to its top row and the view frames the picnic ground lower", tray.collapsed && folded.height < height / 3 && meadow.editingCover < cover,
              "card \(Int(height)) → \(Int(folded.height)), cover \(Int(cover)) → \(Int(meadow.editingCover))")
        await picture("tray-folded")
        let title = item(["View", "Hide Editor Tray"]).map { _ = controller.validateMenuItem($0); return $0.title }
        menu(["View", "Show Editor Tray"])
        await PerfWait.sleep(400)
        check("View › Show Editor Tray unfolds it", !tray.collapsed && abs(trayCard.height - height) < 1 && title == String(localized: "Show Editor Tray", comment: "View menu: unfolds the meadow editor's tray"),
              "menu said “\(title ?? "none")”, folded \(tray.collapsed), card \(Int(trayCard.height))")
        if tray.collapsed { editor.toggleTray() }
        // A narrow window: tools and categories as symbols, the tray inside the meadow, the blankets above it.
        window.setContentSize(NSSize(width: 720, height: 640))
        await PerfWait.sleep(600)
        await still()
        let narrow = trayCard
        let blanketsNarrow = suite.workbench.workspaces.compactMap { meadow.screenRect(of: .blanket($0.id.uuidString)) }
        check("under 760 pt the tray shows its tools and categories as symbols and still fits inside the meadow, the blankets above it",
              tray.narrow && meadow.bounds.contains(narrow) && narrow.width <= meadow.bounds.width - 2 * Look.Space.xl + 1 && blanketsNarrow.allSatisfy { $0.minY > narrow.maxY },
              "card \(narrow) in \(meadow.bounds)")
        await picture("tray-narrow")
        window.setContentSize(NSSize(width: 1440, height: 900))
        await PerfWait.sleep(600)
        check("…and wide again, words", !tray.narrow)
    }

    // MARK: Placing

    func placing() async {
        await enter()
        editor.debugChoose([])
        suite.shortcut("1")
        guard let spot = freeSpotInView(big: true), let point = meadow.viewPoint(ofGround: spot) else { return check("free ground in view to place on", false) }
        await pressTray("tray.item.tree.oak")
        check("a click on a tile arms it; the tray says what to do", tray.armed == "tree.oak" && tray.hint == MeadowWords.hint(.select, armed: true))
        await hoverMeadow(point)
        let ghost = meadow.editMarks.ghost
        check("its ghost follows the pointer onto the ground, ringed, where it may stand", ghost?.id == "tree.oak" && !meadow.editMarks.ghostRefused
              && ghost.map { hypot($0.x - spot.x, $0.z - spot.y) < 0.6 } == true && editor.debugReason == nil, "ghost \(String(describing: ghost)), spot \(spot)")
        await picture("place-ghost")
        // The picnic ground: refused, said.
        guard let picnic = meadow.viewPoint(ofGround: SIMD2(0, 8)) else { return check("the picnic ground in view", false) }
        await hoverMeadow(picnic)
        check("over the picnic ground: greyed, ring dashed, the reason by the pointer", meadow.editMarks.ghostRefused && editor.debugReason == MeadowWords.refusal(.keptForWorkspaces),
              editor.debugReason ?? "no reason")
        await picture("place-refused")
        let before = count
        click(at: picnic)
        await PerfWait.sleep(200)
        check("a click there places nothing and keeps it armed", count == before && tray.armed == "tree.oak")
        // R turns the ghost.
        await hoverMeadow(point)
        let turn = editor.debugPending.item?.turn ?? 0
        suite.shortcut("r")
        let turned = editor.debugPending.item?.turn ?? 0
        check("R turns the ghost 15°, before it is placed", abs(MeadowEditSession.normalTurnForTests(turned - (turn - .pi / 12))) < 1e-3)
        let pending = editor.debugPending.item
        click(at: point)
        await PerfWait.sleep(60)
        let settling = editor.debugSettling
        await PerfWait.sleep(300)
        let id = library.session.drawnIDs.last ?? -1
        let oak = library.session.item(id)
        check("a click places it there, as drawn (its seed, size and turn): one step, chosen, the tool back to choosing",
              count == before + 1 && oak?.asset == "tree.oak" && oak?.seed == pending?.seed && oak?.turn == pending?.turn
                  && oak.map { hypot($0.at.x - Double(spot.x), $0.at.z - Double(spot.y)) < 0.6 } == true
                  && undoName == MeadowWords.place(["tree.oak"]) && editor.debugSelection == [id] && tray.armed == nil && meadow.editMarks.ghost == nil,
              "\(count - before) placed at \(String(describing: oak?.at)), step “\(undoName)”")
        check("…and settles into the meadow (92 % → its own size in 160 ms)", settling && !editor.debugSettling && meadow.scenery == library.scenery)
        await picture("placed-chosen")
        suite.shortcut("cmd+z")
        check("⌘Z takes it away", count == before && library.session.item(id) == nil)
        suite.shortcut("cmd+shift+z")
        check("⇧⌘Z puts it back, the same oak", library.session.item(id) == oak)

        // ⇧-click places more.
        suite.shortcut("2")
        await pressTray("tray.item.flower.poppy")
        guard let grass = grassPoint() else { return check("grass for poppies", false) }
        let more = count
        click(at: grass, flags: .shift)
        await PerfWait.sleep(150)
        click(at: NSPoint(x: grass.x + 40, y: grass.y), flags: .shift)
        await PerfWait.sleep(150)
        let poppies = library.session.drawnIDs.suffix(2).compactMap { library.session.item($0) }
        check("⇧-click places one and keeps the next armed; no two alike", count == more + 2 && tray.armed == "flower.poppy" && poppies.count == 2
              && poppies[0].size != poppies[1].size, "\(count - more) placed")
        suite.shortcut("esc")
        check("Esc puts the armed thing back (and the next Esc lets go of the choice)", tray.armed == nil && meadow.editMarks.ghost == nil && controller.meadowEditing)

        // A tile dragged out onto the meadow.
        suite.shortcut("3")
        guard let stoneSpot = freeSpotInView(big: false), let stonePoint = meadow.viewPoint(ofGround: stoneSpot) else { return check("free ground for a stone", false) }
        let dragged = count
        await dragTile("stone.mossy", to: stonePoint) {
            self.check("a tile dragged out over the meadow carries its ghost under the pointer", self.meadow.editMarks.ghost?.id == "stone.mossy" && self.tray.dragging == "stone.mossy")
            await self.picture("place-drag")
        }
        let stone = library.session.drawnIDs.last.flatMap { library.session.item($0) }
        check("…let go there, it is placed where it was let go, chosen", count == dragged + 1 && stone?.asset == "stone.mossy"
              && stone.map { hypot($0.at.x - Double(stoneSpot.x), $0.at.z - Double(stoneSpot.y)) < 0.8 } == true && editor.debugSelection.count == 1 && tray.dragging == nil)
        let tray = trayCard
        await dragTile("stone.stone", to: NSPoint(x: tray.midX + 200, y: tray.midY))
        check("a tile dragged and let go back over the tray places nothing and puts it back", count == dragged + 1 && self.tray.armed == nil)
        // A double-click places at once, nearest the view's middle.
        await pressTray("tray.item.stone.stone", count: 2)
        check("a double-click on a tile places it at once near the middle of the view, chosen", count == dragged + 2 && library.session.drawnIDs.last.flatMap { library.session.item($0) }?.asset == "stone.stone")
        // With Reduce Motion a placed thing is simply there.
        Look.Motion.debugReducesMotion = true
        await pressTray("tray.item.stone.mossy", count: 2)
        check("with Reduce Motion a placed thing does not settle: it is there", !editor.debugSettling && meadow.scenery == library.scenery && count == dragged + 3)
        Look.Motion.debugReducesMotion = false
        for _ in 0..<3 { suite.shortcut("cmd+z"); await PerfWait.sleep(60) }
        check("⌘Z three times takes the three away", count == dragged)
        suite.shortcut("esc")
    }

    // MARK: The Brush

    func brushing() async {
        await enter()
        editor.debugChoose([])
        suite.shortcut("b")
        await pressTray("tray.item.flower.daisy")
        check("the Brush's shelf: the wildflower mix, then the plants it paints; a click chooses what it paints",
              tray.tool == .brush && tray.brushKind == "flower.daisy" && tray.shelf.first?.id == EditorTray.wildflowers
                  && tray.shelf.dropFirst().allSatisfy { MeadowCatalog.current.asset($0.id).map(MeadowBrush.paints) == true })
        guard let from = grassPoint() else { return check("grass to paint on", false) }
        let to = NSPoint(x: min(from.x + 320, meadow.bounds.maxX - 60), y: from.y + 40)
        let before = count
        let started = perfNow()
        await dragPointer(from: from, to: to, steps: 150) {
            self.check("while the stroke is under way the Brush's circle follows and the plants are drawn as they are laid",
                       self.editor.debugStrokeUnderWay && self.meadow.editMarks.brush?.erasing == false && self.meadow.scenery.things.count > self.library.scenery.things.count)
            await self.picture("brush-stroke")
        }
        let ended = perfNow()
        let added = library.session.drawnIDs.suffix(count - before).compactMap { library.session.item($0) }
        var field = SceneryRules.Field(MeadowScenery(things: library.scenery.things.dropLast(added.count)))
        var apart = true
        for thing in added.compactMap(library.session.thing) {
            if field.refusal(for: thing) != nil { apart = false }
            field.add(thing)
        }
        check("a stroke plants clumps of daisies along it, none overlapping anything, as one step “\(MeadowWords.brush("flower.daisy"))”",
              added.count >= 10 && added.allSatisfy { $0.asset == "flower.daisy" } && apart && undoName == MeadowWords.brush("flower.daisy") && !editor.debugStrokeUnderWay,
              "\(added.count) planted, apart \(apart), step “\(undoName)”")
        let turns = Set(added.map(\.turn)).count, sizes = Set(added.compactMap(\.size)).count
        check("…each its own (turned and sized its own way: never a stamp)", Double(turns) > Double(added.count) * 0.95 && Double(sizes) > Double(added.count) * 0.95,
              "\(turns) turns and \(sizes) sizes among \(added.count)")
        frameRate("brushing", from: started, to: ended)
        suite.shortcut("cmd+z")
        check("⌘Z takes the whole stroke back", count == before)
        suite.shortcut("cmd+shift+z")
        check("⇧⌘Z plants it again, the same plants", count == before + added.count && library.session.drawnIDs.suffix(added.count).compactMap { library.session.item($0) } == added)
        // ⌥-drag clears what the Brush paints.
        await dragPointer(from: from, to: to, steps: 40, flags: .option)
        let cleared = before + added.count - count
        check("⌥-drag with the Brush clears the daisies under it, as one step", cleared > added.count / 2 && undoName == MeadowWords.erase(Array(repeating: "flower.daisy", count: cleared)),
              "\(cleared) cleared of \(added.count), step “\(undoName)”")
        suite.shortcut("cmd+z")
        // Size and density.
        let radius = tray.brushRadius
        suite.shortcut("]")
        suite.shortcut("]")
        let larger = tray.brushRadius
        suite.shortcut("[")
        await pressTray("tray.density.dense")
        check("] and [ size the Brush a unit at a time; Dense is chosen by its button", larger == radius + 2 && tray.brushRadius == radius + 1 && tray.density == .dense,
              "\(radius) → \(larger) → \(tray.brushRadius)")
        await pressTray("tray.density.natural")
        // The wildflower mix, by keys alone: Return dabs at the keyboard's cursor.
        await pressTray("tray.item.\(EditorTray.wildflowers)")
        let mix = count
        suite.shortcut("up")
        suite.shortcut("return")
        let dab = library.session.drawnIDs.suffix(count - mix).compactMap { library.session.item($0)?.asset }
        check("Return with the Brush plants one clump of the wildflowers at the cursor, a step of its own",
              !dab.isEmpty && Set(dab).isSubset(of: Set(MeadowBrush.wildflowers.map(\.asset))) && undoName == MeadowWords.brush(EditorTray.wildflowers), "\(dab)")
        suite.shortcut("esc")
        check("Esc puts the Brush down: back to Select", tray.tool == .select)
    }

    // MARK: The Eraser

    func erasing() async {
        await enter()
        editor.debugChoose([])
        suite.shortcut("e")
        await pressTray("tray.item.\(EditorTray.anyKind)")
        guard let stone = ["stone.stone", "stone.mossy", "fungus.flyAgaric", "flower.poppy"].lazy.compactMap({ self.visible(kind: $0) }).first,
              let kind = library.session.item(stone)?.asset else { return check("a small thing in view", false) }
        let before = count
        await hoverMeadow(grabPoint(stone)!)
        await picture("erase-hover")
        await clickThing(stone)
        check("a click with the Eraser takes the thing under it away: one step", count == before - 1 && library.session.item(stone) == nil && undoName == MeadowWords.erase([kind]))
        suite.shortcut("cmd+z")
        guard let tree = visible(kind: "tree.young") ?? visible(kind: "tree.oak") else { return check("a tree in view", false) }
        await clickThing(tree)
        check("…a tree too, by a click", library.session.item(tree) == nil)
        suite.shortcut("cmd+z")
        // A sweep over a stretch with trees, flowers and stones: the small things go, the trees stay.
        guard let a = meadow.viewPoint(ofGround: library.session.item(tree).map { SIMD2(Float($0.at.x) - 6, Float($0.at.z)) } ?? .zero) else { return check("ground by the tree", false) }
        let b = NSPoint(x: a.x + 140, y: a.y)
        let trees = library.session.drawnIDs.filter { SceneryRules.isBig(library.session.item($0)!.asset) }.count
        let small = count
        await dragPointer(from: a, to: b, steps: 40) {
            self.check("while sweeping the Eraser's circle shows, dashed", self.meadow.editMarks.brush?.erasing == true && self.editor.debugStrokeUnderWay)
            await self.picture("erase-sweep")
        }
        let afterTrees = library.session.drawnIDs.filter { SceneryRules.isBig(library.session.item($0)!.asset) }.count
        check("a sweep takes the plants and stones it passes, never a tree or the log, as one step",
              count < small - 1 && afterTrees == trees && library.session.item(tree) != nil && undoName == MeadowWords.erase(Array(repeating: "stone.stone", count: small - count)),
              "\(small - count) taken, trees \(trees) → \(afterTrees), step “\(undoName)”")
        suite.shortcut("cmd+z")
        check("⌘Z brings them all back", count == small)
        // Only one kind: daisies.
        suite.shortcut("2")
        check("the categories' keys choose Select's shelf from the Eraser", tray.tool == .select)
        suite.shortcut("e")
        await pressTray("tray.item.flower.daisy")
        let daisies = library.session.drawnIDs.filter { library.session.item($0)!.asset == "flower.daisy" }.count
        let others = count - daisies
        if let from = grassPoint() {
            await dragPointer(from: NSPoint(x: meadow.bounds.minX + 120, y: from.y), to: NSPoint(x: meadow.bounds.maxX - 160, y: from.y), steps: 60)
        }
        let daisiesAfter = library.session.drawnIDs.filter { library.session.item($0)!.asset == "flower.daisy" }.count
        check("with a kind chosen, the Eraser sweeps only that kind", daisiesAfter < daisies && count - daisiesAfter == others, "daisies \(daisies) → \(daisiesAfter), others \(others) → \(count - daisiesAfter)")
        suite.shortcut("cmd+z")
        if let stone = visible(kind: "stone.stone") {
            await clickThing(stone)
            check("…and a click on another kind takes nothing and says why", library.session.item(stone) != nil && editor.debugReason == MeadowWords.onlyErasing("flower.daisy"),
                  editor.debugReason ?? "no reason")
        }
        await pressTray("tray.item.\(EditorTray.anyKind)")
        suite.shortcut("v")
    }

    // MARK: The caps

    func limits() async {
        await enter()
        editor.debugChoose([])
        let mine = library.active
        // A meadow of 47 trees (round its edge, out of the way: young trees, apple trees and pines) and 4,998 things in
        // all: the plants of the Flowers shelf, and every twelfth a made thing or wood, as many made things as it may hold.
        var entries = library.session.document.entries
        var trees = library.session.document.counts(.current)[.trees, default: 0]
        var k = 0
        while trees < 47 {
            let a = Double(k) * 0.19
            entries.append(.item(MeadowFile.MeadowItem(asset: ["tree.young", "tree.apple", "tree.pine"][k % 3],
                                                        placement: .at(MeadowPoint(MeadowJSON.quantized(cos(a) * 157), MeadowJSON.quantized(sin(a) * 157))), seed: UInt32(k + 1))))
            trees += 1
            k += 1
        }
        var j = 0, made = library.session.document.counts(.current)[.madeThings, default: 0]
        let plants = ["flower.daisy", "plant.clover", "flower.cornflower", "plant.fern", "flower.foxglove"]
        let things = ["cat.box", "cat.bed", "wood.stump", "cat.bowl", "cat.yarn", "wood.logPile", "cat.scratchingPost", "work.cushion", "stone.boulder"]
        while entries.count < MeadowFormat.maxItems - 2 {
            let x = Double(j % 60) * 1.1 - 80, z = Double(j / 60) * 1.1 - 30
            var asset = plants[j % plants.count]
            if j % 12 == 0 {
                let thing = things[(j / 12) % things.count]
                if MeadowCatalog.current.asset(thing)?.caps.contains(.madeThings) != true || made < MeadowCatalog.Cap.madeThings.limit - 10 {
                    asset = thing
                    if MeadowCatalog.current.asset(thing)?.caps.contains(.madeThings) == true { made += 1 }
                }
            }
            entries.append(.item(MeadowFile.MeadowItem(asset: asset, placement: .at(MeadowPoint(MeadowJSON.quantized(x), MeadowJSON.quantized(z))))))
            j += 1
        }
        // As many garden lamps as a meadow holds, round its edge inside the trees (tall things: 47 trees and 32 lamps).
        entries.removeLast(MeadowCatalog.Cap.lamps.limit)
        entries += Self.fullMeadowLamps()
        let file = "Full Meadow.whiskrmeadow"
        do {
            let data = try MeadowDocument(name: "Full Meadow", entries: entries).fileData(writtenBy: MeadowLibrary.writtenBy)
            try library.folder.write(data, as: file)
            _ = try library.folder.read(file)
        } catch {
            return check("a full meadow written and read back", false, "\(error)")
        }
        library.refreshFiles()
        library.use(file, name: "Use “Full Meadow”")
        check("the full meadow is shown: \(MeadowFormat.maxItems - 2) things, 47 trees", library.active == file && count == MeadowFormat.maxItems - 2,
              "active \(library.active ?? "Default"), \(count) things")
        meadow.scenery = library.scenery
        _ = await PerfWait.until(2000) { self.tray.fullness != nil }
        // Its lamps are at their cap (the fullest, said first); the things not yet.
        let lampsFull = MeadowWords.refusal(.full(.lamps, limit: MeadowCatalog.Cap.lamps.limit))
        check("past 80 % of a cap the tray says how full the meadow is (the lamps, at theirs); only the lamp's tile says it is full",
              tray.fullness == MeadowWords.fullness(MeadowCatalog.Cap.lamps.limit, of: MeadowCatalog.Cap.lamps.limit, .lamps)
                  && tray.full == ["work.lampPost": lampsFull], "\(tray.fullness ?? "nothing said"), \(tray.full)")
        await picture("full-meadow")
        // At the caps (Stage 7's models among its things), the meadow rests as soon as any meadow must; its cost at
        // rest is recorded (the terminal printing all along this flow, its chrome limits are the idle flow's to hold).
        suite.shortcut("cmd+return")
        _ = await PerfWait.until(2000) { !self.controller.meadowEditing }
        let left = perfNow()
        let rested = await PerfWait.until(12000) { self.meadow.isResting }
        check("a full meadow rests within 12 s of leaving editing", rested != nil, rested.map { String(format: "%.1f s", ($0 - left) / 1000) } ?? "not in 12 s")
        await suite.idleStretch("editor: idle, a full meadow", limits: false)
        await fullMeadowAtNight()
        await enter()
        editor.debugChoose([])
        // One more tree: the 48th; then the trees' tiles say the meadow holds as many as it can.
        suite.shortcut("1")
        guard let spot = freeSpotInView(big: true) else { return check("free ground for the 48th tree", false) }
        await pressTray("tray.item.tree.birch")
        click(at: meadow.viewPoint(ofGround: spot)!)
        await PerfWait.sleep(300)
        let treeFull = MeadowWords.refusal(.full(.trees, limit: 48))
        check("the 48th tree is placed; then every tree's tile says, kindly, that the meadow holds as many trees as it can",
              library.session.document.counts(.current)[.trees] == 48
                  && Set(tray.full.keys) == Set(EditorTray.things.filter { $0.category == .trees }.map(\.id)).union(["work.lampPost"])
                  && tray.full.filter { $0.key != "work.lampPost" }.values.allSatisfy { $0 == treeFull }, "trees \(library.session.document.counts(.current)[.trees] ?? 0), tiles \(tray.full)")
        await picture("tray-full")
        await pressTray("tray.item.tree.oak")
        check("a full kind's tile arms nothing and says why", tray.armed == nil && editor.debugReason != nil, editor.debugReason ?? "nothing said")
        suite.shortcut("cmd+z")
        _ = await PerfWait.until(1000) { self.tray.full.isEmpty }
        // The Brush stops at 5,000 and says so.
        suite.shortcut("b")
        if let from = grassPoint() {
            let before = count
            await dragPointer(from: from, to: NSPoint(x: from.x + 160, y: from.y), steps: 30)
            check("the Brush stops at 5,000 things and says why", count == MeadowFormat.maxItems && count - before == 2 && editor.debugReason == MeadowWords.refusal(.full(nil, limit: 5_000)),
                  "\(count) things, reason \(editor.debugReason ?? "none")")
            suite.shortcut("cmd+z")
        }
        // Sweeping a full meadow keeps the full frame rate.
        suite.shortcut("e")
        if let a = meadow.viewPoint(ofGround: SIMD2(-70, 0)), let b = meadow.viewPoint(ofGround: SIMD2(-30, 10)), meadow.bounds.contains(a), meadow.bounds.contains(b) {
            let started = perfNow()
            await dragPointer(from: a, to: b, steps: 150)
            frameRate("sweeping a full meadow", from: started, to: perfNow(), rate: false)
            suite.shortcut("cmd+z")
        } else {
            print("editor: the full meadow's daisies are out of view; sweeping it not measured")
        }
        suite.shortcut("v")
        if let mine { library.use(mine, name: "Use “My Meadow”") }
        meadow.scenery = library.scenery
        check("back to My Meadow", library.active == mine)
    }

    /// The meadow's own count of frames drawn each second over a stroke (its first second, the press, apart).
    /// `rate`: judged by its frame rate; otherwise by what the editing costs the main thread per frame (a meadow
    /// of 5,000 flowers is bound by the GPU's drawing of it, which is the full-meadow stage's to hold).
    func frameRate(_ what: String, from started: Double, to ended: Double, rate: Bool = true) {
        let timings = suite.log.meadow(from: started + 1100, to: ended - 200)
        let quiet = MachineLoad.shared.others(from: started, to: ended).map { $0 <= MachineLoad.busyCores } ?? true
        let fps = timings.map(\.framesPerSecond).min() ?? 0, dropped = timings.map(\.droppedFrames).reduce(0, +)
        let target = timings.map(\.targetFramesPerSecond).max() ?? 0
        let cpu = timings.map(\.cpuMilliseconds).max() ?? 0, gpu = timings.map(\.gpuMilliseconds).max() ?? 0
        print(String(format: "editor: %@: %.0f frames a second at the least (asked %d), %d dropped, %d seconds measured; main thread %.1f ms, GPU %.1f ms a frame at the most",
                     what, fps, target, dropped, timings.count, cpu, gpu))
        if !rate {
            check("while \(what) the editing costs the main thread little (under 4 ms a frame)", !timings.isEmpty && cpu < 4, String(format: "%.1f ms", cpu))
        } else if quiet {
            check("while \(what) the meadow draws at the full rate", !timings.isEmpty && target >= 60 && fps >= Double(target) * 0.85, String(format: "%.0f of %d", fps, target))
        } else {
            print("editor: frame pacing while \(what) not judged: the Mac was busy")
        }
    }

    // MARK: Pictures of the tools

    /// Each state of the tools in the theme shown: a thing armed where it may stand and where it may not, a
    /// stroke of the Brush, the Eraser's circle (`wide`), or the tray and a ghost (narrow).
    func toolPictures(_ name: String, wide: Bool) async {
        editor.debugChoose([])
        suite.shortcut("1")
        await pressTray("tray.item.tree.cherry")
        if let spot = freeSpotInView(big: true), let point = meadow.viewPoint(ofGround: spot) {
            await hoverMeadow(point)
            await picture("\(name)-ghost")
        }
        if wide, let picnic = meadow.viewPoint(ofGround: SIMD2(0, 8)) {
            await hoverMeadow(picnic)
            await picture("\(name)-ghost-refused")
        }
        suite.shortcut("esc")
        suite.shortcut("b")
        if let from = grassPoint() {
            await dragPointer(from: from, to: NSPoint(x: from.x + 200, y: from.y + 30), steps: 30) { await self.picture("\(name)-brush") }
            suite.shortcut("cmd+z")
        }
        if wide {
            suite.shortcut("e")
            if let from = grassPoint() {
                await hoverMeadow(from)
                await picture("\(name)-erase")
            }
        }
        // The Ground tool: a stroke of path across the picnic ground and on, the circle on the ground.
        suite.shortcut("g")
        await pressTray("tray.item.ground.path")
        if let from = meadow.viewPoint(ofGround: SIMD2(-26, 6)), let to = meadow.viewPoint(ofGround: SIMD2(18, 2)), meadow.bounds.contains(from), meadow.bounds.contains(to) {
            await dragPointer(from: from, to: to, steps: 40) { await self.picture("\(name)-ground") }
            // A lawn beside it, painted wide, and the two together.
            await pressTray("tray.item.ground.lawn")
            for _ in 0..<3 { suite.shortcut("]") }
            var lawn = 0
            for z in [Float(-14), -19] {
                if let a = meadow.viewPoint(ofGround: SIMD2(24, z)), let b = meadow.viewPoint(ofGround: SIMD2(34, z)), meadow.bounds.contains(a), meadow.bounds.contains(b),
                   !trayCard.contains(a), !trayCard.contains(b) {
                    await dragPointer(from: a, to: b, steps: 20)
                    lawn += 1
                }
            }
            await hoverMeadow(to)
            await picture("\(name)-ground-painted")
            for _ in 0..<(lawn + 1) { suite.shortcut("cmd+z") }
            for _ in 0..<3 { suite.shortcut("[") }
            await pressTray("tray.item.ground.path")
        }
        // Stepping stones laid along a drag.
        suite.shortcut("v")
        suite.shortcut("3")
        await pressTray("tray.item.stone.stepping")
        if let from = meadow.viewPoint(ofGround: SIMD2(-30, -10)), let to = meadow.viewPoint(ofGround: SIMD2(-18, -16)), meadow.bounds.contains(from), meadow.bounds.contains(to),
           !trayCard.contains(from), !trayCard.contains(to) {
            await dragPointer(from: from, to: to, steps: 30)
            await picture("\(name)-stones")
            suite.shortcut("cmd+z")
        }
        suite.shortcut("esc")
        suite.shortcut("v")
    }
}
#endif
