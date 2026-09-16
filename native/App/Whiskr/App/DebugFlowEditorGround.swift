#if DEBUG
import AppKit
import MeadowFile
@_spi(Diagnostics) import MeadowScene
import WhiskrKit
import WhiskrMeadow

/// The editor flow's part for the Ground tool and stepping stones (`DebugFlowEditor.swift`), every press, drag,
/// release and key through `NSApplication.sendEvent`:
/// - the Ground tool: G, the Ground tab (4) and View › Editor Tools; its shelf of paints, each pictured as turf;
///   a stroke of path across the picnic ground and on (one step, at the full frame rate, drawn as it is painted),
///   ⌥-drag bringing the wild grass back, the size by `[` `]`, Return painting at the cursor, lawn and soil, the
///   painted ground saved in the meadow's file and drawn as it holds it;
/// - stepping stones: a drag lays a row a stride apart, each set its own way, none overlapping anything, as one
///   step, the row chosen; a click places one; undone and done again.
extension EditorFlow {
    /// The cells of the paint grid a ground point lies in, painted as the meadow's file holds it (0 for none).
    func cell(_ spot: SIMD2<Float>) -> UInt8 {
        guard let ground = library.session.document.ground, let cell = GroundGrid.cell(at: MeadowPoint(Double(spot.x), Double(spot.y))) else { return 0 }
        return ground[cell.column, cell.row]
    }

    /// The paint drawn at a ground point (as the scene is given it).
    func drawn(_ spot: SIMD2<Float>) -> MeadowScenery.Ground.Paint {
        guard let ground = meadow.scenery.ground, let cell = MeadowScenery.Ground.cell(at: spot.x, spot.y) else { return .wild }
        return ground[cell.column, cell.row]
    }

    // MARK: The Ground tool

    func painting() async {
        await enter()
        editor.debugChoose([])
        // The picnic ground framed (0), then facing north (View › Editor View › Face North).
        suite.shortcut("0")
        await PerfWait.sleep(1200)
        menu(["View", "Editor View", "Face North"])
        await PerfWait.sleep(1200)
        await still()
        suite.shortcut("g")
        await PerfWait.sleep(150)
        check("G chooses the Ground tool: its shelf is Path, Lawn, Soil and Wild Grass, each pictured as turf, the Ground tab chosen",
              tray.tool == .ground && tray.shelf.map(\.id) == ["ground.path", "ground.lawn", "ground.soil", "ground.wild"]
                  && tray.shelf.allSatisfy { tray.pictures[$0.id] != nil } && tray.hint == MeadowWords.hint(.ground, armed: false),
              "\(tray.tool), \(tray.shelf.map(\.id))")
        await picture("ground-tray")
        suite.shortcut("v")
        suite.shortcut("4")
        let byNumber = tray.tool == .ground
        suite.shortcut("v")
        await pressTray("tray.category.ground")
        let byTab = tray.tool == .ground
        suite.shortcut("v")
        menu(["View", "Editor Tools", "Ground"])
        check("4, the Ground tab and View › Editor Tools › Ground choose it too", byNumber && byTab && tray.tool == .ground)
        await pressTray("tray.item.ground.path")
        check("a click on a tile chooses what it paints", tray.groundPaint == "ground.path")

        // A stroke of path across the picnic ground and on into the meadow.
        let a = SIMD2<Float>(-30, 9), b = SIMD2<Float>(30, 9)
        guard let from = meadow.viewPoint(ofGround: a), let to = meadow.viewPoint(ofGround: b), meadow.bounds.contains(from), meadow.bounds.contains(to),
              !trayCard.contains(from), !trayCard.contains(to) else { return check("the picnic ground's sides in view to paint across", false) }
        let before = library.session.document.ground
        let started = perfNow()
        await dragPointer(from: from, to: to, steps: 150) {
            self.check("while painting the circle follows the pointer and the meadow is drawn painted as it goes, before it is a step",
                       self.editor.debugStrokeUnderWay && self.meadow.editMarks.brush?.erasing == false && self.drawn(SIMD2(0, 9)) == .path
                           && self.cell(SIMD2(0, 9)) == 0)
            await self.picture("ground-stroke")
        }
        let ended = perfNow()
        let along = stride(from: Float(-28), through: 28, by: 2).map { SIMD2($0, 9) }
        check("the stroke is one step “\(MeadowWords.paint("ground.path"))”: a path all along it, the picnic ground too (blankets draw over it)",
              undoName == MeadowWords.paint("ground.path") && along.allSatisfy { cell($0) == 1 } && cell(SIMD2(0, 20)) == 0
                  && library.session.document.ground?.paints == (before?.paints.contains("ground.path") == true ? before!.paints : (before?.paints ?? []) + ["ground.path"])
                  && !editor.debugStrokeUnderWay && meadow.scenery == library.scenery,
              "step “\(undoName)”, painted \(along.filter { cell($0) == 1 }.count) of \(along.count)")
        frameRate("painting the ground", from: started, to: ended)
        let painted = library.session.document.ground
        suite.shortcut("cmd+z")
        check("⌘Z takes the whole stroke back", library.session.document.ground == before && meadow.scenery == library.scenery)
        suite.shortcut("cmd+shift+z")
        check("⇧⌘Z paints it again, the same cells", library.session.document.ground == painted)
        await picture("ground-path")

        // ⌥-drag brings the wild grass back over the first half.
        let half = meadow.viewPoint(ofGround: SIMD2(-2, 9))!
        await dragPointer(from: from, to: half, steps: 40, flags: .option)
        check("⌥-drag brings the wild grass back where it passes, as one step “\(MeadowWords.paint(MeadowWords.wildGround))”",
              undoName == MeadowWords.paint(MeadowWords.wildGround) && cell(SIMD2(-20, 9)) == 0 && cell(SIMD2(20, 9)) == 1, "step “\(undoName)”")
        suite.shortcut("cmd+z")

        // Size.
        let radius = tray.groundRadius
        suite.shortcut("]")
        suite.shortcut("]")
        let larger = tray.groundRadius
        suite.shortcut("[")
        check("] and [ size the Ground tool's circle a unit at a time", larger == radius + 2 && tray.groundRadius == radius + 1, "\(radius) → \(larger) → \(tray.groundRadius)")
        suite.shortcut("[")

        // Lawn by the keys alone: Return paints at the keyboard's cursor.
        await pressTray("tray.item.ground.lawn")
        suite.shortcut("up")
        suite.shortcut("up")
        suite.shortcut("return")
        check("Return paints lawn at the keyboard's cursor, a step of its own", undoName == MeadowWords.paint("ground.lawn")
              && library.session.document.ground?.paints.contains("ground.lawn") == true, "step “\(undoName)”")
        // A bed of soil, beside the picnic ground.
        await pressTray("tray.item.ground.soil")
        if let s = meadow.viewPoint(ofGround: SIMD2(-34, -14)), let e = meadow.viewPoint(ofGround: SIMD2(-26, -14)), meadow.bounds.contains(s) {
            await dragPointer(from: s, to: e, steps: 30)
            check("a stroke of soil makes a bed", undoName == MeadowWords.paint("ground.soil") && cell(SIMD2(-30, -14)) == 3, "step “\(undoName)”")
        }
        await picture("ground-painted")

        // Saved in the meadow's file, as it is drawn.
        library.save()
        library.waitForSaves()
        let saved = library.active.flatMap { try? library.folder.read($0) }?.document
        check("the painted ground is saved in the meadow's file and read back as it is drawn",
              saved?.ground == library.session.document.ground && saved.map { MeadowScenery($0).ground } == meadow.scenery.ground)
        suite.shortcut("esc")
        check("Esc puts the Ground tool down: back to Select", tray.tool == .select)
    }

    // MARK: Stepping stones

    func steppingStones() async {
        await enter()
        editor.debugChoose([])
        // The picnic ground framed (0), then facing north (View › Editor View › Face North).
        suite.shortcut("0")
        await PerfWait.sleep(1200)
        menu(["View", "Editor View", "Face North"])
        await PerfWait.sleep(1200)
        await still()
        suite.shortcut("3")
        await pressTray("tray.item.stone.stepping")
        check("stepping stones are on the Stones & Wood shelf and arm like any thing", tray.armed == "stone.stepping")
        let right = meadow.groundAxes.right
        guard let start = (0..<6).lazy.compactMap({ k -> SIMD2<Float>? in
            let spot = SIMD2<Float>(-40 + Float(k) * 4, -18 + Float(k) * 3)
            guard let a = self.meadow.viewPoint(ofGround: spot), let b = self.meadow.viewPoint(ofGround: spot + right * 12),
                  self.meadow.bounds.insetBy(dx: 40, dy: 40).contains(a), self.meadow.bounds.insetBy(dx: 40, dy: 40).contains(b),
                  !self.trayCard.contains(a), !self.trayCard.contains(b) else { return nil }
            return spot
        }).first, let from = meadow.viewPoint(ofGround: start), let to = meadow.viewPoint(ofGround: start + right * 12) else {
            return check("ground in view for a row of stepping stones", false)
        }
        let before = count
        await dragPointer(from: from, to: to, steps: 60) { await self.picture("stones-laying") }
        let laid = library.session.drawnIDs.suffix(count - before).compactMap { library.session.item($0) }
        let gaps = zip(laid, laid.dropFirst()).map { hypot($0.at.x - $1.at.x, $0.at.z - $1.at.z) }
        var field = SceneryRules.Field(MeadowScenery(things: library.scenery.things.dropLast(laid.count)))
        var apart = true
        for thing in laid.compactMap(library.session.thing) {
            if field.refusal(for: thing) != nil { apart = false }
            field.add(thing)
        }
        check("a drag lays a row of stepping stones about a stride (\(MeadowEditSession.steppingStride)) apart, none overlapping anything, as one step, chosen",
              laid.count >= 6 && laid.allSatisfy { $0.asset == "stone.stepping" } && apart && (gaps.min() ?? 0) > 0.95
                  && gaps.sorted()[gaps.count / 2] > 1.0 && gaps.sorted()[gaps.count / 2] < 1.25
                  && undoName == MeadowWords.lay(laid.count) && editor.debugSelection == library.session.drawnIDs.suffix(laid.count) && tray.armed == nil,
              "\(laid.count) laid, gaps \(gaps.map { String(format: "%.2f", $0) }), step “\(undoName)”")
        check("…each set its own way: no two turned or sized alike", Set(laid.map(\.turn)).count == laid.count && Set(laid.compactMap(\.size)).count == laid.count)
        await picture("stones-row")
        suite.shortcut("cmd+z")
        check("⌘Z takes the whole row up", count == before)
        suite.shortcut("cmd+shift+z")
        check("⇧⌘Z lays it again, the same stones", library.session.drawnIDs.suffix(laid.count).compactMap { library.session.item($0) } == laid)
        // A click places one.
        editor.debugChoose([])
        await pressTray("tray.item.stone.stepping")
        if let spot = freeSpotInView(big: false), let point = meadow.viewPoint(ofGround: spot) {
            await hoverMeadow(point)
            click(at: point)
            await PerfWait.sleep(200)
            check("a click places one stepping stone", count == before + laid.count + 1 && undoName == MeadowWords.place(["stone.stepping"]), "step “\(undoName)”")
            suite.shortcut("cmd+z")
        }
        suite.shortcut("esc")
        suite.shortcut("esc")
    }
}
#endif
