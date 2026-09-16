import Foundation
import simd

// Trees as they grow, in clay: a trunk that flares into roots gripping the ground, limbs forking off it, and the
// leaves in masses filling the crown's space, each carried on a branch from the nearest limb. A mass is a cloud of
// small clumps, domed on top and flat beneath (a pine's a flat plate of needles; a birch's hangs from drooping
// twigs), so a crown reads as foliage from the editor's height as well as from the side, never as a few smooth
// balloons: many masses of different sizes, overlapping, with gaps between them where the limbs and the shade
// show, sunlit outside and dark within. Each kind fills a space of its own shape (`Species.Crown`): an oak's
// broad dome, a birch's narrow, airy oval, a cherry's vase, an apple tree's low, wide bowl open in the middle,
// a Scots pine's flat-topped umbrella high on a bare trunk.

struct Species {
    /// How a kind of tree grows.
    enum Form {
        /// A trunk forking into limbs: the oak, birch, cherry, a young tree.
        case broadleaf
        /// An orchard apple: a short trunk, limbs spreading wide and low round an open middle, apples among the
        /// leaves, a few windfalls in the grass beneath.
        case apple
        /// A Scots pine: a tall trunk, bare for most of its height and turning orange as it rises, carrying its
        /// needles in flat plates on short limbs straight off it.
        case pine
    }

    /// The space the leaves fill and how they fill it.
    struct Crown {
        /// From how high above the ground to how high: a dome round the middle of these, `reach` round.
        var low: Float
        var high: Float
        /// Masses of leaves in it, each kept `room` times its own size from the next (below 1.2 they overlap
        /// into a full crown; well above, the light comes through between them).
        var masses: Int
        var room: Float
        /// Small clumps in one mass.
        var clumps: ClosedRange<Int>
        /// A mass's height for its width: a flat plate (below 0.5, a pine's needles), domed and flat beneath
        /// (below 1), or hanging in a curtain from drooping twigs (above 1, a birch's).
        var tall: Float
        /// How much of the middle is kept open above the limbs, as an orchard tree is pruned (a share of the reach).
        var hollow: Float = 0
    }

    var height: Float      // ground to where the trunk forks (a pine: to its top)
    var girth: Float       // trunk radius just above the roots
    var limbs: Int         // limbs forking from the trunk (a pine: none, its branches come straight off it)
    var reach: Float       // how far the crown spreads round the trunk
    var clump: Float       // radius of one mass of leaves (a pine: of one plate of needles)
    var bark: (UInt32, UInt32)
    var leaves: (UInt32, UInt32)
    var crown: Crown
    var form = Form.broadleaf
    /// Dark marks across pale bark (a birch).
    var marked = false

    /// Broad and spreading, wider than tall on a short, stout trunk: heavy limbs leaving low, a dome of leaves in
    /// crowded billows with deep shade between.
    static let oak = Species(height: 8, girth: 1.9, limbs: 6, reach: 10.5, clump: 3, bark: (0x6a4d36, 0x97734f), leaves: (0x3f7a33, 0xa6d05c),
                             crown: Crown(low: 7, high: 23, masses: 25, room: 0.8, clumps: 4...5, tall: 0.85))
    /// Tall and light: a white trunk marked with black, a narrow crown of small curtains of leaves hanging from
    /// drooping twigs, with the light coming through between them.
    static let birch = Species(height: 9, girth: 1.0, limbs: 5, reach: 5.6, clump: 1.7, bark: (0xd9d4c6, 0xf3efe4), leaves: (0x6aa33e, 0xc6e06c),
                               crown: Crown(low: 8, high: 25, masses: 22, room: 1.55, clumps: 3...4, tall: 1.4), marked: true)
    /// In blossom: limbs rising into a vase, the blossom in clouds along them with the branches showing between.
    static let cherry = Species(height: 5, girth: 1.4, limbs: 5, reach: 8.5, clump: 1.9, bark: (0x5e4038, 0x86605a), leaves: (0xe27ba8, 0xffdcea),
                                crown: Crown(low: 5.5, high: 15, masses: 24, room: 1.05, clumps: 4...5, tall: 0.75))
    /// A young tree, head-high to a person and five cats tall: a slender stem, a few branches, a small open crown.
    static let sapling = Species(height: 3, girth: 0.3, limbs: 3, reach: 2.4, clump: 0.95, bark: (0x7a5a40, 0x9c7a56), leaves: (0x56973c, 0xb0d862),
                                 crown: Crown(low: 3, high: 7.6, masses: 7, room: 1.2, clumps: 3...5, tall: 0.75))
    /// About half an oak's height and nearly as wide: an orchard tree is kept low and open in the middle, so its
    /// apples ripen and can be picked.
    static let apple = Species(height: 3, girth: 1.1, limbs: 5, reach: 7.4, clump: 2, bark: (0x6b5546, 0x93806c), leaves: (0x3b7a33, 0x93c955),
                               crown: Crown(low: 3.6, high: 9.5, masses: 20, room: 0.95, clumps: 4...5, tall: 0.75, hollow: 0.35), form: .apple)
    /// As tall as an oak, slimmer, and dark blue-green all year.
    static let pine = Species(height: 31, girth: 1.25, limbs: 0, reach: 6.5, clump: 3, bark: (0x6e5446, 0xc8743f), leaves: (0x2a5540, 0x6f9c68),
                              crown: Crown(low: 15, high: 33, masses: 16, room: 1.6, clumps: 6...8, tall: 0.45), form: .pine)
}

struct Tree {
    var shape: Geometry
    var crown: Float       // radius its leaves cover, for the shade it throws
    var middle: Vec3       // the middle of its crown
    var bulk: Float        // radius of a ball round that middle holding most of the leaves
    var masses: [Ball]     // its masses of leaves
}

enum Trees {
    /// One small clump of leaves: where, its radius each way, and which mass it belongs to.
    private struct Clump { var at: Vec3; var size: Vec3; var mass: Int }
    /// A mass of leaves: its middle and radius.
    private struct Mass { var at: Vec3; var size: Float }

    static func grow(_ s: Species, _ random: inout Seeded) -> Tree {
        let pine = s.form == .pine, c = s.crown
        func between(_ low: Float, _ high: Float) -> Float { low + random.float() * (high - low) }
        var parts: [Geometry] = []

        // Trunk: a gentle S-bend, root buttresses spreading at the base. A pine's runs on up through its crown,
        // grey-brown and plated low down, thin and orange above.
        let lean = Vec3(between(-1.2, 1.2), 0, between(-1.2, 1.2)) * (pine ? 0.85 : 1)
        let top = Vec3(lean.x * 1.5, s.height, lean.z * 1.5)
        let spine = CatmullRom([Vec3(0, -0.6, 0), Vec3(lean.x * 0.2, s.height * 0.3, lean.z * 0.2), Vec3(lean.x * 1.5, s.height * 0.66, lean.z * 1.5), top])
        let roots = between(0, 6), sides = pine ? 18 : 16, rings = pine ? 26 : 16
        var trunk = Clay.limb(spine, s.girth, s.girth * (pine ? 0.3 : 0.6), s.bark.0, s.bark.1, sides: sides, rings: rings) { along, angle in
            let flare = pow(max(0, 1 - along / (pine ? 0.12 : 0.2)), 2)
            let buttress = pow(max(0, cos(angle * (pine ? 4 : 5) + roots)), 2)
            let plates = pine ? 1 + 0.045 * sin(angle * 9 + along * 40) * max(0, 1 - along * 2) : 1
            return (1 + flare * (pine ? 0.3 + 0.9 * buttress : 0.35 + 1.5 * buttress)) * plates
        }.shape
        let grain = Double(between(0, 1000))
        if s.marked { mark(&trunk, sides: sides, rings: rings, grain) }
        parts.append(trunk)

        // Limbs fork from the top of the trunk out into the crown, crooked, round it; a leader carries on up its
        // middle. Branches grow from these (a pine's from its trunk) to the leaves.
        var holds: [Curve] = pine ? [spine] : []
        let middle = Vec3(top.x, (c.low + c.high) / 2, top.z), half = (c.high - c.low) / 2
        var turn = between(0, 2 * .pi)
        for _ in 0..<s.limbs {
            turn += 2 * .pi / Float(s.limbs) + between(-0.35, 0.35)
            let from = spine.pointAt(between(0.86, 1))
            let way = Vec3(cos(turn), 0, sin(turn)), out = s.reach * between(0.5, 0.78)
            let tip = Vec3(middle.x, middle.y + half * between(-0.3, 0.45), middle.z) + way * out
            let side = Vec3(-way.z, 0, way.x) * between(-0.2, 0.2) * out
            let limb = QuadraticBezier(from, (from + tip) / 2 + side - Vec3(0, (tip.y - from.y) * 0.15, 0), tip)
            parts.append(Clay.limb(limb, s.girth * 0.45, s.girth * 0.14, s.bark.0, s.bark.1, sides: 8, rings: 8).shape)
            holds.append(limb)
        }
        if !pine {
            let leader = QuadraticBezier(top, Vec3(top.x + between(-0.6, 0.6), (top.y + c.high) / 2, top.z + between(-0.6, 0.6)),
                                         Vec3(top.x + between(-1, 1), c.high - s.clump * 0.9, top.z + between(-1, 1)))
            parts.append(Clay.limb(leader, s.girth * 0.5, s.girth * 0.12, s.bark.0, s.bark.1, sides: 8, rings: 8).shape)
            holds.append(leader)
        }

        // The masses, scattered through the crown's space and most toward its outside (where the light is), its
        // underside flatter; none closer to the next than its room allows, so they overlap or stand apart as the
        // kind's do. An orchard tree's middle is kept open above its limbs; a pine's trunk ends under a plate of
        // its own.
        var masses: [Mass] = pine ? [Mass(at: top + Vec3(0, s.clump * 0.3, 0), size: s.clump * 1.1)] : []
        for _ in 0..<(c.masses * 60) where masses.count < c.masses {
            var d = Vec3(between(-1, 1), between(-1, 1), between(-1, 1))
            let length = simd_length(d)
            guard length > 0.05, length <= 1 else { continue }
            d = d / length * (1 - pow(between(0, 1), 2) * 0.55)
            if d.y < 0 { d.y *= 0.75 }
            if hypot(d.x, d.z) < c.hollow, d.y > -0.3 { continue }
            let at = middle + Vec3(d.x * s.reach, d.y * half, d.z * s.reach), size = s.clump * between(0.65, 1.3)
            guard masses.allSatisfy({ simd_distance($0.at, at) > ($0.size + size) * 0.5 * c.room }) else { continue }
            masses.append(Mass(at: at, size: size))
        }

        // Each mass on a branch from the nearest point of a limb, the leader or a pine's trunk, unless it sits on
        // one already.
        for mass in masses {
            var from = Vec3.zero, nearest = Float.infinity
            for hold in holds {
                for k in 2...10 {
                    let p = hold.pointAt(Float(k) / 10)
                    if simd_distance(p, mass.at) < nearest { nearest = simd_distance(p, mass.at); from = p }
                }
            }
            guard nearest > mass.size * 0.5 else { continue }
            let to = mass.at - Vec3(0, mass.size * (pine ? 0.1 : 0.3), 0)
            let branch = QuadraticBezier(from, (from + to) / 2 + Vec3(0, nearest * (pine ? -0.08 : 0.12), 0), to)
            parts.append(pine ? Clay.limb(branch, s.girth * 0.24, s.girth * 0.09, s.bark.1, 0xb06a3c, sides: 6, rings: 5).shape
                              : Clay.limb(branch, s.girth * 0.17, s.girth * 0.06, s.bark.0, s.bark.1, sides: 5, rings: 4).shape)
        }

        var clumps: [Clump] = []
        for (m, mass) in masses.enumerated() {
            clumps += self.clumps(of: mass, m, count: Int(between(Float(c.clumps.lowerBound), Float(c.clumps.upperBound) + 0.99)), tall: c.tall, &random)
        }
        parts.append(foliage(clumps, masses, colors: s.leaves, grain))
        if s.form == .apple { parts += apples(in: clumps, &random) }
        return tree(parts, masses, clumps)
    }

    /// The tree's measures from its leaves: how far they spread, the middle of its crown, and the ball round
    /// that middle holding most of them.
    private static func tree(_ parts: [Geometry], _ masses: [Mass], _ clumps: [Clump]) -> Tree {
        let crown = clumps.map { hypot($0.at.x, $0.at.z) + $0.size.x }.max() ?? 0
        let middle = masses.reduce(Vec3.zero) { $0 + $1.at } / Float(max(masses.count, 1))
        let bulk = masses.map { simd_distance($0.at, middle) + $0.size * 0.8 }.max() ?? 0
        return Tree(shape: Geometry.join(parts), crown: crown, middle: middle, bulk: bulk, masses: masses.map { Ball(center: $0.at, radius: $0.size) })
    }

    /// A mass as small clumps: a larger one in the middle, the rest round it and a little lower, so it is domed
    /// on top and flat beneath, its edge broken. A plate (`tall` below 0.5) spreads them flat; hanging (above 1),
    /// they trail down below it instead.
    private static func clumps(of mass: Mass, _ m: Int, count: Int, tall: Float, _ random: inout Seeded) -> [Clump] {
        func between(_ low: Float, _ high: Float) -> Float { low + random.float() * (high - low) }
        var out: [Clump] = []
        var around = between(0, 2 * .pi)
        for c in 0..<count {
            let r: Float, at: Vec3
            if c == 0 {
                r = mass.size * 0.6
                at = mass.at
            } else if tall < 0.5 {
                // A plate: spread flat round the middle, thicker toward it.
                around += 2.4 + between(-0.5, 0.5)
                let spread = mass.size * between(0.4, 1)
                r = mass.size * between(0.3, 0.44)
                at = mass.at + Vec3(cos(around) * spread, mass.size * (between(-0.12, 0.1) + 0.18 * (1 - spread / mass.size)), sin(around) * spread)
            } else if tall > 1 {
                around += 2.4 + between(-0.4, 0.4)
                r = mass.size * between(0.42, 0.56)
                let down = mass.size * tall * Float(c) / Float(count) * between(0.75, 1)
                let spread = mass.size * between(0.25, 0.55)
                at = mass.at + Vec3(cos(around) * spread, -down, sin(around) * spread)
            } else {
                around += 2.4 + between(-0.5, 0.5)
                r = mass.size * between(0.42, 0.6)
                let spread = mass.size * between(0.38, 0.72)
                at = mass.at + Vec3(cos(around) * spread, mass.size * tall * between(-0.4, 0.25), sin(around) * spread)
            }
            out.append(Clump(at: at, size: tall < 0.5 ? Vec3(r * 1.15, r * 0.58, r) : Vec3(r, r * min(tall, 1) * 1.1, r), mass: m))
        }
        return out
    }

    /// A small clump of leaves: a ball of few points (it is small, and there are many), lit as a smooth one.
    private static let leafBall: Geometry = Shapes.icosahedron(1, detail: 1).welded()

    /// The clumps as one shape. Each is pressed a little out of round; its light is bent toward its mass's, so a
    /// mass shades as one soft cloud while its edge stays broken by the clumps; and it is coloured by where it
    /// lies: dark deep inside the crown and in the hollows between clumps, lighter outward and toward the top,
    /// each mass a little different from the next.
    private static func foliage(_ clumps: [Clump], _ masses: [Mass], colors: (UInt32, UInt32), _ grain: Double) -> Geometry {
        let low = linear(colors.0), high = linear(colors.1), deep = low * 0.34
        let ys = masses.map(\.at.y)
        let bottom = (ys.min() ?? 0) - (masses.map(\.size).max() ?? 0), top = (ys.max() ?? 0) + (masses.map(\.size).max() ?? 0)
        let middle = masses.reduce(Vec3.zero) { $0 + $1.at } / Float(max(masses.count, 1))
        let wide = max(masses.map { hypot($0.at.x - middle.x, $0.at.z - middle.z) + $0.size }.max() ?? 1, 1)
        var parts: [Geometry] = []
        parts.reserveCapacity(clumps.count)
        for (k, clump) in clumps.enumerated() {
            let mass = masses[clump.mass]
            var g = leafBall
            // Smooth: each point's normal is the pressed ball's, not its facets'.
            g.normals = g.positions.map { simd_normalize($0 / clump.size) }
            for i in g.positions.indices {
                let press = 1 + Float(lattice(Double(i) * 1.37, Double(k) * 0.71, grain) - 0.5) * 0.24
                g.positions[i] = clump.at + g.positions[i] * clump.size * press
            }
            // The side of a clump turned in toward its mass's middle (the top of the middle one) is in the hollow.
            let inward = simd_normalize(clump.at - mass.at + Vec3(0, mass.size * 0.5, 0))
            // Each mass a little lighter or darker, a little warmer or cooler, than the next.
            let shift = Float(lattice(Double(clump.mass) * 3.3, 1.9, grain) - 0.5)
            let tint = Vec3(1 + shift * 0.12, 1 + shift * 0.06, 1 - shift * 0.16) * (1 + shift * 0.22)
            g.colors = []
            for i in g.positions.indices {
                let p = g.positions[i], n = g.normals[i]
                let outward = simd_normalize(p - mass.at + Vec3(0, mass.size * 0.35, 0))
                let whole = simd_normalize(p - middle + Vec3(0, (top - bottom) * 0.2, 0))
                g.normals[i] = simd_normalize(n * 0.35 + outward * 0.45 + whole * 0.2)
                let up = clamp((p.y - bottom) / max(top - bottom, 1e-3), 0, 1)
                let out = clamp(hypot(p.x - middle.x, p.z - middle.z) / wide, 0, 1)
                let inMass = clamp((p.y - mass.at.y) / mass.size * 0.6 + 0.5, 0, 1)
                let open = smoothstep(simd_dot(n, inward), -0.6, 0.4)
                let light = clamp(0.06 + 0.46 * up + 0.24 * out + 0.26 * inMass, 0, 1) * (0.5 + 0.5 * open)
                let color = light < 0.5 ? lerp(deep, low, light * 2) : lerp(low, high, (light - 0.5) * 2)
                // Dappled, as leaves catch the light one by one.
                let dapple = 1 + Float(lattice(Double(i) * 2.9, Double(k) * 1.3, grain + 3) - 0.5) * 0.34
                g.colors.append(color * tint * dapple)
            }
            parts.append(g)
        }
        return Geometry.join(parts)
    }

    /// A birch's bark: black marks across the white in short dashes, and darker, fissured bark at its foot.
    private static func mark(_ trunk: inout Geometry, sides: Int, rings: Int, _ grain: Double) {
        let dark = linear(0x3b3632)
        for ring in 0...rings {
            let along = Float(ring) / Float(rings)
            for side in 0..<sides {
                let i = ring * sides + side
                let dash = lattice(Double(ring) * 1.7, Double(side / 3), grain) > 0.74 && along > 0.08
                let foot = along < 0.14 && lattice(Double(ring), Double(side) * 0.9, grain + 5) < 0.75 - Double(along) * 4
                if dash || foot { trunk.colors[i] = lerp(trunk.colors[i], dark, dash ? 0.85 : 0.7) }
            }
        }
    }

    /// An apple about life size (a little over: the meadow's blooms are larger than life, but fruit hung on a
    /// tree that big reads as boils): broad shoulders over a narrower base, a dimple and a stalk on top, yellow
    /// blushing up to red (or a green one).
    static func apple(at: Vec3, red: Bool) -> [Geometry] {
        var body = Clay.thrown([Vec2(0, 0.02), Vec2(0.17, 0), Vec2(0.31, 0.1), Vec2(0.34, 0.27), Vec2(0.28, 0.42), Vec2(0.12, 0.47), Vec2(0.04, 0.42), Vec2(0, 0.41)],
                               red ? 0xd8a43c : 0x9cba4a, red ? 0xc23a2c : 0xc9d05a, around: 9, steps: 6)
        body.translate(at.x, at.y - 0.24, at.z)
        let stalk = Clay.limb(QuadraticBezier(at + Vec3(0, 0.15, 0), at + Vec3(0.01, 0.25, 0), at + Vec3(0.05, 0.31, 0)), 0.035, 0.03, 0x5a3e2b, 0x76533a, sides: 4, rings: 2)
        return [body, stalk.shape]
    }

    /// Apples hanging among the leaves, half hidden in the clumps' lower and outer sides (where they hang from
    /// the spurs below the leaves), and a few windfalls lying in the grass under the crown.
    private static func apples(in clumps: [Clump], _ random: inout Seeded) -> [Geometry] {
        var parts: [Geometry] = []
        for clump in clumps where random.float() < 0.42 {
            let around = random.float() * 2 * .pi
            let way = simd_normalize(Vec3(cos(around), 0.35 - random.float() * 1.35, sin(around)))
            let at = clump.at + way * clump.size * 0.92
            parts += apple(at: at, red: random.float() < 0.8)
        }
        for k in 0..<4 {
            let around = Float(k) * 1.9 + random.float(), out = 2.6 + random.float() * 3.5
            let lie = Mat4.compose(Vec3(cos(around) * out, 0, sin(around) * out), euler: Vec3(random.float() * 1.6, around, 0.4))
            parts += apple(at: Vec3(0, 0.24, 0), red: random.float() < 0.7).map { $0.applied(lie) }
        }
        return parts
    }
}
