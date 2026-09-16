import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// Trees read as foliage from every camera, never as a few smooth balloons: each crown is many masses of leaves of
// different sizes, its outline from above broken and gapped, its fruit small among the leaves, and none of it
// costing more than the trees it replaced.

/// Each kind's trees as the catalog grows them, from a few seeds.
private let kinds = TreePictures.ids
private func grown(_ id: String, _ seed: UInt32) -> Tree {
    var random = Seeded(seed &* 2_654_435_761)
    return Trees.grow(SceneryCatalog.species(id)!, &random)
}

/// What each kind may cost at most, in triangles on average: never more than the trees before them (oak 11.6k,
/// birch 9.9k, cherry 11.6k, young 8.1k, apple 21.7k, pine 22.7k), the heavy apple and pine well under.
private let triangleBudgets = ["tree.oak": 11_700, "tree.birch": 9_000, "tree.cherry": 11_600, "tree.young": 4_000, "tree.apple": 15_500, "tree.pine": 12_000]

/// The share of the ground under a crown that its leaves cover seen from straight above, and how ragged their
/// outline is there: the perimeter of the covered cells squared over 4π times their area (1 for a disc; holes
/// and a broken edge raise it). Drawn at `cells` across the crown's width.
private func fromAbove(_ tree: Tree, cells: Int = 96) -> (cover: Float, ragged: Float) {
    let g = tree.shape, reach = tree.crown, size = 2 * reach / Float(cells)
    var filled = [Bool](repeating: false, count: cells * cells)
    // Only the leaves: green or blossom, high in the tree (not bark, fruit or windfalls).
    func leaf(_ i: Int) -> Bool {
        let c = g.colors[i]
        return g.positions[i].y > tree.middle.y - tree.bulk && (c.y > c.x * 1.1 || c.x > c.y * 1.1 && c.z > c.y)
    }
    func edge(_ u: Vec2, _ v: Vec2, _ q: Vec2) -> Float { (v.x - u.x) * (q.y - u.y) - (v.y - u.y) * (q.x - u.x) }
    var t = 0
    while t + 2 < g.indices.count {
        let corners = [Int(g.indices[t]), Int(g.indices[t + 1]), Int(g.indices[t + 2])]
        t += 3
        guard corners.allSatisfy(leaf) else { continue }
        let p = corners.map { Vec2((g.positions[$0].x + reach) / size, (g.positions[$0].z + reach) / size) }
        let lo = simd_max(simd_min(simd_min(p[0], p[1]), p[2]).rounded(.down), .zero)
        let hi = simd_min(simd_max(simd_max(p[0], p[1]), p[2]).rounded(.up), Vec2(repeating: Float(cells - 1)))
        let area = edge(p[0], p[1], p[2])
        guard lo.x <= hi.x, lo.y <= hi.y, abs(area) > 1e-6 else { continue }
        for y in Int(lo.y)...Int(hi.y) {
            for x in Int(lo.x)...Int(hi.x) {
                let q = Vec2(Float(x) + 0.5, Float(y) + 0.5)
                if edge(p[1], p[2], q) / area >= 0, edge(p[2], p[0], q) / area >= 0, edge(p[0], p[1], q) / area >= 0 { filled[y * cells + x] = true }
            }
        }
    }
    var area = 0, perimeter = 0, disc = 0
    for y in 0..<cells {
        for x in 0..<cells {
            if simd_length(Vec2(Float(x) + 0.5, Float(y) + 0.5) * size - reach) <= reach { disc += 1 }
            guard filled[y * cells + x] else { continue }
            area += 1
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx < 0 || ny < 0 || nx >= cells || ny >= cells || !filled[ny * cells + nx] {
                perimeter += 1
            }
        }
    }
    return (Float(area) / Float(max(disc, 1)), Float(perimeter * perimeter) / (4 * .pi * Float(max(area, 1))))
}

@Suite struct TreeShapes {
    @Test("each kind's crown is many masses of leaves of clearly different sizes, none a large part of it", arguments: kinds)
    func masses(_ id: String) {
        let species = SceneryCatalog.species(id)!
        for seed in UInt32(1)...4 {
            let tree = grown(id, seed), sizes = tree.masses.map(\.radius)
            let small = sizes.min() ?? 0, large = sizes.max() ?? 0
            #expect(tree.masses.count >= max(7, species.crown.masses * 4 / 5), "\(id) \(seed): \(tree.masses.count) masses")
            #expect(large >= small * 1.4, "\(id) \(seed): masses from \(small) to \(large)")
            #expect(large <= tree.crown * 0.42, "\(id) \(seed): a mass of \(large) in a crown of \(tree.crown)")
        }
    }

    @Test("seen from straight above, a crown's outline is broken and gapped, not a disc", arguments: kinds)
    func outlineFromAbove(_ id: String) {
        for seed in UInt32(1)...3 {
            let seen = fromAbove(grown(id, seed))
            #expect(seen.ragged > 3, "\(id) \(seed): outline \(seen.ragged) times a disc's")
            #expect(seen.cover > 0.12 && seen.cover < 0.85, "\(id) \(seed): covers \(seen.cover) of the ground under it")
        }
    }

    @Test("apples are small beside the crown and hang among the leaves, never on top of them")
    func applesAmongTheLeaves() {
        let apple = Geometry.join(Trees.apple(at: .zero, red: true)).bounds
        for seed in UInt32(1)...4 {
            let tree = grown("tree.apple", seed), g = tree.shape
            #expect(apple.max.x - apple.min.x <= tree.crown * 0.08, "an apple \(apple.max.x - apple.min.x) across, the crown \(tree.crown)")
            // Red where the apples are: some in the tree, none above its leaves.
            let reds = g.positions.indices.filter { g.colors[$0].x > g.colors[$0].y * 2.5 && g.positions[$0].y > 1 }
            let top = tree.masses.map { $0.center.y + $0.radius }.max() ?? 0
            #expect(!reds.isEmpty && reds.allSatisfy { g.positions[$0].y < top }, "\(seed)")
        }
    }

    @Test("each kind grows the same from the same seed and another from another, within its budget of triangles", arguments: kinds)
    func seedsAndBudget(_ id: String) {
        let species = SceneryCatalog.species(id)!
        #expect(grown(id, 3).shape.positions == grown(id, 3).shape.positions)
        #expect(grown(id, 3).shape.positions != grown(id, 4).shape.positions)
        let triangles = (UInt32(0)..<8).map { grown(id, $0).shape.indices.count / 3 }
        #expect(triangles.reduce(0, +) / triangles.count <= triangleBudgets[id]!, "\(id): \(triangles)")
        // Its measures still frame it: its shade reaches past its limbs, its middle is among its leaves.
        let tree = grown(id, 3)
        #expect(tree.crown >= species.reach && tree.middle.y > species.crown.low && tree.middle.y < species.crown.high, "\(id)")
    }

    @Test("the Default's young trees and landmark trees leave the meadow's stream where it always was")
    func defaultStream() {
        #expect(StandardMeadow.treeDraws.landmarks.count == StandardMeadow.landmarks.count && StandardMeadow.treeDraws.young.count == 3)
        #expect(StandardMeadow.grown.end == StandardMeadow.end)
    }
}

// MARK: Pictures (TREE_PICTURES)

/// The trees as people see them, for looking at: from the editor's own framing (about 55° above, the picnic
/// ground framed, a blanket and its cats beside for scale), from a sidebar's column, close up from the side,
/// at dusk and by night, and together in a grove and in the Default. Written only when TREE_PICTURES names a
/// folder; the same cameras every time, so pictures from two versions compare.
@MainActor
@Suite(.serialized) struct TreePictures {
    nonisolated static let folder = ProcessInfo.processInfo.environment["TREE_PICTURES"]
    nonisolated static let ids = ["tree.oak", "tree.birch", "tree.cherry", "tree.young", "tree.apple", "tree.pine"]
    /// Where a lone tree stands: beside the picnic ground, in the editor's framing.
    static let spot = SIMD2<Float>(17, -14)
    static let window = NSSize(width: 1440, height: 900)

    static func world(_ blankets: Int = 2) -> MeadowWorld {
        let cats: [MeadowAgent] = [MeadowAgent(id: "main", activity: .reading), MeadowAgent(id: "help", parentID: "main", activity: .running)]
        return MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: (0..<blankets).map {
            MeadowBlanket(id: "b\($0)", title: "", color: .account($0), agents: $0 == 0 ? cats : [MeadowAgent(id: "main", activity: .napping)])
        })])])
    }

    /// The editor at its own framing: the window's size, the tray along its bottom, settled.
    static func editor(_ scenery: MeadowScenery, time: MeadowSettings.TimeOfDay = .day) -> MeadowView {
        let view = MeadowView(frame: NSRect(origin: .zero, size: window), mode: .meadow)
        view.settings = MeadowSettings(timeOfDay: time, effects: MeadowSettings.Effects.all.subtracting(.moonPhase))
        view.world = world()
        view.scenery = scenery
        view.advance(seconds: 0.5)
        view.beginEditing()
        view.editingCover = 230
        view.frameEditView()
        view.advance(seconds: 3)
        return view
    }

    /// A part of the view at 2× round a spot on the ground, `w` by `h` points, the spot `below` points under its middle.
    static func crop(_ view: MeadowView, _ image: CGImage, at spot: SIMD2<Float>, w: CGFloat, h: CGFloat, below: CGFloat) -> CGImage? {
        guard let p = view.viewPoint(ofGround: spot) else { return nil }
        let scale = CGFloat(image.width) / view.bounds.width
        let x = (p.x - w / 2) * scale, y = (view.bounds.height - p.y - h + below) * scale
        let rect = CGRect(x: x, y: y, width: w * scale, height: h * scale).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return image.cropping(to: rect.integral)
    }

    static func lone(_ id: String, seed: UInt32 = 7) -> MeadowScenery {
        MeadowScenery(things: [MeadowScenery.Thing(id: id, x: spot.x, z: spot.y, turn: 0.4, seed: seed)])
    }

    /// Several of each kind round the picnic ground, as a meadow edited by hand holds them.
    static let grove: MeadowScenery = {
        var things: [MeadowScenery.Thing] = []
        let ring: [(String, Float, Float)] = [("tree.oak", -26, -18), ("tree.apple", -6, -26), ("tree.birch", 14, -26), ("tree.pine", 30, -20), ("tree.cherry", 30, 2),
                                              ("tree.young", 20, 12), ("tree.apple", -28, 4), ("tree.oak", -40, -34), ("tree.pine", 6, -44), ("tree.birch", -16, -40),
                                              ("tree.cherry", 44, -38), ("tree.young", -18, 14), ("tree.young", 24, -6)]
        for (k, (id, x, z)) in ring.enumerated() { things.append(MeadowScenery.Thing(id: id, x: x, z: z, turn: Float(k), seed: UInt32(11 + k * 7))) }
        return MeadowScenery(things: things)
    }()

    @Test(.enabled(if: folder != nil)) func editorCamera() {
        var crops: [(String, CGImage)] = [], wide: [(String, CGImage)] = []
        for id in Self.ids {
            let view = Self.editor(Self.lone(id))
            guard let image = view.renderImage(width: Int(Self.window.width * 2), height: Int(Self.window.height * 2)) else { continue }
            if let c = Self.crop(view, image, at: Self.spot, w: 300, h: 300, below: 70) { crops.append((id, c)) }
            if let c = Self.crop(view, image, at: SIMD2(Self.spot.x - 12, Self.spot.y + 8), w: 720, h: 450, below: 160) { wide.append((id, c)) }
        }
        CatalogPictures.sheet(crops, columns: 3, to: "editor-crop", in: Self.folder)
        CatalogPictures.sheet(wide, columns: 2, to: "editor-wide", in: Self.folder)
    }

    @Test(.enabled(if: folder != nil)) func moods() {
        for (mood, time) in [("dusk", MeadowSettings.TimeOfDay.hour(19.6)), ("night", .night)] {
            var crops: [(String, CGImage)] = []
            for id in Self.ids {
                let view = Self.editor(Self.lone(id), time: time)
                guard let image = view.renderImage(width: Int(Self.window.width * 2), height: Int(Self.window.height * 2)) else { continue }
                if let c = Self.crop(view, image, at: Self.spot, w: 300, h: 300, below: 70) { crops.append((id, c)) }
            }
            CatalogPictures.sheet(crops, columns: 3, to: "editor-\(mood)", in: Self.folder)
        }
    }

    @Test(.enabled(if: folder != nil)) func closeUp() {
        var pictures: [(String, CGImage)] = []
        for id in Self.ids {
            let view = Self.editor(Self.lone(id))
            let tall: Float = id == "tree.pine" ? 30 : id == "tree.young" ? 9 : id == "tree.apple" ? 11 : 24
            // The view looks at a cat's height over the ground: from far enough back that the whole crown is in it.
            for (label, pitch, back) in [("side", Float(0.02), Float(4.2)), ("high", 0.96, 2.6)] {
                view.stage.camera.setView(CameraView(x: Self.spot.x, z: Self.spot.y, distance: min(tall * back, 100), pitch: pitch, bearing: 0.45))
                view.advance(seconds: 0.1)
                if let image = view.renderImage(width: 720, height: 540) { pictures.append(("\(id) \(label)", image)) }
            }
        }
        CatalogPictures.sheet(pictures, columns: 4, to: "close", in: Self.folder)
    }

    @Test(.enabled(if: folder != nil)) func sidebar() {
        var pictures: [(String, CGImage)] = []
        for id in Self.ids {
            let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 820), mode: .meadow)
            view.settings = MeadowSettings(timeOfDay: .day, effects: MeadowSettings.Effects.all.subtracting(.moonPhase))
            view.world = Self.world(3)
            view.scenery = MeadowScenery(things: [MeadowScenery.Thing(id: id, x: -13, z: 9, turn: 0.4, seed: 7), MeadowScenery.Thing(id: id, x: 13, z: -3, turn: 1.4, seed: 8)])
            view.advance(seconds: 0.5)
            view.frame(nil, besidePanelWidth: 0, animated: false)
            view.advance(seconds: 3)
            if let image = view.renderImage(width: 600, height: 1640) { pictures.append((id, image)) }
        }
        CatalogPictures.sheet(pictures, columns: 6, to: "sidebar", in: Self.folder)
    }

    @Test(.enabled(if: folder != nil)) func together() {
        var pictures: [(String, CGImage)] = []
        for (name, scenery) in [("grove", Self.grove), ("default", MeadowScenery.standard)] {
            for (mood, time) in [("day", MeadowSettings.TimeOfDay.day), ("dusk", .hour(19.6))] {
                let view = Self.editor(scenery, time: time)
                if let image = view.renderImage(width: Int(Self.window.width * 2), height: Int(Self.window.height * 2)) { pictures.append(("\(name) \(mood)", image)) }
            }
        }
        CatalogPictures.sheet(pictures, columns: 2, to: "together", in: Self.folder)
    }

    @Test(.enabled(if: folder != nil)) func tray() {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), mode: .meadow)
        let tiles = Self.ids.compactMap { id in view.portrait(of: [id], pixels: 256, background: MeadowColor(hex: 0xffffff)).map { (id, $0) } }
        CatalogPictures.sheet(tiles, columns: 6, to: "tray", in: Self.folder)
    }

    @Test(.enabled(if: folder != nil)) func triangles() throws {
        var lines: [String] = []
        for id in Self.ids {
            let counts = (0..<8).map { seed -> Int in
                var random = Seeded(UInt32(seed) &* 2_654_435_761)
                return Trees.grow(SceneryCatalog.species(id)!, &random).shape.indices.count / 3
            }
            lines.append("\(id)\tmean \(counts.reduce(0, +) / counts.count)\tmax \(counts.max()!)")
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: URL(fileURLWithPath: Self.folder!).appendingPathComponent("triangles.txt").path, atomically: true, encoding: .utf8)
    }
}
