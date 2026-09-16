import Foundation
import simd

// The Default meadow: the meadow of before there were meadow files, written out as scenery. It is grown
// by the code that always grew it (src/meadow/Meadow.ts, in the web version's order, which the parity
// tests hold), from the same stream and in the same order, so the same flowers stand in the same places.
// Each thing is written with the lean, turn and size it drew; each tree with the state of the stream it
// was grown from (its seed), so drawing the scenery grows the very same tree.

enum StandardMeadow {
    /// The meadow's stream (`Meadow.seed`) where the scenery begins: after the grass.
    static let start: UInt32 = 2_634_129_122
    /// Where it stands once the scenery is grown. The butterflies, fireflies and rain go on from here,
    /// whatever scenery a meadow holds, so they are the Default's in every meadow.
    static let end: UInt32 = 2_154_078_104

    /// Landmark trees stand to the sides and behind, never between the usual camera and the blankets:
    /// kind, degrees round from the camera's side of the meadow, distance from its middle.
    static let landmarks: [(id: String, degrees: Float, out: Float)] = [
        ("tree.oak", 208, 56), ("tree.birch", 152, 50), ("tree.cherry", 258, 62), ("tree.oak", 118, 84), ("tree.birch", 300, 74),
        ("tree.oak", 182, 104), ("tree.cherry", 76, 92), ("tree.oak", 200, 136), ("tree.birch", 166, 128), ("tree.oak", 232, 152),
        ("tree.cherry", 141, 150), ("tree.oak", 270, 142),
    ]
    /// The fallen log lying in the long grass.
    static let log = (x: Float(-27), z: Float(-9), turn: Float(0.5))
    /// The young trees' spots in the middle distance.
    static let saplingSpots: [(Float, Float)] = [(-18, -21), (22, -25), (-34, 3), (34, 7), (-5, -42)]
    /// Fly agarics ring the roots of only the nearest landmark trees (the first eight).
    static let ringedTrees = 8

    /// The Default, and the trees grown on the way (so the meadow showing it grows none twice).
    struct Grown {
        let scenery: MeadowScenery
        let trees: [Grove.Key: Tree]
        /// The stream once everything is grown (`end`).
        let end: UInt32
    }

    static let grown = grow()

    static func grow() -> Grown {
        var random = Seeded(start)
        var trees: [Grove.Key: Tree] = [:]
        var things: [MeadowScenery.Thing] = []

        // Each landmark tree grown on its own, so no two share a shape.
        var roots: [(x: Float, z: Float, girth: Float)] = []
        for (id, degrees, out) in landmarks {
            let angle = degrees * .pi / 180
            let x = sin(angle) * out, z = cos(angle) * out
            let species = SceneryCatalog.species(id)!
            let key = Grove.Key(id: id, seed: random.state)
            trees[key] = Trees.grow(species, &random)
            things.append(MeadowScenery.Thing(id: id, x: x, z: z, seed: key.seed))
            roots.append((x, z, species.girth))
        }
        things.append(MeadowScenery.Thing(id: "wood.fallenLog", x: log.x, z: log.z, turn: log.turn))
        things += growFlowers(&random)
        things += scatterOddments(&random, roots, &trees)
        return Grown(scenery: MeadowScenery(things: things), trees: trees, end: random.state)
    }

    private struct Place { var x: Float; var z: Float; var size: Float; var variant: Int; var lean: Float = 0.12 }

    /// Plants each place with its own lean and size, one shape after another (`shapes[variant]`: the
    /// thing's id and shape), as the meadow always drew them.
    private static func plant(_ shapes: [(id: String, variant: Int, seed: UInt32)], _ places: [Place], _ random: inout Seeded) -> [MeadowScenery.Thing] {
        var things: [MeadowScenery.Thing] = []
        for (variant, shape) in shapes.enumerated() {
            for p in places where p.variant == variant {
                // No two stand alike: each leans its own way and is a little taller or stouter than its neighbour.
                let rx = (random.float() - 0.5) * 2 * p.lean, ry = random.float() * .pi * 2, rz = (random.float() - 0.5) * 2 * p.lean
                let sx = p.size * (0.9 + random.float() * 0.2), sy = p.size * (0.85 + random.float() * 0.3), sz = p.size * (0.9 + random.float() * 0.2)
                things.append(MeadowScenery.Thing(id: shape.id, x: p.x, z: p.z, turn: ry, size: Vec3(sx, sy, sz), tilt: Vec2(rx, rz),
                                                  seed: shape.seed, variant: shape.variant))
            }
        }
        return things
    }

    private static func twoShapes(_ id: String) -> [(id: String, variant: Int, seed: UInt32)] { [(id, 0, 0), (id, 1, 0)] }

    /// Flowers grow where the ground suits them: loose clumps of one kind with calm grass between, plus
    /// the odd stray.
    private static func growFlowers(_ random: inout Seeded) -> [MeadowScenery.Thing] {
        let kinds: [(String, Float)] = [("flower.daisy", 0.4), ("flower.buttercup", 0.3), ("flower.lupin", 0.17), ("flower.poppy", 0.13)]
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
        var things: [MeadowScenery.Thing] = []
        for (k, kind) in kinds.enumerated() { things += plant(twoShapes(kind.0), beds[k], &random) }
        return things
    }

    /// Mushrooms gather at tree roots and beside the log; stones sit in groups of one big, a few medium,
    /// many small; a few young trees stand in the middle distance.
    private static func scatterOddments(_ random: inout Seeded, _ roots: [(x: Float, z: Float, girth: Float)],
                                        _ trees: inout [Grove.Key: Tree]) -> [MeadowScenery.Thing] {
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
        for root in roots.prefix(ringedTrees) { ring(root.x, root.z, root.girth * 2.4, root.girth * 4, atan2(-root.z, -root.x)) }
        ring(log.x, log.z, 1.8, 3.2, 1.2)
        ring(log.x, log.z, 1.8, 3.2, -2)
        var things = plant(twoShapes("fungus.flyAgaric"), mushrooms, &random)

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
        // The plain stone is the first shape, the mossy one the second.
        things += plant([("stone.stone", 0, 0), ("stone.mossy", 0, 0)], stones, &random)

        // Young trees, three shapes among five: tall enough to stand in the way of a picnic, so each can
        // fade on its own; like everything rooted, one makes way if a blanket is ever laid where it stands.
        var young: [(id: String, variant: Int, seed: UInt32)] = []
        for _ in 0..<3 {
            let key = Grove.Key(id: "tree.young", seed: random.state)
            trees[key] = Trees.grow(.sapling, &random)
            young.append((key.id, 0, key.seed))
        }
        let places = saplingSpots.enumerated().map { i, s in Place(x: s.0, z: s.1, size: 0.9 + random.float() * 0.4, variant: i % young.count, lean: 0.03) }
        things += plant(young, places, &random)
        return things
    }
}
