import Foundation
import simd

// The posing half of Cat.ts: `pose()` (ears, arms, head turn bent out of the rest sculpt) and
// `computeVertexNormals()`, from the spike's CatSkin. Written straight into a GPU buffer.

/// The 13 numbers a pose is made of, the same inputs `Cat.pose()` reads.
struct PoseInputs: Equatable {
    var yaw: Float = 0, pitch: Float = 0, roll: Float = 0
    var earFlat: Float = 0, earPerk: Float = 0, flickL: Float = 0, flickR: Float = 0
    var pushL = ARM_REST[0], pushR = ARM_REST[1]

    /// Cat.ts skips re-posing when every input moved less than this.
    func close(to o: PoseInputs) -> Bool {
        let e: Float = 2e-4
        return abs(yaw - o.yaw) < e && abs(pitch - o.pitch) < e && abs(roll - o.roll) < e && abs(earFlat - o.earFlat) < e
            && abs(earPerk - o.earPerk) < e && abs(flickL - o.flickL) < e && abs(flickR - o.flickR) < e
            && simd_reduce_max(simd_abs(pushL - o.pushL)) < e && simd_reduce_max(simd_abs(pushR - o.pushR)) < e
    }
}

/// Bends the shared sculpt into one pose. Interleaved float3 position + float3 normal, 24 bytes a vertex.
final class SkinPoser: @unchecked Sendable {
    static let vertexStride = 24
    static var vertexCount: Int { Sculpt.shared.count }
    static var byteCount: Int { vertexCount * vertexStride }

    private let form = Sculpt.shared
    private var pos: [Vec3]
    private var nrm: [Vec3]
    private static let earVerts: [Int32] = {
        let f = Sculpt.shared
        return (0..<f.count).filter { f.earPull[0][$0] != 0 || f.earPull[1][$0] != 0 }.map(Int32.init)
    }()
    private static let armVerts: [Int32] = {
        let f = Sculpt.shared
        return (0..<f.count).filter { f.armPull[0][$0] != 0 || f.armPull[1][$0] != 0 }.map(Int32.init)
    }()

    init() {
        pos = form.rest
        nrm = [Vec3](repeating: .zero, count: form.count)
    }

    func deform(_ p: PoseInputs, into out: UnsafeMutableRawPointer) {
        let f = form
        let count = f.count
        pos.withUnsafeMutableBufferPointer { P in
            f.rest.withUnsafeBufferPointer { R in
                for i in 0..<count { P[i] = R[i]; P[i].y -= PIVOT }
                f.earPull[0].withUnsafeBufferPointer { eL in
                    f.earPull[1].withUnsafeBufferPointer { eR in
                        for v in Self.earVerts {
                            let i = Int(v), l = eL[i], r = eR[i]
                            P[i].x += (r - l) * p.earFlat * 0.22 + (r * p.flickR - l * p.flickL) * 0.16
                            P[i].y -= (l + r) * p.earFlat * 0.26
                            P[i].z += (l * p.flickL + r * p.flickR) * 0.1 + (l + r) * p.earPerk * 0.1
                        }
                    }
                }
                f.armPull[0].withUnsafeBufferPointer { aL in
                    f.armPull[1].withUnsafeBufferPointer { aR in
                        for v in Self.armVerts {
                            let i = Int(v)
                            P[i] += aL[i] * p.pushL + aR[i] * p.pushR
                        }
                    }
                }
                f.turn.withUnsafeBufferPointer { T in
                    // Head tilt first, then nod, then turn: the same order the face group applies them in.
                    // Full-weight vertices share one rotation; only the neck blend needs its own trig.
                    let cr = cos(p.roll), sr = sin(p.roll), ca = cos(p.pitch), sa = sin(p.pitch), cb = cos(p.yaw), sb = sin(p.yaw)
                    for i in 0..<count {
                        let w = T[i]
                        if w == 0 { P[i].y += PIVOT; continue }
                        var CR = cr, SR = sr, CA = ca, SA = sa, CB = cb, SB = sb
                        if w != 1 {
                            let r = p.roll * w, a = p.pitch * w, b = p.yaw * w
                            CR = cos(r); SR = sin(r); CA = cos(a); SA = sin(a); CB = cos(b); SB = sin(b)
                        }
                        let x = P[i].x, y = P[i].y, z = P[i].z
                        let x0 = x * CR - y * SR, y0 = x * SR + y * CR
                        let y1 = y0 * CA - z * SA, z1 = y0 * SA + z * CA
                        P[i] = Vec3(x0 * CB + z1 * SB, y1 + PIVOT, -x0 * SB + z1 * CB)
                    }
                }
            }
            // computeVertexNormals: area-weighted face normals, (c−b)×(a−b) as three.js does.
            nrm.withUnsafeMutableBufferPointer { N in
                for i in 0..<count { N[i] = .zero }
                f.index.withUnsafeBufferPointer { I in
                    var t = 0
                    while t < I.count {
                        let ia = Int(I[t]), ib = Int(I[t + 1]), ic = Int(I[t + 2])
                        let b = P[ib]
                        let n = simd_cross(P[ic] - b, P[ia] - b)
                        N[ia] += n; N[ib] += n; N[ic] += n
                        t += 3
                    }
                }
                let o = out.assumingMemoryBound(to: Float.self)
                for i in 0..<count {
                    let n = simd_normalize(N[i])
                    let q = P[i]
                    let k = i * 6
                    o[k] = q.x; o[k + 1] = q.y; o[k + 2] = q.z
                    o[k + 3] = n.x; o[k + 4] = n.y; o[k + 5] = n.z
                }
            }
        }
    }

    /// The posed position of one vertex, for tests against values captured from the TypeScript.
    static func posedVertex(_ i: Int, _ p: PoseInputs) -> Vec3 {
        let f = Sculpt.shared
        var v = f.rest[i]
        v.y -= PIVOT
        let l = f.earPull[0][i], r = f.earPull[1][i]
        v.x += (r - l) * p.earFlat * 0.22 + (r * p.flickR - l * p.flickL) * 0.16
        v.y -= (l + r) * p.earFlat * 0.26
        v.z += (l * p.flickL + r * p.flickR) * 0.1 + (l + r) * p.earPerk * 0.1
        v += f.armPull[0][i] * p.pushL + f.armPull[1][i] * p.pushR
        let w = f.turn[i]
        let rr = p.roll * w, a = p.pitch * w, b = p.yaw * w
        let x0 = v.x * cos(rr) - v.y * sin(rr), y0 = v.x * sin(rr) + v.y * cos(rr)
        let y1 = y0 * cos(a) - v.z * sin(a), z1 = y0 * sin(a) + v.z * cos(a)
        return Vec3(x0 * cos(b) + z1 * sin(b), y1 + PIVOT, -x0 * sin(b) + z1 * cos(b))
    }
}
