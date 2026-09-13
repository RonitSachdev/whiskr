import Foundation
import QuartzCore
@preconcurrency import Metal
import simd

// Draws cats: the posed skin (re-posed only when its pose changed, per frame in flight), the tail tube,
// eyes, props, the machine's button and steam, and later (transparent pass) shadows and bubbles.

final class CatDrawer {
    private let gpu: GPU
    private let skinIndex: MTLBuffer
    private let skinIndexCount: Int
    private let tailIndex: MTLBuffer
    private let disc: Mesh
    private let props: [Mesh]
    private let button: Mesh
    private(set) var bubbles: [MTLTexture] = []
    /// The red the "needs you" bubble was painted in; the app's theme can change it.
    private var bubbleAlert = MeadowChrome.standard.alert

    /// Each cat's skin buffers, one per frame in flight, and which pose each holds. When posing is shared
    /// across cores each job touches only its own cat's slots.
    private final class Slots: @unchecked Sendable {
        let poser = SkinPoser()
        var buffers: [MTLBuffer]
        var versions: [Int]
        var lastUsed = 0
        init(_ device: MTLDevice, _ inFlight: Int) {
            buffers = (0..<inFlight).map { _ in device.makeBuffer(length: SkinPoser.byteCount, options: .storageModeShared)! }
            versions = [Int](repeating: -1, count: inFlight)
        }
    }
    private var slots: [ObjectIdentifier: Slots] = [:]
    private var jobs: [(Slots, PoseInputs, Int)] = []
    private var frame = 0
    /// Milliseconds spent re-posing skins in the last frame.
    private(set) var poseMilliseconds = 0.0

    init(gpu: GPU) {
        self.gpu = gpu
        let form = Sculpt.shared
        skinIndex = gpu.buffer(form.index, label: "cat skin index")
        skinIndexCount = form.index.count
        tailIndex = gpu.buffer(TAIL_INDEX, label: "tail index")
        disc = gpu.mesh(Props.disc, label: "disc")
        props = PropName.allCases.map { gpu.mesh(Props.mesh($0), label: "prop \($0)") }
        button = gpu.mesh(Props.buttonCap, label: "machine button")
        bubbles = BubbleMark.allCases.map { Paint.bubble(gpu.device, queue: gpu.queue, $0) }
        jobs.reserveCapacity(64)
    }

    /// Writes this frame's skins: every cat whose pose differs from what its buffer for `slot` holds.
    func pose(_ cats: [Cat], slot: Int, inFlight: Int) {
        frame += 1
        let t0 = CACurrentMediaTime()
        jobs.removeAll(keepingCapacity: true)
        for cat in cats {
            let id = ObjectIdentifier(cat)
            let s: Slots
            if let found = slots[id] { s = found } else { s = Slots(gpu.device, inFlight); slots[id] = s }
            s.lastUsed = frame
            if s.versions[slot] != cat.poseVersion {
                s.versions[slot] = cat.poseVersion
                jobs.append((s, cat.posed, slot))
            }
        }
        // A few cats are posed quicker on this thread than handed out; a crowd is shared across cores
        // (libdispatch then allocates a little for the hand-out).
        if jobs.count <= 4 {
            for (s, inputs, slot) in jobs { s.poser.deform(inputs, into: s.buffers[slot].contents()) }
        } else {
            let work = jobs
            DispatchQueue.concurrentPerform(iterations: work.count) { i in
                let (s, inputs, slot) = work[i]
                s.poser.deform(inputs, into: s.buffers[slot].contents())
            }
        }
        poseMilliseconds = (CACurrentMediaTime() - t0) * 1000
        // Forget cats that have gone.
        if frame % 120 == 0 { slots = slots.filter { frame - $0.value.lastUsed < 60 } }
    }

    private func draw(_ mesh: Mesh, _ instances: Int, _ enc: MTLRenderCommandEncoder) {
        enc.setVertexBuffer(mesh.vertices, offset: 0, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0, instanceCount: instances)
    }

    /// The opaque parts of every cat.
    func encodeOpaque(_ cats: [Cat], slot: Int, arena: Arena, enc: MTLRenderCommandEncoder) {
        guard !cats.isEmpty else { return }
        let ink = Vec4(linear(PropMaterial.ink), 1)
        // Skins.
        enc.setRenderPipelineState(gpu.skin)
        enc.setCullMode(.back)
        let skinInst = arena.alloc(ClayInstance.self, cats.count)
        for (i, cat) in cats.enumerated() {
            skinInst.pointer[i] = ClayInstance(cat.bodyMatrix, tint: ink, roughness: 0.6, lit: .warmed)
        }
        enc.setVertexBuffer(skinInst.buffer, offset: skinInst.offset, index: 3)
        for (i, cat) in cats.enumerated() {
            guard let s = slots[ObjectIdentifier(cat)] else { continue }
            enc.setVertexBuffer(s.buffers[slot], offset: 0, index: 1)
            enc.setVertexBufferOffset(skinInst.offset + i * MemoryLayout<ClayInstance>.stride, index: 3)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: skinIndexCount, indexType: .uint32, indexBuffer: skinIndex, indexBufferOffset: 0)
        }
        // Tails: two-sided, rebuilt every frame.
        enc.setRenderPipelineState(gpu.skinTwoSided)
        enc.setCullMode(.none)
        let tailVerts = arena.alloc(Float.self, cats.count * TAIL_VERTS * 6)
        let tailInst = arena.alloc(ClayInstance.self, cats.count)
        for (i, cat) in cats.enumerated() {
            cat.tailVertices.withUnsafeBufferPointer { src in
                (tailVerts.pointer + i * TAIL_VERTS * 6).update(from: src.baseAddress!, count: TAIL_VERTS * 6)
            }
            tailInst.pointer[i] = ClayInstance(cat.bodyMatrix, tint: ink, roughness: 0.6, lit: [.warmed, .twoSided])
        }
        for i in 0..<cats.count {
            enc.setVertexBuffer(tailVerts.buffer, offset: tailVerts.offset + i * TAIL_VERTS * 24, index: 1)
            enc.setVertexBuffer(tailInst.buffer, offset: tailInst.offset + i * MemoryLayout<ClayInstance>.stride, index: 3)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: TAIL_INDEX.count, indexType: .uint32, indexBuffer: tailIndex, indexBufferOffset: 0)
        }
        enc.setCullMode(.back)
        enc.setRenderPipelineState(gpu.clay)
        // Eyes: whites unlit, pupils in clay.
        let eyes = arena.alloc(ClayInstance.self, cats.count * 4)
        for (i, cat) in cats.enumerated() {
            eyes.pointer[i * 2] = ClayInstance(cat.eyeWhites.0, lit: .unlit)
            eyes.pointer[i * 2 + 1] = ClayInstance(cat.eyeWhites.1, lit: .unlit)
            eyes.pointer[cats.count * 2 + i * 2] = ClayInstance(cat.pupils.0, tint: ink, roughness: 0.6, lit: .warmed)
            eyes.pointer[cats.count * 2 + i * 2 + 1] = ClayInstance(cat.pupils.1, tint: ink, roughness: 0.6, lit: .warmed)
        }
        enc.setVertexBuffer(eyes.buffer, offset: eyes.offset, index: 3)
        draw(disc, cats.count * 4, enc)
        // Props, each where its cat holds it.
        for prop in PropName.allCases {
            var n = 0
            for cat in cats where cat.propScale[prop.rawValue] > 0.01 { n += 1 }
            if n == 0 { continue }
            let inst = arena.alloc(ClayInstance.self, n)
            var k = 0
            for cat in cats where cat.propScale[prop.rawValue] > 0.01 {
                inst.pointer[k] = ClayInstance(cat.propMatrix[prop.rawValue], lit: .warmed)
                k += 1
            }
            enc.setVertexBuffer(inst.buffer, offset: inst.offset, index: 3)
            draw(props[prop.rawValue], n, enc)
            if prop == .machine {
                let b = arena.alloc(ClayInstance.self, n)
                k = 0
                for cat in cats where cat.propScale[prop.rawValue] > 0.01 {
                    let s = cat.propScale[prop.rawValue]
                    b.pointer[k] = ClayInstance(cat.rootMatrix * .scale(s) * .translation(Props.button - Vec3(0, cat.buttonDepth, 0)), lit: .warmed)
                    k += 1
                }
                enc.setVertexBuffer(b.buffer, offset: b.offset, index: 3)
                draw(button, n, enc)
            }
        }
    }

    /// Blob shadows, drawn over the ground before anything see-through.
    func encodeShadows(_ cats: [Cat], arena: Arena, enc: MTLRenderCommandEncoder) {
        guard !cats.isEmpty else { return }
        enc.setRenderPipelineState(gpu.shadow)
        let inst = arena.alloc(ShadowInstance.self, cats.count)
        for (i, cat) in cats.enumerated() { inst.pointer[i] = ShadowInstance(model: cat.shadowMatrix, extra: Vec4(cat.shadowOpacity, 0, 0, 0)) }
        enc.setVertexBuffer(inst.buffer, offset: inst.offset, index: 3)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cats.count)
    }

    /// Steam puffs from the machines (see-through, unlit).
    func encodeSteam(_ cats: [Cat], arena: Arena, enc: MTLRenderCommandEncoder) {
        var n = 0
        for cat in cats where cat.propScale[PropName.machine.rawValue] > 0.01 { for a in cat.steamAlpha where a > 0 { _ = a; n += 1 } }
        if n == 0 { return }
        let inst = arena.alloc(ClayInstance.self, n)
        var k = 0
        let puff = linear(0xd8d3c9)
        for cat in cats where cat.propScale[PropName.machine.rawValue] > 0.01 {
            let base = cat.rootMatrix * .scale(cat.propScale[PropName.machine.rawValue])
            for i in 0..<6 where cat.steamAlpha[i] > 0 {
                let s = cat.steam[i]
                inst.pointer[k] = ClayInstance(base * .translation(Vec3(s.x, s.y, s.z)) * .scale(s.w), tint: Vec4(puff, cat.steamAlpha[i]), lit: .unlit)
                k += 1
            }
        }
        enc.setRenderPipelineState(gpu.clayBlend)
        enc.setDepthStencilState(gpu.depthRead)
        enc.setVertexBuffer(inst.buffer, offset: inst.offset, index: 3)
        draw(disc, n, enc)
    }

    /// The smallest a bubble sprite is drawn, in points: its disc is then about 19 pt across with an 11 pt
    /// glyph, readable on a cat in a sidebar (macOS's smallest text is 10 pt).
    static let smallestBubble: Float = 28
    /// The bubble's disc across, as a share of its sprite (`Paint.bubble`).
    static let bubbleDisc: Float = 176.0 / 256

    /// Bubbles above heads: sprites, one draw per symbol in use, where and as large as `Cat.bubbleDrawn`
    /// says (the village keeps them readable, beside the face and off the flags).
    func encodeBubbles(_ cats: [Cat], alert: MeadowColor = MeadowChrome.standard.alert, arena: Arena, enc: MTLRenderCommandEncoder) {
        if alert != bubbleAlert {
            bubbleAlert = alert
            bubbles[BubbleMark.needsYou.rawValue] = Paint.bubble(gpu.device, queue: gpu.queue, .needsYou, alert: alert)
            bubbles[BubbleMark.error.rawValue] = Paint.bubble(gpu.device, queue: gpu.queue, .error, alert: alert)
        }
        enc.setRenderPipelineState(gpu.sprite)
        for mark in BubbleMark.allCases {
            var n = 0
            for cat in cats where cat.bubbleShown && cat.bubbleMark == mark { n += 1 }
            if n == 0 { continue }
            let inst = arena.alloc(SpriteInstance.self, n)
            var k = 0
            for cat in cats where cat.bubbleShown && cat.bubbleMark == mark {
                let b = cat.bubbleDrawn
                inst.pointer[k] = SpriteInstance(at: Vec4(b.x, b.y, b.z, 1), size: Vec4(b.w, b.w, 0.5, 0.5), tint: Vec4(1, 1, 1, 1), uv: Vec4(0, 0, 1, 1))
                k += 1
            }
            enc.setVertexBuffer(inst.buffer, offset: inst.offset, index: 1)
            enc.setFragmentTexture(bubbles[mark.rawValue], index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: n)
        }
    }
}
