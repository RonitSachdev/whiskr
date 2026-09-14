import Foundation
import simd

// Port of src/village/picnic.ts and blanket.ts shapes, plus the Mac design's lantern. Each is modelled on
// the real thing (how a hamper is woven and lidded, how a teapot is thrown, how a rice ball is pressed,
// how a hurricane lantern is built) and then simplified into clay. Built once, shared by every blanket.

struct Treat {
    var shape: Geometry
    var reach: Float   // radius of the ground it covers, for keeping cats and other things clear of it
}

enum Picnic {
    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }
    private static func at(_ parts: [Geometry], _ x: Float, _ y: Float, _ z: Float, _ turn: Vec3 = .zero) -> [Geometry] { Clay.seat(parts, v(x, y, z), turn) }
    private static func p(_ list: [(Float, Float)]) -> [Vec2] { list.map { Vec2($0.0, $0.1) } }

    static let plateColors: (UInt32, UInt32) = (0xe6e0d4, 0xfbf8f2)
    static func plate(_ r: Float) -> Geometry {
        Clay.thrown(p([(0, 0), (r * 0.55, 0), (r * 0.9, 0.03), (r, 0.055), (r * 0.93, 0.06), (r * 0.55, 0.03), (0, 0.03)]), plateColors.0, plateColors.1, around: 24)
    }

    /// A wicker hamper, closed and ready to carry: sides of stacked willow rounds that widen a little
    /// toward a darker rim, a gently domed lid, two leather straps on the front, and a hoop handle.
    static func basket() -> Geometry {
        let rows = 8, tall: Float = 0.5
        let groove: UInt32 = 0xa9783f, round: UInt32 = 0xddb877, rim: UInt32 = 0x8f6236, leather: UInt32 = 0x6b4428
        // Each row of willow is a ridge with a groove under it, which is what makes wicker read as wicker.
        var sides: [Clay.Ring] = [], tones: [UInt32] = []
        for i in 0..<rows {
            let f = Float(i) / Float(rows)
            let w = 0.5 + f * 0.06, d = 0.35 + f * 0.04, y = 0.02 + f * tall
            sides += [Clay.Ring(w: w - 0.02, d: d - 0.02, y: y), Clay.Ring(w: w, d: d, y: y + tall / Float(rows) / 2)]
            tones += [groove, round]
        }
        sides += [Clay.Ring(w: 0.55, d: 0.38, y: tall + 0.02), Clay.Ring(w: 0.6, d: 0.43, y: tall + 0.05), Clay.Ring(w: 0.59, d: 0.42, y: tall + 0.09)]
        tones += [groove, rim, rim]
        var lid: [Clay.Ring] = [], shades: [UInt32] = []
        for i in 0...4 {
            let out = cos(Float(i) / 4 * .pi * 0.5)
            lid.append(Clay.Ring(w: 0.08 + 0.5 * out, d: 0.06 + 0.35 * out, y: tall + 0.09 + sin(Float(i) / 4 * .pi * 0.5) * 0.09))
            shades.append(i % 2 == 1 ? round : 0xc99c5a)
        }
        return Geometry.join([
            Clay.stacked(sides, around: 36) { row, _ in tones[row] },
            Clay.stacked(lid, around: 36) { row, _ in shades[row] },
            // Two leather straps with brass studs hold the lid shut.
            Clay.blob(at: v(0.28, tall - 0.02, 0.41), size: v(0.045, 0.11, 0.02), color: leather, top: 0x8a5a36),
            Clay.blob(at: v(0.28, tall - 0.1, 0.425), size: v(0.03, 0.03, 0.015), color: 0xcaa24a, top: 0xe6c36c),
            Clay.blob(at: v(-0.28, tall - 0.02, 0.41), size: v(0.045, 0.11, 0.02), color: leather, top: 0x8a5a36),
            Clay.blob(at: v(-0.28, tall - 0.1, 0.425), size: v(0.03, 0.03, 0.015), color: 0xcaa24a, top: 0xe6c36c),
            Clay.limb(QuadraticBezier(v(-0.56, tall + 0.02, 0), v(0, 1.62, 0), v(0.56, tall + 0.02, 0)), 0.05, 0.05, rim, 0xc0935a, sides: 8, rings: 20).shape,
        ])
    }

    /// A round-bellied teapot with a swan-neck spout and a looped handle, and two cups of tea on saucers.
    static func teaSet() -> Geometry {
        let glaze: UInt32 = 0x7fa7b8, light: UInt32 = 0xbfdbe4, cream: UInt32 = 0xe9e3d6, white: UInt32 = 0xfdfbf6
        func cup(_ x: Float, _ z: Float, _ turn: Float) -> [Geometry] {
            at([
                plate(0.2),
                Clay.thrown(p([(0, 0.03), (0.07, 0.03), (0.085, 0.05), (0.125, 0.14), (0.145, 0.22), (0.13, 0.22), (0.11, 0.14), (0.07, 0.07), (0, 0.065)]), cream, white, around: 18),
                Clay.blob(at: v(0, 0.175, 0), size: v(0.118, 0.008, 0.118), color: 0xa9652c, top: 0xc98445),
                Clay.limb(CubicBezier(v(0.125, 0.2, 0), v(0.23, 0.21, 0), v(0.21, 0.08, 0), v(0.095, 0.08, 0)), 0.02, 0.02, cream, white, sides: 6, rings: 8).shape,
            ], x, 0, z, v(0, turn, 0))
        }
        return Geometry.join([
            Clay.thrown(p([(0, 0), (0.2, 0), (0.23, 0.03), (0.3, 0.08), (0.41, 0.2), (0.44, 0.33), (0.39, 0.47), (0.27, 0.56), (0.2, 0.58), (0, 0.58)]), glaze, light, around: 24, steps: 28),
            Clay.thrown(p([(0.215, 0.575), (0.21, 0.61), (0.13, 0.66), (0.05, 0.685), (0, 0.69)]), light, 0xd3e7ee, around: 24),
            Clay.blob(at: v(0, 0.74, 0), size: v(0.06, 0.055, 0.06), color: cream, top: white),
            Clay.limb(CubicBezier(v(0.34, 0.2, 0), v(0.62, 0.2, 0), v(0.52, 0.5, 0), v(0.74, 0.6, 0)), 0.1, 0.045, glaze, light, sides: 10, rings: 12).shape,
            Clay.limb(CubicBezier(v(-0.33, 0.48, 0), v(-0.72, 0.56, 0), v(-0.7, 0.1, 0), v(-0.38, 0.17, 0)), 0.04, 0.04, glaze, light, sides: 8, rings: 14).shape,
        ] + cup(0.7, 0.5, 0.6) + cup(0.42, -0.68, -2.2))
    }

    /// Rice balls pressed into rounded triangles, each with a strip of seaweed folded up from its base, on
    /// a wooden board with a few slices of yellow pickle.
    static func riceBalls() -> Geometry {
        let corner: Float = 0.07, half: Float = 0.2, tall: Float = 0.33
        var o = Outline(divisions: 8)
        o.move(-half + corner, 0)
        o.line(half - corner, 0)
        o.quadratic(half + 0.02, 0, half - 0.03, corner * 1.3)
        o.line(corner * 0.6, tall - corner * 0.5)
        o.quadratic(0, tall + 0.03, -corner * 0.6, tall - corner * 0.5)
        o.line(-half + 0.03, corner * 1.3)
        o.quadratic(-half - 0.02, 0, -half + corner, 0)
        let outline = o.closed
        func ball(_ x: Float, _ z: Float, _ turn: Float, _ lean: Float) -> [Geometry] {
            var wrap = Shapes.roundedBox(0.17, 0.19, 0.225, segments: 1, radius: 0.001)
            wrap.translate(0, 0.07, 0)
            return at([Clay.pressed(outline, thick: 0.1, soft: 0.055, 0xeeeae0, 0xffffff), wrap.painted(0x1f2b25, 0x33443a)], x, 0.11, z, v(lean, turn, 0))
        }
        return Geometry.join([
            Clay.thrown(p([(0, 0), (0.5, 0), (0.56, 0.02), (0.57, 0.05), (0.5, 0.055), (0, 0.05)]), 0xa6763f, 0xd2a268, around: 28),
        ] + ball(-0.2, 0.13, 0.35, -0.12) + ball(0.2, 0.08, -0.45, -0.12) + ball(-0.02, -0.24, 0.1, -0.12) + [
            Clay.blob(at: v(0.32, 0.075, -0.24), size: v(0.07, 0.02, 0.07), color: 0xe6c341, top: 0xf6dc6a),
            Clay.blob(at: v(0.39, 0.085, -0.16), size: v(0.07, 0.02, 0.07), color: 0xe6c341, top: 0xf6dc6a, turn: v(0.3, 0, 0.2)),
        ])
    }

    /// Apples with a dimple at each end, broad shoulders and a short woody stalk: two red ones blushing
    /// up from yellow, and a green one tipped over.
    static func apples() -> Geometry {
        func apple(_ x: Float, _ z: Float, _ low: UInt32, _ high: UInt32, _ tilt: Vec3, _ leaf: Bool) -> [Geometry] {
            at([
                Clay.thrown(p([(0, 0.035), (0.05, 0.005), (0.12, 0.012), (0.19, 0.09), (0.215, 0.2), (0.2, 0.3), (0.14, 0.365), (0.07, 0.375), (0.025, 0.345), (0, 0.335)]), low, high, around: 18, steps: 22),
                Clay.limb(QuadraticBezier(v(0, 0.33, 0), v(0.01, 0.4, 0), v(0.04, 0.45, 0)), 0.014, 0.012, 0x5a3e2b, 0x76533a, sides: 5, rings: 4).shape,
            ] + (leaf ? [Clay.blob(at: v(0.1, 0.44, 0), size: v(0.085, 0.012, 0.045), color: 0x4f8a36, top: 0x86bd58, turn: v(0, 0, 0.35))] : []), x, 0, z, tilt)
        }
        return Geometry.join(apple(-0.25, 0.12, 0xd9a13c, 0xc9302a, v(0, 0.4, 0), true) + apple(0.24, 0.16, 0xe0b548, 0xd4403a, v(0, 2.2, 0), false)
                             + apple(0.02, -0.3, 0x8fb04a, 0xb9d466, v(1.25, 0.6, 0), false).map { $0.applied(.translation(v(0, 0.2, 0))) })
    }

    /// A slice of strawberry shortcake on a plate: two layers of sponge with cream between and on top, a
    /// strawberry on a swirl of cream, and a fork.
    static func cake() -> Geometry {
        // A wedge of a round cake standing on the plate, its point toward the middle.
        func wedge(_ from: Float, _ to: Float, _ low: Float, _ high: Float, _ bottom: UInt32, _ top: UInt32) -> Geometry {
            let half: Float = 0.36
            var o = Outline(divisions: 10)
            o.move(cos(-half) * from, sin(-half) * from)
            o.arc(0, 0, to, -half, half, clockwise: false)
            o.line(cos(half) * from, sin(half) * from)
            if from > 0 { o.arc(0, 0, from, half, -half, clockwise: true) }
            var solid = Extrude.extrude(o.closed, depth: high - low)
            solid.apply(.translation(v(-0.27, low, 0)) * .rotationX(-.pi / 2))
            return solid.painted(bottom, top)
        }
        func layer(_ low: Float, _ high: Float, _ bottom: UInt32, _ top: UInt32) -> Geometry { wedge(0, 0.5, low, high, bottom, top) }
        var berry = Clay.thrown(p([(0, 0.4), (0.05, 0.41), (0.075, 0.45), (0.06, 0.51), (0.02, 0.55), (0, 0.555)]), 0xd9363a, 0xc22a2e, around: 12)
        berry.translate(0.14, 0, 0)
        return Geometry.join([
            plate(0.46),
            layer(0.05, 0.16, 0xe3b866, 0xf1d08d), layer(0.16, 0.2, 0xfff6ea, 0xffffff), layer(0.2, 0.31, 0xe3b866, 0xf1d08d), layer(0.31, 0.36, 0xfff6ea, 0xffffff),
            wedge(0.5, 0.53, 0.05, 0.36, 0xfff6ea, 0xffffff),
            // A glimpse of sliced strawberry in the filling.
            Clay.blob(at: v(-0.08, 0.18, 0.075), size: v(0.045, 0.022, 0.02), color: 0xd9363a),
            Clay.blob(at: v(0.08, 0.18, 0.135), size: v(0.045, 0.022, 0.02), color: 0xd9363a),
            Clay.blob(at: v(0.14, 0.38, 0), size: v(0.085, 0.05, 0.085), color: 0xfff6ea, top: 0xffffff, lumpy: 0.12),
            berry,
            Clay.blob(at: v(0.14, 0.41, 0), size: v(0.07, 0.012, 0.07), color: 0x4f8a36, top: 0x77ad4c),
            Clay.limb(QuadraticBezier(v(-0.2, 0.065, 0.36), v(0, 0.07, 0.4), v(0.2, 0.065, 0.36)), 0.014, 0.012, 0xb9bcc0, 0xe4e6e8, sides: 5, rings: 4).shape,
            Clay.blob(at: v(0.27, 0.066, 0.345), size: v(0.07, 0.008, 0.03), color: 0xc9ccd0, top: 0xeceef0, turn: v(0, 0.3, 0)),
        ])
    }

    /// A square scatter cushion: plump in the middle, thin at the seams, its corners pulled to points,
    /// with a button stitched through the centre.
    static func cushion() -> Geometry {
        var soft = Shapes.icosahedron(1, detail: 4).welded()
        for i in soft.positions.indices {
            let q = soft.positions[i]
            let flat = hypot(q.x, q.z), angle = atan2(q.z, q.x)
            // Pull the round outline out toward a square, further at the corners.
            let squared = 1 / max(abs(cos(angle)), abs(sin(angle)))
            let corner = abs(sin(angle * 2))
            let out = flat * (1 + (squared - 1) * 0.93 + pow(corner, 8) * 0.12 * flat)
            let dimple = 1 - 0.35 * exp(-flat * flat * 40)
            soft.positions[i] = Vec3(cos(angle) * out * 0.46, 0.27 + q.y * 0.27 * (1 - 0.6 * pow(flat, 4)) * dimple, sin(angle) * out * 0.46)
        }
        soft.computeNormals()
        return Geometry.join([soft.painted(0xd2977f, 0xf0c4ae), Clay.blob(at: v(0, 0.445, 0), size: v(0.06, 0.03, 0.06), color: 0xb97862, top: 0xc98a73)])
    }

    /// An enamel jug of flowers picked on the way: daisies, tulips still in bud and a spike of lavender.
    static func flowers() -> Geometry {
        func stem(_ x: Float, _ y: Float, _ z: Float) -> Geometry {
            Clay.limb(QuadraticBezier(v(0, 0.4, 0), v(x * 0.35, y - 0.16, z * 0.35), v(x, y, z)), 0.02, 0.016, 0x4f8a36, 0x6fae45, sides: 5, rings: 5).shape
        }
        func daisy(_ x: Float, _ y: Float, _ z: Float, _ tilt: Vec3) -> [Geometry] {
            var petals: [Geometry] = []
            for i in 0..<9 {
                let round = Float(i) / 9 * 2 * .pi
                petals.append(Clay.blob(at: v(cos(round) * 0.085, 0, sin(round) * 0.085), size: v(0.06, 0.012, 0.03), color: 0xf3efe6, top: 0xffffff, turn: v(0, -round, 0)))
            }
            return [stem(x, y, z)] + at(petals + [Clay.blob(at: v(0, 0.012, 0), size: v(0.045, 0.028, 0.045), color: 0xe2a22b, top: 0xf6cd4f)], x, y, z, tilt)
        }
        func tulip(_ x: Float, _ y: Float, _ z: Float, _ color: UInt32, _ top: UInt32) -> [Geometry] {
            var bud = Clay.thrown(p([(0, 0), (0.045, 0.01), (0.07, 0.07), (0.06, 0.14), (0.025, 0.18), (0, 0.185)]), color, top, around: 10)
            bud.translate(x, y - 0.02, z)
            return [stem(x, y, z), bud]
        }
        func leaf(_ round: Float) -> Geometry {
            Clay.blob(at: v(cos(round) * 0.2, 0.52, sin(round) * 0.2), size: v(0.17, 0.02, 0.06), color: 0x4f8a36, top: 0x86bd58, turn: v(0, -round, 0.55))
        }
        var parts = [
            Clay.thrown(p([(0, 0), (0.16, 0), (0.19, 0.02), (0.235, 0.15), (0.215, 0.29), (0.15, 0.39), (0.14, 0.44), (0.18, 0.5), (0.165, 0.5), (0.12, 0.43), (0, 0.4)]), 0xe6dfd0, 0xfbf7ee, around: 22, steps: 26),
            Clay.thrown(p([(0.172, 0.488), (0.19, 0.5), (0.172, 0.512)]), 0x4f77a8, 0x6f95c4, around: 22, steps: 4),
            Clay.limb(CubicBezier(v(-0.17, 0.46, 0), v(-0.4, 0.48, 0), v(-0.4, 0.14, 0), v(-0.22, 0.17, 0)), 0.03, 0.03, 0xe6dfd0, 0xfbf7ee, sides: 6, rings: 10).shape,
            leaf(0.5), leaf(2.4), leaf(4.3),
        ]
        parts += daisy(0.03, 0.86, 0.02, v(0.15, 0, -0.1)) + daisy(0.2, 0.74, 0.1, v(0.3, 0, -0.5)) + daisy(-0.13, 0.72, -0.14, v(-0.4, 0, 0.4))
        parts += tulip(-0.19, 0.74, 0.1, 0xe2607c, 0xf59ab0) + tulip(0.1, 0.72, -0.19, 0xeab23c, 0xf8d66a)
        parts.append(stem(0.02, 0.8, 0.21))
        for n in 0..<5 {
            let f = Float(n)
            parts.append(Clay.blob(at: v(0.02 + Float(n % 2) * 0.012, 0.74 + f * 0.045, 0.21), size: v(0.035 - f * 0.004, 0.03, 0.035 - f * 0.004), color: 0x8a6cc7, top: 0xae95e0))
        }
        return Geometry.join(parts)
    }

    /// The things laid out on a blanket; the hamper first. All share one material (roughness 0.75,
    /// shaded by passing cloud).
    static let treats: [Treat] = [
        Treat(shape: basket().roughened(0.75), reach: 0.85),
        Treat(shape: teaSet().roughened(0.75), reach: 0.9),
        Treat(shape: riceBalls().roughened(0.75), reach: 0.62),
        Treat(shape: apples().roughened(0.75), reach: 0.55),
        Treat(shape: cake().roughened(0.75), reach: 0.5),
        Treat(shape: cushion().roughened(0.75), reach: 0.66),
        Treat(shape: flowers().roughened(0.75), reach: 0.42),
    ]

    // MARK: lantern (the Mac design: a plain terminal pane)

    /// A hurricane lantern, as camping lanterns are made: a stamped tin base, a glass globe held by four
    /// wire guards, a vented cap with a little chimney, and a wire bail to carry it by. About half a sitting
    /// cat tall, so it never hides one. The globe is drawn separately so it can glow.
    static let lanternTin: UInt32 = 0x3a3a40
    static func lanternFrame() -> Geometry {
        let tin = lanternTin, hi: UInt32 = 0x55555c
        var parts = [
            // Base: a shallow drum with a rolled rim.
            Clay.thrown(p([(0, 0), (0.24, 0), (0.27, 0.02), (0.27, 0.13), (0.24, 0.16), (0.2, 0.17), (0, 0.17)]), tin, hi, around: 24),
            // Cap: a vented dome and a short chimney.
            Clay.thrown(p([(0, 0.7), (0.22, 0.7), (0.26, 0.73), (0.22, 0.79), (0.12, 0.84), (0.07, 0.86), (0.07, 0.94), (0.05, 0.95), (0, 0.95)]), tin, hi, around: 24),
        ]
        // Four wire guards round the globe.
        for k in 0..<4 {
            let a = Float(k) / 4 * 2 * .pi + .pi / 4
            let c = cos(a), s = sin(a)
            parts.append(Clay.limb(CubicBezier(v(c * 0.21, 0.16, s * 0.21), v(c * 0.3, 0.32, s * 0.3), v(c * 0.3, 0.55, s * 0.3), v(c * 0.21, 0.71, s * 0.21)), 0.012, 0.012, tin, hi, sides: 5, rings: 10).shape)
        }
        // The bail: a wire hoop from side to side, standing up over the cap.
        parts.append(Clay.limb(CubicBezier(v(-0.26, 0.74, 0), v(-0.3, 1.2, 0), v(0.3, 1.2, 0), v(0.26, 0.74, 0)), 0.014, 0.014, tin, hi, sides: 5, rings: 18).shape)
        return Geometry.join(parts).roughened(0.55)
    }
    /// The glass globe: a fat barrel, its colour set per lantern (lit, dark, or red).
    static func lanternGlobe() -> Geometry {
        Clay.thrown(p([(0, 0.16), (0.15, 0.16), (0.2, 0.25), (0.22, 0.43), (0.2, 0.61), (0.15, 0.7), (0, 0.7)]), 0xffffff, 0xffffff, around: 24).roughened(0.25)
    }
    static let lanternReach: Float = 0.42

    // MARK: blanket cloth (blanket.ts)

    static let corner: Float = 1.2

    /// A flat stepping stone set in the grass, worn smooth and paler on top where feet go: the path from a
    /// worktree's blanket to its repository's is a row of these, each turned and sized its own way.
    static let steppingStone: Geometry = Clay.blob(at: Vec3(0, 0.012, 0), size: Vec3(0.64, 0.06, 0.48), color: 0x8f877a, top: 0xd9d1c1, lumpy: 0.2)
    static let checksPerUnit: Float = 0.65
    /// The outline of a blanket: a squircle with a gentle ripple, one unit from middle to edge.
    static func clothOutline(_ seed: Float) -> [Vec2] {
        var o = Outline()
        let steps = 120
        for i in 0...steps {
            let a = Float(i) / Float(steps) * 2 * .pi
            let r = clothReach(seed, a)
            if i == 0 { o.move(cos(a) * r, sin(a) * r) } else { o.line(cos(a) * r, sin(a) * r) }
        }
        return o.closed
    }
    /// How far the outline reaches from the middle at angle `a` of its own (x, y): never less than one.
    static func clothReach(_ seed: Float, _ a: Float) -> Float {
        let square = pow(pow(abs(cos(a)), 4.5) + pow(abs(sin(a)), 4.5), -1 / 4.5)
        let ripple = 1 + 0.018 * sin(a * 3 + seed) + 0.012 * sin(a * 7 + seed * 2.3)
        return max(1, square * ripple)
    }
    /// A square of cloth lying flat, its top exactly at y = 0 where the cats sit.
    static func cloth(_ seed: Float) -> Geometry {
        var g = Extrude.extrude(clothOutline(seed), depth: 0.03)
        g.apply(.translation(v(0, -0.03, 0)) * .rotationX(-.pi / 2))
        return g.colored(0xffffff, roughness: 1)
    }
    static let clothSeeds: [Float] = [0.4, 2.1, 4.4]
    /// Each cloth's outline, as `clothOutline` gives it.
    static let outlines: [[Vec2]] = clothSeeds.map { clothOutline($0) }

    /// A flat ribbon following a blanket's outline from `inner` to `outer` units beyond its edge (per unit
    /// of blanket size), for the ring round a chosen blanket.
    static func outlineBand(_ seed: Float) -> [Vec2] { clothOutline(seed) }

    // MARK: ladybird (Village.ts)

    /// A ladybird to wander each blanket: a red dome with dark spots and a dark head.
    static let ladybird: Geometry = {
        var parts = [
            Clay.blob(at: v(0, 0.5, 0), size: v(1, 0.62, 1.15), color: 0xd9352b, top: 0xf0584a),
            Clay.blob(at: v(0, 0.45, 1.05), size: v(0.55, 0.42, 0.45), color: 0x3a2a2a),
        ]
        for (x, z) in [(Float(0.45), Float(0.3)), (-0.45, 0.3), (0.5, -0.45), (-0.5, -0.45), (0, -0.05)] {
            parts.append(Clay.blob(at: v(x, 0.5 + 0.6 * sqrt(max(0, 1 - x * x - z * z * 0.75)), z), size: v(0.2, 0.08, 0.2), color: 0x3a2a2a))
        }
        return Geometry.join(parts).roughened(0.5)
    }()

    /// The pale ring on the ground round the chosen cat: TorusGeometry(1, 0.045, 8, 56) laid flat.
    static let catRing = Shapes.torus(1, 0.045, 8, 56).applied(.rotationX(.pi / 2)).colored(0xffffff, roughness: 1)
}
