import Foundation
import simd

// Small maths shared by every part of the scene. Matrices are column-major (simd), right-handed, y up,
// as in three.js; projection maps depth to Metal's 0…1.

public typealias Vec2 = SIMD2<Float>
public typealias Vec3 = SIMD3<Float>
public typealias Vec4 = SIMD4<Float>
public typealias Mat4 = simd_float4x4

@inline(__always) func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T { min(max(x, lo), hi) }
@inline(__always) func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inline(__always) func lerp(_ a: Vec3, _ b: Vec3, _ t: Float) -> Vec3 { a + (b - a) * t }

/// three.js `MathUtils.smoothstep(x, min, max)` argument order.
@inline(__always) public func smoothstep(_ x: Float, _ e0: Float, _ e1: Float) -> Float {
    if x <= e0 { return 0 }
    if x >= e1 { return 1 }
    let t = (x - e0) / (e1 - e0)
    return t * t * (3 - 2 * t)
}

/// kit.ts `smooth`: a clamped smoothstep over 0…1.
@inline(__always) public func smooth(_ t: Double) -> Double {
    let c = min(1, max(0, t))
    return c * c * (3 - 2 * c)
}
@inline(__always) public func smooth(_ t: Float) -> Float {
    let c = min(1, max(0, t))
    return c * c * (3 - 2 * c)
}

/// The shortest way round from one compass angle to another, in radians.
@inline(__always) func turnFrom(_ from: Float, _ to: Float) -> Float { atan2(sin(to - from), cos(to - from)) }

@inline(__always) func euclideanModulo(_ n: Float, _ m: Float) -> Float { ((n.truncatingRemainder(dividingBy: m)) + m).truncatingRemainder(dividingBy: m) }

extension Mat4 {
    static let identity = matrix_identity_float4x4

    static func translation(_ v: Vec3) -> Mat4 {
        var m = matrix_identity_float4x4
        m.columns.3 = Vec4(v, 1)
        return m
    }
    static func scale(_ v: Vec3) -> Mat4 { Mat4(diagonal: Vec4(v, 1)) }
    static func scale(_ s: Float) -> Mat4 { Mat4(diagonal: Vec4(s, s, s, 1)) }
    static func rotationX(_ a: Float) -> Mat4 {
        let c = cos(a), s = sin(a)
        return Mat4(columns: (Vec4(1, 0, 0, 0), Vec4(0, c, s, 0), Vec4(0, -s, c, 0), Vec4(0, 0, 0, 1)))
    }
    static func rotationY(_ a: Float) -> Mat4 {
        let c = cos(a), s = sin(a)
        return Mat4(columns: (Vec4(c, 0, -s, 0), Vec4(0, 1, 0, 0), Vec4(s, 0, c, 0), Vec4(0, 0, 0, 1)))
    }
    static func rotationZ(_ a: Float) -> Mat4 {
        let c = cos(a), s = sin(a)
        return Mat4(columns: (Vec4(c, s, 0, 0), Vec4(-s, c, 0, 0), Vec4(0, 0, 1, 0), Vec4(0, 0, 0, 1)))
    }
    /// three.js Euler in the default 'XYZ' order: R = Rx · Ry · Rz.
    static func euler(_ x: Float, _ y: Float, _ z: Float) -> Mat4 { rotationX(x) * rotationY(y) * rotationZ(z) }
    /// three.js Euler order 'YXZ' (the cat's face group): R = Ry · Rx · Rz.
    static func eulerYXZ(_ x: Float, _ y: Float, _ z: Float) -> Mat4 { rotationY(y) * rotationX(x) * rotationZ(z) }

    /// three.js Matrix4.compose(position, quaternion-from-euler-XYZ, scale).
    static func compose(_ p: Vec3, euler e: Vec3 = .zero, scale s: Vec3 = Vec3(1, 1, 1)) -> Mat4 {
        translation(p) * euler(e.x, e.y, e.z) * scale(s)
    }

    /// Perspective with a vertical field of view, depth 0…1 (Metal).
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> Mat4 {
        let y = 1 / tan(fovY / 2), x = y / aspect, z = far / (near - far)
        return Mat4(columns: (Vec4(x, 0, 0, 0), Vec4(0, y, 0, 0), Vec4(0, 0, z, -1), Vec4(0, 0, z * near, 0)))
    }

    static func lookAt(eye: Vec3, target: Vec3, up: Vec3 = Vec3(0, 1, 0)) -> Mat4 {
        let z = simd_normalize(eye - target)
        var x = simd_cross(up, z)
        if simd_length_squared(x) < 1e-12 { x = Vec3(1, 0, 0) }
        x = simd_normalize(x)
        let y = simd_cross(z, x)
        return Mat4(columns: (Vec4(x.x, y.x, z.x, 0), Vec4(x.y, y.y, z.y, 0), Vec4(x.z, y.z, z.z, 0),
                              Vec4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
    }

    @inline(__always) func point(_ p: Vec3) -> Vec3 {
        let r = self * Vec4(p, 1)
        return Vec3(r.x, r.y, r.z) / r.w
    }
    @inline(__always) func direction(_ v: Vec3) -> Vec3 {
        let r = self * Vec4(v, 0)
        return Vec3(r.x, r.y, r.z)
    }
    var position: Vec3 { Vec3(columns.3.x, columns.3.y, columns.3.z) }
    /// The normal matrix for this transform (inverse transpose of the upper 3×3).
    var normalMatrix: simd_float3x3 {
        let m = simd_float3x3(Vec3(columns.0.x, columns.0.y, columns.0.z), Vec3(columns.1.x, columns.1.y, columns.1.z),
                              Vec3(columns.2.x, columns.2.y, columns.2.z))
        return m.inverse.transpose
    }
}

/// Unit quaternion turning `from` onto `to` (three.js Quaternion.setFromUnitVectors).
func quaternion(from: Vec3, to: Vec3) -> simd_quatf { simd_quatf(from: from, to: to) }

/// sRGB hex to linear, as three.js Color.set(hex) does with colour management on.
public func linear(_ hex: UInt32) -> Vec3 {
    func c(_ v: UInt32) -> Float {
        let s = Float(v) / 255
        return s < 0.04045 ? s * 0.0773993808 : pow(s * 0.9478672986 + 0.0521327014, 2.4)
    }
    return Vec3(c((hex >> 16) & 255), c((hex >> 8) & 255), c(hex & 255))
}

/// A sphere: something the camera must keep in view, or a pick target.
struct Ball { var center: Vec3; var radius: Float }
