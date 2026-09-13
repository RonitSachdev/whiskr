import Foundation
import simd

// A git worktree's blanket belongs to its repository's: it is laid beside it, and a little path of flat
// clay stepping stones, set in a strip of trodden grass, runs from the one to the other. In a sidebar's
// column it reads like a nested row in a list: the path leaves the repository's cloth, runs down beside
// the worktree (clear of its flag) and turns in to it; two worktrees share the same path, each turning in.
// Everywhere else it is a short, gently bowed path between the two cloths' nearest edges. The stones are
// worked out every frame from where the blankets are now (they ease into place), into lists kept from frame
// to frame, so a frame allocates nothing.

let MAX_STONES = 160
/// Strips of trodden grass under the stones, for the shaders (`World.paths`).
let MAX_TRODDEN = 32
/// Stones are this far apart along a path, from middle to middle.
private let STONE_STEP: Float = 1.3
/// The grass between a path's end and the cloth it leads onto.
private let TRAIL_HEM: Float = 0.35
/// How far beside a worktree's cloth (and its flag) a column's path runs.
private let TRAIL_ASIDE: Float = 2.4
/// The radius of a path's bends.
private let TRAIL_BEND: Float = 1.6

/// A stepping stone's own small variety: how far it sits off the line, its size and its turn, drawn once
/// per blanket from its name.
struct Pebbles {
    static let count = 24
    var values: [Vec3]
    init(_ name: String) {
        var random = chance(name + "/stones")
        values = (0..<Self.count).map { _ in Vec3(random.float() - 0.5, random.float(), random.float() * .pi * 2) }
    }
}

extension Village {
    /// Every joined blanket's path, as it lies this frame.
    func layTrails(_ stage: Stage) {
        stoneCount = 0
        troddenCount = 0
        // In a column, a repository's second worktree carries on down the first one's path.
        var branch: (home: Plot, at: Vec2)?
        for plot in plots {
            plot.trailEnds = nil
            guard let id = plot.view.joinedTo, id != plot.view.id, let home = self.plot(id), home !== plot, plot.blanketSize > 0.5, home.blanketSize > 0.5 else {
                branch = nil
                continue
            }
            trailCorners.removeAll(keepingCapacity: true)
            if arrangement == .column && perRow == 1, abs(plot.middle.x - home.middle.x) > 0.3 {
                route(alongside: plot, from: home, after: branch?.home === home ? branch?.at : nil)
                if trailCorners.count >= 3 { branch = (home, trailCorners[trailCorners.count - 2]) }
            } else {
                route(between: home, and: plot)
            }
            guard trailCorners.count >= 2 else { continue }
            plot.trailEnds = (trailCorners[0], trailCorners[trailCorners.count - 1])
            bend()
            lay(plot)
        }
    }

    // MARK: routes

    /// The column's path: off the front of the repository's cloth on the worktree's inner side, down
    /// beside the worktree, clear of its cloth and of its flag (which stands behind it), and in to it.
    private func route(alongside plot: Plot, from home: Plot, after junction: Vec2?) {
        let side: Float = plot.middle.x > home.middle.x ? 1 : -1
        let inner = Vec2(-side, 0)
        let flagHalf = plot.flagHeight * plot.label.aspect / 2
        // Clear of the cloth however it is turned (its corners reach furthest), and of its flag.
        let reach = max(plot.blanketSize * Picnic.corner * 0.92, flagHalf + 0.15)
        let into = Vec2(plot.middle.x, plot.middle.z) + inner * (edge(plot, inner) + TRAIL_HEM)
        if let junction {
            // On from where the path turned in to the worktree before.
            trailCorners.append(junction)
            trailCorners.append(Vec2(junction.x, into.y))
            trailCorners.append(into)
            return
        }
        let lane = plot.middle.x - side * (reach + TRAIL_ASIDE)
        // Leaves the repository's cloth from its front edge, as near the lane as the cloth allows.
        let front = edge(home, Vec2(0, 1))
        let leaveX = clamp(lane, home.middle.x - front * 0.7, home.middle.x + front * 0.7)
        var out = Vec2(leaveX - home.middle.x, front)
        out = simd_normalize(out)
        let start = Vec2(home.middle.x, home.middle.z) + out * (edge(home, out) + TRAIL_HEM)
        trailCorners.append(start)
        trailCorners.append(Vec2(lane, start.y + TRAIL_BEND))
        trailCorners.append(Vec2(lane, into.y))
        trailCorners.append(into)
    }

    /// A short path between the two cloths' nearest edges, bowed a little so it reads as trodden, not ruled.
    /// In rows, a worktree further along its repository's row than the next blanket is reached by a path
    /// along the grass in front of the row, so it never seems to lead from the blanket in between.
    private func route(between home: Plot, and plot: Plot) {
        var across = Vec2(plot.middle.x - home.middle.x, plot.middle.z - home.middle.z)
        guard simd_length(across) > 1e-3 else { return }
        across = simd_normalize(across)
        let start = Vec2(home.middle.x, home.middle.z) + across * (edge(home, across) + TRAIL_HEM)
        let end = Vec2(plot.middle.x, plot.middle.z) - across * (edge(plot, -across) + TRAIL_HEM)
        let length = simd_distance(start, end)
        guard length > 0.2 else { return }
        if arrangement == .column, abs(plot.middle.z - home.middle.z) < home.blanketSize * 0.6, crossesCloth(start, end, besides: home, plot) {
            return route(inFront: home, plot)
        }
        let bow = Vec2(-across.y, across.x) * length * (plot.pebbles.values[0].x * 0.3)
        trailCorners.append(start)
        trailCorners.append((start + end) / 2 + bow)
        trailCorners.append(end)
    }

    /// Off the front of the repository's cloth, along the grass in front of the row, and in at the front
    /// of the worktree's.
    private func route(inFront home: Plot, _ plot: Plot) {
        let side: Float = plot.middle.x > home.middle.x ? 1 : -1
        var front: Float = -.infinity
        let low = min(home.middle.x, plot.middle.x), high = max(home.middle.x, plot.middle.x)
        for other in plots where other.middle.x >= low - 0.1 && other.middle.x <= high + 0.1 && abs(other.middle.z - home.middle.z) < home.blanketSize {
            front = max(front, other.middle.z + edge(other, Vec2(0, 1)))
        }
        let out = simd_normalize(Vec2(side * 0.45, 1)), into = simd_normalize(Vec2(-side * 0.45, 1))
        let start = Vec2(home.middle.x, home.middle.z) + out * (edge(home, out) + TRAIL_HEM)
        let end = Vec2(plot.middle.x, plot.middle.z) + into * (edge(plot, into) + TRAIL_HEM)
        let row = front + TRAIL_ASIDE * 0.5
        trailCorners.append(start)
        trailCorners.append(Vec2(start.x, row))
        trailCorners.append(Vec2(end.x, row))
        trailCorners.append(end)
    }

    /// Whether a straight path would cross another blanket's cloth.
    private func crossesCloth(_ a: Vec2, _ b: Vec2, besides home: Plot, _ plot: Plot) -> Bool {
        let steps = max(2, Int(simd_distance(a, b) / 0.5))
        for k in 0...steps {
            let p = a + (b - a) * (Float(k) / Float(steps))
            for other in plots where other !== home && other !== plot {
                var d = Vec2(p.x - other.middle.x, p.y - other.middle.z)
                let length = simd_length(d)
                if length < 1e-4 { return true }
                d /= length
                if length < edge(other, d) { return true }
            }
        }
        return false
    }

    /// How far a blanket's cloth reaches from its middle in a direction on the ground (a unit vector,
    /// x and z): its squircle outline, turned as the cloth lies.
    func edge(_ plot: Plot, _ direction: Vec2) -> Float {
        let c = cos(-plot.turn), s = sin(-plot.turn)
        let x = abs(direction.x * c - direction.y * s), z = abs(direction.x * s + direction.y * c)
        return plot.blanketSize / max(pow(pow(x, 4.5) + pow(z, 4.5), 1 / 4.5), 1e-3)
    }

    /// Whether a spot on the ground is on any blanket's cloth (with a little to spare) or under a column's
    /// flag, where no stone may lie.
    private func covered(_ p: Vec2, by reach: Float) -> Bool {
        for plot in plots {
            var d = Vec2(p.x - plot.middle.x, p.y - plot.middle.z)
            let length = simd_length(d)
            if length < 1e-4 { return true }
            d /= length
            if length < edge(plot, d) + reach { return true }
            if arrangement == .column {
                let half = plot.flagHeight * plot.label.aspect / 2 + reach
                if abs(p.x - plot.flagAt.x) < half && abs(p.y - plot.flagAt.z) < 0.4 + reach { return true }
            }
        }
        return false
    }

    // MARK: laying

    /// Rounds the corners of the route into `trailPoints`, as a path is walked round a bend.
    private func bend() {
        trailPoints.removeAll(keepingCapacity: true)
        trailPoints.append(trailCorners[0])
        for i in 1..<(trailCorners.count - 1) {
            let a = trailCorners[i - 1], c = trailCorners[i], b = trailCorners[i + 1]
            guard simd_distance(a, c) > 1e-3, simd_distance(c, b) > 1e-3 else { continue }
            let r = min(TRAIL_BEND, simd_distance(a, c) * 0.5, simd_distance(c, b) * 0.5)
            let from = c + simd_normalize(a - c) * r, to = c + simd_normalize(b - c) * r
            for k in 0...6 {
                let t = Float(k) / 6
                trailPoints.append(from * (1 - t) * (1 - t) + c * 2 * t * (1 - t) + to * t * t)
            }
        }
        trailPoints.append(trailCorners[trailCorners.count - 1])
    }

    /// Stones along the rounded route, a step apart, each a little off the line, its own size and turn;
    /// and the trodden strips under them.
    private func lay(_ plot: Plot) {
        let pebbles = plot.pebbles.values
        var walked: Float = 0, next: Float = STONE_STEP * 0.45, k = 0
        for i in 1..<trailPoints.count {
            let a = trailPoints[i - 1], b = trailPoints[i]
            let length = simd_distance(a, b)
            if troddenCount < MAX_TRODDEN, i % 3 == 1 || i == trailPoints.count - 1 {
                let from = trailPoints[max(0, i - 3)]
                trodden[troddenCount] = Vec4(from.x, from.y, b.x, b.y)
                troddenCount += 1
            }
            guard length > 1e-4 else { continue }
            let along = (b - a) / length
            while next <= walked + length, stoneCount < MAX_STONES {
                let p = a + along * (next - walked)
                let jitter = pebbles[k % Pebbles.count]
                k += 1
                next += STONE_STEP * (0.92 + jitter.y * 0.16)
                let size = 0.85 + jitter.y * 0.3
                let at = p + Vec2(-along.y, along.x) * jitter.x * 0.3
                if covered(at, by: 0.3 * size) { continue }
                stones[stoneCount] = Vec4(at.x, at.y, size, jitter.z)
                stoneCount += 1
            }
            walked += length
        }
    }
}
