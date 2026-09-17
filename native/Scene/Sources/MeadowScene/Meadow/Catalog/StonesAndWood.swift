import Foundation
import simd

// The meadow editor's stones and wood (the Stones & Wood shelf, beside the Default's stones and log): each
// modelled on the real thing, then simplified into the meadow's clay. Found, not made, so each is drawn at
// the size the meadow found it (a boulder varies a little; a stump and a log pile never scale).

enum StonesAndWood {
    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }

    /// The end grain of a sawn log, facing up at y = 0: pale sapwood round a warmer heart, its growth rings
    /// drawn in fine darker lines, a dark pith at the middle, and the cut a hair dished.
    static func endGrain(radius: Float, rings: Int = 6) -> Geometry {
        let around = 28, steps = rings * 2
        var g = Geometry()
        let pith = linear(0x7a5634), heart = linear(0xc69a62), sap = linear(0xe2c597), line = linear(0xae8250)
        for i in 0...steps {
            let f = Float(i) / Float(steps), r = radius * f
            // Rings crowd toward the bark, as a tree grows slower when old.
            let color = i == 0 ? pith : i % 2 == 1 ? line : mix(heart, sap, t: f)
            for k in 0..<around {
                let a = Float(k) / Float(around) * 2 * .pi
                g.positions.append(Vec3(cos(a) * r * (1 + 0.03 * sin(a * 3 + Float(i))), -0.015 * (1 - f * f), sin(a) * r))
                g.normals.append(Vec3(0, 1, 0))
                g.colors.append(color)
            }
        }
        let A = UInt32(around)
        for i in 0..<UInt32(steps) {
            for k in 0..<A {
                let a = i * A + k, b = i * A + (k + 1) % A
                g.indices += [a, b, a + A, b, b + A, a + A]
            }
        }
        g.computeNormals()
        return g
    }

    /// A boulder left in the meadow: a big, rounded, weathered stone about twice a stone's size, half sunk in
    /// the turf, its top worn flat enough to sit on, crusted with pale lichen and with moss gathered at its
    /// shaded foot.
    static let boulder: Plant = {
        var body = Clay.blob(at: v(0, 0.5, 0), size: v(2.05, 1.3, 1.65), color: 0x86827a, top: 0xc3bdb2, lumpy: 0.12)
        // Worn flat on top, a seat.
        for i in body.positions.indices where body.positions[i].y > 1.45 { body.positions[i].y = 1.45 + (body.positions[i].y - 1.45) * 0.35 }
        body.computeNormals()
        var parts = [body, Clay.blob(at: v(1.45, 0.25, 0.75), size: v(0.95, 0.72, 0.85), color: 0x8a857c, top: 0xbfb9ad, lumpy: 0.14)]
        // Lichen: flat crusts, grey-green and ochre, over the top and the sunny side.
        for (a, up, size, ochre) in [(Float(0.4), Float(0.95), Float(0.32), false), (2.1, 0.8, 0.26, true), (3.6, 0.9, 0.3, false), (5.0, 0.55, 0.22, true), (1.2, 0.35, 0.2, false)] {
            let at = v(cos(a) * 2.05 * cos(up) * 0.95, 0.5 + 1.3 * sin(up) * 0.86, sin(a) * 1.65 * cos(up) * 0.95)
            parts.append(Clay.blob(at: at, size: v(size * 1.45, 0.07, size * 1.15), color: ochre ? 0xc29a48 : 0x9fae86, top: ochre ? 0xdcb862 : 0xbcc7a2,
                                   turn: v(0, a, (1 - up) * 1.2), lumpy: 0.25))
        }
        // Moss in its shade: a colony round its damp foot on its west side, and a few cushions higher up it.
        let stone = Geometry.join(parts)
        func side(_ spot: Vec2) -> (Vec3, Vec3) {
            // Round the body at an angle and a height, out along its curve there.
            let a = spot.x, h = spot.y, across = sqrt(max(0.05, 1 - pow((h - 0.5) / 1.3, 2)))
            let at = v(cos(a) * 2.05 * across, h, sin(a) * 1.65 * across)
            return (at, simd_normalize(v(at.x / (2.05 * 2.05), (h - 0.5) / (1.3 * 1.3), at.z / (1.65 * 1.65))))
        }
        parts.append(Moss.patch(Moss.colony(Vec2(2.75, 0.3), reach: Vec2(0.55, 0.2), count: 9, size: 0.44, seed: 11, side)
                                + Moss.colony(Vec2(3.0, 0.95), reach: Vec2(0.3, 0.22), count: 5, size: 0.3, seed: 12, side)
                                + Moss.colony(Vec2(1.2, 0.82), reach: Vec2(0.36, 0.3), count: 4, size: 0.22, seed: 13, Moss.top(of: stone)), seed: 7))
        return Plant(shape: Geometry.join(parts).roughened(0.95), top: v(0, 1.75, 0))
    }()

    /// A tree stump: a sawn trunk knee-high to a person, a seat for a cat, its cut top showing the rings, its
    /// bark ridged, roots spreading into the turf; moss on its shaded side and two bracket fungi on the bark.
    static let stump: Plant = {
        let height: Float = 1.05, radius: Float = 0.95
        // The roots flare out from its foot in four buttresses and run under the turf.
        let trunk = Clay.limb(QuadraticBezier(v(0, -0.14, 0), v(0, 0.45, 0), v(0, height, 0)), radius * 1.04, radius, 0x4f3d2f, 0x7a5d44, sides: 32, rings: 12) { along, angle in
            let flare = pow(max(0, 1 - along / 0.42), 2)
            let buttress = pow(max(0, cos(angle * 4 + 0.6)), 3)
            // The bark in vertical ridges.
            return (1 + flare * (0.16 + 0.62 * buttress)) * (1 + 0.035 * abs(sin(angle * 11)))
        }
        var parts = [trunk.shape]
        var top = endGrain(radius: radius * 0.93)
        top.translate(0, height + 0.012, 0)
        parts.append(top)
        // Moss up the shaded side from the damp foot, and a little over the rim there (`Moss`).
        func bark(_ spot: Vec2) -> (Vec3, Vec3) {
            let a = spot.x, h = spot.y, r = radius * (1.04 + 0.2 * pow(max(0, 1 - h / 0.42), 2))
            return (v(cos(a) * r, h, sin(a) * r), simd_normalize(v(cos(a), 0.25, sin(a))))
        }
        parts.append(Moss.patch(Moss.colony(Vec2(2.75, 0.4), reach: Vec2(0.6, 0.3), count: 8, size: 0.32, seed: 21, bark)
                                + Moss.colony(Vec2(-0.66, 0.26), reach: Vec2(0.18, 0.26), count: 5, size: 0.2, seed: 22) { (v($0.x, height + 0.012, $0.y), v(0, 1, 0)) },
                                seed: 9))
        // Bracket fungi: half-round shelves, tan with a cream edge.
        for (a, y, size) in [(Float(2.3), Float(0.5), Float(0.3)), (2.75, 0.32, 0.22)] {
            let out = Vec3(cos(a), 0, -sin(a))
            parts.append(Clay.blob(at: out * (radius * 1.02) + v(0, y, 0), size: v(size, 0.075, size * 0.75), color: 0xa9783f, top: 0xeee0c4, turn: v(0, a, 0)))
        }
        return Plant(shape: Geometry.join(parts).roughened(0.9), top: v(0, height, 0))
    }()

    /// A pile of round logs as woodland gardens keep them for the wildlife: the biggest three at the bottom, two,
    /// then one, each with its bark on and its sawn ends pale with rings, none quite in line.
    static let logPile: Plant = {
        let r: Float = 0.34
        var parts: [Geometry] = []
        let logs: [(Float, Float, Float, Float)] = [(-0.12, -0.7, 0, 1), (0.1, 0, 0, 1.04), (-0.05, 0.7, 0, 0.96), (0.15, -0.36, 1, 0.98), (-0.1, 0.36, 1, 1), (0.04, 0, 2, 0.92)]
        for (shift, z, row, scale) in logs {
            let radius = r * scale, y = radius + row * r * 1.68 - 0.04
            let half: Float = 1.25 + shift * 0.5
            var log = Clay.limb(QuadraticBezier(v(-half + shift, y, z), v(shift, y + 0.01, z), v(half + shift, y, z)), radius, radius * 0.97, 0x6e543e, 0x6e543e,
                                sides: 14, rings: 6) { along, angle in 1 + 0.05 * abs(sin(angle * 7 + along * 3 + z)) }.shape
            // Bark lit from above: paler and greyer on top, as the sun and rain weather it, so the pile reads as
            // logs from the editor's height and not as one dark heap.
            log.colors = log.positions.map { p in mix(linear(0x6e5844), linear(0xc4ac88), t: smoothstep(p.y - y, -radius * 0.8, radius * 0.6)) }
            parts.append(log)
            // Both sawn ends.
            for end: Float in [-1, 1] {
                var cut = endGrain(radius: radius * 0.94, rings: 4)
                cut.apply(.compose(v(end * half + shift + end * 0.005, y, z), euler: v(0, 0, -end * .pi / 2)))
                parts.append(cut)
            }
        }
        // Moss settling on the oldest logs, low on the shaded side, and a little on the top one (`Moss`).
        func on(_ k: Int) -> (Vec2) -> (Vec3, Vec3) {
            let (_, z, row, scale) = logs[k]
            let radius = r * scale, y = radius + row * r * 1.68 - 0.04
            return { spot in
                let out = v(0, cos(spot.y), -sin(spot.y))
                return (v(spot.x, y, z) + out * radius, out)
            }
        }
        parts.append(Moss.patch(Moss.colony(Vec2(-0.5, 0.75), reach: Vec2(0.6, 0.45), count: 6, size: 0.2, seed: 41, on(0))
                                + Moss.colony(Vec2(0.4, 0.3), reach: Vec2(0.35, 0.3), count: 4, size: 0.15, seed: 42, on(5)), seed: 4))
        // Lying along z, so as it is first placed (and pictured) the ends face you.
        return Plant(shape: Geometry.join(parts).applied(.rotationY(.pi / 2)).roughened(0.9), top: v(0, r * 2 + r * 1.68 * 2, 0))
    }()
}
