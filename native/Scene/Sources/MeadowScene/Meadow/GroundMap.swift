import Foundation
import simd

// The ground's map: what the ground, the grass and everything rooted read about where they stand, baked
// from the scenery when it is laid instead of worked out for every pixel of every frame. One sample of it
// replaces a loop over the trees, so any number of trees can shade the ground.
//
// A square over the meadow, one texel for each cell of a meadow file's paint grid (512 cells over
// x, z ∈ [−150, 150]) and running on past the grid far enough that the shade of the largest tree standing
// at the meadow's edge (`MeadowScenery.Limits.reach`) still falls on it. Outside it nothing is painted,
// shaded or lit.
//
//   surface (RGBA8): path, lawn and soil, how much of each is painted (later: the Ground tool); and the
//                    trees' shade: 1 under a crown's middle, falling to 0 at its reach.
//   light (R8):      lamplight on the ground after dark (later: garden lamps).

struct GroundMap {
    /// A cell of the paint grid, in units.
    static let cell: Float = 300 / 512
    /// Texels beyond the paint grid on each side.
    static let margin = 80
    static let side = 512 + 2 * margin
    /// Half the map's width, in units.
    static var reach: Float { Float(side) * cell / 2 }

    /// `side` × `side` texels, row by row from z = −reach, each row from x = −reach; four bytes each.
    private(set) var surface: [UInt8]
    /// One byte a texel, in the same order.
    private(set) var light: [UInt8]

    /// Nothing painted, shaded or lit.
    init() {
        surface = [UInt8](repeating: 0, count: Self.side * Self.side * 4)
        light = [UInt8](repeating: 0, count: Self.side * Self.side)
    }

    /// Where texel (column, row)'s middle lies on the ground.
    static func middle(_ column: Int, _ row: Int) -> Vec2 {
        Vec2(-reach + (Float(column) + 0.5) * cell, -reach + (Float(row) + 0.5) * cell)
    }

    /// The map for trees shading the ground below them (x, z, the reach of their shade).
    static func baked(shade trees: [Vec4]) -> GroundMap {
        var map = GroundMap()
        for tree in trees where tree.z > 0 {
            // Only the texels within the shade's reach.
            func texel(_ v: Float) -> Int { Int(((v + reach) / cell).rounded(.down)) }
            let low = (max(texel(tree.x - tree.z), 0), max(texel(tree.y - tree.z), 0))
            let high = (min(texel(tree.x + tree.z), side - 1), min(texel(tree.y + tree.z), side - 1))
            guard low.0 <= high.0, low.1 <= high.1 else { continue }
            for row in low.1...high.1 {
                for column in low.0...high.0 {
                    let p = middle(column, row)
                    let nearest = hypot(p.x - tree.x, p.y - tree.y) / tree.z
                    guard nearest < 1 else { continue }
                    let i = (row * side + column) * 4 + 3
                    map.surface[i] = max(map.surface[i], UInt8(((1 - nearest) * 255).rounded()))
                }
            }
        }
        return map
    }

    /// The shade baked at a point, as the shaders read it (bilinear between texel middles; 0 outside):
    /// how near the nearest crown's middle it lies, 1 at the middle, 0 at its reach and beyond.
    func shade(at p: Vec2) -> Float {
        let u = (p.x + Self.reach) / Self.cell - 0.5, v = (p.y + Self.reach) / Self.cell - 0.5
        let c = Int(u.rounded(.down)), r = Int(v.rounded(.down)), fu = u - Float(c), fv = v - Float(r)
        func at(_ column: Int, _ row: Int) -> Float {
            guard (0..<Self.side).contains(column), (0..<Self.side).contains(row) else { return 0 }
            return Float(surface[(row * Self.side + column) * 4 + 3]) / 255
        }
        return (at(c, r) * (1 - fu) + at(c + 1, r) * fu) * (1 - fv) + (at(c, r + 1) * (1 - fu) + at(c + 1, r + 1) * fu) * fv
    }
}
