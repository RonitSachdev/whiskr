import Foundation

// Port of kit.ts randomness and noise, and scatter.ts `chance`. Doubles on purpose: the web version runs
// this in JavaScript doubles, and the same seed has to grow the same meadow.

/// mulberry32, exactly as `seeded()` in kit.ts.
public struct Seeded: Sendable {
    private var a: UInt32
    public init(_ seed: UInt32) { a = seed }
    /// Where the stream stands: `Seeded(state)` goes on exactly as this one does (a tree's seed is the
    /// state it was grown from).
    var state: UInt32 { a }
    public mutating func next() -> Double {
        a = a &+ 0x6d2b_79f5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
    public mutating func float() -> Float { Float(next()) }
}

/// scatter.ts `chance(name)`: FNV-1a over the UTF-16 code units of the name, then mulberry32. The same
/// name always gives the same stream, so nothing jumps about when something else arrives.
public func chance(_ name: String) -> Seeded {
    var seed: UInt32 = 2_166_136_261
    for unit in name.utf16 { seed = (seed ^ UInt32(unit)) &* 16_777_619 }
    return Seeded(seed)
}

@inline(__always) func lattice(_ x: Double, _ z: Double, _ seed: Double) -> Double {
    let s = sin(x * 127.1 + z * 311.7 + seed * 74.7) * 43758.5453
    return s - floor(s)
}

/// With seed 0 this is the same noise the meadow's shaders use, so code can ask what the wind is doing.
public func noise(_ x: Double, _ z: Double, _ seed: Double) -> Double {
    let ix = floor(x), iz = floor(z)
    let fx = smooth(x - ix), fz = smooth(z - iz)
    let near = lattice(ix, iz, seed) * (1 - fx) + lattice(ix + 1, iz, seed) * fx
    let far = lattice(ix, iz + 1, seed) * (1 - fx) + lattice(ix + 1, iz + 1, seed) * fx
    return near * (1 - fz) + far * fz
}

/// Soft, cloudy noise in 0…1: three layers of detail.
public func fbm(_ x: Double, _ z: Double, _ seed: Double) -> Double {
    noise(x, z, seed) * 0.6 + noise(x * 2.1, z * 2.1, seed + 1) * 0.28 + noise(x * 4.3, z * 4.3, seed + 2) * 0.12
}

/// The shaders' lattice hash (ShaderCommon `mHash`), for asking on the CPU what they show.
public func latticeHash(_ x: Double, _ z: Double) -> Double {
    let ix = Int32(truncatingIfNeeded: Int(floor(x))), iz = Int32(truncatingIfNeeded: Int(floor(z)))
    var h = (UInt32(bitPattern: ix) &* 0x8da6_b343) ^ (UInt32(bitPattern: iz) &* 0xd816_3841)
    h = (h ^ (h >> 16)) &* 0x7feb_352d
    h = (h ^ (h >> 15)) &* 0x846c_a68b
    h ^= h >> 16
    return Double(h) / 4_294_967_296
}

/// The shaders' value noise (`mNoise`): the wind's gusts are this, so a cat can feel the gust the grass shows.
public func shaderNoise(_ x: Double, _ z: Double) -> Double {
    let ix = floor(x), iz = floor(z)
    let fx = smooth(x - ix), fz = smooth(z - iz)
    let near = latticeHash(ix, iz) * (1 - fx) + latticeHash(ix + 1, iz) * fx
    let far = latticeHash(ix, iz + 1) * (1 - fx) + latticeHash(ix + 1, iz + 1) * fx
    return near * (1 - fz) + far * fz
}

/// Meadow.ts: the middle is level so blankets lie flat; the land only starts to roll well outside it.
public enum Land {
    public static let level = 70.0      // radius kept flat for sessions
    public static let ground = -0.03    // a hair under y = 0, so blankets and cat shadows sit cleanly on top
    public static func height(_ x: Double, _ z: Double) -> Double {
        let out = hypot(x, z) - level
        return ground + smooth(out / 70) * (fbm(x / 90, z / 90, 3) * 16 + out * 0.03)
    }
    public static func height(_ x: Float, _ z: Float) -> Float { Float(height(Double(x), Double(z))) }

    // However many blankets there are and wherever they are laid (a sidebar's column runs far past the
    // level middle), each lies on level ground: within `flat` of a blanket's edge the land is brought down
    // to `ground`, easing back to its own lie over `blend` beyond. The same rule runs in the shaders
    // (`levelAt`) for the ground, the grass and the plants; here for what stands on the land as a whole.
    static let flat: Float = 6
    static let blend: Float = 14
    /// How far the land at (x, z) is levelled, 0…1, by the blankets' clearings (x, z, radius).
    static func level(_ x: Float, _ z: Float, _ clearings: [Vec4], _ count: Int) -> Float {
        var k: Float = 0
        for i in 0..<min(count, clearings.count) {
            let c = clearings[i]
            k = max(k, 1 - smoothstep(hypot(x - c.x, z - c.y) - max(c.z, 0), flat, flat + blend))
        }
        return k
    }
    /// A point standing on the land, moved down (or up) with it where it is levelled.
    static func levelled(_ p: Vec3, _ clearings: [Vec4], _ count: Int) -> Vec3 {
        let k = level(p.x, p.z, clearings, count)
        return k == 0 ? p : Vec3(p.x, p.y + (Float(ground) - height(p.x, p.z)) * k, p.z)
    }
}
