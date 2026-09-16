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
        for tree in trees { map.shade(tree, within: Region.whole) }
        return map
    }

    /// A rectangle of texels, columns and rows, both ends included.
    struct Region: Equatable {
        var columns: ClosedRange<Int>
        var rows: ClosedRange<Int>
        static let whole = Region(columns: 0...(side - 1), rows: 0...(side - 1))

        /// The texels a tree's shade can reach (nil: none, off the map).
        init?(shade tree: Vec4) {
            guard tree.z > 0 else { return nil }
            func texel(_ v: Float) -> Int { Int(((v + reach) / cell).rounded(.down)) }
            self.init(columns: texel(tree.x - tree.z)...texel(tree.x + tree.z), rows: texel(tree.y - tree.z)...texel(tree.y + tree.z))
            guard let onMap = intersection(.whole) else { return nil }
            self = onMap
        }

        init(columns: ClosedRange<Int>, rows: ClosedRange<Int>) {
            self.columns = columns
            self.rows = rows
        }

        func union(_ o: Region) -> Region {
            Region(columns: min(columns.lowerBound, o.columns.lowerBound)...max(columns.upperBound, o.columns.upperBound),
                   rows: min(rows.lowerBound, o.rows.lowerBound)...max(rows.upperBound, o.rows.upperBound))
        }

        func intersection(_ o: Region) -> Region? {
            guard columns.overlaps(o.columns), rows.overlaps(o.rows) else { return nil }
            return Region(columns: columns.clamped(to: o.columns), rows: rows.clamped(to: o.rows))
        }
    }

    /// Adds a tree's shade to the texels of `region` it reaches.
    private mutating func shade(_ tree: Vec4, within region: Region) {
        guard let reached = Region(shade: tree)?.intersection(region) else { return }
        for row in reached.rows {
            for column in reached.columns {
                let p = Self.middle(column, row)
                let nearest = hypot(p.x - tree.x, p.y - tree.y) / tree.z
                guard nearest < 1 else { continue }
                let i = (row * Self.side + column) * 4 + 3
                surface[i] = max(surface[i], UInt8(((1 - nearest) * 255).rounded()))
            }
        }
    }

    /// The shade in `region` baked again from `trees` (after some moved), the same as baking them all
    /// afresh, touching only those texels.
    mutating func rebake(shade trees: [Vec4], in region: Region) {
        for row in region.rows {
            for column in region.columns { surface[(row * Self.side + column) * 4 + 3] = 0 }
        }
        for tree in trees { shade(tree, within: region) }
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
