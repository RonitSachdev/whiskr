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
    /// Young trees: each can fade on its own when it stands in the way; index of its screen.
    var screens: [Int]? = nil
}

/// One shape a thing is drawn with: its id, which of its shapes, and the seed it grew from.
struct ShapeKey: Hashable { var id: String; var variant = 0; var seed: UInt32 = 0 }

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
    /// Counts the sceneries laid, so what is drawn from one is rebuilt when it changes.
    private(set) var sceneryVersion = 0
    private var grove = Grove()
    /// Every plant shape (flowers, mushrooms, stones, young trees) by index, and what each is.
    private(set) var plants: [Plant] = []
    private(set) var plantKeys: [ShapeKey] = []
    private(set) var beds: [Bed] = []
    /// Landmark trees, each its own mesh: shape, what it is, where it stands, its turn, lean and size
    /// about its root, its screen.
    private(set) var treeShapes: [(shape: Geometry, key: ShapeKey, at: Vec3, pose: Mat4, screen: Int)] = []
    /// Fallen logs: where each lies, its screen.
    private(set) var logs: [(matrix: Mat4, screen: Int)] = []
    private(set) var hills: [(Mat4, Vec3)] = []
    private(set) var clouds: [Mat4] = []
    private(set) var stars: [Vec3] = []
    private(set) var screens: [Screen] = []
    /// Ground a blanket must not be laid on: round the roots of every tree, and along each fallen log.
    private(set) var obstacles: [Clearing] = []
    /// Trees whose shade dapples the ground: x, z, reach.
    private(set) var shade: [Vec4] = []
    /// The ground's map, baked from the scenery when it is laid (`GroundMap`).
    private(set) var groundMap = GroundMap()
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
    /// already grown, shapes already made and how faded each tall thing is are kept.
    func show(_ scenery: MeadowScenery) {
        guard scenery != self.scenery else { return }
        critters.bloom(lay(scenery))
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
        case .youngTree, .plant:
            return []
        }
    }

    /// Lays `scenery`: every thing the scene can draw, within its limits (`MeadowScenery.Limits`), in its
    /// order. Returns the flowers' tops, where butterflies and bees settle.
    private func lay(_ scenery: MeadowScenery) -> [Vec3] {
        let oldPlants = Dictionary(zip(plantKeys, plants)) { first, _ in first }
        let oldTrees = Dictionary(treeShapes.map { ($0.key, $0.shape) }) { first, _ in first }
        let oldFades = Dictionary(screens.map { (ScreenKey($0), $0.fade) }) { first, _ in first }
        self.scenery = scenery
        plants = []; plantKeys = []; beds = []; treeShapes = []; logs = []; screens = []; obstacles = []; shade = []
        var bedOf: [ShapeKey: Int] = [:]
        var blooms: [Vec3] = []
        var grown = Set<ShapeKey>()
        var things = 0, trees = 0, tall = 0
        typealias Limits = MeadowScenery.Limits

        func screen(_ s: Screen) -> Int {
            var s = s
            s.fade = oldFades[ScreenKey(s)] ?? 1
            screens.append(s)
            return screens.count - 1
        }
        func instance(_ key: ShapeKey, _ make: () -> Plant, sway: Float, _ matrix: Mat4, screened: Bool) -> Int {
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
            return b
        }

        for thing in scenery.things {
            guard let kind = SceneryCatalog.kinds[thing.id], things < Limits.things, hypot(thing.x, thing.z) <= Limits.reach else { continue }
            switch kind {
            case .tree, .youngTree: guard trees < Limits.trees, tall < Limits.tall else { continue }; trees += 1; tall += 1
            case .log: guard tall < Limits.tall else { continue }; tall += 1
            case .plant: break
            }
            things += 1
            obstacles += Self.obstacles(of: thing, kind)
            switch kind {
            case .tree(let species):
                let key = ShapeKey(id: thing.id, seed: thing.seed)
                let tree = grove.tree(key, species)
                grown.insert(key)
                let at = Vec3(thing.x, Land.height(thing.x, thing.z), thing.z)
                let pose = Mat4.compose(.zero, euler: Vec3(thing.tilt.x, thing.turn, thing.tilt.y), scale: thing.size)
                let crown = at + pose.point(tree.middle), spread = Self.spread(thing)
                let s = screen(Screen(from: at, to: crown, thick: species.girth * 1.4 * spread, crown: crown, crownSize: tree.bulk * 0.85 * spread))
                treeShapes.append((oldTrees[key] ?? tree.shape.roughened(0.85), key, at, pose, s))
                shade.append(Vec4(thing.x, thing.z, tree.crown * 1.1 * spread, 0))
            case .youngTree(let species):
                let key = ShapeKey(id: thing.id, seed: thing.seed)
                let tree = grove.tree(key, species)
                grown.insert(key)
                let m = Self.matrix(of: thing)
                let b = instance(key, { Plant(shape: tree.shape.roughened(0.8), top: Vec3(0, 9, 0)) }, sway: 0, m, screened: true)
                let scaleX = simd_length(Vec3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
                let crown = m.point(tree.middle)
                beds[b].screens?.append(screen(Screen(from: m.position, to: crown, thick: species.girth * 2 * scaleX, crown: crown,
                                                      crownSize: tree.bulk * 0.85 * scaleX)))
            case .plant(let shapes, let sway, let blooming):
                let m = Self.matrix(of: thing)
                let all = shapes()
                let variant = all.indices.contains(thing.variant) ? thing.variant : 0
                let b = instance(ShapeKey(id: thing.id, variant: variant), { all[variant] }, sway: sway, m, screened: false)
                if blooming { blooms.append(m.point(plants[beds[b].plant].top)) }
            case .log:
                let m = Self.matrix(of: thing, lift: -Float(Land.ground))
                // It lies along its own x axis.
                func onLog(_ t: Float) -> Vec3 { m.point(Vec3(t, 1, 0)) }
                let reach = SceneryCatalog.logHalfLength
                logs.append((m, screen(Screen(from: onLog(-reach), to: onLog(reach), thick: 1.4, crown: nil, crownSize: 0))))
            }
        }
        grove.keep(grown)
        groundMap = GroundMap.baked(shade: shade)
        sceneryVersion += 1
        return blooms
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
