import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import simd
@_spi(Diagnostics) @testable import MeadowScene

// The meadow editor's Stage 7 models (cat things, stones and wood, plants, the apple tree and the pine): each
// builds within its budget, stands on the ground, keeps within the ground the editor's rules give it, has a
// picture of its own for the tray, and (where it invites one) a spot for a cat.

/// What each model may come to: the most triangles, its height and how far it may reach across, in units.
private let budgets: [String: (triangles: Int, height: ClosedRange<Float>, reach: Float)] = [
    "tree.apple": (90_000, 8...20, 16),
    "tree.pine": (90_000, 26...40, 12),
    "flower.cornflower": (14_000, 1.6...2.6, 0.9),
    "flower.foxglove": (14_000, 2.8...3.8, 1.2),
    "plant.fern": (20_000, 1.6...2.8, 2.9),
    "plant.clover": (16_000, 0.6...1.1, 0.7),
    "stone.boulder": (12_000, 1.4...2.3, 2.9),
    "wood.stump": (8_000, 0.9...1.3, 2.1),
    "wood.logPile": (10_000, 1.3...1.9, 1.8),
    "work.cushion": (12_000, 0.6...0.9, 1.6),
    "cat.box": (8_000, 1.4...2.6, 2.6),
    "cat.scratchingPost": (8_000, 3...3.8, 1.35),
    "cat.yarn": (8_000, 0.6...1, 1.8),
    "cat.bed": (6_000, 0.55...0.9, 1.7),
    "cat.bowl": (10_000, 0.25...0.5, 0.65),
]

/// The models Stage 7 brings, in the catalog's order.
let stageSeven = ["tree.apple", "tree.pine", "flower.cornflower", "flower.foxglove", "plant.fern", "plant.clover", "stone.boulder", "wood.stump", "wood.logPile",
                  "work.cushion", "cat.box", "cat.scratchingPost", "cat.yarn", "cat.bed", "cat.bowl"]

/// A model as the meadow draws it, at its own size, standing at the middle.
private func model(_ id: String, seed: UInt32 = 1) -> Geometry? {
    Meadow.alone(MeadowScenery.Thing(id: id, x: 0, z: 0, seed: seed)).map { $0.make() }
}

@Suite struct CatalogModels {
    @Test("every Stage 7 model builds within its budget of triangles, tall and wide as the real thing at the meadow's scale",
          arguments: stageSeven)
    func builds(_ id: String) throws {
        let budget = try #require(budgets[id])
        let shape = try #require(model(id), "\(id) draws")
        let triangles = shape.indices.count / 3
        #expect(triangles > 0 && triangles <= budget.triangles, "\(id): \(triangles) triangles")
        #expect(shape.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite } && shape.indices.allSatisfy { Int($0) < shape.count })
        #expect(shape.colors.count == shape.count && shape.roughness.count == shape.count)
        let bounds = shape.bounds
        #expect(budget.height.contains(bounds.max.y), "\(id): \(bounds.max.y) tall")
        let reach = shape.positions.map { hypot($0.x, $0.z) }.max() ?? 0
        #expect(reach <= budget.reach, "\(id): reaches \(reach)")
    }

    @Test("each stands on the ground: nothing hangs below it but what is sunk in the turf, and it touches the ground", arguments: stageSeven)
    func standsOnTheGround(_ id: String) throws {
        let shape = try #require(model(id))
        let low = shape.bounds.min.y
        // Roots and a boulder's foot go down into the turf, no further (a tree's trunk is rooted deeper).
        #expect(low <= 0.06 && low >= (SceneryCatalog.species(id) == nil ? -0.9 : -1.6), "\(id): lowest point \(low)")
        // A tree stands on its trunk (its windfalls lie in the grass further out).
        guard SceneryCatalog.species(id) == nil else { return }
        // The ground under it is its footprint's: nothing touching the ground reaches past it by more than a little
        // (a fern's leaves overhang, its root does not; a ball of yarn's loose strand trails over the grass).
        let footprint = try #require(SceneryRules.footprint(of: MeadowScenery.Thing(id: id, x: 0, z: 0)).first)
        let touching = shape.positions.filter { $0.y < 0.08 && !(id == "cat.yarn" && hypot($0.x, $0.z) > 0.5) }.map { hypot($0.x, $0.z) }.max() ?? 0
        #expect(touching <= footprint.r * 1.35, "\(id): on the ground out to \(touching), its footprint \(footprint.r)")
        if !SceneryRules.isSmall(id) {
            // A thing standing alone stands on most of its footprint.
            #expect(touching >= footprint.r * 0.5, "\(id): on the ground out to \(touching), its footprint \(footprint.r)")
        }
    }

    @Test("living things sway and grow within their kind's range; found and made things never sway; made things, wood and boulders stand alone")
    func kinds() throws {
        for id in stageSeven {
            let kind = try #require(SceneryCatalog.kinds[id])
            switch (id.split(separator: ".").first, kind) {
            case ("tree", .tree): break
            case ("flower", .plant(_, let sway, let blooms, _)), ("plant", .plant(_, let sway, let blooms, _)):
                #expect(sway > 0 && (blooms == (id != "plant.fern")), "\(id)")
                #expect(SceneryRules.isSmall(id) && !SceneryRules.isBig(id))
            case (_, .plant(_, let sway, let blooms, _)):
                #expect(sway == 0 && !blooms, "\(id)")
                #expect(!SceneryRules.isSmall(id) && !SceneryRules.isBig(id), "\(id) stands alone, and may stand on the picnic ground")
            default: Issue.record("\(id): \(kind)")
            }
        }
        #expect(SceneryRules.isBig("tree.apple") && SceneryRules.isBig("tree.pine") && !SceneryRules.isSmall("tree.pine"))
        #expect(SceneryRules.isSmall("flower.daisy") && SceneryRules.isSmall("stone.stone") && SceneryRules.isSmall("stone.stepping"))
    }

    @Test("an apple tree and a pine grow from their seeds, differently each time, and dapple the ground under them")
    func trees() {
        for species in [Species.apple, .pine] {
            var a = Seeded(5), b = Seeded(5), c = Seeded(6)
            let one = Trees.grow(species, &a), again = Trees.grow(species, &b), other = Trees.grow(species, &c)
            #expect(one.shape.positions == again.shape.positions && one.shape.positions != other.shape.positions)
            #expect(one.crown > species.reach * 0.8 && one.bulk > 0 && one.middle.y > species.height * 0.4)
        }
        let m = Meadow(scenery: MeadowScenery(things: [MeadowScenery.Thing(id: "tree.apple", x: 30, z: 30, seed: 3), MeadowScenery.Thing(id: "tree.pine", x: -30, z: 30, seed: 3)]))
        #expect(m.treeShapes.count == 2 && m.shade.count == 2 && m.screens.count == 2)
        #expect(m.groundMap.shade(at: Vec2(30, 30)) > 0.9 && m.groundMap.shade(at: Vec2(-30, 30)) > 0.9)
    }

    @Test("the Default's trees grow from their seeds alone, as the meadow showing it grew them")
    func defaultTreesFromSeeds() {
        for thing in MeadowScenery.standard.things.prefix(40) where SceneryCatalog.species(thing.id) != nil {
            var random = Seeded(thing.seed)
            #expect(Trees.grow(SceneryCatalog.species(thing.id)!, &random).shape.positions == StandardMeadow.grown.trees[ShapeKey(id: thing.id, seed: thing.seed)]?.shape.positions)
        }
    }

    @Test("things that invite a cat say where, on the thing and in the meadow as it is placed and turned")
    func catSpots() throws {
        for id in ["cat.box", "cat.bed", "cat.scratchingPost", "cat.bowl", "work.cushion", "wood.stump", "stone.boulder", "wood.logPile", "wood.fallenLog"] {
            let spot = try #require(MeadowScenery.catSpot(of: id), "\(id)")
            #expect(abs(simd_length(spot.toward) - 1) < 1e-4)
            let shape: Geometry = id == "wood.fallenLog" ? SceneryCatalog.fallenLog : try #require(model(id))
            switch spot.kind {
            case .sit where spot.at.y > 0.5, .nap where spot.at.y > 0.3:
                // On top: the thing's surface just under its paws.
                let under = shape.positions.filter { hypot($0.x - spot.at.x, $0.z - spot.at.z) < 0.45 }.map(\.y).max() ?? -1
                #expect(abs(under - spot.at.y) < 0.2, "\(id): its top under the spot at \(under), the spot at \(spot.at.y)")
            case .sit, .nap:
                // In it (a box, a bed) or in front of it (a bowl), on the ground, within reach of it.
                #expect(spot.at.y < 0.3 && hypot(spot.at.x, spot.at.z) < 1.6, "\(id)")
            case .scratch:
                // On the ground before the post, facing it, a paw's reach from it.
                let facing = simd_dot(simd_normalize(-Vec2(spot.at.x, spot.at.z)), spot.toward)
                #expect(spot.at.y == 0 && facing > 0.99 && hypot(spot.at.x, spot.at.z) < 1.5, "\(id)")
            }
        }
        for id in ["cat.yarn", "flower.daisy", "tree.oak", "stone.stone"] { #expect(MeadowScenery.catSpot(of: id) == nil, "\(id)") }
        // In the meadow: turned with the thing, on the land where it stands (a quarter turn takes its own z to x).
        let post = MeadowScenery.Thing(id: "cat.scratchingPost", x: 10, z: -4, turn: .pi / 2)
        let spot = try #require(post.catSpot), own = try #require(MeadowScenery.catSpot(of: "cat.scratchingPost"))
        #expect(spot.kind == .scratch && abs(spot.at.y - Land.height(spot.at.x, spot.at.z)) < 1e-4)
        #expect(simd_distance(Vec2(spot.at.x, spot.at.z), Vec2(10 + own.at.z, -4 - own.at.x)) < 1e-3, "\(spot.at)")
        #expect(simd_distance(spot.toward, Vec2(own.toward.y, -own.toward.x)) < 1e-3, "\(spot.toward)")
        #expect(MeadowScenery.Thing(id: "flower.daisy", x: 0, z: 0).catSpot == nil)
    }

    @Test("as a thing is first placed, no cat at it shows the editor's or the sidebar's camera its back")
    func catSpotsFaceTheCamera() {
        // Both look from +z, the editor a little round (`MapCamera.bearing`); a cat side on (scratching at a post, its
        // face to the post and turned your way) is not its back.
        for (id, spot) in SceneryCatalog.catSpots {
            for bearing in [Float(0), MapCamera.bearing] {
                let toYou = Vec2(sin(bearing), cos(bearing))
                #expect(simd_dot(spot.toward, toYou) > -0.15, "\(id) faces \(spot.toward), its back to a camera from \(bearing)")
            }
        }
    }

    @Test("each has a picture for the tray, unlike every other's")
    @MainActor func pictures() throws {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), mode: .meadow)
        let background = MeadowColor(hex: 0xf4f1ea)
        var seen: [Data: String] = [:]
        for id in stageSeven {
            let picture = try #require(view.portrait(of: [id], pixels: 96, background: background), "\(id)")
            let bytes = picture.dataProvider!.data! as Data
            #expect(seen[bytes] == nil, "\(id) pictured as \(seen[bytes] ?? "")")
            seen[bytes] = id
            // Its subject reads on its tile: it fills the tile its longer way (a tall pine tall, a wide bed wide), and
            // is a solid share of the box it fills, not a speck or a scribble (a slender flower less than a solid thing,
            // as the meadow's own daisies). What is unlike the tile's colour is the subject.
            let pixels = [UInt8](bytes)
            var unlike = 0, lo = SIMD2(96, 96), hi = SIMD2(-1, -1)
            for y in 0..<96 {
                for x in 0..<96 {
                    let i = y * picture.bytesPerRow + x * 4
                    guard abs(Int(pixels[i + 2]) - 0xf4) + abs(Int(pixels[i + 1]) - 0xf1) + abs(Int(pixels[i]) - 0xea) > 60 else { continue }
                    unlike += 1
                    lo = SIMD2(min(lo.x, x), min(lo.y, y)); hi = SIMD2(max(hi.x, x), max(hi.y, y))
                }
            }
            let box = SIMD2(hi.x - lo.x + 1, hi.y - lo.y + 1)
            #expect(max(box.x, box.y) >= 58, "\(id): spans \(box.x) by \(box.y) of 96")
            #expect(unlike * (id.hasPrefix("flower.") ? 8 : 4) > box.x * box.y, "\(id): \(unlike) of the \(box.x * box.y) it spans")
        }
    }

    @Test("a meadow at its limits with the new things draws them in a bed per shape, the trees each their own")
    func atTheLimits() {
        var things: [MeadowScenery.Thing] = []
        for i in 0..<MeadowScenery.Limits.things {
            let id = stageSeven[i % stageSeven.count]
            let x = Float(i % 70) * 4 - 140, z = Float(i / 70) * 4 - 140
            things.append(MeadowScenery.Thing(id: id, x: x, z: z, seed: UInt32(i % 7)))
        }
        let m = Meadow(scenery: MeadowScenery(things: things))
        let rooted = m.beds.reduce(0) { $0 + $1.matrices.count }
        #expect(m.treeShapes.count == MeadowScenery.Limits.trees, "\(m.treeShapes.count) trees")
        #expect(m.beds.count == stageSeven.count - 2, "one bed per shape: \(m.beds.count)")
        #expect(rooted + m.treeShapes.count == m.laid.filter { $0 != .none }.count)
    }
}

// MARK: Pictures (MEADOW_SNAPSHOTS)

/// Contact sheets of the Stage 7 models, for looking at: each alone in the meadow, from the editor's height and
/// close up, by day, at dusk and by night; and the ground's paints the same way. Written only when
/// MEADOW_SNAPSHOTS names a folder.
@MainActor
@Suite(.serialized) struct CatalogPictures {
    nonisolated static let folder = ProcessInfo.processInfo.environment["MEADOW_SNAPSHOTS"]

    /// Where each model stands in the sheet's meadow: in rows, well apart, all on the level ground.
    static func spots(_ ids: [String]) -> [String: SIMD2<Float>] {
        Dictionary(uniqueKeysWithValues: ids.enumerated().map { k, id in (id, SIMD2(Float(k % 5) * 26 - 52, Float(k / 5) * 26 - 39)) })
    }

    static func view(_ scenery: MeadowScenery, time: MeadowSettings.TimeOfDay) -> MeadowView {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), mode: .meadow)
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: time)
        view.scenery = scenery
        view.advance(seconds: 1)
        return view
    }

    static func shot(_ view: MeadowView, at spot: SIMD2<Float>, distance: Float, pitch: Float) -> CGImage? {
        view.stage.camera.setView(CameraView(x: spot.x, z: spot.y, distance: distance, pitch: pitch, bearing: 0.45))
        return view.renderImage(width: 480, height: 360)
    }

    /// Pictures in a grid with a caption under each, as one PNG in `folder`.
    static func sheet(_ pictures: [(String, CGImage)], columns: Int, to name: String, in folder: String? = CatalogPictures.folder) {
        guard let folder, !pictures.isEmpty else { return }
        let w = pictures[0].1.width, h = pictures[0].1.height, caption = 26
        let rows = (pictures.count + columns - 1) / columns
        let width = columns * w, height = rows * (h + caption)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for (k, (label, image)) in pictures.enumerated() {
            let x = (k % columns) * w, top = height - (k / columns) * (h + caption)
            context.draw(image, in: CGRect(x: x, y: top - h, width: w, height: h))
            (label as NSString).draw(at: NSPoint(x: x + 8, y: top - h - caption + 6), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.current = nil
        guard let image = context.makeImage(),
              let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: folder).appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(out, image, nil)
        CGImageDestinationFinalize(out)
    }

    static let moods: [(String, MeadowSettings.TimeOfDay)] = [("day", .day), ("dusk", .hour(19.6)), ("night", .night)]

    @Test(.enabled(if: folder != nil)) func models() {
        let spots = Self.spots(stageSeven)
        var things: [MeadowScenery.Thing] = []
        for id in stageSeven {
            let at = spots[id]!
            things.append(MeadowScenery.Thing(id: id, x: at.x, z: at.y, turn: 0.5, seed: 1))
            // Plants as the Brush lays them: a loose clump round the one in the middle.
            guard SceneryRules.isSmall(id) else { continue }
            for k in 1..<8 {
                let a = Float(k) * 2.4, out = 0.9 + 0.35 * Float(k)
                things.append(MeadowScenery.Thing(id: id, x: at.x + cos(a) * out, z: at.y + sin(a) * out, turn: a, size: Vec3(repeating: 0.85 + 0.04 * Float(k % 4))))
            }
        }
        let scenery = MeadowScenery(things: things)
        for (mood, time) in Self.moods {
            let view = Self.view(scenery, time: time)
            var far: [(String, CGImage)] = [], near: [(String, CGImage)] = []
            for id in stageSeven {
                let tall = budgets[id]!.height.upperBound, spot = spots[id]!
                let distance: Float = SceneryRules.isBig(id) ? 70 : 34
                if let image = Self.shot(view, at: spot, distance: distance, pitch: 0.96) { far.append((id, image)) }
                if let image = Self.shot(view, at: spot, distance: max(5, tall * 2.4), pitch: 0.42) { near.append((id, image)) }
            }
            Self.sheet(far, columns: 5, to: "models-editor-\(mood)")
            Self.sheet(near, columns: 5, to: "models-close-\(mood)")
        }
        // The tray's pictures, on the tile's colour of each look.
        let view = Self.view(scenery, time: .day)
        for (look, hex) in [("light", UInt32(0xffffff)), ("dark", 0x2a2826), ("graphite", 0x232326)] {
            let tiles = stageSeven.compactMap { id in view.portrait(of: [id], pixels: 256, background: MeadowColor(hex: hex)).map { (id, $0) } }
            Self.sheet(tiles, columns: 5, to: "models-tray-\(look)")
        }
    }

    /// Each model's triangles, beside the Default's own kinds for comparison.
    @Test(.enabled(if: folder != nil)) func triangles() throws {
        let ids = stageSeven + ["tree.oak", "tree.birch", "tree.cherry", "tree.young", "flower.daisy", "flower.lupin", "fungus.flyAgaric", "stone.stone", "wood.fallenLog"]
        let table = ids.compactMap { id in model(id).map { "\(id)\t\($0.indices.count / 3)" } }.joined(separator: "\n")
        try (table + "\n").write(toFile: URL(fileURLWithPath: Self.folder!).appendingPathComponent("triangles.txt").path, atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: folder != nil)) func ground() {
        var g = MeadowScenery.Ground()
        for row in 0..<MeadowScenery.Ground.side {
            for column in 0..<MeadowScenery.Ground.side {
                let p = SIMD2<Float>(-150 + (Float(column) + 0.5) * MeadowScenery.Ground.cell, -150 + (Float(row) + 0.5) * MeadowScenery.Ground.cell)
                // A path winding past a bed of soil, a lawn beyond.
                if abs(p.y - 4 * sin(p.x * 0.12)) < 1.6, abs(p.x) < 30 { g[column, row] = .path }
                if abs(p.x - 6) < 5, p.y > 5, p.y < 15 { g[column, row] = .soil }
                if abs(p.x + 14) < 7, p.y > 5, p.y < 17 { g[column, row] = .lawn }
            }
        }
        let scenery = MeadowScenery(things: [MeadowScenery.Thing(id: "flower.foxglove", x: 6, z: 10), MeadowScenery.Thing(id: "flower.cornflower", x: 4, z: 8),
                                             MeadowScenery.Thing(id: "plant.clover", x: 8, z: 12)], ground: g)
        var pictures: [(String, CGImage)] = []
        for (mood, time) in Self.moods {
            let view = Self.view(scenery, time: time)
            if let image = Self.shot(view, at: SIMD2(-2, 6), distance: 60, pitch: 0.96) { pictures.append(("\(mood), editor", image)) }
            if let image = Self.shot(view, at: SIMD2(2, 4), distance: 13, pitch: 0.5) { pictures.append(("\(mood), close", image)) }
            if let image = Self.shot(view, at: SIMD2(2, 4), distance: 9, pitch: 1.25) { pictures.append(("\(mood), above", image)) }
        }
        Self.sheet(pictures, columns: 3, to: "ground")
        let view = Self.view(scenery, time: .day)
        let tiles = MeadowScenery.Ground.Paint.allCases.compactMap { paint in view.portrait(of: [paint.id], pixels: 256, background: MeadowColor(hex: 0xffffff)).map { (paint.id, $0) } }
        Self.sheet(tiles, columns: 4, to: "ground-tray")
    }
}
