import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// A cat's afternoon (docs/DESIGN.md, "Idle cats wander"): it uses what the meadow offers cats (sits on a stump,
// in a box, naps in a bed, scratches a post, looks in the bowl), one cat to a spot, hopping down and running home
// for work like anywhere else; it takes the paths it likes; it is up and about on and off for some minutes
// before it naps, and wakes now and then from a long nap for one short outing; and the meadow rests most of the
// time all the same.

@MainActor
@Suite(.serialized) struct CatAfternoons {
    /// The "home" blanket of `Roaming.world`, with a meadow of `ids` set round it in front (toward the camera),
    /// at the given offsets from its middle.
    static func view(_ things: [(String, Vec2)], world: MeadowWorld = alone(), ground: MeadowScenery.Ground? = nil) -> MeadowView {
        // Wide, so the grass a little way out from the blanket, where things stand whole, is in view.
        let view = Roaming.view(world, size: NSSize(width: 1400, height: 900))
        let plot = view.stage.village!.plot("home")!
        view.scenery = MeadowScenery(things: things.map { MeadowScenery.Thing(id: $0.0, x: plot.middle.x + $0.1.x, z: plot.middle.z + $0.1.y) }, ground: ground)
        // Back a little, so the grass out to where things stand whole is in view.
        view.simulateZoom(by: 1.7, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        view.advance(seconds: 1.5)
        return view
    }

    /// One workspace on its own: an idle cat and its helper, awake.
    static func alone(_ activity: AgentActivity = .idle) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "home", title: "home", color: .account(0), agents: [
                MeadowAgent(id: "main", activity: activity), MeadowAgent(id: "h", parentID: "main", activity: .awake),
            ]),
        ])])])
    }

    /// Beside the blanket (to its right as the meadow is seen, where the view shows grass), `out` past its edge
    /// and `along` toward the back.
    static func front(_ out: Float, _ along: Float = 0) -> Vec2 {
        let plot = Roaming.view(alone()).stage.village!.plot("home")!
        return Vec2(plot.radius + out, -along)
    }

    /// Steps until `done` holds (at most `seconds`), a sixtieth of a second at a time.
    static func until(_ view: MeadowView, _ seconds: Double, _ done: () -> Bool) -> Bool {
        for _ in 0..<Int(seconds * 60) {
            if done() { return true }
            view.advance(seconds: 1.0 / 60)
        }
        return done()
    }

    static func place(_ view: MeadowView, _ actor: Actor) -> CatPlace? { actor.roam.spot.map { view.stage.village!.places[$0] } }

    @Test("a cat sits on a stump: it hops up, sits on its top facing the stump's way, and hops down when it goes")
    func sitsOnAStump() {
        let view = Self.view([("wood.stump", Self.front(5.9, 1.5))])
        let actor = Roaming.actor(view)
        Roaming.setOutNow(view)
        let up = Self.until(view, 120) { actor.roam.phase == .stopped && Self.place(view, actor)?.id == "wood.stump" }
        #expect(up, "on the stump")
        guard up, let place = Self.place(view, actor) else { return }
        #expect(abs(actor.cat.position.y - place.at.y) < 0.05, "on its top: \(actor.cat.position.y) for \(place.at.y)")
        #expect(simd_distance(Vec2(actor.cat.position.x, actor.cat.position.z), Vec2(place.at.x, place.at.z)) < 0.05)
        let gone = Self.until(view, 60) { actor.roam.spot == nil }
        #expect(gone)
        _ = Self.until(view, 3) { actor.roam.dismount == nil && actor.roam.hopAt < 0 }
        #expect(actor.cat.position.y < 0.02, "down on the grass again")
    }

    @Test("one cat to a spot: the boss and its helper never take the same stump")
    func oneCatToASpot() {
        let view = Self.view([("wood.stump", Self.front(5.9, 1.5))])
        let village = view.stage.village!
        Roaming.setOutNow(view)
        var used = 0
        for _ in 0..<(150 * 30) {
            view.advance(seconds: 1.0 / 30)
            let at = village.plot("home")!.actors.values.compactMap(\.roam.spot)
            #expect(Set(at).count == at.count, "two cats at one spot")
            if !at.isEmpty { used += 1 }
            for actor in village.plot("home")!.actors.values where actor.roam.out { actor.roam.rested = 0 }
        }
        #expect(used > 0, "the stump was used")
    }

    @Test("on a stump when work comes: it hops down and runs home as from anywhere")
    func runsHomeFromAStump() {
        let view = Self.view([("wood.stump", Self.front(5.9, 1.5))])
        let actor = Roaming.actor(view)
        Roaming.setOutNow(view)
        guard Self.until(view, 120, { actor.roam.phase == .stopped && Self.place(view, actor)?.id == "wood.stump" }) else {
            Issue.record("never on the stump")
            return
        }
        view.world = Self.alone(.reading)
        #expect(actor.roam.phase == .recalled && actor.roam.spot == nil, "the stump is free at once")
        let home = Self.until(view, 6) { !actor.roam.out }
        #expect(home && simd_distance(actor.rootLocal, actor.spot) < 0.05, "home")
        #expect(actor.cat.position.y < 0.01)
    }

    @Test("sleepy, a cat goes to a free bed (or a box) near it and naps in it")
    func napsInABed() {
        let view = Self.view([("cat.bed", Self.front(6.2, 1.2))])
        let actor = Roaming.actor(view)
        Roaming.setOutNow(view)
        _ = Self.until(view, 60) { actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 1.5 }
        view.world = Self.alone(.napping)
        view.stage.village!.letCatsDozeOff()
        let asleep = Self.until(view, 40) { actor.roam.phase == .asleep }
        #expect(asleep && Self.place(view, actor)?.id == "cat.bed", "asleep in \(Self.place(view, actor)?.id ?? "the grass")")
        #expect(actor.cat.isNapping)
    }

    @Test("a post gets a scratch, and the bowl a look", arguments: ["cat.scratchingPost", "cat.bowl"])
    func scratchesAndVisits(_ id: String) {
        let view = Self.view([(id, Self.front(6.9, 1.2))])
        let actor = Roaming.actor(view)
        Roaming.setOutNow(view)
        let used = Self.until(view, 150) {
            guard actor.roam.phase == .stopped, Self.place(view, actor)?.id == id else { return false }
            switch actor.cat.outing {
            case .scratch: return id == "cat.scratchingPost"
            case .sniff: return id == "cat.bowl"
            default: return false
            }
        }
        #expect(used, "\(id) used")
    }

    @Test("cats take a painted path when one is near (`MeadowView.walkingEase`), and still cross the grass")
    func takesThePath() {
        func share(_ painted: Bool) -> Float {
            let probe = Roaming.view(Self.alone()).stage.village!.plot("home")!
            // A path through the grass beside the blanket, from its back to its front.
            var ground = MeadowScenery.Ground()
            let lane = probe.middle.x + probe.radius + 1.6
            for row in 0..<MeadowScenery.Ground.side {
                for column in 0..<MeadowScenery.Ground.side {
                    let x = (Float(column) + 0.5) * MeadowScenery.Ground.cell - MeadowScenery.Ground.reach
                    if painted && abs(x - lane) < 0.7 { ground[column, row] = .path }
                }
            }
            let view = Self.view([], ground: painted ? ground : nil)
            #expect(view.walkingEase(at: SIMD2(lane, probe.middle.z)) == (painted ? 1 : 0.25))
            let actor = Roaming.actor(view)
            Roaming.setOutNow(view)
            var on: Float = 0, all: Float = 0, last = actor.cat.position
            for _ in 0..<(240 * 20) {
                view.advance(seconds: 0.05)
                let p = actor.cat.position, piece = simd_distance(Vec2(p.x, p.z), Vec2(last.x, last.z))
                if actor.roam.phase == .travelling {
                    all += piece
                    if abs(p.x - lane) < 0.75 { on += piece }
                }
                last = p
            }
            return on / max(all, 1e-3)
        }
        let grass = share(false), path = share(true)
        #expect(path > grass * 1.5 && path > 0.05, "on the path: \(path) painted, \(grass) as grass")
    }

    @Test("an idle cat is up and about on and off for minutes, dozes off, and wakes from a long nap for one short outing")
    func anAfternoon() {
        let view = Roaming.view(Roaming.world(.idle, helper: .reading))
        let village = view.stage.village!
        let actor = Roaming.actor(view)
        // Its Claude would let it nap after 45 s.
        view.advance(seconds: 45, step: 1.0 / 20)
        view.world = Roaming.world(.napping, helper: .reading)
        var outings = 0, wasOut = false, dozedAt: Float?
        while village.clock < 7 * 60 {
            view.advance(seconds: 0.5, step: 1.0 / 20)
            if actor.roam.out && !wasOut { outings += 1 }
            wasOut = actor.roam.out
            if dozedAt == nil && actor.cat.isNapping { dozedAt = village.clock }
        }
        #expect(outings >= 3, "\(outings) outings before its nap")
        #expect(dozedAt.map { $0 >= ROAM_AWAKE.least && $0 <= ROAM_AWAKE.least + ROAM_AWAKE.more + 60 } ?? false, "dozed off at \(dozedAt ?? -1) s")
        #expect(actor.cat.isNapping)
        // A long nap later it wakes, stretches and goes out once, then sleeps again.
        let wake = actor.roam.wakeAt
        #expect(wake >= village.clock + ROAM_NAP.least - 60)
        village.clock = wake - 1
        var woke = false, outAgain = false
        for _ in 0..<(150 * 10) {
            view.advance(seconds: 0.1, step: 1.0 / 30)
            woke = woke || !actor.cat.isNapping
            outAgain = outAgain || actor.roam.out
            if woke && actor.cat.isNapping && village.clock > actor.roam.awakeUntil { break }
        }
        #expect(woke && outAgain, "woke \(woke), out \(outAgain)")
        #expect(actor.cat.isNapping, "asleep again")
    }

    /// The share of time the meadow is awake (not at its slow resting tick) over `minutes`, with `cats` idle
    /// cats, driven frame by frame at the rate it asks for, on a clock of the test's own.
    static func awakeShare(cats: Int, minutes: Double) -> Double {
        final class Clock { var now: CFTimeInterval = 1000 }
        let clock = Clock()
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 605, height: 900), mode: .meadow)
        view.clock = { clock.now }
        view.keepsFullRateWhenInactive = true
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .day, picnic: .hamper)
        let blankets = (0..<cats).map { i in MeadowBlanket(id: "b\(i)", title: "w\(i)", color: .account(i), agents: [MeadowAgent(id: "main", activity: .idle)]) }
        view.world = MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: blankets.map { MeadowSpace(id: $0.id, name: $0.id, blankets: [$0]) })])
        var awake = 0.0, all = 0.0
        while all < minutes * 60 {
            let dt = 1 / Double(view.targetRate)
            clock.now += dt
            view.step(Float(dt))
            view.updateRate()
            all += dt
            if all > 10 && !view.isResting { awake += dt }
        }
        return awake / (all - 10)
    }

    @Test("idle cats out and about leave the meadow resting most of the time: one cat, and ten")
    func dutyCycle() {
        let one = Self.awakeShare(cats: 1, minutes: 5), ten = Self.awakeShare(cats: 10, minutes: 5)
        print("duty cycle: the meadow awake \(String(format: "%.1f", one * 100)) % of the time with one idle cat, \(String(format: "%.1f", ten * 100)) % with ten")
        #expect(one < 0.25, "one cat: \(one)")
        #expect(ten < 0.6, "ten cats: \(ten)")
    }

    /// Pictures of each spot in use, written only when asked for.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEADOW_SNAPSHOTS"] != nil))
    func snapshots() {
        for id in ["wood.stump", "cat.box", "cat.bed", "cat.scratchingPost", "cat.bowl", "stone.boulder", "work.cushion"] {
            let view = Self.view([(id, Self.front(6.9, 1.0))])
            let actor = Roaming.actor(view)
            if id == "cat.bed" {
                Roaming.setOutNow(view)
                _ = Self.until(view, 60) { actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 1.5 }
                view.world = Self.alone(.napping)
                view.stage.village!.letCatsDozeOff()
                _ = Self.until(view, 40) { actor.roam.phase == .asleep }
            } else {
                Roaming.setOutNow(view)
                _ = Self.until(view, 150) { actor.roam.phase == .stopped && Self.place(view, actor)?.id == id }
                view.advance(seconds: 0.6)
            }
            let head = view.stage.screen(actor.head)
            view.simulateZoom(by: 0.55, at: CGPoint(x: CGFloat(head.x), y: CGFloat(head.y)))
            view.advance(seconds: 0.4)
            Roaming.save(view, "spot-\(id)")
        }
    }
}
