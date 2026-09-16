import Foundation
import MeadowFile
import MeadowScene
import simd

// Fence runs and colours in the meadow's editor (docs/DESIGN.md, "Edit Meadow"): a fence laid along a drag (a post
// each 2.5 units of it, or one straight length with ⌥), its ends joining a nearby fence's ends so the two become one
// run; a run straightened, given a gate or its gate taken away; and the colour a made thing wears, from its palette.
// A run is one thing of the meadow (its `points` and `params.gate`), so laying, joining, straightening and gating are
// each one step.

/// A fence being drawn: the points laid so far along the pointer's way, a post's spacing apart (or, straight, only
/// where it began).
public struct MeadowFenceDraft: Equatable, Sendable {
    public private(set) var points: [SIMD2<Double>]
    /// One straight length from where it began (⌥).
    public var straight: Bool

    public init(at start: SIMD2<Double>, straight: Bool = false) {
        points = [start]
        self.straight = straight
    }

    /// The pointer has come to `spot`: a point each post's spacing along the way from the last one.
    public mutating func extend(to spot: SIMD2<Double>) {
        guard !straight, var last = points.last else { return }
        let step = MeadowCatalog.fencePostSpacing
        while simd_distance(last, spot) >= step {
            last += simd_normalize(spot - last) * step
            points.append(last)
        }
    }

    /// The draft as it would be laid with its end at `spot`: its points, and `spot` when it is far enough on from
    /// the last to make a span of its own.
    public func points(endingAt spot: SIMD2<Double>) -> [SIMD2<Double>] {
        let laid = straight ? [points[0]] : points
        guard let last = laid.last else { return [spot] }
        return simd_distance(last, spot) >= MeadowEditSession.shortestSpan ? laid + [spot] : laid
    }
}

/// A run ready to be laid: the fence as it will stand, and the runs its ends join (taken into it), by id.
public struct MeadowFenceLaying: Equatable, Sendable {
    public var item: MeadowFile.MeadowItem
    public var joined: [Int]
}

extension MeadowEditSession {
    /// The fence's id, laid in runs along a drag.
    public static let fence = "garden.fence"
    /// How near another fence's end a run's end joins it, in units.
    public static let fenceJoin = 0.8
    /// The shortest span a drawn fence ends with.
    public static let shortestSpan = 0.6
    /// The narrowest span a gate is hung in (a narrower one is no way through).
    public static let narrowestGate = 1.6

    // MARK: Laying a run

    /// A short run placed with a click (or the keys, or a tile let go): two spans, along `turn`, round `spot`.
    public static func shortFence(at spot: SIMD2<Double>, turn: Double) -> [SIMD2<Double>] {
        let along = SIMD2(cos(turn), -sin(turn)) * MeadowCatalog.fencePostSpacing
        return [spot - along, spot, spot + along]
    }

    /// The run `points` would lay, its ends joined to any fence's end within `fenceJoin` (taking that fence into
    /// it, so a corner is one post), closed on itself when it ends at its own start, its points at most what a
    /// run may hold. Nil when it is not long enough to be a fence. A join that would give the run two gates, or more
    /// points than a run holds, is not made.
    public func fenceLaying(_ points: [SIMD2<Double>]) -> MeadowFenceLaying? {
        var run = points.map { MeadowPoint($0.x, $0.y) }
        guard run.count >= 2 else { return nil }
        var gate = 0
        var joined: [Int] = []
        let others = shown.compactMap { id -> (id: Int, points: [MeadowPoint], gate: Int)? in
            guard let item = item(id), item.asset == Self.fence, case .run(let p) = item.placement, p.count >= 2, p.first != p.last else { return nil }
            if case .integer(let g) = item.value(of: "gate", catalog) { return (id, p, g) }
            return (id, p, 0)
        }
        func near(_ a: MeadowPoint, _ b: MeadowPoint) -> Bool { hypot(a.x - b.x, a.z - b.z) <= Self.fenceJoin }
        /// The fence whose end is nearest `spot`, within reach, with its points ordered to end there.
        func join(_ spot: MeadowPoint) -> (id: Int, points: [MeadowPoint], gate: Int)? {
            var best: (id: Int, points: [MeadowPoint], gate: Int, apart: Double)?
            for other in others where !joined.contains(other.id) {
                for (end, reversed) in [(other.points.last!, false), (other.points.first!, true)] where near(end, spot) {
                    let apart = hypot(end.x - spot.x, end.z - spot.z)
                    guard apart < (best?.apart ?? .infinity) else { continue }
                    let segments = other.points.count - 1
                    best = (other.id, reversed ? other.points.reversed() : other.points, reversed && other.gate > 0 ? segments - other.gate + 1 : other.gate, apart)
                }
            }
            return best.map { ($0.id, $0.points, $0.gate) }
        }
        // At its start: the other run first, ending where this begins.
        if let other = join(run[0]), other.points.count + run.count - 1 <= MeadowFormat.runPoints.upperBound {
            run = other.points + run.dropFirst()
            gate = other.gate
            joined.append(other.id)
        }
        // At its end: closing on itself, or the other run after it.
        if run.count >= 4, near(run[run.count - 1], run[0]) {
            run[run.count - 1] = run[0]
        } else if let other = join(run[run.count - 1]), !(gate > 0 && other.gate > 0), run.count + other.points.count - 1 <= MeadowFormat.runPoints.upperBound {
            let before = run.count - 1
            run = Array(run.dropLast()) + other.points.reversed()
            if other.gate > 0 { gate = before + (other.points.count - other.gate) }
            joined.append(other.id)
        }
        run = Self.tidied(run, gate: &gate)
        guard run.count >= 2, zip(run, run.dropFirst()).contains(where: { hypot($1.x - $0.x, $1.z - $0.z) > 1e-3 }) else { return nil }
        var fence = MeadowFile.MeadowItem(asset: Self.fence, placement: Self.quantized(.run(run)))
        if gate > 0 { fence.params["gate"] = .number(Double(gate)) }
        return MeadowFenceLaying(item: fence, joined: joined)
    }

    /// A run's points with none twice in a row, and no more than a run holds: where there are too many, the points
    /// that bend it least are let go (a post still stands each 2.5 units between those kept), never the gate's.
    static func tidied(_ points: [MeadowPoint], gate: inout Int) -> [MeadowPoint] {
        var run: [MeadowPoint] = []
        var dropped = 0
        for (k, p) in points.enumerated() {
            if let last = run.last, hypot(p.x - last.x, p.z - last.z) < 0.05 {
                // Segment k (between points k − 1 and k) is gone: a gate past it moves down, one in it goes.
                if gate == k - dropped { gate = 0 } else if gate > k - dropped { gate -= 1 }
                dropped += 1
                continue
            }
            run.append(p)
        }
        while run.count > MeadowFormat.runPoints.upperBound {
            var least: (index: Int, bend: Double)?
            for i in 1..<(run.count - 1) where gate == 0 || (i != gate - 1 && i != gate) {
                let a = run[i - 1], b = run[i], c = run[i + 1]
                let bend = abs((b.x - a.x) * (c.z - a.z) - (b.z - a.z) * (c.x - a.x))
                if bend < (least?.bend ?? .infinity) { least = (i, bend) }
            }
            guard let i = least?.index else { break }
            run.remove(at: i)
            if gate > i { gate -= 1 }
        }
        return run
    }

    /// The runs a laying takes in, as they stand in the scenery.
    private func joinedIndices(_ laying: MeadowFenceLaying) -> Set<Int> { Set(laying.joined.compactMap(thingIndex(of:))) }

    /// Why `laying` may not be laid (nil: it may): the meadow's fence posts or things in all (the runs it joins
    /// counted out), or a rule of where things stand (judged against everything but the runs it joins).
    public func fenceRefusal(_ laying: MeadowFenceLaying) -> MeadowEditRefusal? {
        if document.entries.count - laying.joined.count + 1 > MeadowFormat.maxItems { return .full(nil, limit: MeadowFormat.maxItems) }
        let joined = laying.joined.compactMap { item($0) }
        let posts = (document.counts(catalog)[.fencePosts] ?? 0) - MeadowDocument(entries: joined.map { .item($0) }).counts(catalog)[.fencePosts, default: 0]
            + MeadowDocument(entries: [.item(laying.item)]).counts(catalog)[.fencePosts, default: 0]
        if posts > MeadowCatalog.Cap.fencePosts.limit { return .full(.fencePosts, limit: MeadowCatalog.Cap.fencePosts.limit) }
        guard let thing = thing(laying.item) else { return nil }
        return SceneryRules.Field(scenery, leavingOut: joinedIndices(laying)).refusal(for: thing).map(said)
    }

    /// The scenery as it would be with `laying` laid (the runs it joins left out of it): what a run being drawn is
    /// shown against.
    public func scenery(laying: MeadowFenceLaying) -> MeadowScenery {
        var shown = scenery
        let leaving = joinedIndices(laying)
        shown.things = shown.things.enumerated().filter { !leaving.contains($0.offset) }.map(\.element)
        return shown
    }

    /// Lays `laying` as one change: the runs it joins taken away, the run added at the end of the meadow.
    public mutating func layFence(_ laying: MeadowFenceLaying) -> Result<MeadowChange, MeadowEditRefused> {
        if let refusal = fenceRefusal(laying) { return .failure(MeadowEditRefused(refusal)) }
        let joined = Set(laying.joined)
        let removed = document.entries.indices.filter { joined.contains(ids[$0]) }.map { MeadowChange.Placed(position: $0, id: ids[$0], entry: document.entries[$0]) }
        let change = MeadowChange(removed: removed, added: [MeadowChange.Placed(position: document.entries.count - removed.count, id: nextID, entry: .item(laying.item))])
        apply(change)
        return .success(change)
    }

    // MARK: A run's shape and its gate

    /// A fence run by id: its points and its gate (0: none).
    public func fenceRun(_ id: Int) -> (points: [MeadowPoint], gate: Int)? {
        guard let item = item(id), item.asset == Self.fence, case .run(let points) = item.placement else { return nil }
        if case .integer(let gate) = item.value(of: "gate", catalog), gate < points.count { return (points, gate) }
        return (points, 0)
    }

    /// Whether a run bends, so Straighten would change it (a run closed on itself has no straight form).
    public func canStraighten(_ id: Int) -> Bool {
        guard let run = fenceRun(id), run.points.count > 2, run.points.first != run.points.last else { return false }
        let a = run.points[0], b = run.points[run.points.count - 1], length = hypot(b.x - a.x, b.z - a.z)
        guard length > 1e-3 else { return false }
        // Off the line from end to end by more than a hair anywhere.
        return run.points.contains { p in abs((b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x)) / length > 0.05 }
    }

    /// Straight from its first point to its last; a gate it had kept where along it the gate was.
    public mutating func straighten(_ id: Int) -> Result<MeadowChange, MeadowEditRefused> {
        guard canStraighten(id), let run = fenceRun(id) else { return .success(MeadowChange()) }
        let at = run.gate > 0 ? Self.gateMiddle(run.points, gate: run.gate) : nil
        var straight = [run.points[0], run.points[run.points.count - 1]]
        var gate = 0
        if let at { (straight, gate) = Self.hangingGate(straight, near: at) }
        return edit([id]) { item, _ in
            item.placement = .run(straight)
            item.params["gate"] = gate > 0 ? .number(Double(gate)) : nil
        }
    }

    /// Hangs a gate in the run's span nearest its middle along it that is wide enough for one, or takes its gate
    /// away; the run's posts stay where they stood.
    public mutating func toggleGate(_ id: Int) -> Result<MeadowChange, MeadowEditRefused> {
        guard let run = fenceRun(id) else { return .success(MeadowChange()) }
        if run.gate > 0 {
            return edit([id]) { item, _ in item.params["gate"] = nil }
        }
        let (points, gate) = Self.hangingGate(run.points, near: Self.length(run.points) / 2)
        guard gate > 0 else { return .failure(MeadowEditRefused(.noRoom, id: id)) }
        return edit([id]) { item, _ in
            item.placement = .run(points)
            item.params["gate"] = .number(Double(gate))
        }
    }

    /// Whether a run has a span wide enough for a gate (or has one to take away).
    public func canToggleGate(_ id: Int) -> Bool {
        guard let run = fenceRun(id) else { return false }
        return run.gate > 0 || Self.hangingGate(run.points, near: 0).gate > 0
    }

    static func length(_ points: [MeadowPoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.z - $1.0.z) }
    }

    /// How far along a run its gate's middle is.
    static func gateMiddle(_ points: [MeadowPoint], gate: Int) -> Double {
        let before = length(Array(points.prefix(gate)))
        let a = points[gate - 1], b = points[gate]
        return before + hypot(b.x - a.x, b.z - a.z) / 2
    }

    /// `points` with a gate hung in the span (between posts, as the scene stands them) whose middle is nearest
    /// `along` the run and that is at least `narrowestGate` wide: that span made a segment of its own (points put at
    /// its two posts, which stood there already), and the gate's segment number. No such span: as they were, 0.
    static func hangingGate(_ points: [MeadowPoint], near along: Double) -> (points: [MeadowPoint], gate: Int) {
        var best: (segment: Int, k: Int, n: Int, apart: Double)?
        var walked = 0.0
        for s in 1..<points.count {
            let a = points[s - 1], b = points[s], length = hypot(b.x - a.x, b.z - a.z)
            let n = max(1, Int((length / MeadowCatalog.fencePostSpacing - 1e-4).rounded(.up)))
            for k in 0..<n where length / Double(n) >= narrowestGate {
                let apart = abs(walked + length * (Double(k) + 0.5) / Double(n) - along)
                if apart < (best?.apart ?? .infinity) { best = (s, k, n, apart) }
            }
            walked += length
        }
        guard let best else { return (points, 0) }
        let a = points[best.segment - 1], b = points[best.segment]
        func post(_ k: Int) -> MeadowPoint { MeadowPoint(a.x + (b.x - a.x) * Double(k) / Double(best.n), a.z + (b.z - a.z) * Double(k) / Double(best.n)) }
        var inside: [MeadowPoint] = []
        if best.k > 0 { inside.append(post(best.k)) }
        if best.k + 1 < best.n { inside.append(post(best.k + 1)) }
        let split = Array(points.prefix(best.segment)) + inside + Array(points.dropFirst(best.segment))
        let gate = best.segment + (best.k > 0 ? 1 : 0)
        guard split.count <= MeadowFormat.runPoints.upperBound else { return (points, 0) }
        return (split.map { MeadowPoint(MeadowJSON.quantized($0.x), MeadowJSON.quantized($0.z)) }, gate)
    }

    // MARK: Colours

    /// The colour a thing wears from its palette (its own, the first, when it names none this Whiskr has); nil for
    /// a thing with no palette.
    public func colour(of id: Int) -> String? {
        guard let item = item(id), case .choice(let name) = item.value(of: "colour", catalog) else { return nil }
        return name
    }

    /// The colours things of `asset` may wear, their own first; empty for a kind with no palette.
    public func palette(of asset: String) -> [String] {
        guard case .choice(let choices) = catalog.asset(asset)?.parameter("colour")?.kind else { return [] }
        return choices.map(\.name)
    }

    /// `ids` (those whose palette holds it) in the colour `name`; their own colour is written as none, as it was.
    public mutating func recolour(_ ids: Set<Int>, to name: String) -> Result<MeadowChange, MeadowEditRefused> {
        var own: [Int: Bool] = [:]
        for id in ids {
            guard let item = item(id) else { continue }
            let palette = palette(of: item.asset)
            if palette.contains(name) { own[id] = palette.first == name }
        }
        return edit(Set(own.keys)) { item, id in
            item.params["colour"] = own[id] == true ? nil : .string(name)
        }
    }
}
