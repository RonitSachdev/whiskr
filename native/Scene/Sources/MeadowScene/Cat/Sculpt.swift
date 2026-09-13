import Foundation
import simd

// Port of src/cat/sculpt.ts (taken from native/Spikes/Shared/Sculpt.swift): one continuous lathe skin, pressed into a cat by sculpting strokes,
// with per-vertex weights recorded so ears, arms and head can be posed every frame.

let SIDES: [Float] = [-1, 1]
let PIVOT: Float = 1.0
let ARM_BASE: [SIMD3<Float>] = SIDES.map { SIMD3($0 * 0.5, 0.85, 0.6) }
let ARM_MIN: Float = 0.34
let ARM_MAX: Float = 0.5
let ARM_REST: [SIMD3<Float>] = SIDES.map { SIMD3($0 * 0.04, -0.3, 0.2) }

struct Eye: Sendable {
    public var position: SIMD3<Float>   // in face space (y measured from PIVOT)
    public var facing: simd_quatf
}

final class Sculpt: @unchecked Sendable {
    public let rest: [SIMD3<Float>]
    public let index: [UInt32]
    public var count: Int { rest.count }
    public let earPull: [[Float]]
    public let armPull: [[Float]]
    public let turn: [Float]
    public let eyes: [Eye]

    public static let shared = Sculpt()

    private static let PROFILE: [SIMD2<Double>] = [
        [0, 0], [0.45, 0], [0.74, 0.1], [0.9, 0.38], [0.88, 0.7], [0.81, 0.98],
        [0.87, 1.22], [1.0, 1.5], [1.0, 1.78], [0.84, 2.03], [0.5, 2.2], [0, 2.26],
    ]
    public static let RINGS = 72, SEGMENTS = 88

    private init() {
        // three.js SplineCurve (centripetal-free Catmull-Rom per axis), with one mirrored point past each end.
        let P = Self.PROFILE
        let pts: [SIMD2<Double>] = [SIMD2(-P[1].x, P[1].y)] + P + [SIMD2(-P[P.count - 2].x, P[P.count - 2].y)]
        func catmull(_ t: Double, _ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
            let v0 = (p2 - p0) * 0.5, v1 = (p3 - p1) * 0.5, t2 = t * t, t3 = t * t2
            return (2 * p1 - 2 * p2 + v0 + v1) * t3 + (-3 * p1 + 3 * p2 - 2 * v0 - v1) * t2 + v0 * t + p1
        }
        func point(_ t: Double) -> SIMD2<Double> {
            let p = Double(pts.count - 1) * t
            let i = Int(floor(p)), w = p - floor(p)
            let p0 = pts[i == 0 ? i : i - 1], p1 = pts[i]
            let p2 = pts[i > pts.count - 2 ? pts.count - 1 : i + 1]
            let p3 = pts[i > pts.count - 3 ? pts.count - 1 : i + 2]
            return SIMD2(catmull(w, p0.x, p1.x, p2.x, p3.x), catmull(w, p0.y, p1.y, p2.y, p3.y))
        }
        let spans = Double(P.count + 1)
        let R = Self.RINGS, S = Self.SEGMENTS
        let outline: [SIMD2<Double>] = (0...R).map { i in
            var p = point(1 / spans + (1 - 2 / spans) * Double(i) / Double(R))
            p.x = (i == 0 || i == R) ? 0 : max(p.x, 0)
            return p
        }

        // LatheGeometry, then mergeVertices(1e-4): first occurrence of each position wins.
        var lathe: [SIMD3<Double>] = []
        for i in 0...S {
            let phi = Double(i) / Double(S) * 2 * Double.pi
            for p in outline { lathe.append(SIMD3(p.x * sin(phi), p.y, p.x * cos(phi))) }
        }
        var latheIndex: [Int] = []
        let n = outline.count
        for i in 0..<S {
            for j in 0..<(n - 1) {
                let base = j + i * n
                let a = base, b = base + n, c = base + n + 1, d = base + 1
                latheIndex += [a, b, d, c, d, b]
            }
        }
        var lookup: [SIMD3<Int64>: UInt32] = [:]
        var remap = [UInt32](repeating: 0, count: lathe.count)
        var merged: [SIMD3<Float>] = []
        for (k, v) in lathe.enumerated() {
            let key = SIMD3<Int64>(Int64((v.x * 1e4).rounded()), Int64((v.y * 1e4).rounded()), Int64((v.z * 1e4).rounded()))
            if let found = lookup[key] { remap[k] = found; continue }
            let id = UInt32(merged.count)
            lookup[key] = id
            remap[k] = id
            merged.append(SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)))
        }
        index = latheIndex.map { remap[$0] }
        var rest = merged
        let count = rest.count

        for i in 0..<count {
            rest[i].x *= 1 + 0.08 * smoothstep(rest[i].y, 1.1, 1.6)
            rest[i].z *= 0.9
        }

        func stroke(_ center: SIMD3<Float>, _ dir: SIMD3<Float>, _ radii: SIMD3<Float>, _ height: Float, _ power: Float, _ record: UnsafeMutablePointer<Float>? = nil) {
            let d = simd_normalize(dir)
            for i in 0..<count {
                let q = (rest[i] - center) / radii
                let d2 = simd_dot(q, q)
                if d2 >= 1 { continue }
                let pull = pow(1 - d2, power)
                rest[i] += d * height * pull
                record?[i] = pull
            }
        }
        var ears = [[Float]](repeating: [Float](repeating: 0, count: count), count: 2)
        var arms = ears
        for (n, side) in SIDES.enumerated() {
            ears[n].withUnsafeMutableBufferPointer { e in
                stroke([side * 0.62, 2.12, 0], [side * 0.4, 1, 0], [0.4, 0.42, 0.3], 0.4, 1.5, e.baseAddress)
            }
            stroke([side * 0.72, 1.4, 0.48], [side, -0.1, 0.5], [0.5, 0.45, 0.5], 0.07, 1.5)
            stroke([side * 0.74, 0.36, -0.05], [side, 0, 0.1], [0.5, 0.5, 0.6], 0.11, 1.5)
            stroke([side * 0.3, 0.13, 0.58], [0, -0.04, 1], [0.25, 0.22, 0.32], 0.2, 1.3)
        }
        for n in 0..<2 {
            arms[n].withUnsafeMutableBufferPointer { a in
                stroke(ARM_BASE[n], [0, 0, 1], [0.21, 0.21, 0.21], 0, 0.8, a.baseAddress)
            }
        }
        turn = rest.map { smoothstep($0.y, 0.7, 1.35) }

        // Eyes: press straight into the face (front faces only, as three's Raycaster does by default).
        let idx = index
        eyes = SIDES.map { side in
            let origin = SIMD3<Float>(side * 0.43, 1.62, 5), dir = SIMD3<Float>(0, 0, -1)
            var best = Float.infinity, bestNormal = SIMD3<Float>(0, 0, 1)
            for t in stride(from: 0, to: idx.count, by: 3) {
                let a = rest[Int(idx[t])], b = rest[Int(idx[t + 1])], c = rest[Int(idx[t + 2])]
                let normal = simd_cross(c - b, a - b)
                if simd_length(normal) < 1e-12 || simd_dot(normal, dir) >= 0 { continue }
                // Möller–Trumbore
                let e1 = b - a, e2 = c - a, pv = simd_cross(dir, e2), det = simd_dot(e1, pv)
                if abs(det) < 1e-12 { continue }
                let inv = 1 / det, tv = origin - a
                let u = simd_dot(tv, pv) * inv
                if u < 0 || u > 1 { continue }
                let qv = simd_cross(tv, e1), v = simd_dot(dir, qv) * inv
                if v < 0 || u + v > 1 { continue }
                let dist = simd_dot(e2, qv) * inv
                if dist > 0 && dist < best { best = dist; bestNormal = simd_normalize(normal) }
            }
            var position = origin + dir * best - bestNormal * 0.02
            position.y -= PIVOT
            return Eye(position: position, facing: simd_quatf(from: [0, 0, 1], to: bestNormal))
        }
        self.rest = rest
        earPull = ears
        armPull = arms
    }
}
