#if DEBUG
import AppKit
import MeadowFile
@_spi(Diagnostics) import MeadowScene
import WhiskrKit
import WhiskrMeadow

/// The editor flow's part for the things Stage 8 brought (`DebugFlowEditor.swift`), every press, drag, release and key
/// through the app's own event paths:
/// - one of each garden and workplace thing placed from its shelf by a click where it may stand;
/// - a fence laid by a press and drag (its ghost refused over the picnic ground first), a second joined to its end as
///   one run, a gate hung and the run straightened from the selection's bar, a fence laid with the keys alone;
/// - colours: the bar's Colour popover opened, a swatch chosen (one step, undone), the next one armed wearing it;
/// - pictures: the garden from the editor's height and close, the fence with its gate, the colours' popover.
extension EditorFlow {
    /// Stage 8's things standing at one spot, in the catalog's order.
    static let gardenThings = ["garden.flowerPot", "garden.planter", "garden.wateringCan", "garden.birdhouse", "garden.skep", "work.desk", "work.bookshelf",
                               "work.bench", "work.signpost", "work.mailbox", "work.noticeboard", "place.shed", "place.tent"]

    func garden() async {
        await enter()
        editor.debugChoose([])
        suite.shortcut("0")
        await PerfWait.sleep(1200)
        menu(["View", "Editor View", "Face North"])
        await PerfWait.sleep(1200)
        await still()
        let before = count

        check("the tray offers Stage 8's things on the Garden and Workplace shelves, the fence first",
              EditorTray.things.filter { $0.category == .garden }.map(\.id) == ["garden.fence", "garden.flowerPot", "garden.planter", "garden.wateringCan", "garden.birdhouse", "garden.skep"]
                  && EditorTray.things.filter { $0.category == .workplace }.map(\.id) == ["work.desk", "work.cushion", "work.bookshelf", "work.bench", "work.signpost", "work.mailbox",
                                                                                          "work.noticeboard", "place.shed", "place.tent"])

        // One of each, placed with a click where it may stand, east of the picnic ground.
        guard let middle = meadow.groundPoint(at: NSPoint(x: meadow.bounds.midX, y: meadow.bounds.midY + 60)) else { return check("ground in view", false) }
        var placed: [(id: String, entry: Int)] = []
        for (k, id) in Self.gardenThings.enumerated() {
            let asset = MeadowCatalog.current.asset(id)!
            await pressTray("tray.category.\(asset.category.rawValue)")
            await pressTray("tray.item.\(id)")
            let near = SIMD2<Float>(28 + Float(k % 4) * 7, middle.y - 10 + Float(k / 4) * 7)
            guard tray.armed == id, let spot = freeSpot(for: id, near: near), let point = meadow.viewPoint(ofGround: spot) else {
                check("\(id): armed, with free ground in view to place it", false, "armed \(tray.armed ?? "nothing")")
                continue
            }
            await hoverMeadow(point)
            click(at: point)
            await PerfWait.sleep(250)
            let entry = library.session.drawnIDs.last ?? -1
            let item = library.session.item(entry)
            check("\(MeadowWords.name(id)): placed where clicked as one step", item?.asset == id && undoName == MeadowWords.place([id]) && meadow.scenery == library.scenery,
                  "\(item?.asset ?? "nothing"), step “\(undoName)”")
            if item?.asset == id { placed.append((id, entry)) }
        }
        check("all thirteen placed", placed.count == Self.gardenThings.count, "\(placed.count) placed")
        let spots = placed.compactMap { library.session.item($0.entry).flatMap { library.session.thing($0)?.catSpot } }
        check("the bench, desk, bookshelf, shed, tent and nest box each say where a cat would be", spots.count == 6, "\(spots.count)")
        editor.debugChoose([])
        await PerfWait.sleep(300)
        await picture("garden-placed")

        await colours(placed)
        await fences()

        // Close up, the garden by day.
        if let shed = placed.first(where: { $0.id == "work.bench" })?.entry, let at = library.session.item(shed)?.at,
           let point = meadow.viewPoint(ofGround: SIMD2(Float(at.x), Float(at.z))) {
            meadow.simulateZoom(by: 0.35, at: point)
            await still()
            await picture("garden-close")
            suite.shortcut("0")
            await PerfWait.sleep(1200)
            await still()
        }

        while count > before, library.undoManager.canUndo { suite.shortcut("cmd+z"); await PerfWait.sleep(30) }
        check("⌘Z takes every garden step away again", count == before, "\(count - before) left")
        suite.shortcut("esc")
    }

    // MARK: Colours

    private func colours(_ placed: [(id: String, entry: Int)]) async {
        guard let bench = placed.first(where: { $0.id == "work.bench" })?.entry else { return check("a bench to colour", false) }
        await clickThing(bench)
        await PerfWait.sleep(300)
        check("a bench chosen: its bar offers its palette, wood (its own) worn",
              editor.barModel.swatches.map(\.name) == ["wood", "sage", "cream", "slate"] && editor.barModel.wearing == "wood"
                  && editor.barModel.swatches.map(\.label) == ["wood", "sage", "cream", "slate"].map(MeadowWords.colourName))
        await clickBarButton(index: 10)
        _ = await PerfWait.until(1500) { self.editor.barModel.paletteOpen }
        await PerfWait.sleep(300)
        check("the bar's Colour opens the row of swatches", editor.barModel.paletteOpen)
        await picture("garden-colours-popover")
        // The swatch's button does what a click on it does.
        editor.barModel.act(.colour("sage"))
        await PerfWait.sleep(250)
        let item = library.session.item(bench)
        check("Sage chosen: kept in params, drawn in its swatch, one step",
              item?.params["colour"] == .string("sage") && library.session.thingIndex(of: bench).map { library.scenery.things[$0].swatch } == 1
                  && undoName == MeadowWords.colour(["work.bench"], "sage") && editor.barModel.wearing == "sage", "step “\(undoName)”")
        editor.barModel.paletteOpen = false
        suite.shortcut("cmd+z")
        await PerfWait.sleep(200)
        check("undone: the bench in its own wood again", library.session.item(bench)?.params["colour"] == nil)
        suite.shortcut("cmd+shift+z")
        await PerfWait.sleep(200)
        // The next bench armed wears the colour last chosen.
        editor.debugChoose([])
        await pressTray("tray.category.workplace")
        await pressTray("tray.item.work.bench")
        await PerfWait.sleep(200)
        check("the next bench armed wears sage, as its ghost shows", editor.debugPending.item?.params["colour"] == .string("sage")
              && meadow.editMarks.ghost?.swatch == 1)
        suite.shortcut("esc")
        await PerfWait.sleep(150)
    }

    // MARK: Fences

    /// Free ground in view for a fence `length` long, west of the picnic ground first (the garden stands east of it).
    private func fenceLine(z: Float, length: Float) -> (SIMD2<Float>, SIMD2<Float>)? {
        let field = SceneryRules.Field(library.scenery)
        for x in Array(stride(from: Float(-38), through: -34, by: 2)) + Array(stride(from: Float(24), through: 70, by: 3)) {
            for dz in stride(from: Float(0), through: 30, by: 3) {
                let a = SIMD2(x, z + dz), b = SIMD2(x + length, z + dz)
                // The run, the leg joined to its end and the straight line across them all clear.
                let probe = MeadowScenery.Thing(id: MeadowEditSession.fence, points: [a, b, b + SIMD2(0, -5), a])
                guard field.refusal(for: probe) == nil, let pa = meadow.viewPoint(ofGround: a), let pb = meadow.viewPoint(ofGround: b),
                      meadow.bounds.insetBy(dx: 60, dy: 60).contains(pa), meadow.bounds.insetBy(dx: 60, dy: 60).contains(pb), !trayCard.insetBy(dx: -30, dy: -30).contains(pb)
                else { continue }
                return (a, b)
            }
        }
        return nil
    }

    private func fences() async {
        await pressTray("tray.category.garden")
        await pressTray("tray.item.garden.fence")
        check("the fence armed, its hint saying how it is laid", tray.armed == MeadowEditSession.fence && tray.hint == MeadowWords.fenceHint)
        // Over the picnic ground: its ghost refused, with why, and let go there nothing is laid.
        let steps = count
        if let from = meadow.viewPoint(ofGround: SIMD2(-8, 20)), let to = meadow.viewPoint(ofGround: SIMD2(4, 20)) {
            await dragPointer(from: from, to: to, steps: 20) {
                self.check("dragged over the picnic ground: the run's ghost refused, the reason by it",
                           self.editor.debugPending.refusal == .keptForWorkspaces && self.meadow.editMarks.ghostRefused && self.editor.debugReason == MeadowWords.refusal(.keptForWorkspaces),
                           "\(String(describing: self.editor.debugPending.refusal))")
            }
            check("let go there, nothing laid; the fence still armed", count == steps && tray.armed == MeadowEditSession.fence)
        }
        // Laid along a drag: a post each 2.5 units, one run, one step.
        guard let (a, b) = fenceLine(z: -4, length: 12), let from = meadow.viewPoint(ofGround: a), let to = meadow.viewPoint(ofGround: b) else {
            return check("free ground in view for a fence", false)
        }
        await dragPointer(from: from, to: to, steps: 30, flags: .shift) {
            self.check("dragged: the run's ghost drawn along the way, the rings round its lengths", self.meadow.editMarks.ghost?.isRun == true && !self.meadow.editMarks.ghostRefused)
            await self.picture("garden-fence-ghost")
        }
        guard let first = library.session.drawnIDs.last, let run = library.session.fenceRun(first) else { return check("a fence laid by the drag", false) }
        check("a fence laid along the drag: one thing, its points a post apart, one step (⇧ keeps it armed)",
              count == steps + 1 && run.points.count >= 5 && undoName == MeadowWords.layFence && tray.armed == MeadowEditSession.fence, "\(run.points.count) points, “\(undoName)”")
        // A second, begun at the first's end, going north (away from the garden): joined into one run with a corner post.
        let end = SIMD2(Float(run.points.last!.x), Float(run.points.last!.z))
        if let start = meadow.viewPoint(ofGround: end + SIMD2(0.3, 0.3)), let north = meadow.viewPoint(ofGround: end + SIMD2(0.3, -4.5)) {
            await dragPointer(from: start, to: north, steps: 24)
            let runs = library.session.drawnIDs.filter { library.session.fenceRun($0) != nil }
            let joined = runs.last.flatMap { library.session.fenceRun($0) }
            check("a run begun at a fence's end joins it: one run round the corner, one step", runs.count == 1 && (joined?.points.count ?? 0) > run.points.count
                  && undoName == MeadowWords.joinFence && tray.armed == nil, "\(runs.count) runs, “\(undoName)”")
        }
        guard let fence = library.session.drawnIDs.last(where: { library.session.fenceRun($0) != nil }) else { return }
        // Chosen: its bar is the fence's. A gate hung, then the run straightened.
        editor.debugChoose([fence])
        await PerfWait.sleep(300)
        check("a fence chosen: Straighten and Add Gate on its bar", editor.barModel.fence && editor.barModel.bends && editor.barModel.gateFits && !editor.barModel.hasGate)
        await picture("garden-fence-chosen")
        await clickBarButton(index: 9)
        let gate = library.session.fenceRun(fence)?.gate ?? 0
        check("Add Gate hangs a gate in it, one step", gate > 0 && undoName == MeadowWords.addGate && library.scenery.things[library.session.thingIndex(of: fence)!].gate == gate)
        // Picked by a span's rail as well as its posts.
        if let run = library.session.fenceRun(fence), let index = library.session.thingIndex(of: fence) {
            // Over the middle of each span between its points, a little above the ground (where its rails are).
            var found: [Int?] = []
            for (a, b) in zip(run.points, run.points.dropFirst()) {
                guard let rail = meadow.viewPoint(ofGround: SIMD2(Float(a.x + b.x) / 2, Float(a.z + b.z) / 2)) else { continue }
                found.append(meadow.sceneryThing(at: NSPoint(x: rail.x, y: rail.y + 5)))
            }
            check("a click on a span's rails picks the whole run", found.filter { $0 == index }.count * 2 > found.count, "\(found)")
        }
        editor.debugChoose([])
        await PerfWait.sleep(200)
        await picture("garden-fence-gate")
        editor.debugChoose([fence])
        await PerfWait.sleep(200)
        await clickBarButton(index: 8)
        check("Straighten makes it one straight length, its gate kept, one step", !library.session.canStraighten(fence) && (library.session.fenceRun(fence)?.gate ?? 0) > 0
              && undoName == MeadowWords.straighten, "“\(undoName)”, \(editor.debugReason ?? "no reason shown")")
        suite.shortcut("cmd+z")
        await PerfWait.sleep(200)
        check("undone: round its corner again", library.session.canStraighten(fence))
        editor.debugChoose([])

        // With the keys alone: armed from the shelf, Return begins it at the cursor, the arrows and Return set a
        // corner, Return again where the cursor is lays it.
        let laidBefore = count
        if tray.armed != MeadowEditSession.fence { await pressTray("tray.item.garden.fence") }
        guard let (k0, _) = fenceLine(z: 14, length: 8) else { return check("free ground for a fence by the keys", false) }
        editor.cursor = k0
        giveMeadowTheKeyboard()
        suite.typeKeys("\r")
        await PerfWait.sleep(150)
        let axes = meadow.groundAxes
        for _ in 0..<4 { suite.shortcut("shift+right"); await PerfWait.sleep(40) }
        suite.typeKeys("\r")
        await PerfWait.sleep(150)
        suite.typeKeys("\r")
        await PerfWait.sleep(250)
        let keyed = library.session.drawnIDs.last.flatMap { library.session.fenceRun($0) }
        let wanted: SIMD2<Float> = k0 + axes.right * 8
        let reached = keyed?.points.last.map { hypot(Float($0.x) - wanted.x, Float($0.z) - wanted.y) } ?? .infinity
        check("a fence laid with the keys alone", count == laidBefore + 1 && (keyed?.points.count ?? 0) >= 2 && reached < 1.5, "\(String(describing: keyed?.points))")
        suite.shortcut("esc")
    }

    /// The keyboard to the meadow.
    private func giveMeadowTheKeyboard() { window.makeFirstResponder(meadow) }
}
#endif
