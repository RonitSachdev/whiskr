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
//   surface (RGBA8): r how worn the ground is: 1 bare earth (a painted path, under a stepping stone), 0 the
//                    meadow's own; g how short the grass is cut (painted lawn, and trodden round a stepping
//                    stone); b painted soil; and a the trees' shade: 1 under a crown's middle, falling to 0
//                    at its reach.
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

    /// The map for trees shading the ground below them (x, z, the reach of their shade), the painted ground
    /// and the stones walked on.
    static func baked(shade trees: [Vec4], ground: MeadowScenery.Ground? = nil, treads: [Tread] = []) -> GroundMap {
        var map = GroundMap()
        for tree in trees { map.shade(tree, within: Region.whole) }
        // Only round what is painted: the rest stays as nothing painted.
        let painted = ([difference(nil, ground)] + treads.map(Region.init(tread:))).compactMap { $0 }
        if let first = painted.first { map.paint(ground, treads: treads, in: painted.dropFirst().reduce(first) { $0.union($1) }) }
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
            self.init(around: Vec2(tree.x, tree.y), reach: tree.z)
        }

        /// The texels a stone walked on wears (nil: none, off the map).
        init?(tread: Tread) {
            self.init(around: Vec2(tread.x, tread.z), reach: max(tread.half.x, tread.half.y) + Tread.wornBeyond)
        }

        /// The texels within `reach` of a point, on the map (nil: none).
        init?(around p: Vec2, reach: Float) {
            func texel(_ v: Float) -> Int { Int(((v + GroundMap.reach) / cell).rounded(.down)) }
            self.init(columns: texel(p.x - reach)...texel(p.x + reach), rows: texel(p.y - reach)...texel(p.y + reach))
            guard let onMap = intersection(.whole) else { return nil }
            self = onMap
        }

        /// The texels of the paint grid's cells `columns` and `rows`.
        init(cells columns: ClosedRange<Int>, _ rows: ClosedRange<Int>) {
            self.init(columns: (columns.lowerBound + margin)...(columns.upperBound + margin), rows: (rows.lowerBound + margin)...(rows.upperBound + margin))
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
    func shade(at p: Vec2) -> Float { sample(p, channel: 3) }

    /// A channel at a point, as the shaders read it: bilinear between texel middles, 0 outside.
    func sample(_ p: Vec2, channel: Int) -> Float {
        let u = (p.x + Self.reach) / Self.cell - 0.5, v = (p.y + Self.reach) / Self.cell - 0.5
        let c = Int(u.rounded(.down)), r = Int(v.rounded(.down)), fu = u - Float(c), fv = v - Float(r)
        func at(_ column: Int, _ row: Int) -> Float {
            guard (0..<Self.side).contains(column), (0..<Self.side).contains(row) else { return 0 }
            return Float(surface[(row * Self.side + column) * 4 + channel]) / 255
        }
        return (at(c, r) * (1 - fu) + at(c + 1, r) * fu) * (1 - fv) + (at(c, r + 1) * (1 - fu) + at(c + 1, r + 1) * fu) * fv
    }

    // MARK: the painted ground

    /// A stone walked on (`SceneryCatalog.isTread`), as it lies: its middle, its turn about up and how far it
    /// reaches each way along its own x and z.
    struct Tread: Hashable {
        var x: Float
        var z: Float
        var turn: Float
        var half: Vec2

        /// How far past its edge the turf round it is trodden short.
        static let wornBeyond: Float = 1.1
        /// How short the grass is trodden round it, as lawn is mown (`trodden` reaches this at its edge).
        static let trodden: Float = 0.6

        /// How far past its edge a point lies, along the line from its middle (negative on the stone).
        func beyond(_ p: Vec2) -> Float {
            // Into the stone's own frame (it is turned about up as the scene turns things: x' = x cos − z sin…).
            let d = p - Vec2(x, z), c = cos(turn), s = sin(turn)
            let local = Vec2(d.x * c - d.y * s, d.x * s + d.y * c)
            let scaled = simd_length(local / half)
            return scaled > 1e-4 ? simd_length(local) * (1 - 1 / scaled) : -max(half.x, half.y)
        }

        /// The ground under the stone, worn bare (the earth shows only as a thin rim where it meets the turf),
        /// so no grass grows through it.
        func under(_ p: Vec2) -> Float { 1 - smoothstep(beyond(p), -0.12, 0.1) }

        /// The turf round its edge, trodden short for a hand's width and growing back beyond: a row of them stands
        /// in a strip of short grass, as stepping stones through a meadow do.
        func trodden(_ p: Vec2) -> Float { Self.trodden * (1 - smoothstep(beyond(p), Self.wornBeyond - 0.6, Self.wornBeyond)) }

        /// Whether a point is on the stone itself.
        func holds(_ p: Vec2) -> Bool {
            let d = p - Vec2(x, z), c = cos(turn), s = sin(turn)
            return simd_length_squared(Vec2(d.x * c - d.y * s, d.x * s + d.y * c) / half) <= 1
        }
    }

    /// Paints `region` again from `ground` (nil: nothing painted) and `treads`: path, lawn and soil from the
    /// cells under it, softened a little (each texel weighs its cell and the three round it each way, as a
    /// binomial blur), so the shaders' edges run round in curves rather than along the grid; then the wear under and
    /// round each stone walked on. The trees' shade is left as it is. Returns the texels it changed: the region and
    /// the softening's reach round it.
    @discardableResult
    mutating func paint(_ ground: MeadowScenery.Ground?, treads: [Tread], in region: Region) -> Region {
        let reach = Self.soften.count / 2
        func widened(_ r: Region, _ by: Int) -> Region {
            Region(columns: (r.columns.lowerBound - by)...(r.columns.upperBound + by), rows: (r.rows.lowerBound - by)...(r.rows.upperBound + by)).intersection(.whole)!
        }
        let changed = widened(region, reach), read = widened(changed, reach)
        let side = MeadowScenery.Ground.side, width = read.columns.count
        // Each texel of what is read: 1 in the channel of its cell's paint.
        var painted = [Float](repeating: 0, count: width * read.rows.count * 3)
        if let ground {
            for (r, row) in read.rows.enumerated() where (0..<side).contains(row - Self.margin) {
                for (c, column) in read.columns.enumerated() where (0..<side).contains(column - Self.margin) {
                    let channel: Int? = switch ground[column - Self.margin, row - Self.margin] {
                    case .path: 0
                    case .lawn: 1
                    case .soil: 2
                    case .wild: nil
                    }
                    if let channel { painted[(r * width + c) * 3 + channel] = 1 }
                }
            }
        }
        // Along each row, then down each column.
        var across = [Float](repeating: 0, count: painted.count)
        for r in 0..<read.rows.count {
            for c in 0..<width {
                for channel in 0..<3 {
                    var sum: Float = 0
                    for (k, w) in Self.soften.enumerated() {
                        let cc = min(max(c + k - reach, 0), width - 1)
                        sum += painted[(r * width + cc) * 3 + channel] * w
                    }
                    across[(r * width + c) * 3 + channel] = sum
                }
            }
        }
        let firstRow = changed.rows.lowerBound - read.rows.lowerBound, firstColumn = changed.columns.lowerBound - read.columns.lowerBound
        for (r, row) in changed.rows.enumerated() {
            for (c, column) in changed.columns.enumerated() {
                let i = (row * Self.side + column) * 4
                for channel in 0..<3 {
                    var sum: Float = 0
                    for (k, w) in Self.soften.enumerated() {
                        let rr = min(max(firstRow + r + k - reach, 0), read.rows.count - 1)
                        sum += across[(rr * width + firstColumn + c) * 3 + channel] * w
                    }
                    surface[i + channel] = UInt8((sum * 255).rounded())
                }
            }
        }
        for tread in treads {
            guard let reached = Region(tread: tread)?.intersection(changed) else { continue }
            for row in reached.rows {
                for column in reached.columns {
                    let p = Self.middle(column, row), i = (row * Self.side + column) * 4
                    surface[i] = max(surface[i], UInt8((tread.under(p) * 255).rounded()))
                    surface[i + 1] = max(surface[i + 1], UInt8((tread.trodden(p) * 255).rounded()))
                }
            }
        }
        return changed
    }

    /// The softening's weights, texel by texel across (1 6 15 20 15 6 1, adding up to 1).
    static let soften: [Float] = [1, 6, 15, 20, 15, 6, 1].map { $0 / 64 }

    /// The texels whose cells differ between two grounds (nil: none differ), rows compared whole.
    static func difference(_ a: MeadowScenery.Ground?, _ b: MeadowScenery.Ground?) -> Region? {
        guard a != nil || b != nil else { return nil }
        let side = MeadowScenery.Ground.side
        let wild = [UInt8](repeating: 0, count: side * side)
        var columns: ClosedRange<Int>?, rows: ClosedRange<Int>?
        (a?.cells ?? wild).withUnsafeBufferPointer { x in
            (b?.cells ?? wild).withUnsafeBufferPointer { y in
                for row in 0..<side {
                    let start = row * side
                    guard memcmp(x.baseAddress! + start, y.baseAddress! + start, side) != 0 else { continue }
                    var first = 0, last = side - 1
                    while x[start + first] == y[start + first] { first += 1 }
                    while x[start + last] == y[start + last] { last -= 1 }
                    columns = columns.map { min($0.lowerBound, first)...max($0.upperBound, last) } ?? first...last
                    rows = rows.map { $0.lowerBound...row } ?? row...row
                }
            }
        }
        guard let columns, let rows else { return nil }
        return Region(cells: columns, rows)
    }
}
