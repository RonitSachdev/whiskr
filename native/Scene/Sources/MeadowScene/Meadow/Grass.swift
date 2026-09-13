import Foundation
import simd

// Port of src/meadow/grass.ts (via the spike): tens of thousands of chunky blades, thick where you look
// and thinning toward the hills, drawn in squares so squares off screen cost nothing.

enum GrassField {
    static let reach = 112.0       // how far out grass grows
    static let chunk = 24.0        // grass is drawn in squares this size
    // Tufts per square unit, by distance from the middle of the meadow.
    static func density(_ out: Double) -> Double { out < 32 ? 4.4 : out < 66 ? 2.1 : 0.7 }
    // Where each band ends and how finely its blades are cut: four sections up close, two in the middle
    // distance, a single triangle far off.
    static let bands: [(to: Double, levels: [Float])] = [(32, [0, 0.35, 0.65, 0.88]), (66, [0, 0.55]), (.infinity, [0])]

    /// One tuft: three flat, tapering blades fanning from a single root, each bending over toward its
    /// tip. Interleaved position + normal (24 bytes a vertex).
    static func tuft(_ levels: [Float]) -> (vertices: [Float], indices: [UInt16]) {
        var positions: [Vec3] = []
        var index: [UInt16] = []
        for (yaw, height, lean) in [(Float(0.2), Float(1.0), Float(0.22)), (2.3, 0.82, 0.34), (4.3, 0.66, 0.44)] {
            let start = positions.count
            func add(_ across: Float, _ t: Float) {
                let p = Vec3(across, t * height, lean * t + 0.3 * t * t)
                positions.append(Vec3(p.x * cos(yaw) + p.z * sin(yaw), p.y, -p.x * sin(yaw) + p.z * cos(yaw)))
            }
            for t in levels {
                let half = 0.09 * (1 - t * 0.72)
                add(-half, t)
                add(half, t)
            }
            add(0, 1)
            for level in 0..<(levels.count - 1) {
                let a = start + level * 2
                index += [a, a + 1, a + 2, a + 1, a + 3, a + 2].map { UInt16($0) }
            }
            let last = start + (levels.count - 1) * 2
            index += [last, last + 1, last + 2].map { UInt16($0) }
        }
        var normals = [Vec3](repeating: .zero, count: positions.count)
        for t in stride(from: 0, to: index.count, by: 3) {
            let a = Int(index[t]), b = Int(index[t + 1]), c = Int(index[t + 2])
            let n = simd_cross(positions[c] - positions[b], positions[a] - positions[b])
            normals[a] += n; normals[b] += n; normals[c] += n
        }
        var v: [Float] = []
        for (p, n) in zip(positions, normals) {
            let m = simd_normalize(n)
            v += [p.x, p.y, p.z, m.x, m.y, m.z]
        }
        return (v, index)
    }

    /// A tuft in the field: root and turn about y, (wide, tall). Matches `struct Tuft` in the shader.
    struct Tuft { var rootYaw: Vec4; var scale: Vec4 }

    struct Chunk {
        var band: Int
        var center: Vec2
        var first: Int
        var count: Int
        var bounds: (min: Vec3, max: Vec3)
        /// Part of the strip along a sidebar's column past the field (`alongColumn`), drawn only where
        /// blankets are laid.
        var column = false
        /// grass.ts `thin()`: tufts were placed in random order, so drawing only the first so-many thins a
        /// square evenly.
        func kept(eye: Vec3) -> Int {
            let away = hypot(eye.x - center.x, eye.z - center.y) + eye.y * 0.6
            let k: Float = away < 45 ? 1 : max(0.32, 1 - (away - 45) / 130)
            return max(1, Int((Float(count) * k).rounded()))
        }
    }

    /// A sidebar's column runs from the middle toward +z, as far as there are workspaces, beyond the
    /// field's reach: past it, grass grows along the column's band too (to where the ground ends), so a
    /// far row stands in grass like the first. Its own random stream, so the rest of the meadow grows as
    /// it always has.
    static let alongColumn = (across: 72.0, to: 400.0)

    /// The whole field, drawn from the meadow's own random stream (the first thing it grows), then the
    /// strip along the column.
    static func grow(_ random: inout Seeded) -> (tufts: [Tuft], chunks: [Chunk]) {
        let span = Int(ceil(reach / chunk))
        var tufts: [Tuft] = []
        var chunks: [Chunk] = []
        var strip = Seeded(0x5ee1)
        let across = Int(alongColumn.across / chunk), along = Int(ceil(alongColumn.to / chunk))
        let squares = (-span..<span).flatMap { cx in (-span..<span).map { (cx, $0, false) } }
            + (-across..<across).flatMap { cx in (Int(reach / chunk)..<along).map { (cx, $0, true) } }
        for (cx, cz, column) in squares {
                let midX = (Double(cx) + 0.5) * chunk, midZ = (Double(cz) + 0.5) * chunk
                let out = hypot(midX, midZ)
                if !column && out > reach + chunk * 0.7 { continue }
                // The strip is as thick as the middle distance, and only where the field is not.
                let count = Int((chunk * chunk * (column ? density(32) : density(out))).rounded())
                let first = tufts.count
                var lo = Vec3(repeating: .infinity), hi = Vec3(repeating: -.infinity)
                for _ in 0..<count {
                    func next() -> Double { column ? strip.next() : random.next() }
                    let x = Double(cx) * chunk + next() * chunk
                    let z = Double(cz) * chunk + next() * chunk
                    let away = hypot(x, z)
                    if column ? away <= reach || z > alongColumn.to : away > reach { continue }
                    // Taller in some patches than others, and coarser far away (the strip as in the middle distance).
                    let tall = (0.95 + fbm(x / 17, z / 17, 21) * 0.95) * (0.85 + next() * 0.3)
                    let wide = (0.95 + next() * 0.5) * (column ? 1.35 : away > 66 ? 1.9 : away > 32 ? 1.35 : 1)
                    let yaw = next() * Double.pi * 2
                    let root = Vec3(Float(x), Float(Land.height(x, z)), Float(z))
                    tufts.append(Tuft(rootYaw: Vec4(root, Float(yaw)), scale: Vec4(Float(wide), Float(tall), 0, 0)))
                    lo = simd_min(lo, root - Vec3(1.5, 0, 1.5) * Float(wide))
                    hi = simd_max(hi, root + Vec3(1.5 * Float(wide), 2.2 * Float(tall), 1.5 * Float(wide)))
                }
                if tufts.count == first { continue }
                // Where blankets are laid the land is levelled under it, down to the ground (`Land.level`).
                lo.y = min(lo.y, Float(Land.ground))
                let band = column ? 1 : bands.firstIndex { out < $0.to }!
                chunks.append(Chunk(band: band, center: Vec2(Float(midX), Float(midZ)), first: first, count: tufts.count - first, bounds: (lo, hi), column: column))
        }
        return (tufts, chunks)
    }
}
