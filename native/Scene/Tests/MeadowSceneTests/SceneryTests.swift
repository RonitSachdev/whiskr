import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// The meadow draws whatever scenery it is given (`MeadowScenery`); the Default is today's meadow written
// out as scenery (`StandardMeadow`). Exactness of the Default against the growth it replaced was proven
// once, frame for frame and matrix for matrix, before that growth was removed (Stage 2 of the editor);
// these keep what that proof rests on.

@Suite struct DefaultScenery {
    @Test("the Default grows from the meadow's stream where the grass leaves it, and gives it back where it always did")
    func stream() {
        var random = Seeded(Meadow.seed)
        _ = GrassField.grow(&random)
        #expect(random.state == StandardMeadow.start)
        #expect(StandardMeadow.grown.end == StandardMeadow.end)
        #expect(StandardMeadow.grow().scenery == MeadowScenery.standard, "the same every time")
    }

    @Test("the Default holds today's meadow: twelve landmark trees, five young ones of three shapes, the log, flowers, fly agarics and stones")
    func contents() {
        let things = MeadowScenery.standard.things
        func count(_ id: String) -> Int { things.filter { $0.id == id }.count }
        #expect(count("tree.oak") + count("tree.birch") + count("tree.cherry") == 12)
        #expect(count("tree.young") == 5 && Set(things.filter { $0.id == "tree.young" }.map(\.seed)).count == 3)
        #expect(count("wood.fallenLog") == 1)
        #expect(count("flower.daisy") > 0 && count("flower.buttercup") > 0 && count("flower.lupin") > 0 && count("flower.poppy") > 0)
        #expect(count("fungus.flyAgaric") > 0 && count("stone.stone") + count("stone.mossy") == 40)
        #expect(things.allSatisfy { MeadowScenery.draws($0.id) })
        #expect(things.allSatisfy { hypot($0.x, $0.z) <= MeadowScenery.Limits.reach })
        // Every landmark tree's seed grows the tree the meadow grew there.
        for thing in things where SceneryCatalog.species(thing.id) != nil {
            var random = Seeded(thing.seed)
            let tree = Trees.grow(SceneryCatalog.species(thing.id)!, &random)
            #expect(tree.shape.positions == StandardMeadow.grown.trees[ShapeKey(id: thing.id, seed: thing.seed)]?.shape.positions)
        }
    }

    @Test("a meadow showing the Default grows no tree twice and draws every landmark tree's shade")
    func meadow() {
        let m = Meadow()
        #expect(m.scenery == .standard)
        #expect(m.treeShapes.count == 12 && m.logs.count == 1 && m.shade.count == 12)
        #expect(m.obstacles == Meadow.obstaclesForTests)
        // All twelve dapple the ground, the four far ones too (once only the first eight did).
        for tree in m.shade { #expect(m.groundMap.shade(at: Vec2(tree.x, tree.y)) > 0.95) }
    }
}

@Suite struct GroundMapBaking {
    @Test("shade is 1 under a crown's middle, falls with the distance, and is 0 from its reach on")
    func shade() {
        let map = GroundMap.baked(shade: [Vec4(10, -20, 12, 0)])
        #expect(map.shade(at: Vec2(10, -20)) > 0.95)
        for d: Float in [3, 6, 9] {
            let got = map.shade(at: Vec2(10 + d, -20)), want = 1 - d / 12
            #expect(abs(got - want) < 0.03, "\(d): \(got) vs \(want)")
        }
        #expect(map.shade(at: Vec2(10 + 12.6, -20)) == 0)
        #expect(map.shade(at: Vec2(-100, 100)) == 0)
        // Where crowns overlap, the nearer one's shade counts.
        let two = GroundMap.baked(shade: [Vec4(0, 0, 10, 0), Vec4(6, 0, 10, 0)])
        #expect(abs(two.shade(at: Vec2(3, 0)) - 0.7) < 0.03)
    }

    @Test("its texels lie on the paint grid's cells, and it holds the shade of the largest tree at the meadow's edge")
    func extent() {
        // The paint grid (512 cells over ±150) falls exactly on texels.
        #expect(abs(GroundMap.middle(GroundMap.margin, GroundMap.margin).x - (-150 + GroundMap.cell / 2)) < 1e-4)
        #expect(abs(Float(512) * GroundMap.cell - 300) < 1e-4)
        // The widest crown a landmark tree grows, at its largest size (1.2 in the catalog).
        var widest: Float = 0
        for species in [Species.oak, .birch, .cherry] {
            for seed in UInt32(0)..<200 {
                var random = Seeded(seed &* 2_654_435_761)
                widest = max(widest, Trees.grow(species, &random).crown * 1.1 * 1.2)
            }
        }
        #expect(MeadowScenery.Limits.reach + widest < GroundMap.reach, "shade reaching \(MeadowScenery.Limits.reach + widest) vs the map's \(GroundMap.reach)")
        // Baked at the edge, it stops short of the map's last texel.
        let edge = GroundMap.baked(shade: [Vec4(MeadowScenery.Limits.reach, 0, widest, 0)])
        #expect(edge.shade(at: Vec2(MeadowScenery.Limits.reach + widest - 1, 0)) > 0)
        #expect(edge.shade(at: Vec2(GroundMap.reach - GroundMap.cell, 0)) == 0)
    }

    @Test("the shaders read the map where the baker writes it")
    func shaderAgrees() {
        #expect(ShaderSource.common.contains("#define GROUND_MAP_REACH \(GroundMap.reach)"))
        #expect(!ShaderSource.all.contains("W.trees"), "no loop over trees is left")
    }
}

@Suite struct LayingScenery {
    func thing(_ id: String, _ x: Float, _ z: Float, seed: UInt32 = 0, variant: Int = 0) -> MeadowScenery.Thing {
        MeadowScenery.Thing(id: id, x: x, z: z, seed: seed, variant: variant)
    }

    @Test("an empty meadow holds nothing; the Default comes back as it was, its trees not grown again")
    func emptyAndBack() {
        let m = Meadow()
        let trees = m.treeShapes.map(\.at), beds = m.beds.map(\.matrices)
        m.show(.empty)
        #expect(m.beds.isEmpty && m.treeShapes.isEmpty && m.logs.isEmpty && m.screens.isEmpty && m.obstacles.isEmpty && m.shade.isEmpty)
        #expect(m.groundMap.shade(at: Vec2(-26.3, -49.4)) == 0)
        m.show(.standard)
        #expect(m.treeShapes.map(\.at) == trees && m.beds.map(\.matrices) == beds)
    }

    @Test("a thing is drawn turned, leant and sized as given, standing on the land; a tree grows from its seed")
    func placing() {
        var oak = thing("tree.oak", 20, 10, seed: 77)
        oak.turn = 1
        oak.size = Vec3(1.1, 1.2, 1.1)
        var daisy = thing("flower.daisy", -4, 3, variant: 1)
        daisy.tilt = Vec2(0.05, -0.02)
        let m = Meadow(scenery: MeadowScenery(things: [oak, daisy]))
        #expect(m.treeShapes.count == 1 && m.beds.count == 1 && m.plants.count == 1)
        let pose = m.treeShapes[0].pose
        #expect(simd_distance(pose.point(Vec3(1, 0, 0)), Vec3(cos(1) * 1.1, 0, -sin(1) * 1.1)) < 1e-4)
        #expect(m.treeShapes[0].at == Vec3(20, Land.height(20, 10), 10))
        #expect(m.shade[0].z > 0 && m.obstacles[0].r == Species.oak.girth * 3.2 * 1.1)
        var random = Seeded(77)
        #expect(m.treeShapes[0].shape.positions == Trees.grow(.oak, &random).shape.roughened(0.85).positions)
        #expect(m.beds[0].matrices == [Meadow.matrix(of: daisy)] && m.plantKeys[0] == ShapeKey(id: "flower.daisy", variant: 1))
        // A shape it does not have draws as the first; an id the scene does not know is left out.
        let other = Meadow(scenery: MeadowScenery(things: [thing("flower.daisy", 0, 0, variant: 9), thing("cat.box", 1, 1), thing("garden.pond", 2, 2)]))
        #expect(other.beds.count == 1 && other.plantKeys == [ShapeKey(id: "flower.daisy", variant: 0)])
    }

    @Test("past a limit, further things of that kind are left out in order; nothing stands beyond the meadow's reach")
    func limits() {
        typealias Limits = MeadowScenery.Limits
        var things: [MeadowScenery.Thing] = []
        for i in 0..<(Limits.trees + 5) {
            let x = Float(i % 10) * 8 - 40, z = Float(i / 10) * 8 - 40
            things.append(thing("tree.young", x, z, seed: UInt32(i % 3)))
        }
        for i in 0..<Limits.things {
            let x = Float(i % 70) - 35, z = Float(i / 70) - 35
            things.append(thing("stone.stone", x, z))
        }
        things.append(thing("flower.poppy", Limits.reach + 1, 0))
        let m = Meadow(scenery: MeadowScenery(things: things))
        let trees = m.beds.filter { $0.screens != nil }.reduce(0) { $0 + $1.matrices.count }
        let all = m.beds.reduce(0) { $0 + $1.matrices.count }
        #expect(trees == Limits.trees && all == Limits.things && m.screens.count == Limits.trees)
        #expect(!m.plantKeys.contains { $0.id == "flower.poppy" })
        // Tall things: trees and logs together.
        var logs: [MeadowScenery.Thing] = []
        for i in 0..<(Limits.tall + 3) {
            let x = Float(i % 12) * 12 - 70, z = Float(i / 12) * 12 - 70
            logs.append(thing("wood.fallenLog", x, z))
        }
        #expect(Meadow(scenery: MeadowScenery(things: logs)).logs.count == Limits.tall)
    }

    @Test("blankets keep off the trees and logs of the scenery shown")
    @MainActor func obstaclesFollow() {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let log = thing("wood.fallenLog", 5, 30)
        view.scenery = MeadowScenery(things: [log])
        #expect(view.scenery.things == [log])
        #expect(view.stage.village!.obstacles == Meadow.obstacles(of: log, .log))
    }
}
