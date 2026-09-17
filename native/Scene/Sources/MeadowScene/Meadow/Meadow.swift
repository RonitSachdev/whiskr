import Foundation
import simd

// Port of src/meadow/Meadow.ts: the world the cats live in, a spring meadow at cat scale, in the same
// matte clay as the cat. The grass, hills, clouds, stars, butterflies, fireflies and rain grow from the
// meadow's own seeds, in the same order as the web version. The scenery (trees, flowers, mushrooms,
// stones, the log) is whatever `MeadowScenery` it is given: the Default (`StandardMeadow`) unless told
// otherwise. A new scenery is laid when it is given, never per frame.

/// A circle of ground: a blanket's clearing, or ground blankets must keep off.
struct Clearing: Equatable { var x: Float; var z: Float; var r: Float }

/// Instances of one plant shape, each placed with its own lean and size.
struct Bed {
    var plant: Int              // index into Meadow.plants
    var sway: Float
    var matrices: [Mat4]
    /// Young trees and lamps: each can fade on its own when it stands in the way; index of its screen.
    var screens: [Int]? = nil
    /// Lamps: which of the meadow's lamps (`MeadowLamps.lamps`) each is.
    var lamps: [Int]? = nil
}

/// One shape a thing is drawn with: its id, which of its shapes, and the seed it grew from.
/// For a fence's parts, `variant` is the part (`Fences.Part`); for a whole run on its own (the editor's ghost), its
/// points and gate.
struct ShapeKey: Hashable { var id: String; var variant = 0; var seed: UInt32 = 0; var swatch = 0; var run: [Vec2] = []; var gate = 0 }

/// Trees grown from their seeds, kept so a tree is never grown twice.
struct Grove {
    typealias Key = ShapeKey
    private(set) var trees: [Key: Tree] = [:]

    init(_ trees: [Key: Tree] = [:]) { self.trees = trees }

    mutating func tree(_ key: Key, _ species: Species) -> Tree {
        if let tree = trees[key] { return tree }
        var random = Seeded(key.seed)
        let tree = Trees.grow(species, &random)
        trees[key] = tree
        return tree
    }

    /// Lets go of every tree but those in `keys`.
    mutating func keep(_ keys: Set<Key>) { trees = trees.filter { keys.contains($0.key) } }
}

final class Meadow {
    /// The meadow's own stream: the grass, then the Default's scenery (`StandardMeadow`), then the critters.
    static let seed: UInt32 = 20_261_112
    static let fireflies = 14
    static let fall = (drops: 700, wide: Float(50), tall: Float(26))
    /// How far past a hill's foot the view's eye must be for the hill to stand at its whole height.
    static let hillClearOfEye: Float = 40

    private(set) var random = Seeded(0)
    let grass: (tufts: [GrassField.Tuft], chunks: [GrassField.Chunk])
    /// What the meadow holds, as it was given.
    private(set) var scenery = MeadowScenery.empty
    /// Counts the sceneries laid, so the meshes drawn from them are made when they change.
    private(set) var sceneryVersion = 0
    /// Counts the ground's maps baked whole, so the map drawn is replaced when it changes.
    private(set) var groundVersion = 0
    private var grove = Grove()
    /// Every plant shape (flowers, mushrooms, stones, young trees) by index, and what each is.
    private(set) var plants: [Plant] = []
    private(set) var plantKeys: [ShapeKey] = []
    private(set) var beds: [Bed] = []
    /// Landmark trees, each its own mesh: shape, what it is, where it stands, its turn, lean and size
    /// about its root, its screen, and how far round its trunk it stands on the ground.
    private(set) var treeShapes: [(shape: Geometry, key: ShapeKey, at: Vec3, pose: Mat4, screen: Int, foot: Float)] = []
    /// Fallen logs: where each lies, its screen, and the ground along it (as blankets see it).
    private(set) var logs: [(matrix: Mat4, screen: Int, foot: [Clearing])] = []
    /// Where each of the scenery's things went when it was laid, in its order.
    private(set) var laid: [Laid] = []
    /// The flowers' tops, where butterflies and bees settle, and which is whose (-1: none).
    private var blooms: [Vec3] = []
    private var bloomOf: [Int] = []
    private(set) var hills: [(Mat4, Vec3)] = []
    private(set) var clouds: [Mat4] = []
    private(set) var stars: [Vec3] = []
    private(set) var screens: [Screen] = []
    /// Ground a blanket must not be laid on: round the roots of every tree, and along each fallen log.
    private(set) var obstacles: [Clearing] = []
    /// Trees whose shade dapples the ground: x, z, reach.
    private(set) var shade: [Vec4] = []
    /// Stones walked on (stepping stones), which wear the turf round them; and which of the scenery's things
    /// each is, by its index there.
    private(set) var treads: [GroundMap.Tread] = []
    private var treadOf: [Int: Int] = [:]
    /// The ground's map, baked from the scenery when it is laid (`GroundMap`).
    private(set) var groundMap = GroundMap()
    /// The part of the ground's map changed since it was last drawn by moving trees (nil: none); a new
    /// scenery bakes it whole (`sceneryVersion`).
    private var groundChanged: GroundMap.Region?
    /// The garden lamps, lit after dark, and the part of the map's lamplight baked since it was last drawn.
    private(set) var lamps = MeadowLamps()
    private var lightChanged: GroundMap.Region?
    /// The lamps as the map bakes them, kept so baking allocates nothing.
    private var lampLights: [GroundMap.Lamp] = []
    private(set) var critters: Critters!
    private(set) var fireflyWays: [(angle: Float, spin: Float, out: Float, high: Float, phase: Float, pulse: Float)] = []
    /// This frame's fireflies: position and glow.
    private(set) var fireflies: [Vec4] = []
    private(set) var drops: [Vec3] = []
    private(set) var cloudTurn: Float = 0

    /// A meadow holding `scenery`; nil for the Default (whose trees were grown with it, so none is grown twice).
    init(scenery: MeadowScenery? = nil) {
        var random = Seeded(Self.seed)
        grass = GrassField.grow(&random)
        buildHills()
        buildClouds()
        if scenery == nil { grove = Grove(StandardMeadow.grown.trees) }
        let blooms = lay(scenery ?? .standard)
        // The butterflies, fireflies and rain go on from where the Default's scenery left the stream, so
        // they are the same whatever the meadow holds.
        var ambient = Seeded(StandardMeadow.end)
        critters = Critters(&ambient, blooms: blooms)

        // Night: a sky full of stars riding with the camera, and fireflies round the picnics. The stars are
        // thickest low down, where a view tilted low sees the sky over the far hills (the hills and trees
        // hide those below them); they come from a sequence of their own, so everything grown after them
        // stands where it always did.
        var sky = Seeded(43)
        for k in 0..<1300 {
            // Most in the band from 6° below level to 8° above, the rest scattered up to 70°.
            let up = (k < 1000 ? -6 + 14 * sky.float() : 8 + 62 * sky.float()) * Float.pi / 180, around = sky.float() * .pi * 2
            stars.append(Vec3(cos(around) * cos(up) * 430, sin(up) * 430, sin(around) * cos(up) * 430))
        }
        for _ in 0..<(600 * 2) { _ = ambient.float() }
        for _ in 0..<(24 * Self.fireflies) {
            let angle = ambient.float() * .pi * 2
            let spin = (ambient.float() < 0.5 ? -1 : 1) * (0.06 + ambient.float() * 0.16)
            let out = ambient.float(), high = ambient.float(), phase = ambient.float() * .pi * 2, pulse = 0.55 + ambient.float() * 0.7
            fireflyWays.append((angle, spin, out, high, phase, pulse))
        }
        for _ in 0..<Self.fall.drops {
            let x = (ambient.float() - 0.5) * Self.fall.wide, y = ambient.float() * Self.fall.tall, z = (ambient.float() - 0.5) * Self.fall.wide
            drops.append(Vec3(x, y, z))
        }
        fireflies = [Vec4](repeating: .zero, count: MAX_CLEARINGS * Self.fireflies)
        self.random = ambient
    }

    /// Shows `scenery` instead of what the meadow holds now (nothing happens if it is the same). Trees
    /// already grown, shapes already made and how faded each tall thing is are kept. When only some things
    /// moved, turned, leant or changed size (an edit, a drag under way), only those are placed again and the
    /// ground's shade is baked again only where a tree moved; anything else lays the scenery afresh (the
    /// ground's map only if the trees' shade changed).
    /// A change of the painted ground alone (a stroke of the Ground tool) paints again only the cells that
    /// changed.
    func show(_ scenery: MeadowScenery) {
        guard scenery != self.scenery else { return }
        let ground = self.scenery.ground
        if scenery.things == self.scenery.things {
            self.scenery = scenery
        } else if !move(to: scenery) {
            critters.bloom(lay(scenery))
        }
        if scenery.ground != ground, let changed = GroundMap.difference(ground, scenery.ground) { repaint(changed) }
    }

    /// The painted ground and the wear round stones walked on painted again in `region`, to be drawn.
    private func repaint(_ region: GroundMap.Region) {
        let changed = groundMap.paint(scenery.ground, treads: treads, in: region)
        groundChanged = groundChanged.map { $0.union(changed) } ?? changed
    }

    /// The part of the ground's map moved trees have changed since this was last asked, and forgets it
    /// (nil: none). A scenery laid afresh is baked whole instead (`sceneryVersion`).
    func takeGroundChanges() -> GroundMap.Region? {
        defer { groundChanged = nil }
        return groundChanged
    }

    /// The obstacles the Default's scenery places (tree roots, the log), for layout tests without growing a meadow.
    static var obstaclesForTests: [Clearing] {
        MeadowScenery.standard.things.flatMap { thing in SceneryCatalog.kinds[thing.id].map { obstacles(of: thing, $0) } ?? [] }
    }

    // MARK: building

    private func buildHills() {
        // Broad, low and far away, turning blue-green as they recede into the haze.
        var r = Seeded(7)
        let near = linear(0xa9d486), far = linear(0xb4dccf)
        for i in 0..<14 {
            let angle = Float(i) / 14 * 2 * .pi + r.float() * 0.3
            let out = 170 + r.float() * 90, size = 34 + r.float() * 34
            hills.append((.translation(Vec3(cos(angle) * out, 3, sin(angle) * out)) * .scale(Vec3(size * 1.5, size * 0.3, size * 1.5)), mix(near, far, t: (out - 170) / 90)))
        }
    }

    private func buildClouds() {
        // Big cumulus low round the horizon, each a huddle of clay puffs.
        var r = Seeded(11)
        for i in 0..<13 {
            let angle = Float(i) / 13 * 2 * .pi + r.float() * 0.35
            let out = 190 + r.float() * 90, height = 50 + r.float() * 45, size = 11 + r.float() * 13
            let middle = Vec3(cos(angle) * out, height, sin(angle) * out)
            let count = 4 + Int(r.float() * 3)
            for p in 0..<count {
                let along = (Float(p) - Float(count - 1) / 2) * size * 0.75
                let lump = size * (0.62 + r.float() * 0.5) * (1 - abs(along) / (size * Float(count) * 0.75))
                let at = middle + Vec3(-sin(angle) * along, lump * 0.42, cos(angle) * along)
                clouds.append(.translation(at) * .scale(Vec3(lump, lump * 0.74, lump)))
            }
        }
    }

    /// A tree's place, gone down with the land where that is levelled for blankets.
    func treeAt(_ i: Int, _ clearings: [Vec4], _ count: Int) -> Vec3 { Land.levelled(treeShapes[i].at, clearings, count) }
    /// How a tree is drawn: its turn, lean and size about its root, standing where the land is.
    func treeMatrix(_ i: Int, _ clearings: [Vec4], _ count: Int) -> Mat4 { .translation(treeAt(i, clearings, count)) * treeShapes[i].pose }

    /// A far hill, sunk into the ground as far as blankets laid near it need (a long column can reach
    /// the hills): from its whole height down to none, as the land is levelled round it. It sinks too when
    /// the view backs off over it (a long column, or zoomed far out, tilted low), so it never fills the
    /// foreground between you and the meadow.
    func hill(_ i: Int, _ clearings: [Vec4], _ count: Int, eye: Vec3) -> Mat4 {
        let m = hills[i].0
        let middle = Vec3(m.columns.3.x, m.columns.3.y, m.columns.3.z), reach = m.columns.0.x, tall = m.columns.1.y
        var k = 1 - smoothstep(hypot(middle.x - eye.x, middle.z - eye.z) - reach, Self.hillClearOfEye, Self.hillClearOfEye + 60)
        for j in 0..<min(count, clearings.count) {
            let c = clearings[j]
            k = max(k, 1 - smoothstep(hypot(middle.x - c.x, middle.z - c.y) - max(c.z, 0) - reach, Land.flat, Land.flat + Land.blend))
        }
        return k > 0 ? .translation(Vec3(0, -(middle.y + tall) * k, 0)) * m : m
    }

    // MARK: laying the scenery

    /// Where a thing stands and how it is turned, leant and sized, on the land. A log was shaped lying on
    /// y = 0, a hair above where the land is cut (`Land.ground`), and keeps that hair wherever it lies.
    static func matrix(of thing: MeadowScenery.Thing, lift: Float = 0) -> Mat4 {
        .compose(Vec3(thing.x, Land.height(thing.x, thing.z) + lift, thing.z), euler: Vec3(thing.tilt.x, thing.turn, thing.tilt.y), scale: thing.size)
    }

    /// How much wider than its own a tree's footprint, shade and screen are.
    private static func spread(_ thing: MeadowScenery.Thing) -> Float { max(thing.size.x, thing.size.z) }

    /// The ground blankets keep off for a thing: round a tree's roots, along a log.
    static func obstacles(of thing: MeadowScenery.Thing, _ kind: SceneryCatalog.Kind) -> [Clearing] {
        switch kind {
        case .tree(let species):
            return [Clearing(x: thing.x, z: thing.z, r: species.girth * 3.2 * spread(thing))]
        case .log:
            let m = matrix(of: thing, lift: -Float(Land.ground))
            return [Float(-5), 0, 5].map { t in let p = m.point(Vec3(t, 1, 0)); return Clearing(x: p.x, z: p.z, r: 3) }
        case .fence:
            // Round each post (the loose arrangement's blankets keep clear of a fence).
            return Fences.posts(along: thing.points).map { Clearing(x: $0.at.x, z: $0.at.y, r: 0.8) }
        case .youngTree, .plant:
            return []
        }
    }

    /// Where one of the scenery's things went when it was laid.
    enum Laid: Equatable {
        /// Not drawn: the scene has no builder for it yet, or it stands past the meadow's reach or a limit.
        case none
        /// One instance of a bed (a plant, a mushroom, a stone, a young tree).
        case bed(Int, slot: Int)
        case tree(Int)
        case log(Int)
        /// A fence: its parts, in `runs`.
        case run(Int)
    }

    /// The lamplight baked again where it changed (a lamp warming up, placed, moved or carried as the ghost).
    private func bakeLight() {
        guard let region = lamps.takeChanged() else { return }
        lamps.lights(into: &lampLights)
        groundMap.light(lampLights, in: region)
        lightChanged = lightChanged.map { $0.union(region) } ?? region
    }

    /// The part of the map's lamplight baked since this was last asked, and forgets it (nil: none).
    func takeLightChanges() -> GroundMap.Region? {
        defer { lightChanged = nil }
        return lightChanged
    }

    /// The lamps moved on by `dt` seconds: lit while `lit` (the light says it is dark and lamps light at night),
    /// at once when `steady`; `ghost`, a lamp the editor is about to place, lit with them. Their light is baked
    /// where it changed.
    /// A lamp standing where a blanket has come shrinks away with its light, as rooted things do (`clearings`).
    func light(_ dt: Float, lit: Bool, steady: Bool, ghost: MeadowScenery.Thing?, clearings: [Vec4] = [], clearingCount: Int = 0) {
        lamps.update(dt, lit: lit, steady: steady)
        for i in lamps.lamps.indices {
            let lamp = lamps.lamps[i]
            lamps.stand(i, clearingCount > 0 ? Self.standing(lamp.x, lamp.z, 0, clearings, clearingCount) : 1)
        }
        lamps.carry(ghost.flatMap { Lamps.isLamp($0.id) ? Self.matrix(of: $0).point(Lamps.head) : nil })
        bakeLight()
    }

    /// One fence as it was laid: each part's bed and slot (in `Fences.parts`' order), where its posts stand, and
    /// the lines it draws across the ground (the spans a cat cannot pass, and its gate).
    struct Run {
        var parts: [(bed: Int, slot: Int)]
        var kinds: [Fences.Part]
        var posts: [Vec3]
        var lines: FenceLines.Run
    }
    private(set) var runs: [Run] = []
    /// Every fence's lines together, for whatever leads a cat about (`crossesFence`, the cats' routes): made again
    /// whenever a fence is laid, moved or taken away.
    private(set) var fences = FenceLines()

    /// Lays `scenery`: every thing the scene can draw, within its limits (`MeadowScenery.Limits`), in its
    /// order. Returns the flowers' tops, where butterflies and bees settle. The ground's map is baked again
    /// only when the trees' shade is not as it was (things added or taken away beside them leave it be).
    private func lay(_ scenery: MeadowScenery) -> [Vec3] {
        let oldPlants = Dictionary(zip(plantKeys, plants)) { first, _ in first }
        let oldTrees = Dictionary(treeShapes.map { ($0.key, $0.shape) }) { first, _ in first }
        let oldFades = Dictionary(screens.map { (ScreenKey($0), $0.fade) }) { first, _ in first }
        let oldShade = shade, oldTreads = treads
        var placedLamps: [(x: Float, z: Float, head: Vec3)] = []
        self.scenery = scenery
        plants = []; plantKeys = []; beds = []; treeShapes = []; logs = []; runs = []; screens = []; obstacles = []; shade = []; treads = []; treadOf = [:]
        laid = []; blooms = []; bloomOf = []
        laid.reserveCapacity(scenery.things.count)
        bloomOf.reserveCapacity(scenery.things.count)
        var bedOf: [ShapeKey: Int] = [:]
        var grown = Set<ShapeKey>()
        var things = 0, trees = 0, tall = 0, lit = 0
        typealias Limits = MeadowScenery.Limits

        func screen(_ s: Screen) -> Int {
            var s = s
            s.fade = oldFades[ScreenKey(s)] ?? 1
            screens.append(s)
            return screens.count - 1
        }
        func instance(_ key: ShapeKey, _ make: () -> Plant, sway: Float, _ matrix: Mat4, screened: Bool) -> (bed: Int, slot: Int) {
            let b: Int
            if let existing = bedOf[key] {
                b = existing
            } else {
                plants.append(oldPlants[key] ?? make())
                plantKeys.append(key)
                beds.append(Bed(plant: plants.count - 1, sway: sway, matrices: [], screens: screened ? [] : nil))
                b = beds.count - 1
                bedOf[key] = b
            }
            beds[b].matrices.append(matrix)
            return (b, beds[b].matrices.count - 1)
        }

        for thing in scenery.things {
            var placed = Laid.none, bloom = -1
            defer { laid.append(placed); bloomOf.append(bloom) }
            guard let kind = SceneryCatalog.kinds[thing.id], things < Limits.things, hypot(thing.x, thing.z) <= Limits.reach else { continue }
            switch kind {
            case .tree, .youngTree: guard trees < Limits.trees, tall < Limits.tall else { continue }; trees += 1; tall += 1
            case .log: guard tall < Limits.tall else { continue }; tall += 1
            case .plant where Lamps.isLamp(thing.id): guard lit < Limits.lamps, tall < Limits.tall else { continue }; lit += 1; tall += 1
            case .plant where SceneryCatalog.tall.contains(thing.id): guard tall < Limits.tall else { continue }; tall += 1
            case .plant: break
            case .fence: guard thing.points.count >= 2, thing.points.allSatisfy({ simd_length($0) <= Limits.reach }) else { continue }
            }
            things += 1
            obstacles += Self.obstacles(of: thing, kind)
            switch kind {
            case .tree(let species):
                let key = ShapeKey(id: thing.id, seed: thing.seed)
                let tree = grove.tree(key, species)
                grown.insert(key)
                let p = Self.treePlace(thing, species, tree)
                treeShapes.append((oldTrees[key] ?? tree.shape.roughened(0.85), key, p.at, p.pose, screen(p.screen), p.foot))
                shade.append(p.shade)
                placed = .tree(treeShapes.count - 1)
            case .youngTree(let species):
                let key = ShapeKey(id: thing.id, seed: thing.seed)
                let tree = grove.tree(key, species)
                grown.insert(key)
                let m = Self.matrix(of: thing)
                let at = instance(key, { Plant(shape: tree.shape.roughened(0.8), top: Vec3(0, 9, 0)) }, sway: 0, m, screened: true)
                beds[at.bed].screens?.append(screen(Self.youngScreen(m, species, tree)))
                placed = .bed(at.bed, slot: at.slot)
            case .plant(_, let sway, let blooming, _):
                let m = Self.matrix(of: thing)
                guard let shape = SceneryCatalog.shape(of: thing) else { continue }
                let screened = SceneryCatalog.tall.contains(thing.id)
                let at = instance(shape.key, shape.make, sway: sway, m, screened: screened)
                if Lamps.isLamp(thing.id) {
                    beds[at.bed].screens?.append(screen(Self.lampScreen(m)))
                    beds[at.bed].lamps = (beds[at.bed].lamps ?? []) + [placedLamps.count]
                    placedLamps.append((thing.x, thing.z, m.point(Lamps.head)))
                } else if screened {
                    let s = screen(Self.madeScreen(m, plants[beds[at.bed].plant]))
                    beds[at.bed].screens?.append(s)
                }
                if SceneryCatalog.isTread(thing.id) {
                    treadOf[laid.count] = treads.count
                    treads.append(Self.tread(thing))
                }
                if blooming {
                    blooms.append(m.point(plants[beds[at.bed].plant].top))
                    bloom = blooms.count - 1
                }
                placed = .bed(at.bed, slot: at.slot)
            case .log:
                let p = Self.logPlace(thing)
                logs.append((p.matrix, screen(p.screen), Self.obstacles(of: thing, kind)))
                placed = .log(logs.count - 1)
            case .fence:
                var run = Self.runPlace(thing)
                for part in Fences.parts(thing.points, gate: thing.gate) {
                    let key = ShapeKey(id: thing.id, variant: part.part.rawValue)
                    let at = instance(key, { Fences.shapes[part.part.rawValue] }, sway: 0, part.matrix, screened: false)
                    run.parts.append((at.bed, at.slot))
                    run.kinds.append(part.part)
                }
                runs.append(run)
                placed = .run(runs.count - 1)
            }
        }
        grove.keep(grown)
        lamps.lay(placedLamps)
        // The shade as it was (a plant brushed in or swept away, a thing taken away beside the trees): the
        // map stands, with any part still to be drawn from moved trees.
        if shade != oldShade || groundVersion == 0 {
            groundMap = GroundMap.baked(shade: shade, ground: scenery.ground, treads: treads)
            groundVersion += 1
            groundChanged = nil
            // A fresh map holds no light yet: the lamps' is baked into it whole (and drawn with it).
            _ = lamps.takeChanged()
            lamps.lights(into: &lampLights)
            groundMap.light(lampLights, in: .whole)
            lightChanged = nil
        } else if treads != oldTreads {
            // Stepping stones laid or taken up: the turf round each worn again, or grown back.
            let changed = Set(oldTreads).symmetricDifference(Set(treads)).compactMap(GroundMap.Region.init(tread:))
            if let first = changed.first { repaint(changed.dropFirst().reduce(first) { $0.union($1) }) }
        }
        fences = FenceLines(runs.map(\.lines))
        bakeLight()
        sceneryVersion += 1
        return blooms
    }

    /// The same things as now with only their places, turns, leans or sizes changed: each placed again where
    /// it is now, its screen moved (keeping how faded it is), the ground's shade baked again only where a
    /// tree moved. False, with nothing changed, when anything else differs (a thing added, removed or of
    /// another kind or shape, or one crossing the meadow's edge), which the scenery is laid afresh for.
    private func move(to new: MeadowScenery) -> Bool {
        let old = scenery
        guard new.things.count == old.things.count, laid.count == old.things.count else { return false }
        var changed: [Int] = []
        for i in new.things.indices where new.things[i] != old.things[i] {
            let a = old.things[i], b = new.things[i]
            guard a.id == b.id, a.seed == b.seed, a.variant == b.variant, a.swatch == b.swatch, a.gate == b.gate,
                  (hypot(a.x, a.z) <= MeadowScenery.Limits.reach) == (hypot(b.x, b.z) <= MeadowScenery.Limits.reach) else { return false }
            // A fence moved or turned whole keeps its parts; one reshaped (its posts not as many) is laid afresh.
            if case .run(let r) = laid[i] {
                guard b.points.allSatisfy({ simd_length($0) <= MeadowScenery.Limits.reach }),
                      Fences.parts(b.points, gate: b.gate).map(\.part) == runs[r].kinds else { return false }
            }
            changed.append(i)
        }
        scenery = new
        var shaded: GroundMap.Region?
        var worn: GroundMap.Region?
        var bloomsMoved = false
        var obstaclesMoved = false, fencesMoved = false
        for i in changed {
            let thing = new.things[i]
            switch laid[i] {
            case .none:
                continue
            case .bed(let b, let slot):
                let m = Self.matrix(of: thing)
                beds[b].matrices[slot] = m
                if let s = beds[b].screens?[slot] {
                    let fade = screens[s].fade
                    if case .youngTree(let species) = SceneryCatalog.kinds[thing.id] {
                        screens[s] = Self.youngScreen(m, species, grove.tree(ShapeKey(id: thing.id, seed: thing.seed), species))
                    } else if let lamp = beds[b].lamps?[slot] {
                        screens[s] = Self.lampScreen(m)
                        lamps.move(lamp, x: thing.x, z: thing.z, head: m.point(Lamps.head))
                    } else {
                        screens[s] = Self.madeScreen(m, plants[beds[b].plant])
                    }
                    screens[s].fade = fade
                }
                if bloomOf[i] >= 0 {
                    blooms[bloomOf[i]] = m.point(plants[beds[b].plant].top)
                    bloomsMoved = true
                }
                if let t = treadOf[i] {
                    for region in [GroundMap.Region(tread: treads[t]), GroundMap.Region(tread: Self.tread(thing))].compactMap({ $0 }) {
                        worn = worn.map { $0.union(region) } ?? region
                    }
                    treads[t] = Self.tread(thing)
                }
            case .tree(let t):
                guard case .tree(let species) = SceneryCatalog.kinds[thing.id] else { continue }
                let p = Self.treePlace(thing, species, grove.tree(treeShapes[t].key, species))
                let s = treeShapes[t].screen, fade = screens[s].fade
                screens[s] = p.screen
                screens[s].fade = fade
                treeShapes[t].at = p.at
                treeShapes[t].pose = p.pose
                treeShapes[t].foot = p.foot
                for region in [GroundMap.Region(shade: shade[t]), GroundMap.Region(shade: p.shade)].compactMap({ $0 }) {
                    shaded = shaded.map { $0.union(region) } ?? region
                }
                shade[t] = p.shade
                obstaclesMoved = true
            case .log(let l):
                let p = Self.logPlace(thing)
                let s = logs[l].screen, fade = screens[s].fade
                screens[s] = p.screen
                screens[s].fade = fade
                logs[l].matrix = p.matrix
                logs[l].foot = Self.obstacles(of: thing, .log)
                obstaclesMoved = true
            case .run(let r):
                let parts = runs[r].parts, kinds = runs[r].kinds
                runs[r] = Self.runPlace(thing)
                runs[r].parts = parts
                runs[r].kinds = kinds
                for (part, at) in zip(Fences.parts(thing.points, gate: thing.gate), parts) { beds[at.bed].matrices[at.slot] = part.matrix }
                obstaclesMoved = true
                fencesMoved = true
            }
        }
        if fencesMoved { fences = FenceLines(runs.map(\.lines)) }
        if obstaclesMoved {
            obstacles = zip(new.things, laid).flatMap { thing, placed in
                guard placed != .none, let kind = SceneryCatalog.kinds[thing.id] else { return [Clearing]() }
                return Self.obstacles(of: thing, kind)
            }
        }
        if let shaded {
            groundMap.rebake(shade: shade, in: shaded)
            groundChanged = groundChanged.map { $0.union(shaded) } ?? shaded
        }
        if let worn { repaint(worn) }
        bakeLight()
        if bloomsMoved { critters.bloom(blooms) }
        return true
    }

    /// Where a landmark tree stands and how it is turned, leant and sized about its root, the screen that
    /// fades it when it stands in the way, the shade it throws (x, z, reach) and the ground round its trunk.
    private static func treePlace(_ thing: MeadowScenery.Thing, _ species: Species, _ tree: Tree)
        -> (at: Vec3, pose: Mat4, screen: Screen, shade: Vec4, foot: Float) {
        let at = Vec3(thing.x, Land.height(thing.x, thing.z), thing.z)
        let pose = Mat4.compose(.zero, euler: Vec3(thing.tilt.x, thing.turn, thing.tilt.y), scale: thing.size)
        let crown = at + pose.point(tree.middle), spread = Self.spread(thing)
        return (at, pose, Screen(from: at, to: crown, thick: species.girth * 1.4 * spread, crown: crown, crownSize: tree.bulk * 0.85 * spread),
                Vec4(thing.x, thing.z, tree.crown * 1.1 * spread, 0), species.girth * 2 * spread)
    }

    /// A thing that wears the turf (`SceneryCatalog.treads`) as it lies: turned and sized as the thing is.
    private static func tread(_ thing: MeadowScenery.Thing) -> GroundMap.Tread {
        let tread = SceneryCatalog.treads[thing.id] ?? (Vec2(0.64, 0.48), true)
        return GroundMap.Tread(x: thing.x, z: thing.z, turn: thing.turn, half: tread.half * Vec2(thing.size.x, thing.size.z), walked: tread.walked)
    }

    /// A young tree's screen, drawn with `m`.
    private static func youngScreen(_ m: Mat4, _ species: Species, _ tree: Tree) -> Screen {
        let scaleX = simd_length(Vec3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let crown = m.point(tree.middle)
        return Screen(from: m.position, to: crown, thick: species.girth * 2 * scaleX, crown: crown, crownSize: tree.bulk * 0.85 * scaleX)
    }

    /// A lamp's screen, drawn with `m`: up its post to its finial, as wide as its lantern (no crown: nothing of it
    /// spreads over the ground).
    private static func lampScreen(_ m: Mat4) -> Screen {
        Screen(from: m.position, to: m.point(Lamps.post.top), thick: 0.55, crown: nil, crownSize: 0)
    }

    /// A tall made thing's screen (a shed, a tent, a bookcase, a nest box), drawn with `m`: up its middle to its
    /// top, its body the ball a cat behind it is hidden by.
    static func madeScreen(_ m: Mat4, _ plant: Plant) -> Screen {
        let bounds = plant.shape.bounds
        let reach = max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z) / 2
        let middle = m.point(Vec3(0, plant.top.y * 0.55, 0))
        return Screen(from: m.position, to: m.point(Vec3(0, plant.top.y, 0)), thick: reach * 0.6, crown: middle, crownSize: max(reach, plant.top.y * 0.5) * 0.85)
    }

    /// A fence as it stands (its parts are laid by the caller): where its posts are on the land, and its lines.
    static func runPlace(_ thing: MeadowScenery.Thing) -> Run {
        let (posts, spans) = Fences.layout(thing.points, gate: thing.gate)
        return Run(parts: [], kinds: [], posts: posts.map { Vec3($0.at.x, Land.height($0.at.x, $0.at.y), $0.at.y) }, lines: FenceLines.Run(posts, spans))
    }

    /// Whether going straight from `a` to `b` on the ground crosses a fence: through any of its spans but a gate's.
    func crossesFence(_ a: Vec2, _ b: Vec2) -> Bool { fences.crosses(a, b) }

    /// Where a fallen log lies, and its screen along it.
    private static func logPlace(_ thing: MeadowScenery.Thing) -> (matrix: Mat4, screen: Screen) {
        let m = matrix(of: thing, lift: -Float(Land.ground))
        // It lies along its own x axis.
        func onLog(_ t: Float) -> Vec3 { m.point(Vec3(t, 1, 0)) }
        let reach = SceneryCatalog.logHalfLength
        return (m, Screen(from: onLog(-reach), to: onLog(reach), thick: 1.4, crown: nil, crownSize: 0))
    }

    // MARK: making way for blankets

    /// How much of a landmark tree stands, 1 whole … 0 gone: a blanket laid within reach of its trunk shrinks
    /// it away, as the rooted things shrink (`openGround`, `rootKernel` in the shaders), and it grows back
    /// when the blanket goes. Blankets never move for scenery.
    func treeStanding(_ i: Int, _ clearings: [Vec4], _ count: Int) -> Float {
        let t = treeShapes[i]
        return Self.standing(t.at.x, t.at.z, t.foot, clearings, count)
    }

    /// How much of a fallen log stands, as `treeStanding`: the nearest blanket to any part of it decides.
    func logStanding(_ i: Int, _ clearings: [Vec4], _ count: Int) -> Float {
        var least: Float = 1
        for c in logs[i].foot { least = min(least, Self.standing(c.x, c.z, c.r * 0.5, clearings, count)) }
        return least
    }

    /// The shaders' rule for a rooted thing (`openGround`, then `rootKernel`'s shrink), for ground of
    /// radius `r` round (x, z): 0 on a blanket, low on the trodden ring round it, 1 in open meadow.
    static func standing(_ x: Float, _ z: Float, _ r: Float, _ clearings: [Vec4], _ count: Int) -> Float {
        var open: Float = 1
        for j in 0..<min(count, clearings.count) {
            let c = clearings[j]
            let d = hypot(x - c.x, z - c.y) - c.z - r
            open = min(open, d < 0 ? 0 : lerp(0.14, 1, smoothstep(d, 1, 4.6)))
        }
        return smoothstep(open, 0.25, 0.95)
    }

    // MARK: pointing at things

    /// Balls holding most of a thing as it is drawn, for telling what is under the pointer: a tree's crown
    /// and its trunk, along a log, a plant's body. None when it is not drawn.
    func picking(_ i: Int) -> [Ball] {
        guard laid.indices.contains(i) else { return [] }
        let thing = scenery.things[i]
        func along(_ s: Screen, _ count: Int, _ radius: Float) -> [Ball] {
            (0..<count).map { k in Ball(center: s.from + (s.to - s.from) * (Float(k) + 0.5) / Float(count), radius: radius) }
        }
        switch laid[i] {
        case .none:
            return []
        case .tree(let t):
            let s = screens[treeShapes[t].screen]
            return [Ball(center: s.crown ?? s.to, radius: s.crownSize)] + along(s, 3, s.thick * 1.3)
        case .log(let l):
            return along(screens[logs[l].screen], 5, 1.5)
        case .run(let r):
            // Each post, and each span's middle: any of it picks the whole run.
            let posts = runs[r].posts
            var balls = posts.map { Ball(center: $0 + Vec3(0, Fences.tall * 0.5, 0), radius: Fences.tall * 0.5) }
            for (a, b) in zip(posts, posts.dropFirst()) where simd_distance(a, b) < Fences.spacing * 1.5 {
                balls.append(Ball(center: (a + b) / 2 + Vec3(0, Fences.tall * 0.5, 0), radius: Fences.tall * 0.45))
            }
            return balls
        case .bed(let b, let slot):
            let m = beds[b].matrices[slot]
            if let s = beds[b].screens?[slot] { return [Ball(center: screens[s].crown ?? screens[s].to, radius: screens[s].crownSize)] + along(screens[s], 2, screens[s].thick * 1.5) }
            let top = plants[beds[b].plant].top, size = max(thing.size.x, thing.size.y, thing.size.z)
            let base = SceneryRules.footprint(of: thing).first?.r ?? 0.3
            return [Ball(center: m.point(Vec3(0, top.y * 0.5, 0)), radius: max(top.y * 0.5 * size, base * 1.1))]
        }
    }

    /// Where a tree's crown spreads over the ground (its middle, x and z, and how far round it), for a tree or a
    /// young tree as it is drawn now: what the editor rings round a chosen tree. Nil for anything else.
    func canopy(_ i: Int) -> (x: Float, z: Float, r: Float)? {
        guard laid.indices.contains(i) else { return nil }
        let screen: Screen
        switch laid[i] {
        case .tree(let t): screen = screens[treeShapes[t].screen]
        case .bed(let b, let slot):
            guard let s = beds[b].screens?[slot], case .youngTree = SceneryCatalog.kinds[scenery.things[i].id] else { return nil }
            screen = screens[s]
        case .none, .log, .run: return nil
        }
        guard let crown = screen.crown else { return nil }
        return (crown.x, crown.z, screen.crownSize)
    }

    // MARK: walking

    /// How gladly a cat walks at a ground point, 0…1: 1 on a painted path or a stepping stone, less on mown
    /// lawn, least in the long wild grass and on tilled soil. Read from the painted cells and the stones
    /// themselves, so it is exact where the map is soft.
    func walkingEase(_ x: Float, _ z: Float) -> Float {
        let p = Vec2(x, z)
        // Only where the turf is trodden or cut can a stone be underfoot (`GroundMap.Tread.trodden`).
        if groundMap.sample(p, channel: 1) > 0, treads.contains(where: { $0.walked && $0.holds(p) }) { return 1 }
        guard let ground = scenery.ground, let cell = MeadowScenery.Ground.cell(at: x, z) else { return Self.walkingEase(.wild) }
        return Self.walkingEase(ground[cell.column, cell.row])
    }

    static func walkingEase(_ paint: MeadowScenery.Ground.Paint) -> Float {
        switch paint {
        case .path: 1
        case .lawn: 0.6
        case .wild, .soil: 0.25
        }
    }

    // MARK: a thing on its own

    /// A thing's shape on its own, as the meadow draws it, and where it stands: for the editor's ghost of
    /// what is about to be placed, and the tray's pictures. `make` grows or builds the shape (a tree from the
    /// thing's seed); the same `key`, the same shape, so it is made once.
    static func alone(_ thing: MeadowScenery.Thing) -> (key: ShapeKey, make: () -> Geometry, matrix: Mat4)? {
        guard let kind = SceneryCatalog.kinds[thing.id] else { return nil }
        func grown(_ key: ShapeKey, _ species: Species) -> Tree {
            if let tree = StandardMeadow.grown.trees[key] { return tree }
            var random = Seeded(key.seed)
            return Trees.grow(species, &random)
        }
        switch kind {
        case .tree(let species):
            let key = ShapeKey(id: thing.id, seed: thing.seed)
            return (key, { grown(key, species).shape.roughened(0.85) }, matrix(of: thing))
        case .youngTree(let species):
            let key = ShapeKey(id: thing.id, seed: thing.seed)
            return (key, { grown(key, species).shape.roughened(0.8) }, matrix(of: thing))
        case .plant:
            guard let made = SceneryCatalog.shape(of: thing) else { return nil }
            return (made.key, {
                let shape = made.make().shape
                return shape.roughness.isEmpty ? shape.roughened(0.8) : shape
            }, matrix(of: thing))
        case .log:
            return (ShapeKey(id: thing.id), { SceneryCatalog.fallenLog }, matrix(of: thing, lift: -Float(Land.ground)))
        case .fence:
            // The whole run as one shape on the land where it lies (a thing with no points: the tray's short run).
            let run = thing.isRun ? (points: thing.points, gate: thing.gate) : Fences.pictured
            return (ShapeKey(id: thing.id, run: run.points, gate: run.gate), { Fences.joined(run.points, gate: run.gate) }, .identity)
        }
    }

    /// A tall thing's screen, as far as telling it from another goes: where it stands and reaches.
    private struct ScreenKey: Hashable {
        var from: Vec3, to: Vec3
        init(_ s: Screen) { from = s.from; to = s.to }
    }

    // MARK: each frame

    /// How hard the wind is blowing at a spot right now, 0…1: the same gusts that bend the grass there
    /// (`windAt` in the shaders), their waves moved on by `drift` (`Stage.gustDrift`).
    static func gust(_ x: Float, _ z: Float, drift: Vec2) -> Float {
        Float(smooth((shaderNoise(Double(x) * 0.045 - Double(drift.x), Double(z) * 0.045 - Double(drift.y)) - 0.35) / 0.5))
    }

    func update(_ dt: Float, fading: Float, time: Float, eye: Vec3, lookAt: Vec3, sleepers: [Perch], sights: [Ball], sightCount: Int,
                clearOf: [Ball] = [], clearCount: Int = 0, clearings: [Vec4], clearingCount: Int, light: Light, windToward: Vec2) {
        cloudTurn += dt * 0.004
        critters.update(dt, wind: windToward, sleepers: sleepers, random: &random)
        Occlusion.update(&screens, dt: fading, eye: eye, sights: sights, count: sightCount)
        glow(time: time, eye: eye, clearings: clearings, count: clearingCount, night: light.night, falling: light.falling > 0)
        keepFlyersOff(clearOf, count: clearCount, eye: eye)
        fall(dt, time: time, around: lookAt, light: light, windToward: windToward)
    }

    /// Fireflies come out as it gets dark, only round the picnics: each circles its blanket slowly at its
    /// own distance and height, pulsing in its own time. They keep to the hem of the cloth and the grass
    /// beyond, below the cats' heads, so from any angle none flies into or over a face; only out past the
    /// edge do some rise higher. (Meadow.ts `glow`, as finished for the night look.)
    private func glow(time t: Float, eye: Vec3, clearings: [Vec4], count blankets: Int, night: Float, falling: Bool) {
        let out = night * (falling ? 0.4 : 1)
        for b in 0..<MAX_CLEARINGS {
            let home = clearings[b]
            let count = b < blankets && out > 0.01 ? clamp(Int((2 + home.z * 1.3).rounded()), 5, Self.fireflies) : 0
            var toEye = Vec2(eye.x - home.x, eye.z - home.y)
            toEye = simd_length(toEye) > 0 ? simd_normalize(toEye) : Vec2(0, 1)
            // The nearest blanket within a short flight, for the wanderers.
            var neighbour: Vec4? = nil
            var nearest: Float = 14
            if count > 0 {
                for o in 0..<blankets where o != b {
                    let other = clearings[o]
                    let gap = hypot(other.x - home.x, other.y - home.y) - other.z - home.z
                    if gap < nearest { neighbour = other; nearest = gap }
                }
            }
            for k in 0..<Self.fireflies {
                let i = b * Self.fireflies + k
                if k >= count { fireflies[i] = .zero; continue }
                let way = fireflyWays[i % fireflyWays.count]
                var x = home.x, z = home.y
                if let neighbour, k >= count - 2 {
                    let away = 0.4 * pow(max(0, sin(t * 0.05 + way.phase)), 2)
                    x += (neighbour.x - x) * away
                    z += (neighbour.y - z) * away
                }
                let angle = way.angle + t * way.spin, reach = home.z * (0.85 + 0.5 * way.out) + sin(t * 0.37 + way.phase) * 0.4
                x += cos(angle) * reach + sin(t * 1.3 + way.phase) * 0.12
                z += sin(angle) * reach + cos(t * 1.1 + way.phase) * 0.12
                // A wanderer passing a neighbour keeps out of its ring of cats too.
                if let neighbour {
                    let dx = x - neighbour.x, dz = z - neighbour.y, apart = hypot(dx, dz), least = neighbour.z * 0.85
                    if apart < least {
                        x = neighbour.x + dx / max(apart, 1e-3) * least
                        z = neighbour.y + dz / max(apart, 1e-3) * least
                    }
                }
                let fromMiddle = hypot(x - home.x, z - home.y), past = smooth((fromMiddle - home.z * 1.05) / 1.5)
                // On the side nearest you they fly lower still, so they never pass in front of a small cat's face.
                let facing = ((x - home.x) * toEye.x + (z - home.y) * toEye.y) / max(fromMiddle, 1e-3)
                let y = (0.35 + way.high * (1.05 + 1.2 * past) + sin(t * 0.5 + way.phase * 2) * 0.2) * (1 - 0.45 * smooth(facing))
                let pulse = 0.5 + 0.5 * sin(t * way.pulse + way.phase)
                fireflies[i] = Vec4(x, y, z, out * (0.12 + 0.88 * pulse * pulse * pulse))
            }
        }
    }

    /// No firefly, and no butterfly or bee on the wing, passes in front of a flag's name, a bubble or a waking
    /// cat (from the sidebar's height a butterfly under a face reads as a mouth): one that comes between
    /// your eye and any of them is moved aside, out of its outline as seen from where you look.
    private func keepFlyersOff(_ balls: [Ball], count: Int, eye: Vec3) {
        guard count > 0 else { return }
        for i in fireflies.indices where fireflies[i].w > 0 {
            let p = Self.outOfSight(Vec3(fireflies[i].x, fireflies[i].y, fireflies[i].z), of: balls, count: count, eye: eye)
            fireflies[i] = Vec4(p.x, p.y, p.z, fireflies[i].w)
        }
        critters.moveFlying { Self.outOfSight($0, of: balls, count: count, eye: eye) }
    }

    /// A point moved, if it must be, just out of the lines of sight from `eye` to each ball.
    static func outOfSight(_ point: Vec3, of balls: [Ball], count: Int, eye: Vec3) -> Vec3 {
        var p = point
        for b in 0..<count {
            let ball = balls[b]
            let line = ball.center - eye
            let length = simd_length(line)
            guard length > 1e-3 else { continue }
            let along = simd_dot(p - eye, line) / length
            guard along > 0 else { continue }
            // Where the line of sight to the ball passes this point's distance, and how far aside it is.
            let onLine = eye + line / length * along
            let aside = p - onLine
            let apart = simd_length(aside)
            let least = ball.radius * along / length + 0.12
            if apart < least {
                let push = apart > 1e-4 ? aside / apart : Vec3(0, -1, 0)
                p = onLine + push * least
            }
        }
        return p
    }

    /// Rain comes down fast and slanted by the wind; snow drifts. A drop that reaches the ground, or
    /// wanders out of the box around where you are looking, starts again. Light rain or snow is fewer
    /// drops: the first `fallingCount` of them.
    private(set) var falling = false
    private(set) var snowing = false
    private(set) var fallingCount = 0
    /// How a raindrop moves (before each one's own share of speed), for drawing it as a streak along it.
    private(set) var dropVelocity = Vec3(0, -24, 0)
    private func fall(_ dt: Float, time t: Float, around: Vec3, light: Light, windToward: Vec2) {
        falling = light.falling > 0
        snowing = light.snowing
        guard falling else { fallingCount = 0; return }
        fallingCount = Int((Float(drops.count) * (0.25 + 0.75 * light.falling)).rounded())
        let speed: Float = snowing ? 1.7 : 24, push = light.wind * (snowing ? 1.1 : 3.2)
        dropVelocity = Vec3(windToward.x * push, -speed, windToward.y * push)
        let w = Self.fall.wide
        for i in 0..<fallingCount {
            var d = drops[i]
            d.y -= speed * (0.8 + Float(i % 5) * 0.1) * dt
            // Snowflakes wander across the wind as they drift down.
            let wander = snowing ? sin(t * 1.3 + Float(i)) * 0.7 : 0
            d.x += (windToward.x * push - windToward.y * wander) * dt
            d.z += (windToward.y * push + windToward.x * wander) * dt
            if d.y < 0 { d.y += Self.fall.tall }
            d.x = around.x + euclideanModulo(d.x - around.x + w / 2, w) - w / 2
            d.z = around.z + euclideanModulo(d.z - around.z + w / 2, w) - w / 2
            drops[i] = d
        }
    }
}
