import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// Editing the meadow: where a thing may stand (`SceneryRules`), a moved thing redrawn without laying the
// scenery afresh, trees and logs making way for blankets, the column's lane fixed, pointing at things, and
// the view lifting for editing and coming back exactly where it was.

private func thing(_ id: String, _ x: Float, _ z: Float, seed: UInt32 = 0, variant: Int = 0, size: Float = 1) -> MeadowScenery.Thing {
    MeadowScenery.Thing(id: id, x: x, z: z, size: Vec3(size, size, size), seed: seed, variant: variant)
}

@Suite struct WhereThingsMayStand {
    @Test("a footprint for each kind: round a tree's roots, a plant's base, along a log; none for what is not drawn")
    func footprints() {
        #expect(SceneryRules.footprint(of: thing("tree.oak", 10, 5)) == [SceneryRules.Circle(x: 10, z: 5, r: Species.oak.girth * 2.4)])
        #expect(SceneryRules.footprint(of: thing("tree.oak", 10, 5, size: 1.2)).first!.r == Species.oak.girth * 2.4 * 1.2)
        #expect(SceneryRules.footprint(of: thing("flower.daisy", 0, 0)).first!.r == 0.3)
        #expect(SceneryRules.footprint(of: thing("stone.mossy", 0, 0, size: 2)).first!.r == 2.5)
        let log = SceneryRules.footprint(of: MeadowScenery.Thing(id: "wood.fallenLog", x: 0, z: 0, turn: .pi / 2))
        // Turned a quarter, it lies along z.
        #expect(log.count == 5 && log.allSatisfy { abs($0.x) < 1e-4 } && abs(log.last!.z + 6) < 1e-4)
        #expect(SceneryRules.footprint(of: thing("cat.box", 0, 0)).isEmpty)
    }

    @Test("inside the meadow, measured to the trunk's middle")
    func reach() {
        let field = SceneryRules.Field(MeadowScenery())
        #expect(field.refusal(for: thing("flower.poppy", 159, 0)) == nil)
        #expect(field.refusal(for: thing("flower.poppy", 120, 120)) == .outsideMeadow)
    }

    @Test("big things are kept off the picnic ground; plants, stones and mushrooms may grow there")
    func picnicGround() {
        let field = SceneryRules.Field(MeadowScenery())
        #expect(field.refusal(for: thing("tree.birch", 0, 40)) == .keptForWorkspaces)
        #expect(field.refusal(for: thing("tree.young", 21, 60)) == .keptForWorkspaces, "its roots reach over the edge")
        #expect(field.refusal(for: thing("wood.fallenLog", 0, -4)) == .keptForWorkspaces, "its side reaches in")
        #expect(field.refusal(for: thing("wood.fallenLog", 0, -8)) == nil)
        #expect(field.refusal(for: thing("tree.birch", 30, 40)) == nil)
        for id in ["flower.daisy", "stone.stone", "fungus.flyAgaric"] { #expect(field.refusal(for: thing(id, 0, 40)) == nil, "\(id)") }
        // The column's lane runs down its middle.
        #expect(Village.columnLane == 0 && SceneryRules.picnicGround.minX == -20 && SceneryRules.picnicGround.maxX == 20)
    }

    @Test("nothing overlaps anything, with grass between; the nearest in the way is named; what moves is not judged against itself")
    func apart() {
        let scenery = MeadowScenery(things: [thing("tree.oak", 50, 0), thing("flower.daisy", 40, 0), thing("flower.daisy", 40.5, 0)])
        let field = SceneryRules.Field(scenery)
        #expect(field.refusal(for: thing("flower.poppy", 40.2, 0.1)) == .tooClose(1))
        #expect(field.refusal(for: thing("flower.poppy", 41, 0)) == .tooClose(2))
        #expect(field.refusal(for: thing("flower.poppy", 42, 3)) == nil)
        #expect(field.refusal(for: thing("tree.birch", 46, 0)) == .tooClose(0))
        #expect(field.refusal(for: thing("tree.birch", 58, 0)) == nil)
        // Moving the oak itself: it is left out of the field, so it may stand where it was.
        #expect(SceneryRules.Field(scenery, leavingOut: [0]).refusal(for: thing("tree.oak", 50.5, 0)) == nil)
    }

    @Test("every thing of the Default stands inside the meadow, and none of its big things is on the picnic ground")
    func defaultIsFine() {
        for t in MeadowScenery.standard.things {
            #expect(hypot(t.x, t.z) <= SceneryRules.reach)
            if SceneryRules.isBig(t.id) { #expect(!SceneryRules.footprint(of: t).contains(where: SceneryRules.onPicnicGround), "\(t.id) at \(t.x), \(t.z)") }
        }
    }
}

@Suite struct MovingScenery {
    /// The Default with some things moved, turned and sized.
    func moved(_ base: MeadowScenery) -> (MeadowScenery, [Int]) {
        var scenery = base
        var changed: [Int] = []
        for (i, t) in base.things.enumerated() where ["tree.oak", "tree.young", "wood.fallenLog", "flower.daisy", "stone.stone"].contains(t.id) {
            guard changed.filter({ base.things[$0].id == t.id }).count < 2 else { continue }
            scenery.things[i].x += 3
            scenery.things[i].z -= 2
            scenery.things[i].turn += 0.5
            changed.append(i)
        }
        return (scenery, changed)
    }

    @Test("moving things places just those again: the same as laying the moved scenery afresh, the shade included, nothing grown or made again")
    func sameAsAfresh() {
        let m = Meadow()
        let version = m.sceneryVersion
        let (scenery, changed) = moved(.standard)
        #expect(changed.count == 9, "two oaks, young trees, daisies and stones each, and the log")
        m.show(scenery)
        #expect(m.sceneryVersion == version, "not laid afresh")
        let fresh = Meadow(scenery: scenery)
        #expect(m.beds.map(\.matrices) == fresh.beds.map(\.matrices))
        #expect(m.treeShapes.map(\.at) == fresh.treeShapes.map(\.at) && m.treeShapes.map(\.pose) == fresh.treeShapes.map(\.pose))
        #expect(m.logs.map(\.matrix) == fresh.logs.map(\.matrix))
        #expect(m.shade == fresh.shade && m.obstacles == fresh.obstacles)
        #expect(m.screens.map(\.from) == fresh.screens.map(\.from) && m.screens.map(\.to) == fresh.screens.map(\.to))
        #expect(m.groundMap.surface == fresh.groundMap.surface, "the shade baked again where trees moved, as afresh")
        #expect(m.takeGroundChanges() != nil && m.takeGroundChanges() == nil, "the changed part is told once")
    }

    @Test("adding, removing or reshaping a thing, or one leaving the meadow, lays the scenery afresh")
    func otherChanges() {
        let m = Meadow()
        var version = m.sceneryVersion
        var scenery = MeadowScenery.standard
        scenery.things.removeLast()
        m.show(scenery)
        #expect(m.sceneryVersion == version + 1)
        version = m.sceneryVersion
        scenery.things[20].variant = 1 - scenery.things[20].variant
        m.show(scenery)
        #expect(m.sceneryVersion == version + 1)
        version = m.sceneryVersion
        let tree = scenery.things.firstIndex { $0.id == "tree.oak" }!
        scenery.things[tree].x = 200
        m.show(scenery)
        #expect(m.sceneryVersion == version + 1 && m.treeShapes.count == 11)
    }

    @Test("a moved flower takes the butterflies' perch with it")
    func blooms() {
        let m = Meadow()
        var scenery = MeadowScenery.standard
        let daisy = scenery.things.firstIndex { $0.id == "flower.daisy" }!
        scenery.things[daisy].x += 5
        m.show(scenery)
        let top = Meadow.matrix(of: scenery.things[daisy]).point(Flora.daisies[scenery.things[daisy].variant].top)
        #expect(m.critters.blooms.contains { simd_distance($0, top) < 1e-4 })
    }

    @Test("moving a thing costs a fraction of laying the scenery afresh")
    func cheap() {
        let m = Meadow()
        var scenery = MeadowScenery.standard
        let oak = scenery.things.firstIndex { $0.id == "tree.oak" }!
        let clock = ContinuousClock()
        let moving = clock.measure {
            for step in 0..<60 {
                scenery.things[oak].x += 0.05 * Float(step % 2 == 0 ? 1 : -1)
                m.show(scenery)
            }
        }
        var other = MeadowScenery.standard
        other.things.removeLast()
        let afresh = clock.measure { m.show(other) }
        #expect(moving / 60 < afresh / 4, "a step \(moving / 60), afresh \(afresh)")
    }
}

@MainActor
@Suite(.serialized) struct EditingTheView {
    func world(_ count: Int) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: (0..<count).map { i in
            MeadowSpace(id: "w\(i)", name: "w\(i)", blankets: [MeadowBlanket(id: "w\(i)", title: "workspace \(i)", color: .account(i), agents: [])])
        })])
    }

    func view(_ size: NSSize, count: Int = 3) -> MeadowView {
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .day, picnic: .hamper)
        view.world = world(count)
        view.advance(seconds: 1.5)
        return view
    }

    @Test("editing lifts the view to about 55° over the picnic ground; ending it brings back exactly the view there was")
    func liftAndBack() {
        let view = view(NSSize(width: 300, height: 820))
        view.simulateDrag(dx: 40, dy: -30)
        view.advance(seconds: 1.5)
        let before = view.cameraView
        view.beginEditing()
        #expect(view.isEditing)
        view.setFrameSize(NSSize(width: 1100, height: 820))
        view.advance(seconds: 1.5)
        let editing = view.cameraView
        #expect(abs(editing.pitch - 55 * .pi / 180) < 0.01)
        // The picnic ground's near end and the first blankets are in view.
        #expect(view.viewPoint(ofGround: SIMD2(0, 0)).map { view.bounds.contains($0) } == true)
        view.endEditing()
        view.setFrameSize(NSSize(width: 300, height: 820))
        view.advance(seconds: 1.5)
        let after = view.cameraView
        #expect(!view.isEditing)
        #expect(abs(after.x - before.x) < 1e-3 && abs(after.z - before.z) < 1e-3 && abs(after.distance - before.distance) < 1e-3
                    && abs(after.pitch - before.pitch) < 1e-4 && abs(after.bearing - before.bearing) < 1e-4, "\(before) → \(after)")
    }

    @Test("the blankets keep their rows while editing, however wide the meadow grows, and take the width's rows after")
    func heldRows() {
        let view = view(NSSize(width: 300, height: 820), count: 6)
        #expect(view.blanketsPerRow == 1)
        let places = view.stage.village!.plots.map(\.at)
        view.beginEditing()
        view.setFrameSize(NSSize(width: 1440, height: 836))
        view.advance(seconds: 1)
        #expect(view.blanketsPerRow == 1 && view.stage.village!.plots.map(\.at) == places)
        view.endEditing()
        view.setFrameSize(NSSize(width: 1440, height: 836))
        view.advance(seconds: 2)
        #expect(view.blanketsPerRow == 4, "now wide, rows of four")
    }

    @Test("editing, the view may come closer and roam the whole meadow; scrolling zooms rather than scrolls the column")
    func roam() {
        let view = view(NSSize(width: 1100, height: 800))
        view.beginEditing()
        view.advance(seconds: 1.2)
        for _ in 0..<40 { view.simulateZoom(by: 0.8, at: CGPoint(x: 550, y: 400)) }
        view.advance(seconds: 0.5)
        #expect(view.cameraView.distance < MapCamera.nearest && view.cameraView.distance >= Stage.editClosest - 1e-3)
        for _ in 0..<30 { view.simulateDrag(dx: 0, dy: 400, slide: true) }
        view.advance(seconds: 1)
        let far = hypot(view.cameraView.x, view.cameraView.z)
        #expect(far > 60 && far <= SceneryRules.reach + MapCamera.reach + 1, "\(far)")
    }

    @Test("pointing at a thing finds it; a rectangle finds what stands inside it; an empty spot finds nothing")
    func pointing() {
        let view = view(NSSize(width: 1100, height: 800), count: 0)
        view.scenery = MeadowScenery(things: [thing("tree.oak", -30, -10, seed: 4), thing("stone.stone", 10, -6, size: 1.5), thing("flower.poppy", 14, -4)])
        view.beginEditing()
        view.advance(seconds: 1.5)
        for i in 0..<3 {
            let t = view.scenery.things[i]
            guard let spot = view.viewPoint(ofGround: SIMD2(t.x, t.z)) else { Issue.record("\(t.id) not in view"); continue }
            // Its base, a little above the ground.
            #expect(view.sceneryThing(at: NSPoint(x: spot.x, y: spot.y + 4)) == i, "\(t.id)")
        }
        if let a = view.viewPoint(ofGround: SIMD2(8, -2)), let b = view.viewPoint(ofGround: SIMD2(16, -8)) {
            #expect(view.sceneryThings(in: NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))) == [1, 2])
        }
        if let empty = view.viewPoint(ofGround: SIMD2(0, 25)) { #expect(view.sceneryThing(at: empty) == nil) }
        let ground = view.groundPoint(at: view.viewPoint(ofGround: SIMD2(10, -6))!)!
        #expect(simd_distance(ground, SIMD2(10, -6)) < 0.05)
        #expect(view.screenRect(ofScenery: [0])!.height > view.screenRect(ofScenery: [2])!.height, "a tree is drawn taller than a poppy")
    }

    @Test("the marks are drawn without trouble, dashed or solid, by day and by night")
    func marks() {
        let view = view(NSSize(width: 640, height: 400))
        view.beginEditing()
        view.advance(seconds: 1.2)
        view.editMarks = MeadowEditMarks(selected: [0, 1, 2], refused: [1], hovered: 5, cursor: SIMD2(3, 4), highContrast: true)
        #expect(view.renderImage(width: 640, height: 400) != nil)
        view.endEditing()
        #expect(view.editMarks == MeadowEditMarks())
    }
}

@MainActor
@Suite(.serialized) struct MakingWay {
    @Test("a tree, and a log, make way where a blanket comes, as plants do, and stand again once it goes")
    func trees() {
        let m = Meadow(scenery: MeadowScenery(things: [thing("tree.oak", 0, 0, seed: 1), MeadowScenery.Thing(id: "wood.fallenLog", x: 40, z: 0)]))
        var clearings = [Vec4](repeating: .zero, count: MAX_CLEARINGS)
        #expect(m.treeStanding(0, clearings, 0) == 1 && m.logStanding(0, clearings, 0) == 1)
        clearings[0] = Vec4(3, 0, 2.5, 0)
        clearings[1] = Vec4(44, 1, 2.5, 0)
        #expect(m.treeStanding(0, clearings, 2) == 0 && m.logStanding(0, clearings, 2) == 0)
        clearings[0] = Vec4(30, 30, 2.5, 0)
        clearings[1] = Vec4(-30, 30, 2.5, 0)
        #expect(m.treeStanding(0, clearings, 2) == 1 && m.logStanding(0, clearings, 2) == 1)
        // Between, a little of it: easing, never jumping.
        clearings[0] = Vec4(9, 0, 2.5, 0)
        let partly = m.treeStanding(0, clearings, 1)
        #expect(partly > 0 && partly < 1)
    }
}
