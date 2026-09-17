import Foundation
import Testing
import simd
@testable import MeadowScene

// The looks the model audit fixed, held (docs/DESIGN.md, "Things read from the editor's height"): moss settles in
// colonies of tufted cushions with the wood or stone showing between them, never one smooth pad; a fern is a star of
// feathery fronds, not a mat of leaves; a clover patch is a mat of trefoils its white heads stand above; a kettle's
// steam is wisps, not a string of balls.

/// A model as the meadow draws it, at its own size.
private func shape(_ id: String) -> Geometry? {
    id == "wood.fallenLog" ? SceneryCatalog.fallenLog : Meadow.alone(MeadowScenery.Thing(id: id, x: 0, z: 0)).map { $0.make() }
}

/// Seen from straight above, how much of the outline round `points` (x, z) they fill: a cell a tenth of `cell` on a
/// side counts as filled when a point falls in it. A smooth pad or a solid mat fills nearly all of its outline; a
/// colony of cushions, or a star of fronds, much less.
private func fill(_ points: [Vec2], cell: Float) -> Float {
    guard points.count > 3 else { return 1 }
    // The outline: the convex hull (monotone chain).
    let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    func cross(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    var lower: [Vec2] = [], upper: [Vec2] = []
    for p in sorted {
        while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
        lower.append(p)
    }
    for p in sorted.reversed() {
        while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
        upper.append(p)
    }
    let hull = Array(lower.dropLast() + upper.dropLast())
    var area: Float = 0
    for i in hull.indices { let a = hull[i], b = hull[(i + 1) % hull.count]; area += a.x * b.y - b.x * a.y }
    area = abs(area) / 2
    var cells = Set<SIMD2<Int32>>()
    for p in points { cells.insert(SIMD2(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)))) }
    return Float(cells.count) * cell * cell / max(area, 1e-6)
}

/// The points of a shape seen from above, filled in: its triangles sampled across, not just their corners.
private func cover(_ g: Geometry, where keep: (Vec3) -> Bool) -> [Vec2] {
    var out: [Vec2] = []
    var k = 0
    while k + 2 < g.indices.count {
        let a = Int(g.indices[k]), b = Int(g.indices[k + 1]), c = Int(g.indices[k + 2])
        k += 3
        guard keep(g.colors[a]) || keep(g.colors[b]) || keep(g.colors[c]) else { continue }
        let pa = g.positions[a], pb = g.positions[b], pc = g.positions[c]
        for (u, v) in [(Float(1) / 3, Float(1) / 3), (0.1, 0.1), (0.8, 0.1), (0.1, 0.8), (0.45, 0.45), (0.45, 0.1), (0.1, 0.45)] {
            let p = pa + (pb - pa) * u + (pc - pa) * v
            out.append(Vec2(p.x, p.z))
        }
    }
    return out
}

/// Moss green: far greener than red or blue (a lichen's grey-green, bark and stone are not).
private func mossy(_ c: Vec3) -> Bool { c.y > c.x * 1.4 && c.y > c.z * 1.6 }

@Suite struct ModelLooks {
    nonisolated static let mossed = ["wood.fallenLog", "stone.mossy", "stone.boulder", "wood.stump", "wood.logPile"]

    @Test("moss settles as a colony of cushions, none much of it, never one smooth pad laid on the wood or the stone",
          arguments: Self.mossed)
    func mossInColonies(_ id: String) throws {
        let g = try #require(shape(id))
        // Each separate piece of moss (its triangles joined by the points they share), by how many points it has.
        var parent = Array(0..<g.count)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        var k = 0
        while k + 2 < g.indices.count {
            let a = Int(g.indices[k]), b = Int(g.indices[k + 1]), c = Int(g.indices[k + 2])
            k += 3
            guard mossy(g.colors[a]) && mossy(g.colors[b]) && mossy(g.colors[c]) else { continue }
            parent[root(b)] = root(a)
            parent[root(c)] = root(a)
        }
        var pieces: [Int: Int] = [:]
        for i in 0..<g.count where mossy(g.colors[i]) { pieces[root(i), default: 0] += 1 }
        let sizes = pieces.values.filter { $0 > 12 }.sorted(by: >)
        let all = sizes.reduce(0, +)
        #expect(sizes.count >= 6, "\(id): its moss is \(sizes.count) pieces")
        #expect(Float(sizes.first ?? 0) < Float(all) * 0.34, "\(id): one piece holds \(sizes.first ?? 0) of the moss's \(all) points")
    }

    @Test("a colony's cushions are of clearly different sizes, and each is lumpy and tufted, never a smooth disc")
    func cushions() {
        let colony = Moss.colony(.zero, reach: Vec2(1, 0.6), count: 9, size: 0.5, seed: 4) { (Vec3($0.x, 0, $0.y), Vec3(0, 1, 0)) }
        let sizes = colony.map(\.size)
        #expect(sizes.max()! > sizes.min()! * 1.6, "\(sizes)")
        let one = Moss.patch([Moss.Cushion(at: .zero, up: Vec3(0, 1, 0), size: 1)], seed: 2)
        // Its outline from above: the reach at each angle round it varies, as a lobed cushion's does.
        var reach = [Float](repeating: 0, count: 24)
        for p in one.positions {
            let k = Int(((atan2(p.z, p.x) + .pi) / (2 * .pi) * 24).rounded(.down)) % 24
            reach[k] = max(reach[k], hypot(p.x, p.z))
        }
        let mean = reach.reduce(0, +) / 24
        let spread = (reach.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 24).squareRoot() / mean
        #expect(spread > 0.08, "a cushion's outline varies by \(spread) round it")
        // Low: far wider than it is high.
        #expect(one.bounds.max.y < mean * 0.55, "\(one.bounds.max.y) high for \(mean) across")
    }

    @Test("a fern is a star of feathery fronds from above, its leaflets many, narrow and set close, not a mat of leaves")
    func fern() throws {
        let g = try #require(shape("plant.fern"))
        let leaves = cover(g) { $0.y > $0.x * 1.2 }
        let filled = fill(leaves, cell: 0.08)
        #expect(filled < 0.72, "the fern fills \(filled) of its outline from above")
        // Each frond carries 13 leaflets a side: the fern is many small parts, a little over 40 times its seven fronds'.
        #expect(g.indices.count / 3 < 20_000)
    }

    @Test("a clover patch is a mat of trefoils its white heads stand above, the leaves held up into the light")
    func clover() throws {
        let g = try #require(shape("plant.clover"))
        let white = g.positions.indices.filter { g.colors[$0].x > 0.7 && g.colors[$0].y > 0.7 && g.colors[$0].z > 0.6 }.map { g.positions[$0] }
        let green = g.positions.indices.filter { mossy(g.colors[$0]) || g.colors[$0].y > g.colors[$0].x * 1.3 }.map { g.positions[$0] }
        #expect(!white.isEmpty && !green.isEmpty)
        let heads = white.map(\.y).max()!, leaves = green.map(\.y).max()!
        #expect(heads > leaves + 0.1, "heads at \(heads), leaves up to \(leaves)")
        // The leaves stand in the upper part of the meadow's grass, not down in it.
        let leafHeights = green.map(\.y).sorted()
        #expect(leafHeights[leafHeights.count * 3 / 4] > 0.4, "most leaves below \(leafHeights[leafHeights.count * 3 / 4])")
        // A mat: from above its leaves cover most of the ground round its middle.
        let disc = cover(g) { $0.y > $0.x * 1.3 }.filter { simd_length($0) < 0.4 }
        #expect(fill(disc, cell: 0.05) > 0.5, "a sparse patch")
    }

    @Test("a kettle's steam is soft wisps, each puff billowing unevenly, and thins out within about a kettle's height")
    func steam() {
        var reach: [Float] = []
        for p in Kettle.puff.positions where abs(p.y) < 0.3 { reach.append(hypot(p.x, p.z)) }
        let mean = reach.reduce(0, +) / Float(reach.count)
        let spread = (reach.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(reach.count)).squareRoot() / mean
        #expect(spread > 0.1, "a puff round its middle varies by \(spread): a ball")
    }
}
