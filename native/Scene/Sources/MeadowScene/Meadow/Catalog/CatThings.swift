import Foundation
import simd

// The meadow editor's Cat Things: what a cat's home has, out in the meadow. Made things, so cat-sized (the cat
// is 2.3 units tall and about 2 across) and never scaled: a box a cat fits in, a bed it curls up in, a post it
// stretches up to scratch. Each modelled on the real thing, then simplified into the meadow's clay; those with
// a palette (yarn, bed, bowl) are built in the swatch asked for (`Palette`), the first their own.

enum CatThings {
    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }

    /// A corrugated cardboard box with its four flaps folded open and flopping outward, kraft brown, darker
    /// inside, the torn tape that held it shut still along the long flaps.
    static let box: Plant = {
        let w: Float = 2.5, d: Float = 2.0, h: Float = 1.45, t: Float = 0.09
        let kraft = linear(0xc29a68), shade = linear(0x8f6c45), edge = linear(0xd9bb8c)
        /// A board of the box, its faces toward the inside darker.
        func board(_ size: Vec3, _ at: Vec3, inside: (Vec3) -> Bool) -> Geometry {
            var g = Shapes.roundedBox(size.x, size.y, size.z, segments: 1, radius: 0.035)
            g.translate(at.x, at.y, at.z)
            g.colors = g.positions.map { p in inside(p) ? shade : mix(kraft * 0.92, kraft, t: p.y / h) }
            return g
        }
        let innerX = w / 2 - t, innerZ = d / 2 - t
        var parts = [
            board(v(w, t, d), v(0, t / 2, 0)) { $0.y > t * 0.9 },
            board(v(w, h, t), v(0, h / 2, d / 2 - t / 2)) { $0.z < innerZ + 0.001 },
            board(v(w, h, t), v(0, h / 2, -d / 2 + t / 2)) { $0.z > -innerZ - 0.001 },
            board(v(t, h, d - 2 * t), v(w / 2 - t / 2, h / 2, 0)) { $0.x < innerX + 0.001 },
            board(v(t, h, d - 2 * t), v(-w / 2 + t / 2, h / 2, 0)) { $0.x > -innerX - 0.001 },
        ]
        // The flaps: each half the box's depth long, hinged at a top edge and fallen outward at its own angle.
        let flap = d / 2 - 0.02
        for (side, along, droop) in [(Vec3(0, 0, 1), true, Float(2.05)), (Vec3(0, 0, -1), true, 2.35), (Vec3(1, 0, 0), false, 1.75), (Vec3(-1, 0, 0), false, 2.2)] {
            let width = along ? w - 0.04 : d - 0.04
            var g = Shapes.roundedBox(width, flap, t * 0.9, segments: 1, radius: 0.035)
            g.translate(0, flap / 2, 0)
            // The face that was inside the box, now up, is darker.
            g.colors = g.positions.map { p in p.z < 0 ? shade * 1.12 : kraft }
            var parts2 = [g]
            if along {
                // What is left of the tape that held it shut: a torn strip at the middle of its free edge.
                var tape = Shapes.roundedBox(0.26, flap * 0.3, t * 0.92 + 0.012, segments: 1, radius: 0.02)
                tape.translate(0.06, flap * 0.86, 0)
                parts2.append(tape.colored(0xd9c59c, roughness: 0.6))
            }
            let yaw = atan2(side.x, side.z)
            let hinge = v(side.x * (w / 2 - t / 2), h, side.z * (d / 2 - t / 2))
            parts += parts2.map { $0.applied(.compose(hinge, euler: v(0, yaw, 0)) * .rotationX(droop)) }
        }
        // The flutes' paler edge along the walls' tops.
        for (size, at) in [(v(w, 0.03, t * 1.02), v(0, h, d / 2 - t / 2)), (v(w, 0.03, t * 1.02), v(0, h, -d / 2 + t / 2)),
                           (v(t * 1.02, 0.03, d), v(w / 2 - t / 2, h, 0)), (v(t * 1.02, 0.03, d), v(-w / 2 + t / 2, h, 0))] {
            var rim = Shapes.roundedBox(size.x, size.y, size.z, segments: 1, radius: 0.012)
            rim.translate(at.x, at.y, at.z)
            rim.colors = [Vec3](repeating: edge, count: rim.count)
            parts.append(rim)
        }
        return Plant(shape: Geometry.join(parts).roughened(0.95), top: v(0, h, 0))
    }()

    /// A scratching post: a square carpeted base, a post wound tight with sisal rope (each turn a ridge), a
    /// carpeted perch on top a cat can sit on, and a pompom hanging from it on a cord.
    static let scratchingPost: Plant = {
        let tall: Float = 3.2, carpet: (UInt32, UInt32) = (0xd8ccb6, 0xeee6d6)
        var base = Shapes.roundedBox(1.8, 0.24, 1.8, segments: 2, radius: 0.1)
        base.translate(0, 0.12, 0)
        var perch = Shapes.roundedBox(1.3, 0.22, 1.3, segments: 2, radius: 0.1)
        perch.translate(0, tall + 0.11, 0)
        let turns: Float = 22
        let post = Clay.limb(QuadraticBezier(v(0, 0.2, 0), v(0, tall / 2, 0), v(0, tall + 0.02, 0)), 0.3, 0.3, 0xc2a670, 0xd6bf8c, sides: 16, rings: 132) { along, angle in
            1 + 0.08 * pow(abs(cos((along * turns - angle / (2 * .pi)) * .pi)), 0.6)
        }
        let cord = Clay.limb(CubicBezier(v(0.5, tall, 0.5), v(0.56, tall - 0.25, 0.54), v(0.6, tall - 0.5, 0.55), v(0.62, tall - 0.78, 0.58)), 0.03, 0.03, 0x8a7a66, 0x9c8c76, sides: 5, rings: 8)
        return Plant(shape: Geometry.join([
            base.painted(carpet.0, carpet.1), perch.painted(carpet.0, carpet.1), post.shape, cord.shape,
            Clay.blob(at: cord.end + v(0, -0.12, 0), size: 0.17, color: 0xd98a86, top: 0xf0b0a6, lumpy: 0.2),
        ]).roughened(0.92), top: v(0, tall + 0.22, 0))
    }()

    /// A ball of yarn in a swatch of its palette (oat its own): a round ball wound in criss-crossing bands, a little
    /// flattened where it rests, and a loose strand trailing over the grass.
    static func yarn(_ swatch: Int) -> Plant {
        let r: Float = 0.42, clay = Palette.clay("cat.yarn", swatch), color = (clay.shade, clay.light)
        var parts = [Clay.blob(at: v(0, r * 0.94, 0), size: v(r, r * 0.94, r), color: color.0, top: color.1)]
        // Wraps laid at angles, each a strand standing a little proud of the ball.
        for (k, tilt) in [(0.3, 0.2), (1.2, 0.9), (2.0, 0.4), (2.7, 1.3), (0.8, 1.6), (1.7, 0.1), (2.4, 2.0), (3.0, 0.7)].enumerated() {
            let ring = Shapes.torus(r * 0.97, 0.04, 6, 32).applied(.compose(v(0, r * 0.94, 0), euler: v(Float(tilt.1), Float(tilt.0), Float(k) * 0.4), scale: v(1, 0.94, 1)))
            // Strands alternately a little deeper and a little paler than the ball, so the winding reads.
            parts.append(ring.painted(color.0, color.1).tinted(k % 2 == 0 ? 0.93 : 1.05))
        }
        let strand = Clay.limb(CatmullRom([v(r * 0.6, r * 0.5, r * 0.55), v(r * 1.1, 0.06, r * 0.9), v(0.95, 0.045, 0.55), v(1.3, 0.045, 0.85), v(1.6, 0.045, 0.6)]),
                               0.045, 0.045, color.0, color.0, sides: 6, rings: 20)
        parts.append(strand.shape)
        return Plant(shape: Geometry.join(parts).roughened(1), top: v(0, r * 1.9, 0))
    }

    /// A round cat bed in a swatch of its palette (oat its own): a plump bolster ring round a sunken cushion a cat
    /// curls into, soft and matte, the cushion a shade deeper than the rim.
    static func bed(_ swatch: Int) -> Plant {
        let clay = Palette.clay("cat.bed", swatch)
        let profile = [(0.0, 0.0), (1.35, 0.0), (1.55, 0.1), (1.62, 0.34), (1.52, 0.58), (1.3, 0.68), (1.08, 0.58), (0.98, 0.36), (0.8, 0.2), (0.4, 0.16), (0.0, 0.16)]
        let ring = Clay.thrown(profile.map { Vec2(Float($0.0), Float($0.1)) }, clay.shade, clay.light, around: 40, steps: 40)
        let cushion = Clay.blob(at: v(0, 0.17, 0), size: v(0.88, 0.07, 0.88), color: clay.shade, top: clay.light).tinted(0.9)
        return Plant(shape: Geometry.join([ring, cushion]).roughened(1), top: v(0, 0.68, 0))
    }

    /// A food bowl in a swatch of its palette (cream its own): wide and shallow, as cats like them, glazed
    /// stoneware on an unglazed foot, heaped with kibble.
    static func bowl(_ swatch: Int) -> Plant {
        let clay = Palette.clay("cat.bowl", swatch)
        let glaze = Clay.thrown([Vec2(0, 0.03), Vec2(0.38, 0.03), Vec2(0.47, 0.12), Vec2(0.55, 0.26), Vec2(0.58, 0.31), Vec2(0.55, 0.33), Vec2(0.48, 0.24), Vec2(0.36, 0.13), Vec2(0, 0.11)],
                                clay.shade, clay.light, around: 28, steps: 20).roughened(0.4)
        let foot = Clay.thrown([Vec2(0, 0), Vec2(0.38, 0), Vec2(0.4, 0.035), Vec2(0.37, 0.05), Vec2(0, 0.05)], 0xb89268, 0xc9a67c, around: 28, steps: 6).roughened(0.9)
        var kibble: [Geometry] = []
        for k in 0..<18 {
            let a = Float(k) * 2.399963, out = 0.4 * sqrt(Float(k) / 18)
            let y = 0.13 + 0.12 * (1 - out / 0.42)
            let colour: (UInt32, UInt32) = k % 5 == 0 ? (0x6b3f1e, 0x84502a) : k % 2 == 0 ? (0xa8682f, 0xbf7d3c) : (0xc58b4a, 0xd8a060)
            // Small enough that a ball of few faces is as round as any.
            kibble.append(Shapes.sphere(1, 8, 5).applied(.compose(v(cos(a) * out, y, sin(a) * out), euler: v(0.3 * Float(k % 3), a, 0.2), scale: v(0.07, 0.045, 0.06)))
                .painted(colour.0, colour.1))
        }
        return Plant(shape: Geometry.join([glaze, foot, Geometry.join(kibble).roughened(0.85)]), top: v(0, 0.33, 0))
    }
}
