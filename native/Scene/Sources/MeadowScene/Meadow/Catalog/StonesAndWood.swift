import Foundation
import simd

// The meadow editor's stones and wood (the Stones & Wood shelf, beside the Default's stones and log): each
// modelled on the real thing, then simplified into the meadow's clay. Found, not made, so each is drawn at
// the size the meadow found it (a boulder varies a little; a stump and a log pile never scale).

enum StonesAndWood {
    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }

    /// The end grain of a sawn log, facing up at y = 0: pale sapwood round a warmer heart, its growth rings
    /// drawn in fine darker lines, a dark pith at the middle, and the cut a hair dished.
    static func endGrain(radius: Float, rings: Int = 6, around: Int = 28) -> Geometry {
        let steps = rings * 2
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

    /// A stacked woodpile as gardens keep one: short round logs of about one length laid front to back in four
    /// tidy rows on two bearers, held at each end by a pair of stakes, so it is wider than it is tall; their sawn
    /// ends, pale with rings, all face the front, their bark the back and the ends, each log a little different in
    /// girth and length so the face is uneven as a real one's. Moss has settled on the top rows at the back. From
    /// above it reads as a long, low stack of logs; from the front, as a wall of log ends.
    static let logPile: Plant = {
        var parts: [Geometry] = []
        let weathered: (UInt32, UInt32) = (0x6f6252, 0x9d8f78)
        /// A square stick of weathered wood from `a` to `b` (a bearer, a stake), `w` across.
        func stick(_ a: Vec3, _ b: Vec3, _ w: Float) -> Geometry {
            Clay.limb(QuadraticBezier(a, (a + b) / 2, b), w, w * 0.9, weathered.0, weathered.1, sides: 4, rings: 1).shape
        }
        // The bearers it stands on, along its length, and the stakes holding each end.
        let half: Float = 1.62, bearer: Float = 0.14
        for z: Float in [-0.4, 0.4] { parts.append(stick(v(-half, bearer / 2, z), v(half, bearer / 2, z), 0.08)) }
        for x: Float in [-half - 0.03, half + 0.03] {
            for z: Float in [-0.42, 0.42] { parts.append(stick(v(x, -0.15, z), v(x, 1.82, z), 0.065)) }
        }
        // The logs, row on row: seven a row, a little irregular.
        let rows = 4, across = 7, r: Float = 0.215, rise: Float = 0.39, front: Float = 0.62
        var top: Float = 0
        for row in 0..<rows {
            for k in 0..<across {
                let n = Float(row * across + k)
                let wobble = Float(lattice(Double(n), 2.3, 7)) - 0.5, girth = Float(lattice(Double(n), 5.9, 7)) - 0.5
                let radius = r * (1 + girth * 0.22)
                let x = (Float(k) - Float(across - 1) / 2) * r * 2.06 + wobble * 0.05 + (row % 2 == 0 ? 0 : 0.04)
                let y = bearer + r + Float(row) * rise + wobble * 0.02
                let ahead = front + wobble * 0.07, back = -front - 0.08 + girth * 0.16
                var log = Clay.limb(QuadraticBezier(v(x, y, back), v(x, y + 0.005, (back + ahead) / 2), v(x, y, ahead)), radius, radius * 0.97, 0x6e5844, 0x6e5844,
                                    sides: 9, rings: 1).shape
                // Bark weathered paler and greyer on top, darker beneath and in the cracks between the logs.
                log.colors = log.positions.map { p in mix(linear(0x5e4a3a), linear(0xb7a07e), t: smoothstep(p.y - y, -radius * 0.8, radius * 0.7)) }
                parts.append(log)
                // The sawn ends: the front's with its rings, the back's plainer.
                for (end, z, rings, around) in [(Float(1), ahead + 0.004, 2, 12), (-1, back - 0.004, 1, 9)] {
                    var cut = endGrain(radius: radius * 0.94, rings: rings, around: around)
                    cut.apply(.compose(v(x, y, z), euler: v(end * .pi / 2, 0, 0)))
                    parts.append(cut)
                }
                top = max(top, y + radius)
            }
        }
        // Moss settling on the top rows at the back, where the cat does not sit (`Moss`).
        let stack = Geometry.join(parts)
        parts.append(Moss.patch(Moss.colony(Vec2(-0.85, -0.3), reach: Vec2(0.4, 0.22), count: 4, size: 0.17, seed: 41, Moss.top(of: stack))
                                + Moss.colony(Vec2(0.95, -0.38), reach: Vec2(0.3, 0.18), count: 3, size: 0.15, seed: 42, Moss.top(of: stack)), seed: 4))
        return Plant(shape: Geometry.join(parts).roughened(0.9), top: v(0, top, 0))
    }()
}
