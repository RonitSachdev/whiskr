import Foundation
import simd

// Port of src/meadow/trees.ts: trees as they actually grow, in clay: a trunk that flares into roots
// gripping the ground, limbs forking off it, and a crown of many overlapping clumps of leaves.

struct Species {
    var height: Float      // ground to where the trunk forks
    var girth: Float       // trunk radius just above the roots
    var limbs: Int
    var reach: Float       // how far limbs spread
    var clump: Float       // size of one clump of leaves
    var bark: (UInt32, UInt32)
    var leaves: (UInt32, UInt32)

    static let oak = Species(height: 16, girth: 1.9, limbs: 5, reach: 9.5, clump: 3.4, bark: (0x6a4d36, 0x97734f), leaves: (0x4c8a3a, 0xa3d15a))
    static let birch = Species(height: 21, girth: 1.0, limbs: 4, reach: 6, clump: 2.4, bark: (0xd9d4c6, 0xf3efe4), leaves: (0x74ad42, 0xc6e06c))
    static let cherry = Species(height: 11, girth: 1.4, limbs: 5, reach: 8, clump: 2.9, bark: (0x5e4038, 0x86605a), leaves: (0xe880ad, 0xffd9e8))
    /// A young tree, head-high to a person and five cats tall: its whole crown is in view.
    static let sapling = Species(height: 5.5, girth: 0.3, limbs: 3, reach: 2.6, clump: 1.35, bark: (0x7a5a40, 0x9c7a56), leaves: (0x5c9c40, 0xb0d862))
}

struct Tree {
    var shape: Geometry
    var crown: Float       // radius its leaves cover, for the shade it throws
    var middle: Vec3       // the middle of its crown
    var bulk: Float        // radius of a ball round that middle holding most of the leaves
}

enum Trees {
    static func grow(_ s: Species, _ random: inout Seeded) -> Tree {
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

        // Limbs fork from the upper trunk, rising as they spread, each ending in a crown of leaf clumps.
        var tips: [Vec3] = []
        for n in 0..<s.limbs {
            let around = Float(n) / Float(s.limbs) * 2 * .pi + between(-0.4, 0.4)
            let from = spine.pointAt(between(0.78, 0.97))
            let out = between(0.7, 1) * s.reach
            let tip = Vec3(from.x + cos(around) * out, from.y + between(0.45, 0.85) * s.reach, from.z + sin(around) * out)
            let elbow = Vec3(from.x + cos(around) * out * 0.55, from.y + s.reach * 0.12, from.z + sin(around) * out * 0.55)
            parts.append(Clay.limb(QuadraticBezier(from, elbow, tip), s.girth * 0.42, s.girth * 0.14, s.bark.0, s.bark.1, sides: 8, rings: 10).shape)
            tips.append(tip)
        }
        // …and one leader carrying on upward.
        let leader = Vec3(top.x + between(-1.5, 1.5), s.height + s.reach * 0.95, top.z + between(-1.5, 1.5))
        parts.append(Clay.limb(QuadraticBezier(top, Vec3(top.x, s.height + s.reach * 0.5, top.z), leader), s.girth * 0.55, s.girth * 0.16, s.bark.0, s.bark.1, sides: 8, rings: 10).shape)
        tips.append(leader)

        // Crown: big clumps at the limb ends, smaller ones filling between, pressed unevenly so no two
        // look alike. Darker beneath, sunlit on top.
        var crown: Float = 0
        for tip in tips {
            let clumps = 4 + Int(random.float() * 3)
            for c in 0..<clumps {
                let size = s.clump * (c == 0 ? 1.15 : between(0.55, 0.95))
                let spread: Float = c == 0 ? 0 : s.clump * between(0.6, 1.25)
                let around = random.float() * .pi * 2
                let x = tip.x + cos(around) * spread, z = tip.z + sin(around) * spread
                let y = tip.y + (c == 0 ? 0.4 : between(-0.5, 0.6)) * s.clump
                parts.append(Clay.blob(at: Vec3(x, y, z), size: Vec3(size, size * 0.8, size), color: s.leaves.0, top: s.leaves.1, lumpy: 0.16))
                crown = max(crown, hypot(x, z) + size)
            }
        }
        let middle = tips.reduce(Vec3.zero, +) / Float(tips.count)
        let bulk = (tips.map { simd_distance($0, middle) }.max() ?? 0) + s.clump
        return Tree(shape: Geometry.join(parts), crown: crown, middle: middle, bulk: bulk)
    }
}
