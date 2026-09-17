import Foundation
import simd

// Moss as it grows on a fallen log, a stump, a pile of logs and old stones: never one smooth pad, but a colony of
// low cushions of different sizes crowding together, the biggest where it took hold first and smaller ones
// creeping out from it, so its edge is ragged and the wood or the stone shows between them; each cushion tufted
// all over with the tiny shoots of its stems, catching the light on top and darker down its sides. The trees'
// foliage language (docs/DESIGN.md, "Trees read as foliage") at a smaller scale: from the editor's height a patch
// reads as moss settled on the thing, not as a green balloon laid on it.

enum Moss {
    /// Where one cushion grows: the point of the surface under its middle, the way out from the surface there, and
    /// its radius along the surface.
    struct Cushion { var at: Vec3; var up: Vec3; var size: Float }

    /// Sun-bleached tips over the deep green of the stems, as the meadow's moss always was.
    static let colors: (UInt32, UInt32) = (0x3d6526, 0xa6cb5e)

    /// The ball a cushion is pressed from: more points round it than up it, as its outline seen from above runs round
    /// its middle; few, as there are dozens of cushions on a log and the tufts are in their colours as much as their shape.
    private static let ball: Geometry = {
        var g = Shapes.sphere(1, 10, 5).welded()
        g.computeNormals()
        return g
    }()

    /// A colony of cushions spreading over a surface from `middle` (in the surface's own two coordinates), `reach`
    /// across along each way and `count` cushions in all: the largest at its middle, smaller ones out to its ragged
    /// edge. `surface` gives the point of the surface and the way out from it at each of its coordinates.
    static func colony(_ middle: Vec2, reach: Vec2, count: Int, size: Float, seed: Double, _ surface: (Vec2) -> (Vec3, Vec3)) -> [Cushion] {
        var cushions: [Cushion] = []
        for k in 0..<count {
            // Out from the middle in a sunflower's spiral, a little shaken, so none fall in rows.
            let f = Float(k) / Float(max(count - 1, 1))
            let a = Float(k) * 2.399963 + Float(lattice(Double(k), 1.3, seed)) * 1.2
            let out = sqrt(f) * (0.85 + 0.3 * Float(lattice(Double(k), 4.1, seed)))
            let spot = middle + Vec2(cos(a) * reach.x, sin(a) * reach.y) * out
            let (at, up) = surface(spot)
            // The first cushions are the biggest; those creeping out at the edge are small.
            let r = size * (1 - 0.55 * f) * (0.8 + 0.4 * Float(lattice(Double(k), 7.7, seed)))
            cushions.append(Cushion(at: at, up: simd_normalize(up), size: r))
        }
        return cushions
    }

    /// The top of a shape as moss settles on it, seen from above: at each spot (x, z), the highest point of the shape
    /// within a finger's width of it and the way out from it there, so a colony follows a lumpy stone's every bump.
    static func top(of shape: Geometry) -> (Vec2) -> (Vec3, Vec3) {
        { spot in
            var best = -1, nearest = -1, high = -Float.infinity, close = Float.infinity
            for (i, p) in shape.positions.enumerated() {
                let d = hypot(p.x - spot.x, p.z - spot.y)
                if d < 0.16, p.y > high { high = p.y; best = i }
                if d < close { close = d; nearest = i }
            }
            let i = best >= 0 ? best : nearest
            return (shape.positions[i], shape.normals.indices.contains(i) ? shape.normals[i] : Vec3(0, 1, 0))
        }
    }

    /// The cushions as one shape. Each is a low dome flat against the surface it grows on (and sunk a little into
    /// it, so none floats), its outline in lobes and its top tufted in two sizes of bump, lighter where it is high and
    /// sunlit, darker down its sides and in the hollows between the tufts.
    static func patch(_ cushions: [Cushion], seed: Double, colors: (UInt32, UInt32) = Moss.colors) -> Geometry {
        let low = linear(colors.0), high = linear(colors.1)
        var parts: [Geometry] = []
        parts.reserveCapacity(cushions.count)
        for (k, cushion) in cushions.enumerated() {
            let own = seed + Double(k) * 5.31
            // The tufts: a broad lobing of the outline, then the shoots.
            func tufts(_ d: Vec3) -> (broad: Float, fine: Float) {
                let broad = Float(noise(Double(d.x * 2.2 + d.y * 0.7) + own, Double(d.z * 2.2 - d.y * 0.5), 0)) - 0.5
                let fine = Float(noise(Double(d.x * 9.5 + d.y * 3.1) + own, Double(d.z * 9.5 - d.y * 2.3), 0)) - 0.5
                return (broad, fine)
            }
            var g = ball
            g.colors = []
            for i in g.positions.indices {
                let d = g.positions[i]
                let (broad, fine) = tufts(d)
                let round = 1 + broad * 0.55 + fine * 0.28
                // Low and domed: hardly a third as high as it is wide, pressed flat and a little sunk beneath.
                let y = d.y > 0 ? d.y * 0.3 * (1 + broad * 0.4 + fine * 0.5) : d.y * 0.12
                g.positions[i] = Vec3(d.x * round, y, d.z * round)
                let height = clamp((y + 0.04) / 0.4, 0, 1)
                g.colors.append(lerp(low, high, smooth(height)) * (1 + fine * 0.5))
            }
            // Into place: its y along the way out from the surface, turned round it by the seed.
            let up = cushion.up
            let side = simd_normalize(abs(up.y) < 0.95 ? simd_cross(up, Vec3(0, 1, 0)) : simd_cross(up, Vec3(1, 0, 0)))
            let spin = Float(lattice(Double(k), 2.9, seed)) * 2 * .pi
            let x = side * cos(spin) + simd_cross(side, up) * sin(spin), z = simd_cross(x, up)
            let s = cushion.size
            let m = Mat4(columns: (Vec4(x * s, 0), Vec4(up * s, 0), Vec4(z * s, 0), Vec4(cushion.at - up * s * 0.06, 1)))
            g.apply(m)
            g.computeNormals()
            parts.append(g)
        }
        return Geometry.join(parts)
    }
}
