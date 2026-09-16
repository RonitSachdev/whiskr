import Foundation
import simd

/// Where a thing of the scenery may stand when someone moves, copies or places it (docs/DESIGN.md, "The
/// meadow's scenery"): inside the meadow, clear of every other thing by a strip of grass (nothing overlaps
/// anything), and, for big things, off the picnic ground kept for the workspaces' blankets. Plain values in,
/// a verdict out, so the editor and the marks the meadow draws for it agree.
///
/// The rules judge what is moved or put down, never what already stands: a meadow file may hold things a
/// little closer than this (the Default's flowers grow in tight clumps; someone else's file was their choice).
public enum SceneryRules {
    /// A circle of ground a thing stands on, in units.
    public struct Circle: Equatable, Sendable {
        public var x: Float
        public var z: Float
        public var r: Float

        public init(x: Float, z: Float, r: Float) {
            self.x = x
            self.z = z
            self.r = r
        }
    }

    /// Why a thing may not stand where it was put.
    public enum Refusal: Equatable, Sendable {
        /// Past the meadow's edge (`reach`, measured to its trunk's or root's middle).
        case outsideMeadow
        /// A big thing on the picnic ground.
        case keptForWorkspaces
        /// Its ground overlaps that of the thing at this index of the scenery (with the grass kept between).
        case tooClose(Int)
    }

    /// The picnic ground: where the workspaces' blankets lie at any width of the meadow, round the column's
    /// lane at x = 0 (a row of six with its sway either side, and the column's kept length). Big things are
    /// kept off it; plants, stones and mushrooms may grow there and make way when a blanket comes.
    public static let picnicGround = (minX: Float(-20), maxX: Float(20), minZ: Float(-3), maxZ: Float(120))

    /// How far from the meadow's middle a thing may stand: its trunk's or root's middle.
    public static var reach: Float { MeadowScenery.Limits.reach }

    /// The ground a thing stands on: round a tree's roots, a plant's or a stone's base, along a log.
    /// Nothing for a thing the scene does not draw.
    public static func footprint(of thing: MeadowScenery.Thing) -> [Circle] {
        guard let kind = SceneryCatalog.kinds[thing.id] else { return [] }
        let spread = max(thing.size.x, thing.size.z)
        switch kind {
        case .tree(let species):
            return [Circle(x: thing.x, z: thing.z, r: species.girth * 2.4 * spread)]
        case .youngTree(let species):
            return [Circle(x: thing.x, z: thing.z, r: species.girth * 3.6 * spread)]
        case .plant(_, _, _, let base):
            return [Circle(x: thing.x, z: thing.z, r: base * spread)]
        case .log:
            // Along its length (its own x axis), as it lies turned.
            let along = Vec2(cos(thing.turn), -sin(thing.turn))
            return [Float(-6), -3, 0, 3, 6].map { t in Circle(x: thing.x + along.x * t * thing.size.x, z: thing.z + along.y * t * thing.size.x, r: 1.5) }
        }
    }

    /// Trees, young trees, logs and lamps: kept off the picnic ground (a lamp's light would fall on the blankets
    /// and their lanterns, and a lit lamp among them could be taken for one).
    public static func isBig(_ id: String) -> Bool {
        switch SceneryCatalog.kinds[id] {
        case .tree, .youngTree, .log: true
        default: Lamps.isLamp(id)
        }
    }

    /// Plants, mushrooms and stones (a boulder aside): the small things brushed and swept away in numbers and
    /// read out by VoiceOver as clumps of a kind. Everything else (trees, wood, a boulder, made things) is placed,
    /// taken away and read out one at a time, so no stroke of the Eraser loses one.
    public static func isSmall(_ id: String) -> Bool {
        guard case .plant = SceneryCatalog.kinds[id] else { return false }
        return !SceneryCatalog.alone.contains(id)
    }

    /// The grass a thing keeps round its ground: more round trees and logs than round a flower.
    public static func gap(_ id: String) -> Float {
        switch SceneryCatalog.kinds[id] {
        case .tree, .log: 0.6
        case .youngTree: 0.4
        case .plant(_, _, _, let base): base > 1 ? 0.2 : 0.1
        case nil: 0
        }
    }

    /// The ground of the scenery's things but those left out, sorted into squares, so each thing put down
    /// is judged against its neighbours only.
    public struct Field: Sendable {
        private var ids: [String]
        private var cells: [Int64: [(thing: Int, circle: Circle)]] = [:]
        private static let cell: Float = 8

        /// `scenery`'s things but `leavingOut` (the ones being moved, which keep their shape among themselves).
        public init(_ scenery: MeadowScenery, leavingOut: Set<Int> = []) {
            ids = scenery.things.map(\.id)
            for (i, thing) in scenery.things.enumerated() where !leavingOut.contains(i) {
                for circle in SceneryRules.footprint(of: thing) { insert(i, circle) }
            }
        }

        /// `thing` added after the scenery's things (at the next index): one just brushed, so the next of a
        /// stroke keeps its grass from it too.
        public mutating func add(_ thing: MeadowScenery.Thing) {
            let index = ids.count
            ids.append(thing.id)
            for circle in SceneryRules.footprint(of: thing) { insert(index, circle) }
        }

        private static func key(_ cx: Int, _ cz: Int) -> Int64 { Int64(cx) << 32 | Int64(UInt32(bitPattern: Int32(cz))) }
        private static func span(_ v: Float, _ r: Float) -> ClosedRange<Int> { Int(((v - r) / cell).rounded(.down))...Int(((v + r) / cell).rounded(.down)) }

        private mutating func insert(_ thing: Int, _ circle: Circle) {
            for cx in Self.span(circle.x, circle.r) {
                for cz in Self.span(circle.z, circle.r) { cells[Self.key(cx, cz), default: []].append((thing, circle)) }
            }
        }

        /// Why `thing` may not stand where it is (nil: it may). Of several things it is too close to, the
        /// nearest is named. What it was too close to already, where it stood before (`excusing`, from
        /// `overlapping`), is excused, and so is the picnic ground for a big thing that stood on it before
        /// (`wasOnPicnicGround`): an edit is refused only for what it makes worse.
        public func refusal(for thing: MeadowScenery.Thing, excusing: Set<Int> = [], wasOnPicnicGround: Bool = false) -> Refusal? {
            if hypot(thing.x, thing.z) > SceneryRules.reach { return .outsideMeadow }
            if !wasOnPicnicGround, SceneryRules.isOnPicnicGround(thing) { return .keptForWorkspaces }
            var nearest: (thing: Int, overlap: Float)?
            visitOverlaps(of: thing) { other, overlap in
                if !excusing.contains(other), overlap < (nearest?.overlap ?? 0) { nearest = (other, overlap) }
            }
            return nearest.map { .tooClose($0.thing) }
        }

        /// The things whose ground `thing` reaches into, with the grass kept between.
        public func overlapping(_ thing: MeadowScenery.Thing) -> Set<Int> {
            var found = Set<Int>()
            visitOverlaps(of: thing) { other, _ in found.insert(other) }
            return found
        }

        private func visitOverlaps(of thing: MeadowScenery.Thing, _ each: (Int, Float) -> Void) {
            let gap = SceneryRules.gap(thing.id)
            for c in SceneryRules.footprint(of: thing) {
                for cx in Self.span(c.x, c.r) {
                    for cz in Self.span(c.z, c.r) {
                        for other in cells[Self.key(cx, cz)] ?? [] {
                            let apart = hypot(c.x - other.circle.x, c.z - other.circle.z) - c.r - other.circle.r - max(gap, SceneryRules.gap(ids[other.thing]))
                            if apart < 0 { each(other.thing, apart) }
                        }
                    }
                }
            }
        }
    }

    /// A big thing whose ground reaches onto the picnic ground.
    public static func isOnPicnicGround(_ thing: MeadowScenery.Thing) -> Bool {
        isBig(thing.id) && footprint(of: thing).contains(where: onPicnicGround)
    }

    /// Whether a circle of ground reaches onto the picnic ground.
    static func onPicnicGround(_ c: Circle) -> Bool {
        let g = picnicGround
        let dx = max(g.minX - c.x, 0, c.x - g.maxX), dz = max(g.minZ - c.z, 0, c.z - g.maxZ)
        return dx * dx + dz * dz < c.r * c.r
    }
}
