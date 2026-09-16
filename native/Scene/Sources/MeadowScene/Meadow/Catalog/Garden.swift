import Foundation
import simd

// The meadow editor's Garden things (beside the fence, `Fences`): made things, cat-sized (the cat is 2.3 units tall,
// so a thing a person uses is drawn at about a fortieth of a unit to a centimetre, as the Workplace's are) and never
// scaled. Each modelled on the real thing, then simplified into the meadow's clay; those with a palette are built
// in the swatch asked for (`Palette`), the first their own.

enum Garden {
    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }

    /// A ball of few faces, as round as any at the size of a leaf or a floret.
    private static let ball = Shapes.sphere(1, 10, 7)
    private static func bead(at: Vec3, size: Vec3, color: UInt32, top: UInt32, turn: Vec3 = .zero) -> Geometry {
        ball.applied(.compose(at, euler: turn, scale: size)).painted(color, top)
    }

    /// A flower pot: a tapered pot a little squatter than wide, its thick rolled rim proud of the body (the band a
    /// pot is lifted by), dark soil inside, planted with a geranium: a dome of round scalloped leaves with clusters of
    /// soft pink flowers held above on stalks. Terracotta (its own) or glazed, the glaze thinning over the rim.
    static func flowerPot(_ swatch: Int) -> Plant {
        let clay = Palette.clay("garden.flowerPot", swatch), glazed = swatch > 0
        let profile = [(0.0, 0.0), (0.34, 0.0), (0.37, 0.03), (0.47, 0.66), (0.5, 0.68), (0.55, 0.7), (0.56, 0.84), (0.53, 0.87), (0.46, 0.86), (0.43, 0.8), (0.0, 0.8)]
        var pot = Clay.thrown(profile.map { Vec2(Float($0.0), Float($0.1)) }, clay.shade, clay.light, around: 26, steps: 30)
        if glazed {
            // The glaze pools darker at the foot and thins paler over the rim, as it runs in the kiln.
            pot.colors = pot.positions.map { p in mix(linear(clay.shade) * 0.85, linear(clay.light), t: smoothstep(p.y, 0.05, 0.86)) }
        }
        var parts = [pot.roughened(glazed ? 0.45 : 0.95)]
        parts.append(Clay.blob(at: v(0, 0.8, 0), size: v(0.45, 0.04, 0.45), color: 0x3d2c20, top: 0x54402e).roughened(1))
        // The geranium: leaves in a dome, then its flower heads.
        var leaves: [Geometry] = []
        for k in 0..<11 {
            let a = Float(k) * 2.399963, out: Float = k == 0 ? 0 : 0.18 + 0.2 * Float(k % 3) / 2
            let y = 0.98 + 0.22 * (1 - out / 0.4)
            leaves.append(bead(at: v(cos(a) * out, y, sin(a) * out), size: v(0.22, 0.08, 0.2), color: 0x4f7f34, top: 0x7aab4e, turn: v(0.3 * cos(a), a, 0.3 * sin(a))))
        }
        parts.append(Geometry.join(leaves).roughened(0.85))
        for (k, a) in [Float(0.4), 2.5, 4.4].enumerated() {
            let at = v(cos(a) * 0.2, 1.42 + 0.06 * Float(k % 2), sin(a) * 0.2)
            parts.append(Clay.limb(QuadraticBezier(v(cos(a) * 0.1, 1.05, sin(a) * 0.1), v(cos(a) * 0.16, 1.25, sin(a) * 0.16), at), 0.035, 0.028, 0x4f7f34, 0x6a9a44, sides: 5, rings: 4).shape.roughened(0.85))
            // An umbel: a round head of small florets.
            for f in 0..<7 {
                let b = Float(f) * 2.399963, out: Float = f == 0 ? 0 : 0.1
                parts.append(bead(at: at + v(cos(b) * out, f == 0 ? 0.06 : 0.02, sin(b) * out), size: v(0.08, 0.06, 0.08), color: 0xe27e98, top: 0xf6b3c2).roughened(0.7))
            }
        }
        return Plant(shape: Geometry.join(parts), top: v(0, 1.5, 0))
    }

    /// A raised bed: a box of two weathered boards a side screwed to square corner posts that stand a little proud,
    /// filled to near its top with dark soil, growing two lettuces and marigolds between.
    static let planter: Plant = {
        let w: Float = 3.2, d: Float = 1.5, board: Float = 0.44, t: Float = 0.12
        var parts: [Geometry] = []
        for row in 0..<2 {
            let y = 0.02 + Float(row) * board + board / 2
            for (size, at) in [(v(w, board - 0.03, t), v(0, y, d / 2 - t / 2)), (v(w, board - 0.03, t), v(0, y, -d / 2 + t / 2)),
                               (v(t, board - 0.03, d - 2 * t), v(w / 2 - t / 2, y, 0)), (v(t, board - 0.03, d - 2 * t), v(-w / 2 + t / 2, y, 0))] {
                var b = Shapes.roundedBox(size.x, size.y, size.z, segments: 1, radius: 0.04)
                b.translate(at.x, at.y, at.z)
                // Soil and damp stain the lower board darker.
                b.paint(row == 0 ? 0x6e5c48 : 0x86735c, row == 0 ? 0x8a7660 : 0xb3a189)
                parts.append(b)
            }
        }
        for x: Float in [-1, 1] {
            for z: Float in [-1, 1] {
                var post = Shapes.roundedBox(0.2, 1.02, 0.2, segments: 1, radius: 0.05)
                post.translate(x * (w / 2 - 0.08), 0.49, z * (d / 2 - 0.08))
                parts.append(post.painted(0x6c5a48, 0xa8977e))
            }
        }
        parts.append(Clay.blob(at: v(0, 0.8, 0), size: v(w / 2 - t, 0.1, d / 2 - t), color: 0x3a2a1e, top: 0x58412f, lumpy: 0.15))
        // Two lettuces: rosettes of pale cupped leaves.
        for x: Float in [-0.95, 0.95] {
            for k in 0..<8 {
                let a = Float(k) * 2.399963 + x, out: Float = k < 2 ? 0.05 : 0.22
                parts.append(bead(at: v(x + cos(a) * out, 0.98 + (k < 2 ? 0.12 : 0), sin(a) * out), size: v(0.22, 0.14, 0.15), color: 0x6f9d3d, top: 0xb7d870,
                                       turn: v(0, -a, k < 2 ? 0 : 0.7)))
            }
        }
        // Marigolds between: low bushes of fine leaves with round golden heads.
        for (x, z) in [(Float(0), Float(0.2)), (0.1, -0.3)] {
            parts.append(Clay.blob(at: v(x, 0.95, z), size: v(0.3, 0.16, 0.24), color: 0x3f6f2c, top: 0x5f8f3c))
            for k in 0..<4 {
                let a = Float(k) * 1.7 + x * 3
                parts.append(bead(at: v(x + cos(a) * 0.17, 1.12, z + sin(a) * 0.12), size: v(0.1, 0.07, 0.1), color: 0xe0a024, top: 0xf6c84a))
            }
        }
        return Plant(shape: Geometry.join(parts).roughened(0.92), top: v(0, 1.15, 0))
    }()

    /// A watering can as gardeners have long used them: a round-shouldered oval body, a long spout rising from its
    /// foot at a steep angle to a flat oval rose, a high handle arching over from the back to the filler, and a cross
    /// stay to the spout. Galvanised zinc (its own) or enamelled.
    static func wateringCan(_ swatch: Int) -> Plant {
        let clay = Palette.clay("garden.wateringCan", swatch), metal = swatch == 0
        let body = Clay.thrown([Vec2(0, 0), Vec2(0.36, 0), Vec2(0.39, 0.04), Vec2(0.4, 0.5), Vec2(0.36, 0.66), Vec2(0.2, 0.74), Vec2(0, 0.75)], clay.shade, clay.light, around: 24, steps: 18)
            .applied(.scale(v(1.18, 1, 0.82)))
        var parts = [body]
        // The filler's collar on top, toward the back.
        parts.append(Shapes.torus(0.13, 0.035, 6, 18).applied(.compose(v(-0.12, 0.75, 0), euler: v(.pi / 2, 0, 0))).painted(clay.shade, clay.light))
        parts.append(Clay.blob(at: v(-0.12, 0.74, 0), size: v(0.11, 0.02, 0.11), color: 0x2f3134))
        // The spout: from the body's foot in front, up and out.
        let spout = Clay.limb(QuadraticBezier(v(0.36, 0.14, 0), v(0.72, 0.42, 0), v(1.05, 0.86, 0)), 0.085, 0.05, clay.shade, clay.light, sides: 10, rings: 8)
        parts.append(spout.shape)
        // The rose: a flat oval dish, its face full of holes, turned up.
        let rose = Clay.thrown([Vec2(0, 0), Vec2(0.06, 0), Vec2(0.15, 0.07), Vec2(0.15, 0.09), Vec2(0, 0.1)], 0x9a7a3c, 0xc8a456, around: 16, steps: 6)
        parts.append(rose.applied(.compose(spout.end + v(0.02, 0.01, 0), euler: v(0, 0, -0.6))))
        // The high handle, back to the filler, and the stay from the shoulder to the spout.
        parts.append(Clay.limb(CubicBezier(v(-0.42, 0.42, 0), v(-0.62, 1.05, 0), v(0.05, 1.22, 0), v(0.18, 0.72, 0)), 0.05, 0.05, clay.shade, clay.light, sides: 8, rings: 16).shape)
        parts.append(Clay.limb(QuadraticBezier(v(0.3, 0.62, 0), v(0.5, 0.62, 0), v(0.66, 0.42, 0)), 0.035, 0.035, clay.shade, clay.light, sides: 6, rings: 5).shape)
        return Plant(shape: Geometry.join(parts).roughened(metal ? 0.55 : 0.5), top: v(0, 1.12, 0))
    }

    /// A nest box on a post: a box a little taller than wide, painted duck egg, under a roof of weathered boards
    /// overhanging its front to keep the rain off, a round entrance high on its face with a perch peg below, on a
    /// square post sunk in the turf.
    static let birdhouse: Plant = {
        let pole: Float = 3.3, w: Float = 0.92, d: Float = 0.78, h: Float = 1.0
        let paint = Palette.swatch("duckEgg").clay, roof: (UInt32, UInt32) = (0x7c6a56, 0xa8977e)
        var parts: [Geometry] = []
        var post = Shapes.roundedBox(0.26, pole + 0.1, 0.26, segments: 1, radius: 0.06)
        post.translate(0, pole / 2 - 0.05, 0)
        parts.append(post.painted(Fences.wood.foot, Fences.wood.top))
        var box = Shapes.roundedBox(w, h, d, segments: 1, radius: 0.06)
        box.translate(0, pole + h / 2, 0)
        parts.append(box.painted(paint.shade, paint.light))
        // The gable under the roof, then the roof's two boards, overhanging in front.
        let gable = Clay.pressed([Vec2(-w / 2, 0), Vec2(w / 2, 0), Vec2(0, 0.4)], thick: d - 0.02, soft: 0.03, paint.shade, paint.light)
        parts.append(gable.applied(.translation(v(0, pole + h - 0.02, 0))))
        for side: Float in [-1, 1] {
            var slab = Shapes.roundedBox(0.7, 0.09, d + 0.3, segments: 1, radius: 0.035)
            slab.apply(.compose(v(side * 0.27, pole + h + 0.23, 0.08), euler: v(0, 0, -side * 0.7)))
            parts.append(slab.painted(roof.0, roof.1))
        }
        parts.append(Clay.blob(at: v(0, pole + h + 0.43, 0.08), size: v(0.07, 0.06, (d + 0.3) / 2), color: roof.0, top: roof.1))
        // The entrance: a dark round hole high on the face, a pale ring of end grain round it, and a perch peg.
        parts.append(Shapes.cylinder(0.11, 0.11, 0.02, 16).applied(.compose(v(0, pole + h * 0.66, d / 2 + 0.005), euler: v(.pi / 2, 0, 0))).colored(0x1d1915, roughness: 1))
        parts.append(Shapes.torus(0.12, 0.025, 6, 18).applied(.compose(v(0, pole + h * 0.66, d / 2), euler: v(0, 0, 0))).painted(0xd8c8a4, 0xe8dcc0))
        parts.append(Clay.limb(QuadraticBezier(v(0, pole + h * 0.38, d / 2), v(0, pole + h * 0.38, d / 2 + 0.1), v(0, pole + h * 0.39, d / 2 + 0.2)), 0.035, 0.03, 0x8a6a48, 0xa8865e, sides: 6, rings: 3).shape)
        return Plant(shape: Geometry.join(parts).roughened(0.9), top: v(0, pole + h + 0.4, 0))
    }()

    /// A straw skep: a bell of straw rope coiled round and round, each coil stitched to the one below (the light
    /// bands of split bramble), a little topknot, its flight hole low on one side; on a round wooden stand.
    static let skep: Plant = {
        let stand: Float = 0.5, coils = 8, tall: Float = 1.05, wide: Float = 0.62
        var parts: [Geometry] = []
        // The stand: a thick round board on three short legs.
        parts.append(Clay.thrown([Vec2(0, stand - 0.13), Vec2(0.74, stand - 0.13), Vec2(0.78, stand - 0.07), Vec2(0.74, stand), Vec2(0, stand)], 0x6c5a48, 0xa48f74, around: 24, steps: 6).roughened(0.95))
        for k in 0..<3 {
            let a = Float(k) / 3 * 2 * .pi + 0.5
            parts.append(Clay.limb(QuadraticBezier(v(cos(a) * 0.45, stand - 0.12, sin(a) * 0.45), v(cos(a) * 0.5, 0.2, sin(a) * 0.5), v(cos(a) * 0.55, -0.04, sin(a) * 0.55)),
                                   0.08, 0.07, 0x6c5a48, 0x8a7660, sides: 7, rings: 3).shape.roughened(0.95))
        }
        // The bell: its outline a dome a little taller than wide, each coil a rounded ridge.
        var profile: [Vec2] = []
        let steps = coils * 6
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let angle = t * .pi / 2
            let ridge = 1 + 0.07 * abs(sin(t * Float(coils) * .pi))
            profile.append(Vec2(wide * cos(angle) * ridge * (1 - 0.06 * t), stand + tall * sin(angle) * (0.96 + 0.04 * ridge)))
        }
        var bell = Shapes.lathe(profile + [Vec2(0, stand + tall + 0.02)], 30)
        // Straw, greying as it weathers, the stitches paler bands down it every so often.
        bell.colors = bell.positions.map { p in
            let around = atan2(p.z, p.x), stitch = pow(max(0, cos(around * 9)), 24)
            let up = (p.y - stand) / tall
            return mix(mix(linear(0xb08a4a), linear(0xdcbf82), t: up), linear(0xefe0b8), t: stitch * 0.7)
        }
        parts.append(bell.roughened(1))
        parts.append(Clay.blob(at: v(0, stand + tall + 0.04, 0), size: v(0.12, 0.1, 0.12), color: 0xb08a4a, top: 0xd4b674, lumpy: 0.2).roughened(1))
        // The flight hole, low in front.
        parts.append(Clay.blob(at: v(0, stand + 0.06, wide * 0.97), size: v(0.13, 0.07, 0.05), color: 0x1d1810).roughened(1))
        return Plant(shape: Geometry.join(parts), top: v(0, stand + tall + 0.1, 0))
    }()
}
