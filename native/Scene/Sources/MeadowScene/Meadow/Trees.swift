import Foundation
import simd

// Port of src/meadow/trees.ts: trees as they actually grow, in clay: a trunk that flares into roots
// gripping the ground, limbs forking off it, and a crown of many overlapping clumps of leaves. The apple
// tree and the Scots pine are the Mac's own (the meadow editor's catalog), grown the same way.

struct Species {
    /// How a kind of tree grows.
    enum Form {
        /// Limbs rising from a fork into a crown of leaf clumps: the oak, birch, cherry, a young tree.
        case broadleaf
        /// An orchard apple: a short trunk, limbs spreading wide and low, a dome of leaves hung with apples, a
        /// few windfalls in the grass beneath.
        case apple
        /// A Scots pine: a tall, bare trunk turning orange as it rises, short limbs in tiers near the top, each
        /// carrying flat pads of needles.
        case pine
    }

    var height: Float      // ground to where the trunk forks (a pine: to its top)
    var girth: Float       // trunk radius just above the roots
    var limbs: Int         // a pine: its tiers of limbs
    var reach: Float       // how far limbs spread
    var clump: Float       // size of one clump of leaves
    var bark: (UInt32, UInt32)
    var leaves: (UInt32, UInt32)
    var form = Form.broadleaf

    static let oak = Species(height: 16, girth: 1.9, limbs: 5, reach: 9.5, clump: 3.4, bark: (0x6a4d36, 0x97734f), leaves: (0x4c8a3a, 0xa3d15a))
    static let birch = Species(height: 21, girth: 1.0, limbs: 4, reach: 6, clump: 2.4, bark: (0xd9d4c6, 0xf3efe4), leaves: (0x74ad42, 0xc6e06c))
    static let cherry = Species(height: 11, girth: 1.4, limbs: 5, reach: 8, clump: 2.9, bark: (0x5e4038, 0x86605a), leaves: (0xe880ad, 0xffd9e8))
    /// A young tree, head-high to a person and five cats tall: its whole crown is in view.
    static let sapling = Species(height: 5.5, girth: 0.3, limbs: 3, reach: 2.6, clump: 1.35, bark: (0x7a5a40, 0x9c7a56), leaves: (0x5c9c40, 0xb0d862))
    /// About half an oak's height and nearly as wide: an orchard tree is kept low, so its apples can be picked.
    static let apple = Species(height: 5.2, girth: 1.15, limbs: 6, reach: 7.4, clump: 2.5, bark: (0x6b5546, 0x93806c), leaves: (0x3f8236, 0x93c955), form: .apple)
    /// As tall as an oak, slimmer, and dark blue-green all year.
    static let pine = Species(height: 31, girth: 1.25, limbs: 5, reach: 5.2, clump: 2.3, bark: (0x6e5446, 0xc8743f), leaves: (0x2e5a42, 0x6f9c68), form: .pine)
}

struct Tree {
    var shape: Geometry
    var crown: Float       // radius its leaves cover, for the shade it throws
    var middle: Vec3       // the middle of its crown
    var bulk: Float        // radius of a ball round that middle holding most of the leaves
}

enum Trees {
    static func grow(_ s: Species, _ random: inout Seeded) -> Tree {
        if s.form == .pine { return growPine(s, &random) }
        let apple = s.form == .apple
        func between(_ low: Float, _ high: Float) -> Float { low + random.float() * (high - low) }
        var parts: [Geometry] = []

        // Trunk: a gentle S-bend, five root buttresses spreading at the base.
        let lean = Vec3(between(-1.2, 1.2), 0, between(-1.2, 1.2))
        let top = Vec3(lean.x * 1.4, s.height, lean.z * 1.4)
        let spine = CatmullRom([Vec3(0, -0.6, 0), Vec3(lean.x * 0.2, s.height * 0.3, lean.z * 0.2), Vec3(lean.x * 1.5, s.height * 0.68, lean.z * 1.5), top])
        let roots = between(0, 6)
        parts.append(Clay.limb(spine, s.girth, s.girth * 0.6, s.bark.0, s.bark.1, sides: 20, rings: 22) { along, angle in
            let flare = pow(max(0, 1 - along / 0.2), 2)
            let buttress = pow(max(0, cos(angle * 5 + roots)), 2)
            return 1 + flare * (0.35 + 1.5 * buttress)
        }.shape)

        // Limbs fork from the upper trunk, rising as they spread, each ending in a crown of leaf clumps. An
        // apple's spread wide and nearly level from lower down, as an orchard tree is pruned.
        var tips: [Vec3] = []
        for n in 0..<s.limbs {
            let around = Float(n) / Float(s.limbs) * 2 * .pi + between(-0.4, 0.4)
            let from = spine.pointAt(apple ? between(0.62, 0.95) : between(0.78, 0.97))
            let out = between(0.7, 1) * s.reach
            let rise = apple ? between(0.12, 0.38) : between(0.45, 0.85)
            let tip = Vec3(from.x + cos(around) * out, from.y + rise * s.reach, from.z + sin(around) * out)
            let elbow = Vec3(from.x + cos(around) * out * 0.55, from.y + s.reach * (apple ? 0.04 : 0.12), from.z + sin(around) * out * 0.55)
            parts.append(Clay.limb(QuadraticBezier(from, elbow, tip), s.girth * 0.42, s.girth * 0.14, s.bark.0, s.bark.1, sides: 8, rings: 10).shape)
            tips.append(tip)
        }
        // …and one leader carrying on upward.
        let climb: Float = apple ? 0.5 : 0.95
        let leader = Vec3(top.x + between(-1.5, 1.5), s.height + s.reach * climb, top.z + between(-1.5, 1.5))
        parts.append(Clay.limb(QuadraticBezier(top, Vec3(top.x, s.height + s.reach * (apple ? 0.27 : 0.5), top.z), leader), s.girth * 0.55, s.girth * 0.16, s.bark.0, s.bark.1,
                               sides: 8, rings: 10).shape)
        tips.append(leader)

        // Crown: big clumps at the limb ends, smaller ones filling between, pressed unevenly so no two
        // look alike. Darker beneath, sunlit on top. An apple's is a lower dome.
        var crown: Float = 0
        var clumps: [(at: Vec3, size: Float)] = []
        for tip in tips {
            let count = 4 + Int(random.float() * 3)
            for c in 0..<count {
                let size = s.clump * (c == 0 ? 1.15 : between(0.55, 0.95))
                let spread: Float = c == 0 ? 0 : s.clump * between(0.6, 1.25)
                let around = random.float() * .pi * 2
                let x = tip.x + cos(around) * spread, z = tip.z + sin(around) * spread
                let y = tip.y + (c == 0 ? 0.4 : between(-0.5, 0.6)) * s.clump
                parts.append(Clay.blob(at: Vec3(x, y, z), size: Vec3(size, size * (apple ? 0.72 : 0.8), size), color: s.leaves.0, top: s.leaves.1, lumpy: 0.16))
                clumps.append((Vec3(x, y, z), size))
                crown = max(crown, hypot(x, z) + size)
            }
        }
        if apple { parts += apples(on: clumps, &random) }
        let middle = tips.reduce(Vec3.zero, +) / Float(tips.count)
        let bulk = (tips.map { simd_distance($0, middle) }.max() ?? 0) + s.clump
        return Tree(shape: Geometry.join(parts), crown: crown, middle: middle, bulk: bulk)
    }

    /// An apple about twice life size, so it reads from the editor's height (as the meadow's blooms do): broad
    /// shoulders over a narrower base, a dimple and a stalk on top, yellow blushing up to red (or a green one).
    static func apple(at: Vec3, red: Bool) -> [Geometry] {
        var body = Clay.thrown([Vec2(0, 0.02), Vec2(0.17, 0), Vec2(0.31, 0.1), Vec2(0.34, 0.27), Vec2(0.28, 0.42), Vec2(0.12, 0.47), Vec2(0.04, 0.42), Vec2(0, 0.41)],
                               red ? 0xd8a43c : 0x9cba4a, red ? 0xcf3a2c : 0xc9d05a, around: 10, steps: 8)
        body.translate(at.x, at.y - 0.24, at.z)
        let stalk = Clay.limb(QuadraticBezier(at + Vec3(0, 0.15, 0), at + Vec3(0.01, 0.25, 0), at + Vec3(0.05, 0.31, 0)), 0.035, 0.03, 0x5a3e2b, 0x76533a, sides: 5, rings: 2)
        return [body, stalk.shape]
    }

    /// Apples hanging singly all over the outside of the crown, where they ripen in the sun (so they show from
    /// above as well as from the side), and a few windfalls lying in the grass under the crown.
    private static func apples(on clumps: [(at: Vec3, size: Float)], _ random: inout Seeded) -> [Geometry] {
        var parts: [Geometry] = []
        for clump in clumps {
            for _ in 0..<2 where random.float() < 0.6 {
                let around = random.float() * 2 * .pi
                let outward = simd_normalize(Vec3(clump.at.x, 0, clump.at.z) + Vec3(cos(around), 0, sin(around)) * 2)
                let way = simd_normalize(outward + Vec3(0, -0.6 + random.float() * 1.3, 0))
                let at = clump.at + way * Vec3(clump.size, clump.size * 0.72, clump.size) * 0.95
                parts += apple(at: .zero, red: random.float() < 0.8).map { $0.applied(.compose(at, euler: .zero, scale: Vec3(repeating: 1.3))) }
            }
        }
        for k in 0..<4 {
            let around = Float(k) * 1.9 + random.float(), out = 2.6 + random.float() * 3.5
            let lie = Mat4.compose(Vec3(cos(around) * out, 0, sin(around) * out), euler: Vec3(random.float() * 1.6, around, 0.4))
            parts += apple(at: Vec3(0, 0.24, 0), red: random.float() < 0.7).map { $0.applied(lie) }
        }
        return parts
    }

    /// A Scots pine: a tall trunk, grey-brown and plated low down, thinner and orange toward the top, bare for its
    /// lower half; above, short limbs in tiers round it (longest low in the crown, shortest at the top), each
    /// carrying a flat pad of needles, and a rounded pad at the very top, so the crown reads as calm layered
    /// clouds of dark blue-green.
    private static func growPine(_ s: Species, _ random: inout Seeded) -> Tree {
        func between(_ low: Float, _ high: Float) -> Float { low + random.float() * (high - low) }
        var parts: [Geometry] = []
        let lean = Vec3(between(-1, 1), 0, between(-1, 1))
        let top = Vec3(lean.x * 1.8, s.height, lean.z * 1.8)
        let spine = CatmullRom([Vec3(0, -0.6, 0), Vec3(lean.x * 0.25, s.height * 0.3, lean.z * 0.25), Vec3(lean.x * 1.5, s.height * 0.62, lean.z * 1.5), top])
        let roots = between(0, 6)
        parts.append(Clay.limb(spine, s.girth, s.girth * 0.3, s.bark.0, s.bark.1, sides: 18, rings: 26) { along, angle in
            let flare = pow(max(0, 1 - along / 0.12), 2)
            let buttress = pow(max(0, cos(angle * 4 + roots)), 2)
            // The lower bark in thick plates; smooth and thin above.
            let plates = 1 + 0.045 * sin(angle * 9 + along * 40) * max(0, 1 - along * 2)
            return (1 + flare * (0.3 + 0.9 * buttress)) * plates
        }.shape)

        var pads: [(at: Vec3, size: Float)] = []
        var turn = between(0, 2 * .pi)
        for tier in 0..<s.limbs {
            let t = Float(tier) / Float(s.limbs - 1)
            let from = spine.pointAt(0.5 + 0.42 * t + between(-0.025, 0.025))
            // An old pine's crown is broad and flat-topped, not a cone: widest in its upper middle.
            let width = s.reach * (0.62 + 0.45 * sin(.pi * min(t * 1.2, 1)))
            let limbs = tier == s.limbs - 1 ? 3 : 4
            for _ in 0..<limbs {
                turn += 2 * .pi / Float(limbs) + between(-0.6, 0.6)
                let out = width * between(0.7, 1.05)
                let tip = Vec3(from.x + cos(turn) * out, from.y + between(0.6, 1.8), from.z + sin(turn) * out)
                let elbow = Vec3(from.x + cos(turn) * out * 0.5, from.y - 0.2, from.z + sin(turn) * out * 0.5)
                parts.append(Clay.limb(QuadraticBezier(from, elbow, tip), s.girth * 0.3, s.girth * 0.12, s.bark.1, 0xb06a3c, sides: 8, rings: 8).shape)
                pads.append((tip, s.clump * between(0.85, 1.15)))
            }
        }
        pads.append((top + Vec3(0, s.clump * 0.3, 0), s.clump * 1.3))

        // Each pad a cloud of a few flattened clumps, darker beneath.
        var crown: Float = 0
        for pad in pads {
            for b in 0..<3 {
                let around = random.float() * 2 * .pi, spread: Float = b == 0 ? 0 : pad.size * between(0.5, 0.85)
                let size = pad.size * (b == 0 ? 1 : between(0.55, 0.8))
                let at = pad.at + Vec3(cos(around) * spread, (b == 0 ? 0.12 : between(-0.2, 0.2)) * pad.size, sin(around) * spread)
                parts.append(Clay.blob(at: at, size: Vec3(size * 1.15, size * 0.6, size), color: s.leaves.0, top: s.leaves.1, turn: Vec3(0, around, 0), lumpy: 0.2))
                crown = max(crown, hypot(at.x, at.z) + size * 1.15)
            }
        }
        let middle = pads.reduce(Vec3.zero) { $0 + $1.at } / Float(pads.count)
        let bulk = (pads.map { simd_distance($0.at, middle) }.max() ?? 0) + s.clump
        return Tree(shape: Geometry.join(parts), crown: crown, middle: middle, bulk: bulk)
    }
}
