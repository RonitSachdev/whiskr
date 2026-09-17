import Foundation
import simd

// CPU meshes, and ports of the three.js geometries and curves the web scene is modelled with. The ports
// follow three.js r187 point for point (vertex order, winding, analytic normals where three has them),
// so shapes built from the same numbers come out the same.

/// An indexed triangle mesh with per-vertex colour (linear) and roughness. Triangles wind
/// counter-clockwise seen from outside, as in three.js.
struct Geometry {
    var positions: [Vec3] = []
    var normals: [Vec3] = []
    var colors: [Vec3] = []
    var roughness: [Float] = []
    /// Texture coordinates, only for the few shapes that need them (the blanket's gingham).
    var uvs: [Vec2] = []
    var indices: [UInt32] = []

    var count: Int { positions.count }

    init() {}
    init(positions: [Vec3], normals: [Vec3] = [], indices: [UInt32]) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
    }

    /// Moves, turns and scales the shape; normals follow by the normal matrix, as in three.js.
    @discardableResult
    mutating func apply(_ m: Mat4) -> Geometry {
        let nm = m.normalMatrix
        for i in positions.indices { positions[i] = m.point(positions[i]) }
        for i in normals.indices { normals[i] = simd_normalize(nm * normals[i]) }
        return self
    }
    func applied(_ m: Mat4) -> Geometry { var g = self; g.apply(m); return g }

    @discardableResult
    mutating func translate(_ x: Float, _ y: Float, _ z: Float) -> Geometry { apply(.translation(Vec3(x, y, z))) }
    @discardableResult
    mutating func scale(_ x: Float, _ y: Float, _ z: Float) -> Geometry { apply(.scale(Vec3(x, y, z))) }
    @discardableResult
    mutating func rotateX(_ a: Float) -> Geometry { apply(.rotationX(a)) }
    @discardableResult
    mutating func rotateY(_ a: Float) -> Geometry { apply(.rotationY(a)) }
    @discardableResult
    mutating func rotateZ(_ a: Float) -> Geometry { apply(.rotationZ(a)) }

    /// three.js computeVertexNormals: area-weighted face normals summed per vertex, (c−b)×(a−b).
    mutating func computeNormals() {
        var n = [Vec3](repeating: .zero, count: positions.count)
        var t = 0
        while t + 2 < indices.count {
            let a = Int(indices[t]), b = Int(indices[t + 1]), c = Int(indices[t + 2])
            let f = simd_cross(positions[c] - positions[b], positions[a] - positions[b])
            n[a] += f; n[b] += f; n[c] += f
            t += 3
        }
        normals = n.map { simd_length_squared($0) > 0 ? simd_normalize($0) : Vec3(0, 1, 0) }
    }

    /// Each triangle gets its own three vertices: what a non-indexed three.js geometry is, so that
    /// `computeNormals` then gives flat facets.
    func unwelded() -> Geometry {
        var g = Geometry()
        g.positions.reserveCapacity(indices.count)
        for i in indices {
            let k = Int(i)
            g.positions.append(positions[k])
            if !normals.isEmpty { g.normals.append(normals[k]) }
            if !colors.isEmpty { g.colors.append(colors[k]) }
            if !roughness.isEmpty { g.roughness.append(roughness[k]) }
            if !uvs.isEmpty { g.uvs.append(uvs[k]) }
        }
        g.indices = (0..<UInt32(indices.count)).map { $0 }
        return g
    }

    /// three.js mergeVertices on positions only (other attributes deleted first): the first vertex at
    /// each position, to 1e-4, is kept.
    func welded(tolerance: Double = 1e-4) -> Geometry {
        let k = 1 / tolerance
        var lookup: [SIMD3<Int64>: UInt32] = [:]
        var remap = [UInt32](repeating: 0, count: positions.count)
        var g = Geometry()
        for (i, p) in positions.enumerated() {
            let key = SIMD3<Int64>(Int64((Double(p.x) * k).rounded()), Int64((Double(p.y) * k).rounded()), Int64((Double(p.z) * k).rounded()))
            if let found = lookup[key] { remap[i] = found; continue }
            let id = UInt32(g.positions.count)
            lookup[key] = id
            remap[i] = id
            g.positions.append(p)
            if !colors.isEmpty { g.colors.append(colors[i]) }
            if !roughness.isEmpty { g.roughness.append(roughness[i]) }
        }
        g.indices = indices.map { remap[Int($0)] }
        return g
    }

    /// Bakes colour into the shape: one colour, or a blend from its bottom to its top (kit.ts `paint`).
    @discardableResult
    mutating func paint(_ bottom: UInt32, _ top: UInt32? = nil) -> Geometry {
        let low = linear(bottom), high = linear(top ?? bottom)
        let ys = positions.map(\.y)
        let lo = ys.min() ?? 0, hi = ys.max() ?? 0
        colors = positions.map { p in
            let t: Float = hi > lo ? (p.y - lo) / (hi - lo) : 0
            return low + (high - low) * t
        }
        return self
    }
    func painted(_ bottom: UInt32, _ top: UInt32? = nil) -> Geometry { var g = self; g.paint(bottom, top); return g }

    /// Sets one roughness for the whole shape (the material it stands for).
    @discardableResult
    mutating func rough(_ r: Float) -> Geometry {
        roughness = [Float](repeating: r, count: positions.count)
        return self
    }
    func roughened(_ r: Float) -> Geometry { var g = self; g.rough(r); return g }

    /// Its baked colours made `k` times as bright (a shade deeper below 1, paler above).
    func tinted(_ k: Float) -> Geometry {
        var g = self
        g.colors = g.colors.map { simd_min($0 * k, Vec3(1, 1, 1)) }
        return g
    }

    /// Uniform colour (for shapes standing for a single-colour material).
    func colored(_ hex: UInt32, roughness r: Float) -> Geometry {
        var g = self
        g.colors = [Vec3](repeating: linear(hex), count: positions.count)
        g.roughness = [Float](repeating: r, count: positions.count)
        return g
    }

    /// kit.ts `join`: several parts as one shape.
    static func join(_ parts: [Geometry]) -> Geometry {
        var g = Geometry()
        let total = parts.reduce(0) { $0 + $1.count }
        g.positions.reserveCapacity(total)
        for part in parts {
            let base = UInt32(g.positions.count)
            g.positions += part.positions
            g.normals += part.normals.isEmpty ? [Vec3](repeating: Vec3(0, 1, 0), count: part.count) : part.normals
            g.colors += part.colors.isEmpty ? [Vec3](repeating: Vec3(1, 1, 1), count: part.count) : part.colors
            g.roughness += part.roughness.isEmpty ? [Float](repeating: 0.8, count: part.count) : part.roughness
            g.uvs += part.uvs.isEmpty ? [Vec2](repeating: .zero, count: part.count) : part.uvs
            g.indices += part.indices.map { $0 + base }
        }
        return g
    }

    var bounds: (min: Vec3, max: Vec3) {
        var lo = Vec3(repeating: .infinity), hi = Vec3(repeating: -.infinity)
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }
}

// MARK: - three.js primitives

enum Shapes {
    /// SphereGeometry(radius, widthSegments, heightSegments).
    static func sphere(_ radius: Float = 1, _ widthSegments: Int = 32, _ heightSegments: Int = 16) -> Geometry {
        var g = Geometry()
        var grid: [[UInt32]] = []
        for iy in 0...heightSegments {
            let v = Float(iy) / Float(heightSegments)
            var row: [UInt32] = []
            for ix in 0...widthSegments {
                let u = Float(ix) / Float(widthSegments)
                let p = Vec3(-radius * cos(u * 2 * .pi) * sin(v * .pi), radius * cos(v * .pi), radius * sin(u * 2 * .pi) * sin(v * .pi))
                g.positions.append(p)
                g.normals.append(simd_length_squared(p) > 0 ? simd_normalize(p) : Vec3(0, iy == 0 ? 1 : -1, 0))
                row.append(UInt32(g.positions.count - 1))
            }
            grid.append(row)
        }
        for iy in 0..<heightSegments {
            for ix in 0..<widthSegments {
                let a = grid[iy][ix + 1], b = grid[iy][ix], c = grid[iy + 1][ix], d = grid[iy + 1][ix + 1]
                if iy != 0 { g.indices += [a, b, d] }
                if iy != heightSegments - 1 { g.indices += [b, c, d] }
            }
        }
        return g
    }

    /// IcosahedronGeometry(radius, detail): three's PolyhedronGeometry subdivision, non-indexed.
    static func icosahedron(_ radius: Float = 1, detail: Int) -> Geometry {
        let t = Float((1 + 5.0.squareRoot()) / 2)
        let v: [Vec3] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
            [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
        ]
        let faces: [Int] = [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
                            3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1]
        var out: [Vec3] = []
        let cols = detail + 1
        for f in stride(from: 0, to: faces.count, by: 3) {
            let a = v[faces[f]], b = v[faces[f + 1]], c = v[faces[f + 2]]
            var grid: [[Vec3]] = []
            for i in 0...cols {
                let aj = a + (c - a) * (Float(i) / Float(cols)), bj = b + (c - b) * (Float(i) / Float(cols))
                let rows = cols - i
                var row: [Vec3] = []
                for j in 0...rows { row.append(j == 0 && i == cols ? aj : aj + (bj - aj) * (Float(j) / Float(rows))) }
                grid.append(row)
            }
            for i in 0..<cols {
                for j in 0..<(2 * (cols - i) - 1) {
                    let k = j / 2
                    if j % 2 == 0 { out += [grid[i][k + 1], grid[i + 1][k], grid[i][k]] } else { out += [grid[i][k + 1], grid[i + 1][k + 1], grid[i + 1][k]] }
                }
            }
        }
        out = out.map { simd_normalize($0) * radius }
        return Geometry(positions: out, indices: (0..<UInt32(out.count)).map { $0 })
    }

    /// CylinderGeometry(radiusTop, radiusBottom, height, radialSegments, heightSegments = 1), closed.
    static func cylinder(_ top: Float, _ bottom: Float, _ height: Float, _ radial: Int = 32, _ heightSegments: Int = 1, openEnded: Bool = false) -> Geometry {
        var g = Geometry()
        let half = height / 2
        let slope = (bottom - top) / height
        var grid: [[UInt32]] = []
        for y in 0...heightSegments {
            let v = Float(y) / Float(heightSegments)
            let r = v * (bottom - top) + top
            var row: [UInt32] = []
            for x in 0...radial {
                let theta = Float(x) / Float(radial) * 2 * .pi
                g.positions.append(Vec3(r * sin(theta), -v * height + half, r * cos(theta)))
                g.normals.append(simd_normalize(Vec3(sin(theta), slope, cos(theta))))
                row.append(UInt32(g.positions.count - 1))
            }
            grid.append(row)
        }
        for x in 0..<radial {
            for y in 0..<heightSegments {
                let a = grid[y][x], b = grid[y + 1][x], c = grid[y + 1][x + 1], d = grid[y][x + 1]
                g.indices += [a, b, d, b, c, d]
            }
        }
        if !openEnded {
            for (isTop, radius) in [(true, top), (false, bottom)] {
                let sign: Float = isTop ? 1 : -1
                let centerStart = UInt32(g.positions.count)
                for _ in 1...radial {
                    g.positions.append(Vec3(0, half * sign, 0)); g.normals.append(Vec3(0, sign, 0))
                }
                let centerEnd = UInt32(g.positions.count)
                for x in 0...radial {
                    let theta = Float(x) / Float(radial) * 2 * .pi
                    g.positions.append(Vec3(radius * sin(theta), half * sign, radius * cos(theta))); g.normals.append(Vec3(0, sign, 0))
                }
                for x in 0..<UInt32(radial) {
                    let c = centerStart + x, i = centerEnd + x
                    g.indices += isTop ? [i, i + 1, c] : [i + 1, i, c]
                }
            }
        }
        return g
    }

    /// TorusGeometry(radius, tube, radialSegments, tubularSegments, arc).
    static func torus(_ radius: Float, _ tube: Float, _ radialSegments: Int, _ tubularSegments: Int, arc: Float = 2 * .pi) -> Geometry {
        var g = Geometry()
        for j in 0...radialSegments {
            for i in 0...tubularSegments {
                let u = Float(i) / Float(tubularSegments) * arc, v = Float(j) / Float(radialSegments) * 2 * .pi
                let p = Vec3((radius + tube * cos(v)) * cos(u), (radius + tube * cos(v)) * sin(u), tube * sin(v))
                g.positions.append(p)
                g.normals.append(simd_normalize(p - Vec3(radius * cos(u), radius * sin(u), 0)))
            }
        }
        let w = UInt32(tubularSegments + 1)
        for j in 1...UInt32(radialSegments) {
            for i in 1...UInt32(tubularSegments) {
                let a = w * j + i - 1, b = w * (j - 1) + i - 1, c = w * (j - 1) + i, d = w * j + i
                g.indices += [a, b, d, b, c, d]
            }
        }
        return g
    }

    /// CircleGeometry(radius, segments), facing +z.
    static func circle(_ radius: Float, _ segments: Int) -> Geometry {
        var g = Geometry()
        g.positions.append(.zero); g.normals.append(Vec3(0, 0, 1))
        for s in 0...segments {
            let a = Float(s) / Float(segments) * 2 * .pi
            g.positions.append(Vec3(radius * cos(a), radius * sin(a), 0)); g.normals.append(Vec3(0, 0, 1))
        }
        for i in 1...UInt32(segments) { g.indices += [i, i + 1, 0] }
        return g
    }

    /// PlaneGeometry(width, height), facing +z.
    static func plane(_ w: Float, _ h: Float) -> Geometry {
        Geometry(positions: [Vec3(-w / 2, h / 2, 0), Vec3(w / 2, h / 2, 0), Vec3(-w / 2, -h / 2, 0), Vec3(w / 2, -h / 2, 0)],
                 normals: [Vec3](repeating: Vec3(0, 0, 1), count: 4), indices: [0, 2, 1, 2, 3, 1])
    }

    /// BoxGeometry(1, 1, 1, s, s, s) pressed into RoundedBoxGeometry(w, h, d, segments, radius).
    static func roundedBox(_ w: Float, _ h: Float, _ d: Float, segments: Int = 3, radius: Float) -> Geometry {
        let s = segments * 2 + 1
        let r = min(w / 2, h / 2, d / 2, radius)
        let half = 0.5 / Float(s)
        let box = Vec3(w, h, d) / 2 - Vec3(repeating: r)
        var g = Geometry()
        // Six faces of a unit box: (axis u, axis v, normal), each a grid of s×s quads, wound outward.
        let faces: [(Vec3, Vec3, Vec3)] = [
            (Vec3(0, 0, -1), Vec3(0, 1, 0), Vec3(1, 0, 0)), (Vec3(0, 0, 1), Vec3(0, 1, 0), Vec3(-1, 0, 0)),
            (Vec3(1, 0, 0), Vec3(0, 0, -1), Vec3(0, 1, 0)), (Vec3(1, 0, 0), Vec3(0, 0, 1), Vec3(0, -1, 0)),
            (Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)), (Vec3(-1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, -1)),
        ]
        for (u, v, n) in faces {
            let start = UInt32(g.positions.count)
            for j in 0...s {
                for i in 0...s {
                    let p = n * 0.5 + u * (Float(i) / Float(s) - 0.5) + v * (Float(j) / Float(s) - 0.5)
                    let sign = Vec3(p.x > 0 ? 1 : p.x < 0 ? -1 : 0, p.y > 0 ? 1 : p.y < 0 ? -1 : 0, p.z > 0 ? 1 : p.z < 0 ? -1 : 0)
                    let normal = simd_normalize(p - sign * half)
                    g.positions.append(box * sign + normal * r)
                    g.normals.append(normal)
                }
            }
            let row = UInt32(s + 1)
            for j in 0..<UInt32(s) {
                for i in 0..<UInt32(s) {
                    let a = start + j * row + i, b = a + 1, c = a + row, d = c + 1
                    g.indices += [a, b, d, a, d, c]
                }
            }
        }
        return g
    }

    /// LatheGeometry(points, segments): spun round y, with three's analytic normals.
    static func lathe(_ points: [Vec2], _ segments: Int) -> Geometry {
        var initNormals: [Vec3] = []
        var prev = Vec3.zero
        for j in 0..<points.count {
            if j == 0 {
                let dx = points[1].x - points[0].x, dy = points[1].y - points[0].y
                prev = Vec3(dy, -dx, 0)
                initNormals.append(simd_length_squared(prev) > 0 ? simd_normalize(prev) : Vec3(0, -1, 0))
            } else if j == points.count - 1 {
                initNormals.append(prev)
            } else {
                let dx = points[j + 1].x - points[j].x, dy = points[j + 1].y - points[j].y
                let cur = Vec3(dy, -dx, 0)
                let sum = cur + prev
                initNormals.append(simd_length_squared(sum) > 0 ? simd_normalize(sum) : cur)
                prev = cur
            }
        }
        var g = Geometry()
        for i in 0...segments {
            let phi = Float(i) / Float(segments) * 2 * .pi
            let s = sin(phi), c = cos(phi)
            for (j, p) in points.enumerated() {
                g.positions.append(Vec3(p.x * s, p.y, p.x * c))
                let n = initNormals[j]
                g.normals.append(Vec3(n.x * s, n.y, n.x * c))
            }
        }
        let n = UInt32(points.count)
        for i in 0..<UInt32(segments) {
            for j in 0..<(n - 1) {
                let base = j + i * n
                let a = base, b = base + n, c = base + n + 1, d = base + 1
                g.indices += [a, b, d, c, d, b]
            }
        }
        // Rings where the profile touches the axis collapse to a point; their normals stay well defined.
        g.normals = g.normals.map { simd_length_squared($0) > 1e-12 ? simd_normalize($0) : Vec3(0, 1, 0) }
        return g
    }
}

// MARK: - curves (three.js Curve, with arc-length parametrisation)

class Curve {
    private var lengths: [Float]?
    /// three.js caches a curve's arc lengths the first time it needs them and, unless told otherwise,
    /// keeps them even when the points move (the cat's tail relies on this).
    var cacheLengths = true

    func point(_ t: Float) -> Vec3 { fatalError("override") }

    func arcLengths() -> [Float] {
        if cacheLengths, let lengths { return lengths }
        let divisions = 200
        var out = [Float](repeating: 0, count: divisions + 1)
        var last = point(0), sum: Float = 0
        for p in 1...divisions {
            let current = point(Float(p) / Float(divisions))
            sum += simd_distance(current, last)
            out[p] = sum
            last = current
        }
        lengths = out
        return out
    }
    func resetLengths() { lengths = nil }

    func uToT(_ u: Float) -> Float {
        let lengths = arcLengths()
        let il = lengths.count
        let target = u * lengths[il - 1]
        var low = 0, high = il - 1
        while low <= high {
            let i = low + (high - low) / 2
            let c = lengths[i] - target
            if c < 0 { low = i + 1 } else if c > 0 { high = i - 1 } else { high = i; break }
        }
        let i = max(high, 0)
        if lengths[i] == target { return Float(i) / Float(il - 1) }
        guard i + 1 < il else { return 1 }
        let before = lengths[i], after = lengths[i + 1]
        return (Float(i) + (target - before) / (after - before)) / Float(il - 1)
    }

    func pointAt(_ u: Float) -> Vec3 { point(uToT(u)) }

    func tangent(_ t: Float) -> Vec3 {
        let delta: Float = 0.0001
        let t1 = max(t - delta, 0), t2 = min(t + delta, 1)
        let d = point(t2) - point(t1)
        return simd_length_squared(d) > 0 ? simd_normalize(d) : Vec3(0, 1, 0)
    }
    func tangentAt(_ u: Float) -> Vec3 { tangent(uToT(u)) }

    /// three.js computeFrenetFrames(segments, false).
    func frenetFrames(_ segments: Int) -> (tangents: [Vec3], normals: [Vec3], binormals: [Vec3]) {
        var tangents = [Vec3](repeating: .zero, count: segments + 1)
        var normals = tangents, binormals = tangents
        frenetFrames(segments, &tangents, &normals, &binormals)
        return (tangents, normals, binormals)
    }

    /// The same, written into arrays already `segments + 1` long, so a frame costs no allocation.
    func frenetFrames(_ segments: Int, _ tangents: inout [Vec3], _ normals: inout [Vec3], _ binormals: inout [Vec3]) {
        for i in 0...segments { tangents[i] = tangentAt(Float(i) / Float(segments)) }
        var smallest = Float.greatestFiniteMagnitude
        let t0 = simd_abs(tangents[0])
        var normal = Vec3.zero
        if t0.x <= smallest { smallest = t0.x; normal = Vec3(1, 0, 0) }
        if t0.y <= smallest { smallest = t0.y; normal = Vec3(0, 1, 0) }
        if t0.z <= smallest { normal = Vec3(0, 0, 1) }
        let vec = simd_normalize(simd_cross(tangents[0], normal))
        normals[0] = simd_cross(tangents[0], vec)
        binormals[0] = simd_cross(tangents[0], normals[0])
        for i in 1...segments {
            var n = normals[i - 1]
            let axis = simd_cross(tangents[i - 1], tangents[i])
            if simd_length(axis) > Float.ulpOfOne {
                let theta = acos(clamp(simd_dot(tangents[i - 1], tangents[i]), -1, 1))
                n = simd_quatf(angle: theta, axis: simd_normalize(axis)).act(n)
            }
            normals[i] = n
            binormals[i] = simd_cross(tangents[i], n)
        }
    }
}

final class QuadraticBezier: Curve {
    let p0, p1, p2: Vec3
    init(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3) { self.p0 = p0; self.p1 = p1; self.p2 = p2 }
    override func point(_ t: Float) -> Vec3 {
        let k = 1 - t
        return k * k * p0 + 2 * k * t * p1 + t * t * p2
    }
}

final class CubicBezier: Curve {
    let p0, p1, p2, p3: Vec3
    init(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3) { self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3 }
    override func point(_ t: Float) -> Vec3 {
        let k = 1 - t
        return k * k * k * p0 + 3 * k * k * t * p1 + 3 * k * t * t * p2 + t * t * t * p3
    }
}

/// CatmullRomCurve3 with three's default centripetal parametrisation, open.
final class CatmullRom: Curve {
    var points: [Vec3]
    init(_ points: [Vec3]) { self.points = points }
    override func point(_ t: Float) -> Vec3 {
        let l = points.count
        let p = Float(l - 1) * t
        var i = Int(floor(p))
        var weight = p - Float(i)
        if weight == 0 && i == l - 1 { i = l - 2; weight = 1 }
        let p0 = i > 0 ? points[i - 1] : (points[0] - points[1]) + points[0]
        let p1 = points[i], p2 = points[i + 1]
        let p3 = i + 2 < l ? points[i + 2] : (points[l - 1] - points[l - 2]) + points[l - 1]
        var dt0 = pow(simd_distance_squared(p0, p1), 0.25), dt1 = pow(simd_distance_squared(p1, p2), 0.25), dt2 = pow(simd_distance_squared(p2, p3), 0.25)
        if dt1 < 1e-4 { dt1 = 1 }
        if dt0 < 1e-4 { dt0 = dt1 }
        if dt2 < 1e-4 { dt2 = dt1 }
        func axis(_ x0: Float, _ x1: Float, _ x2: Float, _ x3: Float) -> Float {
            var t1 = (x1 - x0) / dt0 - (x2 - x0) / (dt0 + dt1) + (x2 - x1) / dt1
            var t2 = (x2 - x1) / dt1 - (x3 - x1) / (dt1 + dt2) + (x3 - x2) / dt2
            t1 *= dt1; t2 *= dt1
            let c0 = x1, c1 = t1, c2 = -3 * x1 + 3 * x2 - 2 * t1 - t2, c3 = 2 * x1 - 2 * x2 + t1 + t2
            let w = weight
            return c0 + c1 * w + c2 * w * w + c3 * w * w * w
        }
        return Vec3(axis(p0.x, p1.x, p2.x, p3.x), axis(p0.y, p1.y, p2.y, p3.y), axis(p0.z, p1.z, p2.z, p3.z))
    }
}

/// three.js SplineCurve (2D, uniform Catmull-Rom); `points(divisions)` as `getPoints`.
struct Spline2 {
    let points: [Vec2]
    func point(_ t: Float) -> Vec2 {
        let n = points.count
        let p = Float(n - 1) * t
        let i = Int(floor(p)), w = p - Float(i)
        let p0 = points[i == 0 ? i : i - 1], p1 = points[i]
        let p2 = points[i > n - 2 ? n - 1 : i + 1], p3 = points[i > n - 3 ? n - 1 : i + 2]
        func c(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> Float {
            let v0 = (c - a) * 0.5, v1 = (d - b) * 0.5, t2 = w * w, t3 = w * t2
            return (2 * b - 2 * c + v0 + v1) * t3 + (-3 * b + 3 * c - 2 * v0 - v1) * t2 + v0 * w + b
        }
        return Vec2(c(p0.x, p1.x, p2.x, p3.x), c(p0.y, p1.y, p2.y, p3.y))
    }
    func sample(_ divisions: Int) -> [Vec2] { (0...divisions).map { point(Float($0) / Float(divisions)) } }
}

// MARK: - flat outlines (three.js Shape) and extrusion

/// A closed 2D outline built the way three.js Shape is, flattened with its `getPoints(divisions)` rules:
/// straight segments add their end, curves `divisions` steps, arcs twice that.
struct Outline {
    private(set) var points: [Vec2] = []
    private var cursor = Vec2.zero
    let divisions: Int
    init(divisions: Int = 12) { self.divisions = divisions }

    private mutating func add(_ p: Vec2) {
        if let last = points.last, simd_distance(last, p) < 1e-9 { return }
        points.append(p)
    }
    mutating func move(_ x: Float, _ y: Float) { cursor = Vec2(x, y); add(cursor) }
    mutating func line(_ x: Float, _ y: Float) { cursor = Vec2(x, y); add(cursor) }
    mutating func quadratic(_ cx: Float, _ cy: Float, _ x: Float, _ y: Float) {
        let p0 = cursor, c = Vec2(cx, cy), p1 = Vec2(x, y)
        for d in 1...divisions {
            let t = Float(d) / Float(divisions), k = 1 - t
            add(k * k * p0 + 2 * k * t * c + t * t * p1)
        }
        cursor = p1
    }
    /// three.js `absarc`: joins the current point to the arc's start, then follows the arc.
    mutating func arc(_ cx: Float, _ cy: Float, _ r: Float, _ from: Float, _ to: Float, clockwise: Bool) {
        var delta = to - from
        let twoPi = 2 * Float.pi
        if abs(delta) < .ulpOfOne { delta = 0 } else {
            while delta < 0 { delta += twoPi }
            while delta > twoPi { delta -= twoPi }
            if delta < .ulpOfOne { delta = 0 }
        }
        if clockwise && delta != 0 { delta = delta == twoPi ? -twoPi : delta - twoPi }
        let steps = divisions * 2
        for d in 0...steps {
            let a = from + Float(d) / Float(steps) * delta
            add(Vec2(cx + r * cos(a), cy + r * sin(a)))
        }
        if let last = points.last { cursor = last }
    }
    /// The outline closed and without its duplicated end point.
    var closed: [Vec2] {
        var p = points
        if p.count > 2, simd_distance(p[0], p[p.count - 1]) < 1e-6 { p.removeLast() }
        return p
    }
}

enum Extrude {
    static func signedArea(_ p: [Vec2]) -> Float {
        var a: Float = 0
        for i in 0..<p.count { let j = (i + 1) % p.count; a += p[i].x * p[j].y - p[j].x * p[i].y }
        return a / 2
    }

    /// Ear-clipping triangulation of a simple polygon given counter-clockwise; indices into `p`.
    static func triangulate(_ p: [Vec2]) -> [UInt32] {
        var idx = Array(0..<p.count)
        var out: [UInt32] = []
        func cross(_ o: Vec2, _ a: Vec2, _ b: Vec2) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        func inside(_ q: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
            cross(a, b, q) >= 0 && cross(b, c, q) >= 0 && cross(c, a, q) >= 0
        }
        var guardCount = 0
        while idx.count > 3 && guardCount < 100_000 {
            guardCount += 1
            var clipped = false
            for k in 0..<idx.count {
                let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                let a = p[i0], b = p[i1], c = p[i2]
                if cross(a, b, c) <= 1e-12 { continue }
                var ear = true
                for j in idx where j != i0 && j != i1 && j != i2 {
                    if inside(p[j], a, b, c) { ear = false; break }
                }
                if !ear { continue }
                out += [UInt32(i0), UInt32(i1), UInt32(i2)]
                idx.remove(at: k)
                clipped = true
                break
            }
            if !clipped {
                // Degenerate remainder: fan it.
                for k in 1..<(idx.count - 1) { out += [UInt32(idx[0]), UInt32(idx[k]), UInt32(idx[k + 1])] }
                return out
            }
        }
        if idx.count == 3 { out += idx.map { UInt32($0) } }
        return out
    }

    /// ExtrudeGeometry of one outline along +z from 0 to `depth`, optionally bevelled; flat-shaded like
    /// three's non-indexed extrusion. With `uv`, the caps carry the outline's own coordinates as uv.
    static func extrude(_ outline: [Vec2], depth: Float, bevel: (size: Float, thickness: Float, segments: Int)? = nil) -> Geometry {
        var contour = outline
        if signedArea(contour) < 0 { contour.reverse() }
        let n = contour.count
        // Outward 2D normals at each point, for bevelling (averaged edge normals, mitred).
        var outward = [Vec2](repeating: .zero, count: n)
        for i in 0..<n {
            let prev = contour[(i + n - 1) % n], cur = contour[i], next = contour[(i + 1) % n]
            let e1 = simd_normalize(cur - prev), e2 = simd_normalize(next - cur)
            let n1 = Vec2(e1.y, -e1.x), n2 = Vec2(e2.y, -e2.x)
            let m = simd_normalize(n1 + n2)
            outward[i] = m / max(simd_dot(m, n1), 0.25)
        }
        // Rings of the outline at heights: back bevel, the straight wall, front bevel.
        var rings: [(offset: Float, z: Float)] = []
        if let bevel {
            for b in 0...bevel.segments {
                let t = Float(b) / Float(bevel.segments)
                rings.append((bevel.size * sin(t * .pi / 2), -bevel.thickness * cos(t * .pi / 2)))
            }
            for b in 0...bevel.segments {
                let t = Float(b) / Float(bevel.segments)
                rings.append((bevel.size * cos(t * .pi / 2), depth + bevel.thickness * sin(t * .pi / 2)))
            }
        } else {
            rings = [(0, 0), (0, depth)]
        }
        func at(_ ring: Int, _ i: Int) -> Vec3 {
            let p = contour[i] + outward[i] * rings[ring].offset
            return Vec3(p.x, p.y, rings[ring].z)
        }
        var g = Geometry()
        let caps = triangulate(contour)
        // Back cap (facing −z) and front cap (facing +z), at the innermost rings.
        let back = 0, front = rings.count - 1
        for t in stride(from: 0, to: caps.count, by: 3) {
            let a = Int(caps[t]), b = Int(caps[t + 1]), c = Int(caps[t + 2])
            for i in [a, c, b] { g.positions.append(at(back, i)); g.uvs.append(contour[i]) }
            for i in [a, b, c] { g.positions.append(at(front, i)); g.uvs.append(contour[i]) }
        }
        for r in 0..<(rings.count - 1) {
            for i in 0..<n {
                let j = (i + 1) % n
                let a = at(r, i), b = at(r, j), c = at(r + 1, j), d = at(r + 1, i)
                g.positions += [a, b, d, b, c, d]
                g.uvs += [Vec2](repeating: .zero, count: 6)
            }
        }
        g.indices = (0..<UInt32(g.positions.count)).map { $0 }
        g.computeNormals()
        return g
    }
}
