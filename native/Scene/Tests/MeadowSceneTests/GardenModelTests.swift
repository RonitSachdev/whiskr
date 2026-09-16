import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// The meadow editor's Stage 8 models (the garden's and the workplace's things, the fence) and the made things'
// palettes: each builds within its budget, stands on the ground within the ground the editor's rules give it, has a
// picture of its own, wears every swatch of its palette, and (where it invites one) has a spot for a cat; a fence
// run stands its posts evenly, follows the land, joins at its corners, opens at its gate and stops a cat.

/// What each model may come to: the most triangles, its height and how far it may reach across, in units.
private let budgets: [String: (triangles: Int, height: ClosedRange<Float>, reach: Float)] = [
    "garden.flowerPot": (8_000, 1.3...1.8, 0.75),
    "garden.planter": (8_000, 1.0...1.4, 1.9),
    "garden.wateringCan": (6_000, 1.0...1.4, 1.3),
    "garden.birdhouse": (4_000, 4.4...5.2, 0.85),
    "garden.skep": (6_000, 1.5...1.9, 0.95),
    "work.desk": (8_000, 1.6...2.1, 1.75),
    "work.bookshelf": (14_000, 3.4...4.0, 1.45),
    "work.bench": (6_000, 2.2...2.7, 2.3),
    "work.signpost": (5_000, 4.4...4.9, 2.1),
    "work.mailbox": (4_000, 2.9...3.5, 0.85),
    "work.noticeboard": (6_000, 3.3...3.8, 1.6),
    "place.shed": (14_000, 5.0...5.7, 3.3),
    "place.tent": (8_000, 3.3...3.9, 3.4),
]

/// The models Stage 8 brings that stand at one spot, in the catalog's order (the fence is a run).
let stageEight = ["garden.flowerPot", "garden.planter", "garden.wateringCan", "garden.birdhouse", "garden.skep", "work.desk", "work.bookshelf", "work.bench",
                  "work.signpost", "work.mailbox", "work.noticeboard", "place.shed", "place.tent"]

/// A model as the meadow draws it, at its own size, standing at the middle, in a swatch.
private func model(_ id: String, swatch: Int = 0) -> Geometry? {
    Meadow.alone(MeadowScenery.Thing(id: id, x: 0, z: 0, swatch: swatch)).map { $0.make() }
}

/// How high a shape's surface is straight above a ground point (x, z), its highest face there below `below`; -1 for none.
func surface(_ shape: Geometry, under p: Vec2, below: Float) -> Float {
    var best: Float = -1
    var t = 0
    while t + 2 < shape.indices.count {
        let a = shape.positions[Int(shape.indices[t])], b = shape.positions[Int(shape.indices[t + 1])], c = shape.positions[Int(shape.indices[t + 2])]
        t += 3
        let d = (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
        guard abs(d) > 1e-9 else { continue }
        let l1 = ((b.z - c.z) * (p.x - c.x) + (c.x - b.x) * (p.y - c.z)) / d, l2 = ((c.z - a.z) * (p.x - c.x) + (a.x - c.x) * (p.y - c.z)) / d, l3 = 1 - l1 - l2
        guard l1 >= 0, l2 >= 0, l3 >= 0 else { continue }
        let y = a.y * l1 + b.y * l2 + c.y * l3
        if y < below { best = max(best, y) }
    }
    return best
}

@Suite struct GardenModels {
    @Test("every Stage 8 model builds within its budget of triangles, tall and wide as the real thing at the meadow's scale", arguments: stageEight)
    func builds(_ id: String) throws {
        let budget = try #require(budgets[id])
        let shape = try #require(model(id), "\(id) draws")
        let triangles = shape.indices.count / 3
        #expect(triangles > 0 && triangles <= budget.triangles, "\(id): \(triangles) triangles")
        #expect(shape.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } && shape.indices.allSatisfy { Int($0) < shape.count })
        #expect(shape.colors.count == shape.count && shape.roughness.count == shape.count)
        #expect(budget.height.contains(shape.bounds.max.y), "\(id): \(shape.bounds.max.y) tall")
        let reach = shape.positions.map { hypot($0.x, $0.z) }.max() ?? 0
        #expect(reach <= budget.reach, "\(id): reaches \(reach)")
    }

    @Test("each stands on the ground within its footprint: nothing hangs below the turf, and its foot is on it", arguments: stageEight)
    func standsOnTheGround(_ id: String) throws {
        let shape = try #require(model(id))
        let low = shape.bounds.min.y
        #expect(low <= 0.06 && low >= -0.3, "\(id): lowest point \(low)")
        let footprint = try #require(SceneryRules.footprint(of: MeadowScenery.Thing(id: id, x: 0, z: 0)).first)
        let touching = shape.positions.filter { $0.y < 0.08 }.map { hypot($0.x, $0.z) }.max() ?? 0
        #expect(touching <= footprint.r * 1.35, "\(id): on the ground out to \(touching), its footprint \(footprint.r)")
        // What stands on a post (a nest box, a sign, a mailbox) has its post's foot; the rest stand on most of theirs.
        let onAPost = ["garden.birdhouse", "work.signpost", "work.mailbox"].contains(id)
        #expect(onAPost || touching >= footprint.r * 0.5, "\(id): on the ground out to \(touching), its footprint \(footprint.r)")
    }

    @Test("made things never sway, stand alone, and only the shed, the tent and the fence are kept off the picnic ground; tall ones fade")
    func kinds() throws {
        for id in stageEight {
            guard case .plant(_, let sway, let blooms, _) = try #require(SceneryCatalog.kinds[id]) else { Issue.record("\(id)"); continue }
            #expect(sway == 0 && !blooms && !SceneryRules.isSmall(id), "\(id)")
            #expect(SceneryRules.isBig(id) == ["place.shed", "place.tent"].contains(id), "\(id)")
        }
        #expect(SceneryRules.isBig("garden.fence") && !SceneryRules.isSmall("garden.fence"))
        #expect(SceneryCatalog.tall == ["garden.birdhouse", "work.bookshelf", "place.shed", "place.tent", "work.lampPost"])
        let m = Meadow(scenery: MeadowScenery(things: [MeadowScenery.Thing(id: "place.shed", x: 40, z: 0), MeadowScenery.Thing(id: "work.bench", x: 50, z: 0)]))
        #expect(m.screens.count == 1 && m.beds.filter { $0.screens != nil }.count == 1, "the shed fades in the way; the bench does not")
        #expect(m.canopy(0) == nil, "a shed has no crown to ring")
    }

    @Test("things that invite a cat say where: on a bench's seat, a desk's top, a bookcase's top, a shed's doorstep, a tent's doorway, under a nest box")
    func catSpots() throws {
        for id in ["work.bench", "work.desk", "work.bookshelf"] {
            let spot = try #require(MeadowScenery.catSpot(of: id))
            let shape = try #require(model(id))
            let under = surface(shape, under: Vec2(spot.at.x, spot.at.z), below: spot.at.y + 0.3)
            #expect(abs(under - spot.at.y) < 0.12, "\(id): its top under the spot at \(under), the spot at \(spot.at.y)")
        }
        for id in ["place.shed", "place.tent", "garden.birdhouse"] {
            let spot = try #require(MeadowScenery.catSpot(of: id))
            #expect(spot.at.y < 0.1 && abs(simd_length(spot.toward) - 1) < 1e-4, "\(id)")
        }
        for id in ["garden.flowerPot", "work.signpost", "work.mailbox", "garden.skep", "garden.fence"] { #expect(MeadowScenery.catSpot(of: id) == nil, "\(id)") }
    }

    @Test("each made thing with a palette wears every swatch, each unlike the others, the first as before", arguments: Array(SceneryCatalog.palettes.keys.sorted()))
    func palettes(_ id: String) throws {
        let names = try #require(SceneryCatalog.palettes[id])
        #expect(names.count >= 4 && names.count <= 8 && Set(names).count == names.count)
        #expect(names.allSatisfy { Palette.swatches[$0] != nil }, "\(id): every swatch has its clay")
        let looks = try names.indices.map { try #require(model(id, swatch: $0)).colors }
        #expect(Set(looks.map { $0.map { "\($0)" }.joined() }).count == names.count, "\(id): every swatch looks its own")
        // One it does not have is drawn as its first.
        #expect(model(id, swatch: names.count)?.colors == looks[0])
        #expect(MeadowScenery.palette(of: id).map(\.name) == names)
    }

    @Test("no swatch is a state's colour (the working vermillion, the finished blue, the alert red)")
    func noStateColours() {
        let states: [MeadowColor] = [MeadowColor(hex: 0xd55e00), MeadowColor(hex: 0x0072b2), MeadowColor(hex: 0xd4433a)]
        for (name, clay) in Palette.swatches {
            for hex in [clay.shade, clay.light] {
                let c = MeadowColor(hex: hex)
                for s in states {
                    let apart = abs(c.red - s.red) + abs(c.green - s.green) + abs(c.blue - s.blue)
                    #expect(apart > 0.25, "\(name) is too near a state's colour")
                }
            }
        }
    }

    @Test("a meadow draws each swatch in a bed of its own, and a swatch changed in place is drawn again in it")
    func swatchBeds() {
        let things = (0..<4).map { MeadowScenery.Thing(id: "work.bench", x: Float($0) * 8, z: 30, swatch: $0) }
        let m = Meadow(scenery: MeadowScenery(things: things + things.map { var t = $0; t.z = 40; return t }))
        #expect(m.beds.count == 4 && m.beds.allSatisfy { $0.matrices.count == 2 })
        var changed = m.scenery
        changed.things[0].swatch = 2
        m.show(changed)
        #expect(m.beds.count == 4 && m.plantKeys.contains(ShapeKey(id: "work.bench", swatch: 2)))
        #expect(m.beds.reduce(0) { $0 + $1.matrices.count } == 8)
    }
}

@Suite struct FenceRuns {
    @Test("posts stand at every point and evenly between, never more than 2.5 apart, as the file's catalog counts them")
    func evenSpacing() {
        let points = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 3.1)]
        let posts = MeadowScenery.fencePosts(along: points)
        // 10 units: four spans of 2.5; 3.1 units: two of 1.55.
        #expect(posts.count == 1 + 4 + 2)
        let gaps = zip(posts, posts.dropFirst()).map { simd_distance($0, $1) }
        #expect(gaps.allSatisfy { $0 <= MeadowScenery.fencePostSpacing + 1e-4 })
        #expect(abs(gaps[0] - 2.5) < 1e-4 && abs(gaps[5] - 1.55) < 1e-4)
        #expect(points.allSatisfy { p in posts.contains { simd_distance($0, p) < 1e-4 } }, "a post at every point")
        // A run closed on itself has no second post where it closes.
        let square = [Vec2(0, 0), Vec2(5, 0), Vec2(5, 5), Vec2(0, 5), Vec2(0, 0)]
        #expect(MeadowScenery.fencePosts(along: square).count == 8)
    }

    @Test("two rails a span, from post to post, following the land; a corner's spans meet in its post")
    func railsAndCorners() throws {
        // Out past the level middle, where the land rises and falls.
        let points = [Vec2(90, 20), Vec2(97.5, 20), Vec2(97.5, 27.5)]
        let parts = Fences.parts(points, gate: 0)
        let posts = parts.filter { $0.part == .post }, rails = parts.filter { $0.part == .rails }
        #expect(posts.count == 7 && rails.count == 6)
        for (part, (a, b)) in zip(rails, zip(posts, posts.dropFirst())) {
            // Each span's rails start at a post's foot and end at the next post's, on the land at both.
            let start = part.matrix.point(.zero), end = part.matrix.point(Vec3(Fences.spacing, 0, 0))
            #expect(simd_distance(start, a.matrix.position) < 1e-3 && simd_distance(end, b.matrix.position) < 1e-3, "\(start) → \(end)")
            #expect(abs(start.y - Land.height(start.x, start.z)) < 1e-3 && abs(end.y - Land.height(end.x, end.z)) < 1e-3)
        }
        #expect(Set(posts.map { $0.matrix.position.y }).count > 1, "the land there is not level: the posts stand at its heights")
        // The corner post faces halfway between its two spans.
        let (laid, _) = Fences.layout(points)
        let corner = try #require(laid.first { simd_distance($0.at, Vec2(97.5, 20)) < 1e-4 })
        #expect(simd_distance(corner.along, simd_normalize(Vec2(1, 1))) < 1e-3)
    }

    @Test("a gate takes one span: no rails there, a gate's leaf, stouter capped posts either side, and a gap in the rules' ground")
    func gate() throws {
        let points = [Vec2(0, 0), Vec2(2.5, 0), Vec2(5, 0), Vec2(7.5, 0)]
        let parts = Fences.parts(points, gate: 2)
        #expect(parts.filter { $0.part == .gate }.count == 1 && parts.filter { $0.part == .rails }.count == 2 && parts.filter { $0.part == .cap }.count == 2)
        let leaf = try #require(parts.first { $0.part == .gate })
        #expect(simd_distance(leaf.matrix.position, Vec3(2.5, Land.height(2.5, 0), 0)) < 1e-3)
        // The rules leave the gateway free: a stepping stone may lie in it, not under a rail.
        let fence = MeadowScenery.Thing(id: "garden.fence", points: points, gate: 2)
        let field = SceneryRules.Field(MeadowScenery(things: [fence]))
        #expect(field.refusal(for: MeadowScenery.Thing(id: "stone.stepping", x: 3.75, z: 0)) == nil)
        #expect(field.refusal(for: MeadowScenery.Thing(id: "stone.stepping", x: 1.25, z: 0)) == .tooClose(0))
        // A gate in a segment of several spans takes its middle one.
        #expect(Fences.layout([Vec2(0, 0), Vec2(12.5, 0)], gate: 1).spans.firstIndex { $0.gate } == 2)
    }

    @Test("a cat cannot go through a fence, only round it or through its gate")
    func barrier() {
        let m = Meadow(scenery: MeadowScenery(things: [MeadowScenery.Thing(id: "garden.fence", points: [Vec2(0, 30), Vec2(10, 30)], gate: 0),
                                                       MeadowScenery.Thing(id: "garden.fence", points: [Vec2(0, 40), Vec2(2.5, 40), Vec2(5, 40)], gate: 2)]))
        #expect(m.crossesFence(Vec2(5, 28), Vec2(5, 32)))
        #expect(!m.crossesFence(Vec2(12, 28), Vec2(12, 32)), "round its end")
        #expect(!m.crossesFence(Vec2(3.75, 38), Vec2(3.75, 42)), "through the gate")
        #expect(m.crossesFence(Vec2(1.25, 38), Vec2(1.25, 42)))
    }

    @Test("a run is one thing: picked by any post or span, moved whole in place, laid afresh when reshaped")
    func oneThing() throws {
        var scenery = MeadowScenery(things: [MeadowScenery.Thing(id: "garden.fence", points: [Vec2(30, 0), Vec2(35, 0), Vec2(35, 5)])])
        let m = Meadow(scenery: scenery)
        guard case .run(let r) = m.laid[0] else {
            Issue.record("laid as a run")
            return
        }
        #expect(m.runs[r].posts.count == 5 && m.picking(0).count >= 9)
        #expect(m.obstacles.count == 5)
        let version = m.sceneryVersion
        scenery.things[0].move(by: Vec2(2, 1))
        m.show(scenery)
        #expect(m.sceneryVersion == version, "moved in place")
        #expect(simd_distance(m.runs[r].posts[0], Vec3(32, Land.height(32, 1), 1)) < 1e-3)
        scenery.things[0].points = [Vec2(32, 1), Vec2(47, 1)]
        m.show(scenery)
        #expect(m.sceneryVersion == version + 1 && m.runs.first?.posts.count == 7)
        // Ghost and picture: one shape, on the land where the run lies.
        let ghost = try #require(Meadow.alone(scenery.things[0]))
        #expect(ghost.make().bounds.min.x > 31 && ghost.matrix == .identity)
    }

    @Test("a run is kept off the picnic ground and inside the meadow by every one of its points")
    func rules() {
        let field = SceneryRules.Field(MeadowScenery())
        #expect(field.refusal(for: MeadowScenery.Thing(id: "garden.fence", points: [Vec2(30, 10), Vec2(15, 10)])) == .keptForWorkspaces)
        #expect(field.refusal(for: MeadowScenery.Thing(id: "garden.fence", points: [Vec2(150, 10), Vec2(165, 10)])) == .outsideMeadow)
        #expect(field.refusal(for: MeadowScenery.Thing(id: "garden.fence", points: [Vec2(30, 10), Vec2(40, 10)])) == nil)
    }
}

// MARK: Pictures (MEADOW_SNAPSHOTS)

/// Contact sheets of the Stage 8 models and fences, for looking at: each alone, from the editor's height and close
/// up, by day and by night; every swatch of each palette; fences straight, at a corner, with a gate and on a slope;
/// and the tray's pictures in the three looks. Written only when MEADOW_SNAPSHOTS names a folder.
@MainActor
@Suite(.serialized) struct GardenPictures {
    static let fences: [(String, MeadowScenery.Thing)] = [
        ("straight", MeadowScenery.Thing(id: "garden.fence", points: [Vec2(-6, 0), Vec2(-3.5, 0), Vec2(-1, 0), Vec2(1.5, 0), Vec2(4, 0)])),
        ("corner", MeadowScenery.Thing(id: "garden.fence", points: [Vec2(-5, -3), Vec2(-2.5, -3), Vec2(0, -3), Vec2(0, -0.5), Vec2(0, 2), Vec2(2.5, 2)])),
        ("gate", MeadowScenery.Thing(id: "garden.fence", points: [Vec2(-5, 0), Vec2(-2.5, 0), Vec2(0, 0), Vec2(2.5, 0), Vec2(5, 0)], gate: 3)),
    ]

    @Test(.enabled(if: CatalogPictures.folder != nil)) func models() {
        let ids = stageEight
        let spots = CatalogPictures.spots(ids)
        var things = ids.map { id in MeadowScenery.Thing(id: id, x: spots[id]!.x, z: spots[id]!.y, turn: 0.5) }
        // The fences beside them, and one on the slope out past the level middle.
        for (k, fence) in Self.fences.enumerated() {
            var f = fence.1
            f.move(by: Vec2(Float(k) * 20 - 20, 50))
            things.append(f)
        }
        things.append(MeadowScenery.Thing(id: "garden.fence", points: (0..<9).map { Vec2(96 + Float($0) * 2.5, 30 + Float($0) * 0.5) }, gate: 5))
        let scenery = MeadowScenery(things: things)
        for (mood, time) in CatalogPictures.moods where mood != "dusk" {
            let view = CatalogPictures.view(scenery, time: time)
            var far: [(String, CGImage)] = [], near: [(String, CGImage)] = []
            for id in ids {
                let tall = budgets[id]!.height.upperBound, spot = spots[id]!
                if let image = CatalogPictures.shot(view, at: spot, distance: SceneryRules.isBig(id) ? 60 : 34, pitch: 0.96) { far.append((id, image)) }
                if let image = CatalogPictures.shot(view, at: spot, distance: max(6, tall * 2.6), pitch: 0.42) { near.append((id, image)) }
            }
            CatalogPictures.sheet(far, columns: 5, to: "garden-editor-\(mood)")
            CatalogPictures.sheet(near, columns: 5, to: "garden-close-\(mood)")
            var fences: [(String, CGImage)] = []
            for (k, (name, _)) in Self.fences.enumerated() {
                let at = SIMD2<Float>(Float(k) * 20 - 20, 50)
                if let image = CatalogPictures.shot(view, at: at, distance: 34, pitch: 0.96) { fences.append(("\(name), editor", image)) }
                if let image = CatalogPictures.shot(view, at: at, distance: 14, pitch: 0.4) { fences.append(("\(name), close", image)) }
            }
            if let image = CatalogPictures.shot(view, at: SIMD2(106, 32), distance: 30, pitch: 0.5) { fences.append(("on a slope", image)) }
            CatalogPictures.sheet(fences, columns: 4, to: "fences-\(mood)")
        }
        let view = CatalogPictures.view(scenery, time: .day)
        for (look, hex) in [("light", UInt32(0xffffff)), ("dark", 0x2a2826), ("graphite", 0x232326)] {
            let tiles = (ids + ["garden.fence"]).compactMap { id in view.portrait(of: [id], pixels: 256, background: MeadowColor(hex: hex)).map { (id, $0) } }
            CatalogPictures.sheet(tiles, columns: 7, to: "garden-tray-\(look)")
        }
    }

    @Test(.enabled(if: CatalogPictures.folder != nil)) func swatches() {
        let ids = SceneryCatalog.palettes.keys.sorted()
        var things: [MeadowScenery.Thing] = []
        for (row, id) in ids.enumerated() {
            for k in SceneryCatalog.palettes[id]!.indices {
                things.append(MeadowScenery.Thing(id: id, x: Float(k) * 14 - 28, z: Float(row) * 14 - 60, turn: 0.5, swatch: k))
            }
        }
        let view = CatalogPictures.view(MeadowScenery(things: things), time: .day)
        var pictures: [(String, CGImage)] = []
        for (row, id) in ids.enumerated() {
            let tall = max(6, (model(id)?.bounds.max.y ?? 2) * 3)
            for (k, name) in SceneryCatalog.palettes[id]!.enumerated() {
                if let image = CatalogPictures.shot(view, at: SIMD2(Float(k) * 14 - 28, Float(row) * 14 - 60), distance: tall, pitch: 0.55) { pictures.append(("\(id) \(name)", image)) }
            }
        }
        CatalogPictures.sheet(pictures, columns: 5, to: "swatches")
    }

    /// Each model's triangles.
    @Test(.enabled(if: CatalogPictures.folder != nil)) func triangles() throws {
        var table = stageEight.compactMap { id in model(id).map { "\(id)\t\($0.indices.count / 3)" } }
        for part in Fences.Part.allCases { table.append("garden.fence \(part)\t\(Fences.shapes[part.rawValue].shape.indices.count / 3)") }
        try (table.joined(separator: "\n") + "\n").write(toFile: URL(fileURLWithPath: CatalogPictures.folder!).appendingPathComponent("garden-triangles.txt").path,
                                                         atomically: true, encoding: .utf8)
    }
}
