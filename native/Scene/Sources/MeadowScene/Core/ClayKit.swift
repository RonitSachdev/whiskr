import Foundation
import simd

// kit.ts clay shapes: squashed balls of clay (`blob`), bending rods (`limb`), colour baked from bottom to
// top (`paint`), and picnic.ts's thrown, stacked and pressed shapes. Everything in the meadow, the
// picnic and the props is built from these.

enum Clay {
    /// The plain ball: SphereGeometry(1, 14, 10).
    static let ball = Shapes.sphere(1, 14, 10)
    /// For anything large enough to see closely: a sphere with no seam, so it can be pressed out of shape.
    static let lump: Geometry = {
        var g = Shapes.icosahedron(1, detail: 3).welded()
        g.computeNormals()
        return g
    }()

    /// A squashed, turned ball of clay: petals, leaves, foliage, caps and stones are all this.
    static func blob(at: Vec3, size: Vec3, color: UInt32, top: UInt32? = nil, turn: Vec3 = .zero, lumpy: Float = 0) -> Geometry {
        var shape = lumpy > 0 ? lump : ball
        if lumpy > 0 {
            // Push each point in or out a little, differently for every blob, then let the light find the dents.
            let seed = Double(at.x) * 3.1 + Double(at.y) * 5.7 + Double(at.z) * 9.3
            for i in shape.positions.indices {
                let p = shape.positions[i]
                let x = Double(p.x), y = Double(p.y), z = Double(p.z)
                let press = Float(1 + (fbm(x * 1.6 + z * 0.9 + seed, y * 1.6 - z * 0.7, 13) - 0.5) * 2 * Double(lumpy))
                shape.positions[i] = p * press
            }
            shape.computeNormals()
        }
        shape.apply(.compose(at, euler: turn, scale: size))
        shape.paint(color, top)
        return shape
    }
    static func blob(at: Vec3, size: Float, color: UInt32, top: UInt32? = nil, turn: Vec3 = .zero, lumpy: Float = 0) -> Geometry {
        blob(at: at, size: Vec3(repeating: size), color: color, top: top, turn: turn, lumpy: lumpy)
    }

    struct Limb { var shape: Geometry; var curve: Curve; var end: Vec3 }

    /// A tapering, bending rod of clay following a curve: stems, branches, trunks and roots. `swell` lets
    /// the outline bulge by height and angle, which is how a trunk gets its root flare.
    static func limb(_ curve: Curve, _ from: Float, _ to: Float, _ color: UInt32, _ top: UInt32, sides: Int = 6, rings: Int = 8,
                     swell: (Float, Float) -> Float = { _, _ in 1 }) -> Limb {
        let frames = curve.frenetFrames(rings)
        let low = linear(color), high = linear(top)
        var g = Geometry()
        for i in 0...rings {
            let along = Float(i) / Float(rings)
            let point = curve.pointAt(along)
            let n = frames.normals[i], b = frames.binormals[i]
            let tint = low + (high - low) * along
            for j in 0..<sides {
                let angle = Float(j) / Float(sides) * 2 * .pi
                let radius = (from + (to - from) * along) * swell(along, angle)
                let c = cos(angle) * radius, s = sin(angle) * radius
                g.positions.append(point + n * c + b * s)
                g.colors.append(tint)
            }
        }
        let S = UInt32(sides)
        for i in 0..<UInt32(rings) {
            for j in 0..<S {
                let a = i * S + j, b = i * S + (j + 1) % S
                g.indices += [a, a + S, b, b, a + S, b + S]
            }
        }
        // Close the far end with a point, so cut ends never show hollow.
        let tip = UInt32(g.positions.count)
        let end = curve.pointAt(1)
        g.positions.append(end)
        g.colors.append(high)
        for j in 0..<S { g.indices += [UInt32(rings) * S + j, tip, UInt32(rings) * S + (j + 1) % S] }
        g.computeNormals()
        return Limb(shape: g, curve: curve, end: end)
    }

    static func bow(_ end: Vec3, _ bend: Vec3) -> QuadraticBezier { QuadraticBezier(.zero, end * 0.5 + bend, end) }

    /// Moves parts modelled around the origin (facing up) to sit somewhere else, tilted.
    static func seat(_ parts: [Geometry], _ at: Vec3, _ tilt: Vec3 = .zero) -> [Geometry] {
        let m = Mat4.compose(at, euler: tilt)
        return parts.map { $0.applied(m) }
    }

    /// Something thrown on a wheel: a side profile of (radius, height) points, smoothed and spun round.
    static func thrown(_ profile: [Vec2], _ bottom: UInt32, _ top: UInt32? = nil, around: Int = 20, steps: Int = 18) -> Geometry {
        let outline = Spline2(points: profile).sample(steps).map { Vec2(max($0.x, 0), $0.y) }
        return Shapes.lathe(outline, around).painted(bottom, top ?? bottom)
    }

    struct Ring { var w: Float; var d: Float; var y: Float }

    /// A solid with rounded-rectangle cross-sections stacked from the first ring to the last, closed at
    /// both ends: boxes with soft corners. `color` picks each point's colour from its ring and place round it.
    static func stacked(_ rings: [Ring], around: Int = 32, square: Float = 5, color: (Int, Int) -> UInt32) -> Geometry {
        var g = Geometry()
        func push(_ p: Vec3, _ hex: UInt32) { g.positions.append(p); g.colors.append(linear(hex)) }
        for (i, ring) in rings.enumerated() {
            for j in 0..<around {
                let angle = Float(j) / Float(around) * 2 * .pi, c = cos(angle), s = sin(angle)
                let sc: Float = c > 0 ? 1 : c < 0 ? -1 : 0, ss: Float = s > 0 ? 1 : s < 0 ? -1 : 0
                push(Vec3(ring.w * sc * pow(abs(c), 2 / square), ring.y, ring.d * ss * pow(abs(s), 2 / square)), color(i, j))
            }
        }
        let A = UInt32(around)
        for i in 0..<UInt32(rings.count - 1) {
            for j in 0..<A {
                let a = i * A + j, b = i * A + (j + 1) % A
                g.indices += [a, a + A, b, b, a + A, b + A]
            }
        }
        let last = UInt32(rings.count - 1), floor = UInt32(g.positions.count)
        push(Vec3(0, rings[0].y, 0), color(0, 0))
        push(Vec3(0, rings[Int(last)].y, 0), color(Int(last), 0))
        for j in 0..<A {
            let next = (j + 1) % A
            g.indices += [j, next, floor]
            g.indices += [last * A + next, last * A + j, floor + 1]
        }
        g.computeNormals()
        return g
    }

    /// A flat outline given thickness and soft edges, lying in the x–y plane and centred front to back,
    /// welded so the light rounds every edge, as pressed clay has no creases.
    static func pressed(_ outline: [Vec2], thick: Float, soft: Float, _ bottom: UInt32, _ top: UInt32? = nil) -> Geometry {
        var solid = Extrude.extrude(outline, depth: thick, bevel: (soft, soft, 3))
        solid.translate(0, 0, -thick / 2)
        var welded = solid.welded()
        welded.computeNormals()
        return welded.painted(bottom, top ?? bottom)
    }
}
