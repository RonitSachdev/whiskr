import AppKit
import Darwin
import Foundation
import Testing
@_spi(Diagnostics) @testable import MeadowScene

// Looks: frames drawn offscreen against reference images (Fixtures/ref-*.png, made with
// `MeadowDemo --shot … --size 320x200` and copied in). Rendering is deterministic, so any visible change
// is a regression or a deliberate change whose reference is then remade.
// Frames: the scene's own per-frame work allocates nothing once running.

@MainActor
enum Scenes {
    static func office() -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "mac", name: "This Mac", spaces: [MeadowSpace(id: "all", name: "all", blankets: [
            MeadowBlanket(id: "office", title: "Three.js agent office visualization", color: .account(0), agents: [
                MeadowAgent(id: "main", activity: .supervising), MeadowAgent(id: "a6f6d2315fad607ad", parentID: "main", activity: .running),
            ]),
        ])])])
    }
    static func busy() -> MeadowWorld {
        var agents = [MeadowAgent(id: "main", activity: .supervising)]
        for k in 1...12 { agents.append(MeadowAgent(id: "h\(k)", parentID: k > 6 ? "h1" : "main", activity: AgentActivity.allCases[k % 11])) }
        let blankets = (0..<6).map { MeadowBlanket(id: "b\($0)", title: "Blanket \($0)", color: .account($0), agents: $0 == 0 ? agents : [MeadowAgent(id: "main", activity: .napping)],
                                                   lanterns: [MeadowLantern(id: "l", title: "dev")]) }
        return MeadowWorld(machines: [MeadowMachine(id: "mac", name: "This Mac", spaces: [MeadowSpace(id: "s", name: "s", blankets: blankets)])])
    }

    /// The demo's `--shot`: settle, advance, draw at 2×.
    static func shot(_ world: MeadowWorld, mode: MeadowView.Mode = .meadow, time: MeadowSettings.TimeOfDay = .day, after: Double) -> CGImage? {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), mode: mode)
        // The moon's phase left out: it would make tonight's frame differ from tomorrow's.
        view.settings = MeadowSettings(timeOfDay: time, effects: MeadowSettings.Effects.all.subtracting(.moonPhase))
        view.world = world
        if mode == .meadow {
            view.advance(seconds: 0.5)
            view.frame(nil, besidePanelWidth: 0, animated: false)
        }
        view.advance(seconds: after)
        return view.renderImage(width: 640, height: 400)
    }
}

private func pixels(_ image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return data
}

/// Mean difference per channel (0…255) and the share of pixels that differ by more than 24 in any channel.
private func difference(_ a: CGImage, _ b: CGImage) -> (mean: Double, changed: Double) {
    let p = pixels(a), q = pixels(b)
    guard p.count == q.count else { return (255, 1) }
    var sum = 0, changed = 0
    for i in stride(from: 0, to: p.count, by: 4) {
        var worst = 0
        for c in 0..<3 { let d = abs(Int(p[i + c]) - Int(q[i + c])); sum += d; worst = max(worst, d) }
        if worst > 24 { changed += 1 }
    }
    return (Double(sum) / Double(p.count / 4 * 3), Double(changed) / Double(p.count / 4))
}

private func reference(_ name: String) -> CGImage? {
    guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Fixtures"),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

@MainActor
@Suite(.serialized) struct Looks {
    @Test(arguments: [("ref-cat-reading", 0), ("ref-blanket-day", 1), ("ref-blanket-night", 2)])
    func frameMatchesItsReference(_ name: String, _ which: Int) throws {
        let world = which == 0 ? MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "playground", title: "", color: .account(0), agents: [MeadowAgent(id: "main", activity: .reading)]),
        ])])]) : Scenes.office()
        let image = try #require(Scenes.shot(world, mode: which == 0 ? .catPlayground : .meadow, time: which == 2 ? .night : .day, after: which == 0 ? 3 : 4))
        let want = try #require(reference(name))
        let d = difference(image, want)
        #expect(d.mean < 0.5 && d.changed < 0.002, "\(name): mean difference \(d.mean), \(d.changed * 100)% of pixels changed")
    }
}

// MARK: allocation counting

#if DEBUG
/// Unoptimised builds keep temporary arrays on the heap, so allocation counts only mean something in
/// release: `swift test -c release -Xswiftc -enable-testing`.
let optimized = false
#else
let optimized = true
#endif

nonisolated(unsafe) private var allocations = 0

/// Counts the allocations libmalloc makes on the main thread (where a frame's work runs; other threads,
/// such as Metal's and the system's, go on with their own business meanwhile) while `body` runs, through
/// `malloc_logger`: the hook libmalloc calls for each one (the one Instruments uses).
private func countingAllocations(_ body: () -> Void) -> Int {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    guard let slot = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return -1 }
    let logger = slot.assumingMemoryBound(to: Logger?.self)
    allocations = 0
    // stack_logging_type_alloc = 2: a new block (malloc, calloc, realloc's new block, valloc…).
    logger.pointee = { type, _, _, _, _, _ in if type & 2 != 0, pthread_main_np() != 0 { allocations += 1 } }
    body()
    logger.pointee = nil
    return allocations
}

@MainActor
@Suite(.serialized) struct Frames {
    /// The counter sees allocations at all (else a zero below proves nothing).
    @Test func counterSeesAllocations() {
        var keep: [[Int]] = []
        let n = countingAllocations { for k in 0..<10 { keep.append([Int](repeating: k, count: 1000 + k)) } }
        #expect(n >= 10, "counted \(n)")
        _ = keep.count
    }

    /// The scene's own work each frame (cats, village, meadow, camera) allocates nothing once running.
    @Test(.enabled(if: optimized, "allocation counts mean something only in an optimised build"))
    func sceneUpdateAllocatesNothing() {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.settings = MeadowSettings(timeOfDay: .night)
        view.world = Scenes.busy()
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 3)
        let n = countingAllocations { for _ in 0..<240 { view.stage.update(1.0 / 120) } }
        #expect(n == 0, "\(n) allocations in 240 updates")
    }

    /// A meadow holding as much as it can draw costs a frame nothing either.
    @Test(.enabled(if: optimized, "allocation counts mean something only in an optimised build"))
    func fullMeadowAllocatesNothing() {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.settings = MeadowSettings(timeOfDay: .night)
        var things: [MeadowScenery.Thing] = []
        let kinds = ["flower.daisy", "flower.buttercup", "flower.lupin", "flower.poppy", "fungus.flyAgaric", "stone.stone", "stone.mossy"]
        for i in 0..<MeadowScenery.Limits.trees {
            let angle = Float(i) * 0.4, out = 30 + Float(i) * 2.2
            things.append(MeadowScenery.Thing(id: i % 4 == 0 ? "tree.young" : ["tree.oak", "tree.birch", "tree.cherry"][i % 3], x: cos(angle) * out,
                                              z: sin(angle) * out, seed: UInt32(i)))
        }
        while things.count < MeadowScenery.Limits.things - 10 {
            let k = things.count
            things.append(MeadowScenery.Thing(id: kinds[k % kinds.count], x: Float(k % 90) - 45, z: Float(k / 90) - 30, turn: Float(k), variant: k % 2))
        }
        for k in 0..<10 { things.append(MeadowScenery.Thing(id: "wood.fallenLog", x: Float(k) * 16 - 80, z: -60)) }
        view.scenery = MeadowScenery(things: things)
        view.world = Scenes.busy()
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 3)
        let n = countingAllocations { for _ in 0..<240 { view.stage.update(1.0 / 120) } }
        #expect(n == 0, "\(n) allocations in 240 updates")
    }

    /// Worktrees' stepping-stone paths, a hand-over, a report and a note in flight cost a frame nothing
    /// either.
    @Test(.enabled(if: optimized, "allocation counts mean something only in an optimised build"))
    func pathsAndErrandsAllocateNothing() {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 820))
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .night)
        func world(helpers: Int) -> MeadowWorld {
            var team = [MeadowAgent(id: "boss", activity: .supervising)]
            for k in 0..<helpers { team.append(MeadowAgent(id: "h\(k)", parentID: "boss", activity: .reading)) }
            return MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [
                MeadowSpace(id: "repo", name: "repo", blankets: [MeadowBlanket(id: "repo", title: "repo", color: .account(0), agents: team)]),
                MeadowSpace(id: "wt1", name: "wt1", blankets: [MeadowBlanket(id: "wt1", title: "wt1", color: .account(1), agents: [MeadowAgent(id: "c")], joinedTo: "repo")]),
                MeadowSpace(id: "wt2", name: "wt2", blankets: [MeadowBlanket(id: "wt2", title: "wt2", color: .account(2), joinedTo: "repo")]),
            ])])
        }
        view.world = world(helpers: 1)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 3)
        view.world = world(helpers: 2)
        view.passNote(from: .cat(blanket: "repo", agent: "h0"), to: .cat(blanket: "repo", agent: "boss"))
        view.passNote(from: .cat(blanket: "wt1", agent: "c"), to: .cat(blanket: "repo", agent: "boss"))
        view.stage.update(1.0 / 120)
        let n = countingAllocations { for _ in 0..<240 { view.stage.update(1.0 / 120) } }
        #expect(view.stage.village!.stoneCount > 0)
        #expect(n == 0, "\(n) allocations in 240 updates")
    }

    /// A whole frame, encoding included. Metal's own per-frame objects (command buffer, encoder, its
    /// completion block) are counted too; this reports them so a change in our share shows.
    @Test(.enabled(if: optimized, "allocation counts mean something only in an optimised build"))
    func wholeFrameAllocations() {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.world = Scenes.busy()
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 2)
        for _ in 0..<30 { _ = view.timeOffscreenFrame(width: 1280, height: 800, dt: 1.0 / 120) }
        let frames = 120
        let n = countingAllocations { for _ in 0..<frames { _ = view.timeOffscreenFrame(width: 1280, height: 800, dt: 1.0 / 120) } }
        print("allocations per whole frame (ours and Metal's):", Double(n) / Double(frames))
        #expect(Double(n) / Double(frames) < 20)
    }
}
