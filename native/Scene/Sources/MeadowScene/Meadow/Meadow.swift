import Foundation
import simd

// Port of src/meadow/Meadow.ts: the world the cats live in, a spring meadow at cat scale, in the same
// matte clay as the cat. Everything is grown from one seed in the same order as the web version, so the
// same flowers stand in the same places.

/// A circle of ground: a blanket's clearing, or ground blankets must keep off.
struct Clearing: Equatable { var x: Float; var z: Float; var r: Float }

/// Instances of one plant shape, each placed with its own lean and size.
struct Bed {
    var plant: Int              // index into Meadow.plants
    var sway: Float
    var matrices: [Mat4]
    /// Saplings: each can fade on its own when it stands in the way; index of its screen.
    var screens: [Int]? = nil
}

final class Meadow {
    // Landmark trees stand to the sides and behind, never between the usual camera and the blankets.
    // Angles from the camera's side of the meadow. The first few shade the ground beneath them.
    static let trees: [(Species, Float, Float)] = [
        (.oak, 208, 56), (.birch, 152, 50), (.cherry, 258, 62), (.oak, 118, 84), (.birch, 300, 74), (.oak, 182, 104), (.cherry, 76, 92),
        (.oak, 200, 136), (.birch, 166, 128), (.oak, 232, 152), (.cherry, 141, 150), (.oak, 270, 142),
    ]
    static let log = (x: Float(-27), z: Float(-9), turn: Float(0.5))
    static let fireflies = 14
    static let fall = (drops: 700, wide: Float(50), tall: Float(26))
    static let wind = simd_normalize(Vec2(1, 0.35))

    private(set) var random = Seeded(0)
    let grass: (tufts: [GrassField.Tuft], chunks: [GrassField.Chunk])
    /// Every plant shape: the flowers, mushrooms, stones and saplings, by index.
    private(set) var plants: [Plant] = []
    private(set) var beds: [Bed] = []
    /// Landmark trees, each its own mesh: shape, where it stands, its screen.
    private(set) var treeShapes: [(shape: Geometry, at: Vec3, screen: Int)] = []
    private(set) var logShape = Geometry()
    let logMatrix: Mat4
    private(set) var logScreen = 0
    private(set) var hills: [(Mat4, Vec3)] = []
    private(set) var clouds: [Mat4] = []
    private(set) var stars: [Vec3] = []
    private(set) var screens: [Screen] = []
    /// Ground a blanket must not be laid on: round the roots of every tree, and along the fallen log.
    private(set) var obstacles: [Clearing] = []
    /// Trees whose shade dapples the ground: x, z, reach.
    private(set) var shade: [Vec4] = []
    private(set) var critters: Critters!
    private(set) var fireflyWays: [(angle: Float, spin: Float, out: Float, high: Float, phase: Float, pulse: Float)] = []
    /// This frame's fireflies: position and glow.
    private(set) var fireflies: [Vec4] = []
    private(set) var drops: [Vec3] = []
    private(set) var cloudTurn: Float = 0

    init() {
        var random = Seeded(20_261_112)
        grass = GrassField.grow(&random)
        logMatrix = .translation(Vec3(Self.log.x, 0, Self.log.z)) * .rotationY(Self.log.turn)
        buildHills()
        buildClouds()
        let roots = plantTrees(&random)
        layLog()
        let blooms = growFlowers(&random)
        scatterOddments(&random, roots)
        critters = Critters(&random, blooms: blooms)

        // Night: a sky full of stars riding with the camera, and fireflies round the picnics.
        for _ in 0..<600 {
            let up = 0.08 + random.float() * 0.9, around = random.float() * .pi * 2, flat = sqrt(1 - up * up)
            stars.append(Vec3(cos(around) * flat * 430, up * 430, sin(around) * flat * 430))
        }
        for _ in 0..<(24 * Self.fireflies) {
            let angle = random.float() * .pi * 2
            let spin = (random.float() < 0.5 ? -1 : 1) * (0.06 + random.float() * 0.16)
            let out = random.float(), high = random.float(), phase = random.float() * .pi * 2, pulse = 0.55 + random.float() * 0.7
            fireflyWays.append((angle, spin, out, high, phase, pulse))
        }
        for _ in 0..<Self.fall.drops {
            let x = (random.float() - 0.5) * Self.fall.wide, y = random.float() * Self.fall.tall, z = (random.float() - 0.5) * Self.fall.wide
            drops.append(Vec3(x, y, z))
        }
        fireflies = [Vec4](repeating: .zero, count: MAX_CLEARINGS * Self.fireflies)
        self.random = random
    }

    /// The obstacles the meadow places (tree roots, the log), for layout tests without growing a meadow.
    static let obstaclesForTests: [Clearing] = {
        var list: [Clearing] = []
        for (species, degrees, out) in trees {
            let a = degrees * .pi / 180
            list.append(Clearing(x: sin(a) * out, z: cos(a) * out, r: species.girth * 3.2))
        }
        let m = Mat4.translation(Vec3(log.x, 0, log.z)) * .rotationY(log.turn)
        for t: Float in [-5, 0, 5] { let p = m.point(Vec3(t, 1, 0)); list.append(Clearing(x: p.x, z: p.z, r: 3)) }
        return list
    }()

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

    /// A far hill, sunk into the ground as far as blankets laid near it need (a long column can reach
    /// the hills): from its whole height down to none, as the land is levelled round it.
    func hill(_ i: Int, _ clearings: [Vec4], _ count: Int) -> Mat4 {
        let m = hills[i].0
        let middle = Vec3(m.columns.3.x, m.columns.3.y, m.columns.3.z), reach = m.columns.0.x, tall = m.columns.1.y
        var k: Float = 0
        for j in 0..<min(count, clearings.count) {
            let c = clearings[j]
            k = max(k, 1 - smoothstep(hypot(middle.x - c.x, middle.z - c.y) - max(c.z, 0) - reach, Land.flat, Land.flat + Land.blend))
        }
        return k > 0 ? .translation(Vec3(0, -(middle.y + tall) * k, 0)) * m : m
    }

    /// Each tree is grown on its own, so no two share a shape. Returns where their roots are.
    private func plantTrees(_ random: inout Seeded) -> [(x: Float, z: Float, girth: Float)] {
        var roots: [(Float, Float, Float)] = []
        for (i, (species, degrees, out)) in Self.trees.enumerated() {
            let angle = degrees * .pi / 180
            let x = sin(angle) * out, z = cos(angle) * out
            let tree = Trees.grow(species, &random)
            let at = Vec3(x, Land.height(x, z), z)
            let crown = tree.middle + at
            screens.append(Screen(from: at, to: crown, thick: species.girth * 1.4, crown: crown, crownSize: tree.bulk * 0.85))
            treeShapes.append((tree.shape.roughened(0.85), at, screens.count - 1))
            obstacles.append(Clearing(x: x, z: z, r: species.girth * 3.2))
            if i < MAX_TREES { shade.append(Vec4(x, z, tree.crown * 1.1, 0)) }
            roots.append((x, z, species.girth))
        }
        return roots
    }

    /// A fallen trunk lying in the long grass, its cut ends pale and moss settling along the top.
    private func layLog() {
        let along = QuadraticBezier(Vec3(-7.5, 0.95, 0), Vec3(0, 1.1, 0.9), Vec3(7.5, 0.9, 0.2))
        let trunk = Clay.limb(along, 1.05, 0.9, 0x6f523a, 0x8f6d4b, sides: 16, rings: 14) { _, angle in 1 + sin(angle * 7) * 0.035 }
        func cut(_ x: Float, _ z: Float, _ r: Float) -> Geometry { Clay.blob(at: Vec3(x, 0.95, z), size: Vec3(0.12, r, r), color: 0xcdb089, top: 0xe6cfa6) }
        let moss = [(Float(-3.5), Float(0.3), Float(1.9)), (0.6, 0.75, 2.6), (4.2, 0.45, 1.6)].map { x, z, size in
            Clay.blob(at: Vec3(x, 1.95, z), size: Vec3(size, 0.22, 0.75), color: 0x79a043, top: 0xa9cb62, lumpy: 0.15)
        }
        logShape = Geometry.join([trunk.shape, cut(-7.5, 0, 1.0), cut(7.42, 0.2, 0.86)] + moss).roughened(0.9)
        // It lies along its own x axis, turned by the log's turn.
        func onLog(_ t: Float) -> Vec3 { logMatrix.point(Vec3(t, 1, 0)) }
        screens.append(Screen(from: onLog(-7.5), to: onLog(7.5), thick: 1.4, crown: nil, crownSize: 0))
        logScreen = screens.count - 1
        for t: Float in [-5, 0, 5] {
            let spot = onLog(t)
            obstacles.append(Clearing(x: spot.x, z: spot.z, r: 3))
        }
    }

    private struct Place { var x: Float; var z: Float; var size: Float; var variant: Int; var lean: Float = 0.12 }

    /// Plants each place with its own lean and size; returns the tops (for butterflies) and the beds made.
    @discardableResult
    private func bed(_ kinds: [Plant], sway: Float, _ places: [Place], _ random: inout Seeded) -> (tops: [Vec3], beds: [Int]) {
        var tops: [Vec3] = []
        var made: [Int] = []
        for (variant, plant) in kinds.enumerated() {
            let mine = places.filter { $0.variant == variant }
            if mine.isEmpty { continue }
            plants.append(plant)
            var matrices: [Mat4] = []
            for p in mine {
                // No two stand alike: each leans its own way and is a little taller or stouter than its neighbour.
                let rx = (random.float() - 0.5) * 2 * p.lean, ry = random.float() * .pi * 2, rz = (random.float() - 0.5) * 2 * p.lean
                let sx = p.size * (0.9 + random.float() * 0.2), sy = p.size * (0.85 + random.float() * 0.3), sz = p.size * (0.9 + random.float() * 0.2)
                let m = Mat4.compose(Vec3(p.x, Land.height(p.x, p.z), p.z), euler: Vec3(rx, ry, rz), scale: Vec3(sx, sy, sz))
                matrices.append(m)
                tops.append(m.point(plant.top))
            }
            beds.append(Bed(plant: plants.count - 1, sway: sway, matrices: matrices))
            made.append(beds.count - 1)
        }
        return (tops, made)
    }

    /// Flowers grow where the ground suits them: loose clumps of one kind with calm grass between, plus
    /// the odd stray. Returns every bloom, for the butterflies and bees.
    private func growFlowers(_ random: inout Seeded) -> [Vec3] {
        let kinds: [([Plant], Float)] = [(Flora.daisies, 0.4), (Flora.buttercups, 0.3), (Flora.lupins, 0.17), (Flora.poppies, 0.13)]
        var beds = [[Place]](repeating: [], count: kinds.count)
        func pick() -> Int {
            var roll = random.float()
            for (i, k) in kinds.enumerated() { roll -= k.1; if roll < 0 { return i } }
            return 0
        }
        func place(_ x: Float, _ z: Float) -> Place {
            let size = 0.8 + random.float() * 0.45
            return Place(x: x, z: z, size: size, variant: random.float() < 0.5 ? 0 : 1)
        }
        func somewhere(_ from: Float, _ to: Float) -> (Float, Float) {
            let out = from + pow(random.float(), 0.8) * (to - from), angle = random.float() * .pi * 2
            return (cos(angle) * out, sin(angle) * out)
        }
        var clumps = 0, tries = 0
        while clumps < 46 && tries < 2000 {
            tries += 1
            let (x, z) = somewhere(7, 84)
            if fbm(Double(x) / 28, Double(z) / 28, 31) < 0.47 { continue }
            let kind = pick(), spread = 1.6 + random.float() * 2.4
            var n = 5 + Int(random.float() * 8)
            while n > 0 {
                let out = spread * sqrt(random.float()), angle = random.float() * .pi * 2
                beds[kind].append(place(x + cos(angle) * out, z + sin(angle) * out))
                n -= 1
            }
            clumps += 1
        }
        for _ in 0..<70 {
            let (x, z) = somewhere(5, 90)
            let kind = pick()
            beds[kind].append(place(x, z))
        }
        var blooms: [Vec3] = []
        for (k, kind) in kinds.enumerated() { blooms += bed(kind.0, sway: 0.12, beds[k], &random).tops }
        return blooms
    }

    /// Mushrooms gather at tree roots and beside the log; stones sit in groups of one big, a few medium,
    /// many small; a few young trees stand in the middle distance.
    private func scatterOddments(_ random: inout Seeded, _ roots: [(x: Float, z: Float, girth: Float)]) {
        func variant() -> Int { random.float() < 0.5 ? 0 : 1 }
        var mushrooms: [Place] = []
        func ring(_ x: Float, _ z: Float, _ from: Float, _ to: Float, _ toward: Float) {
            var n = 3 + Int(random.float() * 5)
            while n > 0 {
                let angle = toward + (random.float() - 0.5) * 1.6, out = from + random.float() * (to - from)
                let size = 0.7 + random.float() * 0.9
                mushrooms.append(Place(x: x + cos(angle) * out, z: z + sin(angle) * out, size: size, variant: variant(), lean: 0.1))
                n -= 1
            }
        }
        for root in roots.prefix(MAX_TREES) { ring(root.x, root.z, root.girth * 2.4, root.girth * 4, atan2(-root.z, -root.x)) }
        ring(Self.log.x, Self.log.z, 1.8, 3.2, 1.2)
        ring(Self.log.x, Self.log.z, 1.8, 3.2, -2)
        bed(Flora.mushrooms, sway: 0, mushrooms, &random)

        var stones: [Place] = []
        for (x, z) in [(Float(19), Float(-13)), (-15, 21), (6, 29), (-31, -27)] {
            func group(_ count: Int, _ small: Float, _ big: Float, _ spread: Float) {
                for _ in 0..<count {
                    let angle = random.float() * .pi * 2, out = spread * sqrt(random.float())
                    let size = small + random.float() * (big - small)
                    stones.append(Place(x: x + cos(angle) * out, z: z + sin(angle) * out, size: size, variant: variant(), lean: 0.05))
                }
            }
            group(1, 1.7, 2.5, 0.3)
            group(3, 0.7, 1.1, 2.6)
            group(6, 0.2, 0.42, 3.8)
        }
        bed(Flora.stones, sway: 0, stones, &random)

        // Young trees, tall enough to stand in the way of a picnic, so each can fade on its own. Like
        // everything rooted, a young tree makes way if a blanket is ever laid where it stands.
        let young = (0..<3).map { _ in Trees.grow(.sapling, &random) }
        let saplings = young.map { Plant(shape: $0.shape.roughened(0.8), top: Vec3(0, 9, 0)) }
        let spots: [(Float, Float)] = [(-18, -21), (22, -25), (-34, 3), (34, 7), (-5, -42)]
        let places = spots.enumerated().map { i, s in Place(x: s.0, z: s.1, size: 0.9 + random.float() * 0.4, variant: i % saplings.count, lean: 0.03) }
        for b in bed(saplings, sway: 0, places, &random).beds {
            let tree = young[beds[b].plant - (plants.count - saplings.count)]
            var list: [Int] = []
            for m in beds[b].matrices {
                let scaleX = simd_length(Vec3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
                let crown = m.point(tree.middle)
                screens.append(Screen(from: m.position, to: crown, thick: Species.sapling.girth * 2 * scaleX, crown: crown, crownSize: tree.bulk * 0.85 * scaleX))
                list.append(screens.count - 1)
            }
            beds[b].screens = list
        }
    }

    // MARK: each frame

    /// How hard the wind is blowing at a spot right now, 0…1: the same gusts that bend the grass there.
    func gust(_ x: Float, _ z: Float, time: Float) -> Float {
        let drift = Double(time) * 0.22
        return Float(smooth((shaderNoise(Double(x) * 0.045 - Double(Self.wind.x) * drift, Double(z) * 0.045 - Double(Self.wind.y) * drift) - 0.35) / 0.5))
    }

    func update(_ dt: Float, time: Float, eye: Vec3, lookAt: Vec3, sleepers: [Perch], sights: [Ball], sightCount: Int,
                clearOf: [Ball] = [], clearCount: Int = 0, clearings: [Vec4], clearingCount: Int, night: Float, weather: MeadowWeather?, wind: Float) {
        cloudTurn += dt * 0.004
        critters.update(dt, sleepers: sleepers, random: &random)
        Occlusion.update(&screens, dt: dt, eye: eye, sights: sights, count: sightCount)
        glow(time: time, eye: eye, clearings: clearings, count: clearingCount, night: night, falling: weather?.sky == .rain || weather?.sky == .snow)
        keepFlyersOff(clearOf, count: clearCount, eye: eye)
        fall(dt, time: time, around: lookAt, snowing: weather?.sky == .snow, raining: weather?.sky == .rain, wind: wind)
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
    /// wanders out of the box around where you are looking, starts again.
    private(set) var falling = false
    private(set) var snowing = false
    private func fall(_ dt: Float, time t: Float, around: Vec3, snowing: Bool, raining: Bool, wind: Float) {
        falling = snowing || raining
        self.snowing = snowing
        guard falling else { return }
        let speed: Float = snowing ? 1.7 : 24, push = wind * (snowing ? 1.1 : 3.2)
        let w = Self.fall.wide
        for i in drops.indices {
            var d = drops[i]
            d.y -= speed * (0.8 + Float(i % 5) * 0.1) * dt
            d.x += (Self.wind.x * push + (snowing ? sin(t * 1.3 + Float(i)) * 0.7 : 0)) * dt
            d.z += Self.wind.y * push * dt
            if d.y < 0 { d.y += Self.fall.tall }
            d.x = around.x + euclideanModulo(d.x - around.x + w / 2, w) - w / 2
            d.z = around.z + euclideanModulo(d.z - around.z + w / 2, w) - w / 2
            drops[i] = d
        }
    }
}
