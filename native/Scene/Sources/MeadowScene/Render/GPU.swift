import Foundation
import QuartzCore
@preconcurrency import Metal
import simd

// What every frame is drawn with: the device, the compiled shaders and their pipeline states, the
// static meshes, and a scratch arena per frame in flight.

/// Per-frame uniforms; must match `struct Frame` in ShaderCommon.
struct FrameUniforms {
    var viewProj = Mat4.identity
    var view = Mat4.identity
    var proj = Mat4.identity
    var invViewProj = Mat4.identity
    var eye = Vec4.zero
    var fog = Vec4.zero
    var counts = Vec4.zero
    var hemiSky = Vec4.zero, hemiGround = Vec4.zero
    var keyColor = Vec4.zero, keyDir = Vec4.zero
    var rimColor = Vec4.zero, rimDir = Vec4.zero
    var turfLow = Vec4.zero, turfHigh = Vec4.zero
    var horizon = Vec4.zero, skyTop = Vec4.zero, skyMid = Vec4.zero
    var viewport = Vec4.zero
    var sky2 = Vec4.zero
    var camRight = Vec4.zero, camUp = Vec4.zero
    /// The wind: which way it blows (x, z) and how far its gusts have travelled (`Stage.gustDrift`).
    var wind = Vec4.zero
    /// How much of a gust's push stays between gusts, the lightning's flash, unused, unused.
    var weather = Vec4.zero
}

let MAX_CLEARINGS = 48
let MAX_STREAMS = 4

/// Must match `struct World` in ShaderCommon.
struct WorldUniforms {
    var clearings = [Vec4](repeating: Vec4(0, 0, -100, 0), count: MAX_CLEARINGS)
    var patches = [Vec4](repeating: .zero, count: MAX_CLEARINGS)
    var streams = [Vec4](repeating: .zero, count: MAX_STREAMS)
    var paths = [Vec4](repeating: .zero, count: MAX_TRODDEN)
    static var byteCount: Int { (MAX_CLEARINGS * 2 + MAX_STREAMS + MAX_TRODDEN) * 16 }
    func write(to p: UnsafeMutableRawPointer) {
        var o = p
        func put(_ list: [Vec4]) {
            list.withUnsafeBytes { o.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            o += list.count * 16
        }
        put(clearings); put(patches); put(streams); put(paths)
    }
}

/// Must match `struct Instance` in ShaderClay.
struct ClayInstance {
    var model: Mat4
    var tint: Vec4
    var emissive: Vec4
    var extra: Vec4
    var info: SIMD4<UInt32>
    init(_ model: Mat4, tint: Vec4 = Vec4(1, 1, 1, 1), emissive: Vec3 = .zero, sway: Float = 0, roughness: Float = -1, lit: Lit) {
        self.model = model
        self.tint = tint
        self.emissive = Vec4(emissive, 0)
        self.extra = Vec4(sway, roughness, 0, 0)
        self.info = SIMD4(lit.rawValue, 0, 0, 0)
    }
}

/// How a clay instance is lit (bits of `info.x`, see ShaderClay).
struct Lit: OptionSet {
    let rawValue: UInt32
    static let unlit = Lit(rawValue: 1)
    static let shaded = Lit(rawValue: 2)
    static let warmed = Lit(rawValue: 4)
    static let rooted = Lit(rawValue: 8)
    static let twoSided = Lit(rawValue: 16)
    static let lambert = Lit(rawValue: 32)
    static let noFog = Lit(rawValue: 64)
    static let glow = Lit(rawValue: 128)
    static let gingham = Lit(rawValue: 256)
    /// The moon: lit from the direction in `emissive` (its phase), the dark side see-through.
    static let moon = Lit(rawValue: 512)
}

/// Must match `struct Sprite` in ShaderOverlay.
struct SpriteInstance {
    var at: Vec4
    var size: Vec4
    var tint: Vec4
    var uv: Vec4
}

struct ShadowInstance { var model: Mat4; var extra: Vec4 }

/// A static mesh on the GPU.
struct Mesh {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int
    let bounds: (min: Vec3, max: Vec3)
}

/// A bump allocator over one shared buffer, reset at the start of the frame that owns it.
final class Arena {
    private(set) var buffer: MTLBuffer
    private var used = 0
    private let device: MTLDevice
    init(device: MTLDevice, size: Int) {
        self.device = device
        buffer = device.makeBuffer(length: size, options: .storageModeShared)!
        buffer.label = "frame arena"
    }
    func reset() { used = 0 }
    /// Room for `count` values of `T`, aligned for the GPU. Grows (once, rarely) if a frame needs more.
    func alloc<T>(_ type: T.Type, _ count: Int) -> (buffer: MTLBuffer, offset: Int, pointer: UnsafeMutablePointer<T>) {
        let bytes = max(MemoryLayout<T>.stride * count, 16)
        let offset = (used + 255) & ~255
        if offset + bytes > buffer.length {
            // Keep the old buffer alive for anything already encoded this frame by retaining it in a list.
            retired.append(buffer)
            buffer = device.makeBuffer(length: max(buffer.length * 2, offset + bytes), options: .storageModeShared)!
            used = 0
            return alloc(type, count)
        }
        used = offset + bytes
        return (buffer, offset, (buffer.contents() + offset).bindMemory(to: T.self, capacity: count))
    }
    private var retired: [MTLBuffer] = []
    func releaseRetired() { retired.removeAll(keepingCapacity: true) }
}

final class GPU {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let colorFormat: MTLPixelFormat
    let sampleCount: Int
    let compileMilliseconds: Double

    let clay, clayBlend, clayDepth, clayFade, skin, skinTwoSided: MTLRenderPipelineState
    let shadow, halo, sky, ground, grass, water, stars, sprite, glow, firefly: MTLRenderPipelineState
    let depthWrite, depthRead, depthEqual, depthNone: MTLDepthStencilState
    let rootKernel: MTLComputePipelineState
    /// Bound where a shader declares a buffer it does not read for this draw.
    let placeholder: MTLBuffer
    /// Bound where the ground's map (`GroundMap`) would be, with no meadow: nothing painted, shaded or lit.
    let blankGroundMap: MTLTexture

    init(device: MTLDevice, colorFormat: MTLPixelFormat = .bgra8Unorm_srgb, sampleCount: Int = 4) throws {
        self.device = device
        self.colorFormat = colorFormat
        self.sampleCount = sampleCount
        queue = device.makeCommandQueue()!
        queue.label = "meadow"
        let t0 = CACurrentMediaTime()
        let library = try device.makeLibrary(source: ShaderSource.all, options: Self.compileOptions)
        self.library = library
        compileMilliseconds = (CACurrentMediaTime() - t0) * 1000

        enum Blend { case none, alpha, premultiplied, additive }
        func pipe(_ v: String, _ f: String?, blend: Blend = .none, colorWrite: Bool = true, label: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = label
            d.vertexFunction = library.makeFunction(name: v)
            d.fragmentFunction = f.flatMap { library.makeFunction(name: $0) }
            d.rasterSampleCount = sampleCount
            d.colorAttachments[0].pixelFormat = colorFormat
            d.depthAttachmentPixelFormat = .depth32Float
            if !colorWrite { d.colorAttachments[0].writeMask = [] }
            let c = d.colorAttachments[0]!
            switch blend {
            case .none: break
            case .alpha:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .sourceAlpha; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .premultiplied:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .additive:
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        clay = try pipe("clayVertex", "clayFragment", label: "clay")
        clayBlend = try pipe("clayVertex", "clayFragment", blend: .alpha, label: "clay blended")
        clayDepth = try pipe("clayVertex", nil, colorWrite: false, label: "clay depth only")
        clayFade = try pipe("clayVertex", "clayFragment", blend: .alpha, label: "clay faded")
        skin = try pipe("skinVertex", "clayFragment", label: "cat skin")
        skinTwoSided = try pipe("skinVertex", "clayFragment", label: "cat tail")
        shadow = try pipe("shadowVertex", "shadowFragment", blend: .alpha, label: "blob shadow")
        halo = try pipe("haloVertex", "haloFragment", blend: .alpha, label: "chosen cat's halo")
        sky = try pipe("skyVertex", "skyFragment", label: "sky")
        ground = try pipe("groundVertex", "groundFragment", label: "ground")
        grass = try pipe("grassVertex", "grassFragment", label: "grass")
        water = try pipe("waterVertex", "waterFragment", label: "water")
        stars = try pipe("starVertex", "starFragment", blend: .alpha, label: "stars")
        sprite = try pipe("spriteVertex", "spriteFragment", blend: .premultiplied, label: "sprite")
        glow = try pipe("spriteVertex", "glowFragment", blend: .additive, label: "glow")
        firefly = try pipe("fireflyVertex", "fireflyFragment", blend: .additive, label: "firefly")

        rootKernel = try device.makeComputePipelineState(function: library.makeFunction(name: "rootKernel")!)
        placeholder = device.makeBuffer(length: 256, options: .storageModeShared)!
        let blank = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        blank.usage = .shaderRead
        blank.storageMode = .shared
        blankGroundMap = device.makeTexture(descriptor: blank)!
        blankGroundMap.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4), bytesPerRow: 4)
        blankGroundMap.label = "no ground map"

        func depth(_ compare: MTLCompareFunction, _ write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthWrite = depth(.less, true)
        depthRead = depth(.lessEqual, false)
        depthEqual = depth(.lessEqual, false)
        depthNone = depth(.always, false)
    }

    private static var compileOptions: MTLCompileOptions {
        let o = MTLCompileOptions()
        o.mathMode = .fast
        return o
    }

    func buffer<T>(_ array: [T], label: String? = nil) -> MTLBuffer {
        let b = array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 16), options: .storageModeShared)! }
        b.label = label
        return b
    }

    /// Uploads a clay mesh: position, normal, colour and roughness interleaved (40 bytes a vertex).
    func mesh(_ g: Geometry, label: String) -> Mesh {
        var data = [Float]()
        data.reserveCapacity(g.count * 10)
        for i in 0..<g.count {
            let p = g.positions[i]
            let n = g.normals.isEmpty ? Vec3(0, 1, 0) : g.normals[i]
            let c = g.colors.isEmpty ? Vec3(1, 1, 1) : g.colors[i]
            let r = g.roughness.isEmpty ? 0.8 : g.roughness[i]
            data += [p.x, p.y, p.z, n.x, n.y, n.z, c.x, c.y, c.z, r]
        }
        return Mesh(vertices: buffer(data, label: label), indices: buffer(g.indices, label: label), indexCount: g.indices.count, bounds: g.bounds)
    }
}
