import Foundation
import simd

// Port of src/meadow/critters.ts: butterflies drifting from bloom to bloom (and now and then onto a
// sleeping cat, which twitches an ear), bees working the flowers, and seeds riding the breeze.

/// Somewhere a flyer can settle. A sleeping cat is a perch too, and gets tickled when one lands.
struct Perch {
    var cat: Cat?
    var at: Vec3
}

final class Critters {
    struct Flyer {
        var bee: Bool
        var color: UInt32
        var where_ = Vec3.zero      // true position; the body bobs around it in flight
        var body = Vec3.zero        // where it is drawn
        var heading: Float = 0
        var perch: Perch? = Perch(cat: nil, at: .zero)
        var perchIsBloom = -1
        var resting: Float = 0.01   // seconds left on its perch; 0 while flying
        var phase: Float
        var wing: Float = 0         // butterflies: how far open (radians); bees: blur
    }

    static let wingColors: [UInt32] = [0xf7b23b, 0xfff6dd, 0x8fc9f2, 0xf58fb5, 0xffe066, 0xf7b23b, 0xfff6dd]
    private(set) var flyers: [Flyer] = []
    /// Live positions, for anything that wants to watch them go by.
    private(set) var spots: ContiguousArray<Vec3> = []
    private(set) var seeds: [Vec3] = []
    private var blooms: [Vec3]
    private var time: Float = 0

    init(_ random: inout Seeded, blooms: [Vec3]) {
        self.blooms = blooms
        for color in Self.wingColors { flyers.append(Flyer(bee: false, color: color, phase: random.float() * 10)) }
        for _ in 0..<5 { flyers.append(Flyer(bee: true, color: 0, phase: random.float() * 10)) }
        for i in flyers.indices {
            let x = (random.float() - 0.5) * 40, z = (random.float() - 0.5) * 40
            flyers[i].where_ = Vec3(x, 2.5, z)
            flyers[i].body = flyers[i].where_
        }
        spots = ContiguousArray(flyers.map(\.body))
        for _ in 0..<40 {
            let x = (random.float() - 0.5) * 90, y = 1 + random.float() * 7, z = (random.float() - 0.5) * 90
            seeds.append(Vec3(x, y, z))
        }
    }

    /// The meadow's flowers changed: a flyer on or bound for a bloom that is gone chooses again at once.
    func bloom(_ tops: [Vec3]) {
        blooms = tops
        for i in flyers.indices where flyers[i].perchIsBloom >= 0 {
            let k = flyers[i].perchIsBloom
            guard k >= tops.count || tops[k] != flyers[i].perch?.at else { continue }
            flyers[i].perchIsBloom = -1
            flyers[i].resting = 1e-3
        }
    }

    /// `wind`: which way it blows (unit length, x and z), for the seeds.
    func update(_ dt: Float, wind: Vec2 = Light.breeze, sleepers: [Perch], random: inout Seeded) {
        time += dt
        let t = time
        for i in flyers.indices {
            var f = flyers[i]
            func sleeperSpot(_ p: Perch) -> Vec3? {
                guard let cat = p.cat else { return nil }
                return sleepers.first { $0.cat === cat }?.at
            }
            if f.resting > 0 {
                f.resting -= dt
                let perch = f.perch!
                // A cat that wakes up is no longer somewhere to sit. Stay on the cat as it breathes.
                let onCat = perch.cat != nil
                let spot = sleeperSpot(perch)
                if let spot { f.where_ = spot }
                f.body = f.where_
                if f.bee { f.body.y += 0.12 + sin(t * 9 + f.phase) * 0.05 }
                if f.resting <= 0 || (onCat && spot == nil) { choose(&f, sleepers, &random) }
            } else {
                let perch = f.perch!
                let target = sleeperSpot(perch) ?? perch.at
                let offset = target - f.where_
                let left = simd_length(offset), step = (f.bee ? 4.2 : 2.3) * dt
                if left <= step + 0.05 {
                    f.where_ = target
                    f.resting = f.bee ? 1.2 + random.float() * 2.2 : 3 + random.float() * 6
                    perch.cat?.tickle()
                } else {
                    f.where_ += offset * (step / left)
                    f.heading = atan2(offset.x, offset.z)
                }
                // Flight is never a straight line: a butterfly lurches up and down and side to side.
                let loose = min(1, left / 2)
                f.body = f.where_
                f.body.y += (f.bee ? 0.15 : 0.5) * loose * (1 + sin(t * (f.bee ? 11 : 5.2) + f.phase))
                f.body.x += sin(t * 3.1 + f.phase * 2) * 0.25 * loose
            }
            // Resting butterflies fold their wings up and open them slowly; flying ones beat them hard.
            if f.bee { f.wing = 0.55 + 0.45 * sin(t * 95 + f.phase) }
            else { f.wing = f.resting > 0 ? 0.95 + sin(t * 2.2 + f.phase) * 0.3 : 0.15 + (sin(t * 17 + f.phase) * 0.5 + 0.5) * 1.15 }
            flyers[i] = f
            spots[i] = f.body
        }
        // Seeds ride the same wind the grass bends to, and come round again when they drift out of sight.
        for i in seeds.indices {
            let fi = Float(i)
            let along = 1.17 + sin(t * 0.7 + fi) * 0.4
            seeds[i].x += wind.x * along * dt
            seeds[i].z += wind.y * along * dt
            seeds[i].y += sin(t * 1.3 + fi * 1.7) * 0.25 * dt
            if seeds[i].x > 45 { seeds[i].x -= 90 } else if seeds[i].x < -45 { seeds[i].x += 90 }
            if seeds[i].z > 45 { seeds[i].z -= 90 } else if seeds[i].z < -45 { seeds[i].z += 90 }
        }
    }

    /// Moves where each butterfly and bee in flight is drawn (one resting stays on its perch).
    func moveFlying(_ move: (Vec3) -> Vec3) {
        for i in flyers.indices where flyers[i].resting <= 0 {
            flyers[i].body = move(flyers[i].body)
            spots[i] = flyers[i].body
        }
    }

    private func choose(_ f: inout Flyer, _ sleepers: [Perch], _ random: inout Seeded) {
        f.resting = 0
        // Butterflies are sometimes drawn to a sleeping cat; otherwise everyone picks the nearest of a few blooms.
        if !f.bee && !sleepers.isEmpty && random.float() < 0.3 {
            f.perch = sleepers[Int(random.float() * Float(sleepers.count)) % sleepers.count]
            f.perchIsBloom = -1
            return
        }
        var best = -1, bestDistance = Float.infinity
        for _ in 0..<5 where !blooms.isEmpty {
            let k = Int(random.float() * Float(blooms.count)) % blooms.count
            let d = simd_distance(blooms[k], f.where_)
            if k != f.perchIsBloom && d > 1.5 && d < bestDistance { best = k; bestDistance = d }
        }
        if best >= 0 {
            f.perch = Perch(cat: nil, at: blooms[best])
            f.perchIsBloom = best
        } else {
            let x = (random.float() - 0.5) * 50, z = (random.float() - 0.5) * 50
            f.perch = Perch(cat: nil, at: Vec3(x, 2.5, z))
            f.perchIsBloom = -1
        }
    }

    // MARK: shapes

    /// Each side: a large forewing and a smaller hindwing, hinged at the body (CircleGeometry, laid flat).
    static let butterflyWing: Geometry = {
        func flat(_ r: Float, _ long: Float, _ x: Float, _ z: Float) -> Geometry {
            Shapes.circle(r, 14).applied(.translation(Vec3(x, 0, z)) * .rotationX(-.pi / 2) * .scale(Vec3(1, long, 1)))
        }
        return Geometry.join([flat(0.2, 1.25, 0.2, 0.08), flat(0.14, 1.1, 0.15, -0.16)])
    }()
    static let butterflyBody = Clay.blob(at: .zero, size: Vec3(0.035, 0.035, 0.17), color: 0x6b4a36).roughened(0.8)
    /// A plump amber body banded with brown.
    static let beeBody: Geometry = {
        var fuzz = Clay.blob(at: .zero, size: Vec3(0.1, 0.095, 0.15), color: 0xf2b632).roughened(0.9)
        let band = linear(0x6b4a36)
        for i in fuzz.positions.indices where sin(fuzz.positions[i].z * 42 + 1) > 0.35 { fuzz.colors[i] = band }
        return fuzz
    }()
    static let beeWing = Shapes.circle(0.09, 10).applied(.translation(Vec3(0.1, 0.09, 0.02)) * .rotationX(-.pi / 2) * .scale(Vec3(1.5, 0.8, 1)))
    static let seed = Shapes.sphere(0.06, 8, 6)
}
