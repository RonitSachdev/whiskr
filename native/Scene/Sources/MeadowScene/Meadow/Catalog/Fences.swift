import Foundation
import simd

// The meadow editor's wooden fence (docs/DESIGN.md, "Fence runs"): a post-and-rail fence as cottage gardens and
// field edges have them, made cat-sized. Square posts with weathered (sloped) tops stand at each point of the run
// and evenly between, at most `spacing` apart; each span between two posts carries two rails mortised through them,
// following the land from post to post; one span may hold a gate, a ledged and braced gate whose brace rises from the
// hinge's foot to the latch's top (a strut, as real ones are braced), hung on stouter posts with ball caps. Each part
// is one shape drawn instanced, so a meadow of six hundred posts holds four small meshes.

enum Fences {
    /// Between posts at most, in units (the catalog's `fencePostSpacing`).
    static let spacing: Float = 2.5
    /// How tall a post stands, and where its two rails run (their middles), in units: a fence a cat can sit on.
    static let tall: Float = 2.25
    static let railHeights: (low: Float, high: Float) = (0.82, 1.68)

    private static func v(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { Vec3(x, y, z) }

    /// The parts, by `ShapeKey.variant`: a post, a span's two rails, a gate's leaf, a gate post's ball cap.
    enum Part: Int, CaseIterable { case post, rails, gate, cap }

    /// One post: where it stands and which way its faces look (along the run).
    struct Post { var at: Vec2; var along: Vec2; var gatePost: Bool }
    /// One span between two posts (by index), and whether it is the gate.
    struct Span { var from: Int; var to: Int; var gate: Bool }

    /// Whether a run closes on itself: its last point on its first.
    static func closed(_ points: [Vec2]) -> Bool {
        points.count > 2 && simd_distance(points[0], points[points.count - 1]) < 1e-3
    }

    /// The posts and spans of a run along `points` with a gate in segment `gate` (1-based, between points; 0 none).
    /// Each segment is cut into equal spans no longer than `spacing`; a gate in a segment of several spans takes the
    /// middle one.
    static func layout(_ points: [Vec2], gate: Int = 0) -> (posts: [Post], spans: [Span]) {
        guard points.count >= 2 else { return (points.map { Post(at: $0, along: Vec2(1, 0), gatePost: false) }, []) }
        let closes = closed(points)
        var at: [Vec2] = [], spans: [Span] = []
        for s in 1..<points.count {
            let a = points[s - 1], b = points[s], length = simd_distance(a, b)
            let n = max(1, Int((length / spacing - 1e-4).rounded(.up)))
            let gateSpan = s == gate ? n / 2 : -1
            for k in 0..<n {
                at.append(a + (b - a) * (Float(k) / Float(n)))
                spans.append(Span(from: at.count - 1, to: at.count, gate: k == gateSpan))
            }
        }
        if closes { spans[spans.count - 1].to = 0 } else { at.append(points[points.count - 1]) }
        var posts = at.map { Post(at: $0, along: Vec2(1, 0), gatePost: false) }
        // Each post faces along the run, a corner post halfway between its two spans.
        for i in posts.indices {
            var along = Vec2.zero
            for span in spans where span.from == i || span.to == i {
                let d = posts[span.to].at - posts[span.from].at
                if simd_length(d) > 1e-5 { along += simd_normalize(d) }
            }
            posts[i].along = simd_length(along) > 1e-5 ? simd_normalize(along) : (spans.first.map { simd_normalize(posts[$0.to].at - posts[$0.from].at + Vec2(1e-6, 0)) } ?? Vec2(1, 0))
        }
        for span in spans where span.gate {
            posts[span.from].gatePost = true
            posts[span.to].gatePost = true
        }
        return (posts, spans)
    }

    /// The posts a run stands on.
    static func posts(along points: [Vec2]) -> [Post] { layout(points).posts }

    /// Where a run's span runs, on the land (from post to post).
    static func ends(_ span: Span, _ posts: [Post]) -> (Vec3, Vec3) {
        let a = posts[span.from].at, b = posts[span.to].at
        return (v(a.x, Land.height(a.x, a.y), a.y), v(b.x, Land.height(b.x, b.y), b.y))
    }

    /// Every part of a run as it stands on the land: which part, and where it is drawn.
    static func parts(_ points: [Vec2], gate: Int) -> [(part: Part, matrix: Mat4)] {
        let (posts, spans) = layout(points, gate: gate)
        var parts: [(Part, Mat4)] = []
        parts.reserveCapacity(posts.count + spans.count + 2)
        for post in posts {
            let base = v(post.at.x, Land.height(post.at.x, post.at.y), post.at.y)
            let turn = atan2(-post.along.y, post.along.x)
            // A gate's posts are the stouter, as they carry it.
            let stout: Vec3 = post.gatePost ? v(1.3, 1.05, 1.3) : v(1, 1, 1)
            parts.append((.post, .compose(base, euler: v(0, turn, 0), scale: stout)))
            if post.gatePost { parts.append((.cap, .compose(base + v(0, tall * 1.05, 0), euler: v(0, turn, 0)))) }
        }
        for span in spans {
            let (a, b) = ends(span, posts)
            let d = b - a, across = hypot(d.x, d.z)
            guard across > 1e-4 else { continue }
            let turn = atan2(-d.z, d.x), rise = atan2(d.y, across)
            // Shaped `spacing` long along x from 0; drawn as long as the span, leaning with the land.
            let m = Mat4.compose(a, euler: v(0, turn, 0)) * .rotationZ(rise) * .scale(v(simd_length(d) / spacing, 1, 1))
            parts.append((span.gate ? .gate : .rails, m))
        }
        return parts
    }

    /// The whole run as one shape, standing on the land (the editor's ghost of a run being laid, and the tray's
    /// picture).
    static func joined(_ points: [Vec2], gate: Int) -> Geometry {
        Geometry.join(parts(points, gate: gate).map { shapes[$0.part.rawValue].shape.applied($0.matrix) })
    }

    /// A short run for the tray's picture: two spans, the second a gate.
    static let pictured: (points: [Vec2], gate: Int) = ([Vec2(-2.5, 0), Vec2(0, 0), Vec2(2.5, 0)], 2)

    // MARK: The parts' shapes

    /// Weathered oak: silvering grey-brown, darker and damp at its foot, paler where the sun bleaches its top.
    static let wood: (foot: UInt32, body: UInt32, top: UInt32) = (0x6c5a48, 0x8f7a62, 0xb4a48c)

    static let shapes: [Plant] = [post, rails, gate, cap]

    /// A square post, its top cut to a low pyramid to shed rain, its corners softened, sunk a little in the turf.
    static let post: Plant = {
        let half: Float = 0.18
        let rings = [Clay.Ring(w: half, d: half, y: -0.12), Clay.Ring(w: half, d: half, y: 0.25), Clay.Ring(w: half, d: half, y: tall - 0.1),
                     Clay.Ring(w: half * 0.86, d: half * 0.86, y: tall), Clay.Ring(w: half * 0.25, d: half * 0.25, y: tall + 0.08)]
        var g = Clay.stacked(rings, around: 16, square: 6) { _, _ in 0 }
        g.colors = g.positions.map { p in
            let grain = 1 + 0.05 * sin(p.x * 31 + p.z * 17)
            let body = p.y < 0.35 ? mix(linear(wood.foot), linear(wood.body), t: smoothstep(p.y, -0.1, 0.35)) : mix(linear(wood.body), linear(wood.top), t: smoothstep(p.y, 0.35, tall))
            return body * grain
        }
        return Plant(shape: g.roughened(0.95), top: v(0, tall, 0))
    }()

    /// A span's two rails, `spacing` long from x = 0, each a sawn rail laid on edge.
    static let rails: Plant = {
        let parts = [railHeights.low, railHeights.high].map { y -> Geometry in
            var rail = Shapes.roundedBox(spacing, 0.26, 0.15, segments: 1, radius: 0.06)
            rail.translate(spacing / 2, y, 0)
            rail.colors = rail.positions.map { p in mix(linear(wood.body), linear(wood.top), t: smoothstep(p.y - y, -0.13, 0.13)) * (1 + 0.04 * sin(p.x * 5.3)) }
            return rail
        }
        return Plant(shape: Geometry.join(parts).roughened(0.95), top: v(spacing / 2, railHeights.high, 0))
    }()

    /// A gate's leaf, `spacing` wide from its hinge (x = 0) to its latch, as cottage garden gates are made: two stiles,
    /// a top and a bottom ledge, the brace behind rising from the hinge's foot to the latch's top, and close-set
    /// palings with rounded tops over them, painted cream so the way through reads at once among the weathered rails;
    /// two black iron strap hinges and a ring latch.
    static let gate: Plant = {
        let fresh: (UInt32, UInt32) = (0xd9cdb6, 0xf4eee2), iron: (UInt32, UInt32) = (0x2f2e2c, 0x4a4844)
        let gap: Float = 0.24, low: Float = 0.26, high: Float = 1.86
        var parts: [Geometry] = []
        func bar(_ from: Vec2, _ to: Vec2, _ thick: Float, _ deep: Float, _ colour: (UInt32, UInt32) = fresh) {
            let d = to - from, length = simd_length(d)
            var g = Shapes.roundedBox(length, thick, deep, segments: 1, radius: min(thick, deep) * 0.4)
            g.apply(.compose(v((from.x + to.x) / 2, (from.y + to.y) / 2, 0), euler: v(0, 0, atan2(d.y, d.x))))
            g.paint(colour.0, colour.1)
            parts.append(g)
        }
        let hinge = gap, latch = spacing - gap
        bar(Vec2(hinge, low - 0.1), Vec2(hinge, high + 0.12), 0.2, 0.14)
        bar(Vec2(latch, low - 0.1), Vec2(latch, high + 0.12), 0.18, 0.14)
        for y in [low + 0.08, high - 0.2] {
            var ledge = Shapes.roundedBox(latch - hinge, 0.2, 0.1, segments: 1, radius: 0.04)
            ledge.translate(spacing / 2, y, -0.06)
            parts.append(ledge.painted(fresh.0, fresh.1))
        }
        var brace = Shapes.roundedBox(hypot(latch - hinge - 0.3, high - low - 0.5), 0.17, 0.08, segments: 1, radius: 0.035)
        brace.apply(.compose(v(spacing / 2, (low + high) / 2 - 0.06, -0.06), euler: v(0, 0, atan2(high - low - 0.5, latch - hinge - 0.3))))
        parts.append(brace.painted(fresh.0, fresh.1).tinted(0.92))
        // The palings, on the face, their tops rounded and a little proud of the stiles' line.
        let count = 6
        for k in 0..<count {
            let x = hinge + 0.2 + (latch - hinge - 0.4) * Float(k) / Float(count - 1)
            var paling = Shapes.roundedBox(0.19, high - low + 0.12, 0.06, segments: 1, radius: 0.09)
            paling.translate(x, (low + high) / 2 + 0.06, 0.04)
            parts.append(paling.painted(fresh.0, fresh.1))
        }
        // Strap hinges on the face, from the hinge post along the top and bottom ledges.
        for y in [low + 0.08, high - 0.2] {
            var strap = Shapes.roundedBox(0.75, 0.07, 0.03, segments: 1, radius: 0.012)
            strap.translate(0.32, y, 0.09)
            parts.append(strap.painted(iron.0, iron.1))
            parts.append(Clay.blob(at: v(0.04, y, 0.0), size: v(0.06, 0.1, 0.06), color: iron.0, top: iron.1))
        }
        parts.append(Shapes.torus(0.08, 0.022, 6, 14).applied(.compose(v(latch - 0.1, high - 0.32, 0.1), euler: v(0, 0, 0))).painted(iron.0, iron.1))
        parts.append(Clay.blob(at: v(latch - 0.1, high - 0.24, 0.08), size: v(0.035, 0.035, 0.035), color: iron.0, top: iron.1))
        return Plant(shape: Geometry.join(parts).roughened(0.9), top: v(spacing / 2, high, 0))
    }()

    /// A gate post's cap: a turned ball on a neck, as gate posts are finished.
    static let cap: Plant = {
        let profile = [Vec2(0, 0), Vec2(0.16, 0), Vec2(0.17, 0.04), Vec2(0.08, 0.08), Vec2(0.07, 0.12), Vec2(0.13, 0.2), Vec2(0.15, 0.29), Vec2(0.11, 0.38), Vec2(0, 0.41)]
        return Plant(shape: Clay.thrown(profile, wood.body, wood.top, around: 14, steps: 14).roughened(0.9), top: v(0, 0.41, 0))
    }()
}

/// The lines the meadow's fences draw across its ground (x, z), for whatever leads a cat about: the spans it cannot
/// pass and the gates it can (`Meadow.crossesFence`, the cats' routes, `Roam.swift`). Each run keeps its bounds, so a
/// way far from a fence is passed over at once. Made when the scenery is laid; asked of without allocating.
struct FenceLines {
    struct Line {
        var a: Vec2
        var b: Vec2
        /// Its middle, and the way across it (a unit vector, either way).
        var middle: Vec2 { (a + b) / 2 }
        var across: Vec2 { let d = simd_normalize(b - a); return Vec2(-d.y, d.x) }
    }

    /// One run's lines: every span but the gate's, and the gate's (if it has one), within their bounds.
    struct Run {
        var barriers: [Line]
        var gate: Line?
        var low: Vec2
        var high: Vec2

        init(_ posts: [Fences.Post], _ spans: [Fences.Span]) {
            barriers = spans.filter { !$0.gate }.map { Line(a: posts[$0.from].at, b: posts[$0.to].at) }
            gate = spans.first(where: \.gate).map { Line(a: posts[$0.from].at, b: posts[$0.to].at) }
            low = posts.map(\.at).reduce(Vec2(repeating: .infinity)) { simd_min($0, $1) }
            high = posts.map(\.at).reduce(Vec2(repeating: -.infinity)) { simd_max($0, $1) }
        }
    }

    private(set) var runs: [Run] = []

    init(_ runs: [Run] = []) { self.runs = runs }

    var isEmpty: Bool { runs.isEmpty }

    /// Whether going straight from `p` to `q` crosses any span but a gate's (of those `standing` says stand: a
    /// fence makes way for a blanket come near, as every rooted thing does).
    func crosses(_ p: Vec2, _ q: Vec2, standing: (Line) -> Bool = { _ in true }) -> Bool {
        let low = simd_min(p, q), high = simd_max(p, q)
        for run in runs where Self.overlaps(run, low, high) {
            for line in run.barriers where Self.cut(p, q, line) != nil && standing(line) { return true }
        }
        return false
    }

    /// Whether any fence reaches into the square `half` each way round `middle`.
    func near(_ middle: Vec2, half: Float) -> Bool {
        runs.contains { Self.overlaps($0, middle - Vec2(repeating: half), middle + Vec2(repeating: half)) }
    }

    /// The first fence line (a span or a gate, of those standing) going straight from `p` to `q` crosses, nearest
    /// `p`: the line, where it is crossed, and whether it is a gate.
    func firstCrossing(_ p: Vec2, _ q: Vec2, standing: (Line) -> Bool = { _ in true }) -> (line: Line, at: Vec2, gate: Bool)? {
        let low = simd_min(p, q), high = simd_max(p, q)
        var best: (line: Line, at: Vec2, gate: Bool, t: Float)?
        for run in runs where Self.overlaps(run, low, high) {
            for line in run.barriers {
                if let t = Self.cut(p, q, line), t < best?.t ?? .infinity, standing(line) { best = (line, p + (q - p) * t, false, t) }
            }
            if let line = run.gate, let t = Self.cut(p, q, line), t < best?.t ?? .infinity, standing(line) { best = (line, p + (q - p) * t, true, t) }
        }
        return best.map { ($0.line, $0.at, $0.gate) }
    }

    /// Every gate within a square `half` each way round `middle`.
    func gates(near middle: Vec2, half: Float, _ body: (Line) -> Void) {
        let low = middle - Vec2(repeating: half), high = middle + Vec2(repeating: half)
        for run in runs where Self.overlaps(run, low, high) { if let gate = run.gate { body(gate) } }
    }

    private static func overlaps(_ run: Run, _ low: Vec2, _ high: Vec2) -> Bool {
        run.low.x <= high.x && run.high.x >= low.x && run.low.y <= high.y && run.high.y >= low.y
    }

    /// Where along `p`→`q` (0…1) it cuts `line`, nil when it does not.
    private static func cut(_ p: Vec2, _ q: Vec2, _ line: Line) -> Float? {
        func cross(_ u: Vec2, _ v: Vec2) -> Float { u.x * v.y - u.y * v.x }
        let r = q - p, s = line.b - line.a, d = cross(r, s)
        guard abs(d) > 1e-9 else { return nil }
        let t = cross(line.a - p, s) / d, u = cross(line.a - p, r) / d
        return t >= 0 && t <= 1 && u >= 0 && u <= 1 ? t : nil
    }
}
