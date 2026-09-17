import AppKit
import Foundation
import Testing
import simd
@_spi(Diagnostics) @testable import MeadowScene

// Cats in the garden (docs/DESIGN.md, "Idle cats wander"): the garden's and the workplace's things that invite a
// cat are used as the meadow's other things are (sit on a bench's seat, a desk's top, a planter's edge, a shed's
// doorstep, under a nest box; nap on a bookcase's top, on a tent's threshold), one cat to a spot; a fence is gone
// round, and its gate crossed with one high bound over its leaf, never through a span; lamp posts are gone round;
// and the app's checks can ask a cat for one outing in the grass rather than wait for one.

/// The "home" blanket of `CatAfternoons` with these things set round it, at offsets from its middle.
@MainActor
private func garden(_ things: [MeadowScenery.Thing], world: MeadowWorld = CatAfternoons.alone()) -> MeadowView {
    let view = Roaming.view(world, size: NSSize(width: 1400, height: 900))
    let plot = view.stage.village!.plot("home")!
    view.scenery = MeadowScenery(things: things.map { thing in
        var thing = thing
        thing.move(by: Vec2(plot.middle.x, plot.middle.z))
        return thing
    })
    view.simulateZoom(by: 1.7, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    view.advance(seconds: 1.5)
    return view
}

private func thing(_ id: String, _ at: Vec2, turn: Float = 0) -> MeadowScenery.Thing { MeadowScenery.Thing(id: id, x: at.x, z: at.y, turn: turn) }

/// A square fence `half` each way round `middle` (blanket-local), closed, its gate (if any) in the side facing the
/// blanket.
private func pen(round middle: Vec2, half: Float, gate: Bool) -> MeadowScenery.Thing {
    let corners = [Vec2(-half, -half), Vec2(-half, half), Vec2(half, half), Vec2(half, -half), Vec2(-half, -half)].map { middle + $0 }
    return MeadowScenery.Thing(id: "garden.fence", points: corners, gate: gate ? 1 : 0)
}

@MainActor
@Suite(.serialized) struct CatsInTheGarden {
    /// Stage 8's things that invite a cat, and how.
    nonisolated static let spots: [(id: String, kind: MeadowScenery.CatSpot.Kind)] = [
        ("work.bench", .sit), ("work.desk", .sit), ("garden.planter", .sit), ("place.shed", .sit), ("garden.birdhouse", .sit),
        ("work.bookshelf", .nap), ("place.tent", .nap),
    ]

    /// Where each stands, beside the blanket: a big thing a little further out, where it stands whole.
    static func spot(_ id: String) -> Vec2 { SceneryRules.isBig(id) ? CatAfternoons.front(7.6, 1.0) : CatAfternoons.front(6.6, 1.0) }

    @Test("each of the garden's and the workplace's spots is used: the cat goes to it, hops up where it is up on the thing, and is there, facing its way",
          arguments: Self.spots.map(\.id))
    func used(_ id: String) {
        let view = garden([thing(id, Self.spot(id))])
        let actor = Roaming.actor(view)
        Roaming.setOutNow(view)
        let there = CatAfternoons.until(view, 240) { actor.roam.phase == .stopped && CatAfternoons.place(view, actor)?.id == id }
        #expect(there, "\(id) used")
        guard there, let place = CatAfternoons.place(view, actor) else { return }
        #expect(abs(actor.cat.position.y - place.at.y) < 0.05, "\(id): at its height, \(actor.cat.position.y) for \(place.at.y)")
        #expect(simd_distance(Vec2(actor.cat.position.x, actor.cat.position.z), Vec2(place.at.x, place.at.z)) < 0.05, "\(id): at its spot")
        #expect(place.kind == Self.spots.first { $0.id == id }!.kind)
        #expect(place.raised == (place.at.y - Land.height(place.at.x, place.at.z) > 0.15 || id == "place.shed"), "\(id): a hop up only onto what is up")
        // It leaves as it came, down on the grass again.
        _ = CatAfternoons.until(view, 60) { actor.roam.spot == nil }
        _ = CatAfternoons.until(view, 3) { actor.roam.dismount == nil && actor.roam.hopAt < 0 }
        #expect(actor.cat.position.y - Land.height(actor.cat.position.x, actor.cat.position.z) < 0.05, "\(id): down again")
    }

    @Test("sleepy, a cat goes to the bookcase's top or the tent's threshold and naps there", arguments: ["work.bookshelf", "place.tent"])
    func napsThere(_ id: String) {
        let view = garden([thing(id, Self.spot(id))])
        let actor = Roaming.actor(view)
        Roaming.setOutNow(view)
        _ = CatAfternoons.until(view, 60) { actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 1.5 }
        view.world = CatAfternoons.alone(.napping)
        view.stage.village!.letCatsDozeOff()
        let asleep = CatAfternoons.until(view, 60) { actor.roam.phase == .asleep }
        #expect(asleep && CatAfternoons.place(view, actor)?.id == id, "asleep at \(CatAfternoons.place(view, actor)?.id ?? "the grass")")
    }

    @Test("one cat to a spot: the boss and its helper never take the same one", arguments: ["work.bench", "garden.planter", "work.bookshelf"])
    func oneCatToASpot(_ id: String) {
        let view = garden([thing(id, Self.spot(id))])
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
        #expect(used > 0, "\(id) was used")
    }

    @Test("the tent's threshold lies outside its canvas, so a cat napping there is seen")
    func tentThresholdOutside() throws {
        let spot = try #require(MeadowScenery.catSpot(of: "place.tent"))
        let canvas = try #require(SceneryCatalog.shape(of: MeadowScenery.Thing(id: "place.tent", x: 0, z: 0))).make().shape
        // The canvas's front as high as a curled cat (the doorway drawn on it included; the rolled flaps tied
        // higher and wider, and the pegs, are not in the way).
        let front = canvas.positions.filter { $0.y > 0.1 && $0.y < 1.2 && abs($0.x) < 0.8 }.map(\.z).max() ?? 0
        #expect(spot.at.z - 0.7 > front, "curled, the cat's back clears the canvas: \(spot.at.z) against \(front)")
    }
}

@MainActor
@Suite(.serialized) struct CatsAndFences {
    /// A fence across the grass from (−6, 0) to (6, 0), with a gate in its middle span or none.
    static func wall(gate: Bool) -> FenceLines {
        let points = [Vec2(-6, 0), Vec2(6, 0)]
        let (posts, spans) = Fences.layout(points, gate: gate ? 1 : 0)
        return FenceLines([FenceLines.Run(posts, spans)])
    }

    @Test("a route never crosses a fence but at its gate; with no gate it goes round the fence's end")
    func routes() throws {
        for gate in [true, false] {
            let fences = Self.wall(gate: gate)
            var field = RoamField()
            field.reset(center: .zero, half: 11)
            field.mark { _ in (true, 1) }
            var path: [Vec2] = []
            #expect(field.route(from: Vec2(-1, -4), to: Vec2(1, 4), fences: fences, into: &path))
            var at = Vec2(-1, -4), crossings: [Vec2] = []
            for corner in path {
                if let crossing = fences.firstCrossing(at, corner) { crossings.append(crossing.at) }
                #expect(!fences.crosses(at, corner), "through a span from \(at) to \(corner)")
                at = corner
            }
            if gate {
                let door = try #require(fences.runs.first?.gate)
                #expect(crossings.count == 1 && crossings.allSatisfy { abs($0.x - door.middle.x) < simd_distance(door.a, door.b) / 2 }, "through the gate: \(crossings)")
            } else {
                #expect(crossings.isEmpty && path.contains { abs($0.x) > 6 }, "round its end: \(path)")
            }
        }
    }

    /// A planter in a pen beside the blanket, far enough out that the whole pen stands (nothing of it makes way for
    /// the blanket), the planter's front toward the pen's gate (if any), on the side facing the blanket.
    static func penned(gate: Bool) -> (view: MeadowView, middle: Vec2, half: Float) {
        let middle = CatAfternoons.front(9, 0), half: Float = 4.5
        let view = garden([thing("garden.planter", middle + Vec2(-1, 0), turn: -.pi / 2), pen(round: middle, half: half, gate: gate)])
        let plot = view.stage.village!.plot("home")!
        return (view, middle + Vec2(plot.middle.x, plot.middle.z), half)
    }

    @Test("a cat goes into a pen through its gate, with one high bound over the gate's leaf, and never through the fence")
    func throughTheGate() throws {
        let (view, middle, half) = Self.penned(gate: true)
        let village = view.stage.village!
        let actor = Roaming.actor(view)
        let gate = try #require(village.fences.runs.first?.gate)
        #expect(village.stands(gate, view.stage), "the gate stands whole, clear of the blanket")
        Roaming.setOutNow(view)
        var last = actor.cat.position, wasUp: Float = 0, overGate = 0, inside = false
        for _ in 0..<(240 * 60) {
            view.advance(seconds: 1.0 / 60)
            let p = actor.cat.position, up = actor.cat.height
            if let crossing = village.fences.firstCrossing(Vec2(last.x, last.z), Vec2(p.x, p.z)) {
                #expect(crossing.gate, "through a span at \(crossing.at)")
                #expect(max(up, wasUp) > 2.04, "over the gate's leaf: \(max(up, wasUp)) high")
                overGate += 1
            }
            if abs(p.x - middle.x) < half - 0.5 && abs(p.z - middle.y) < half - 0.5 { inside = true }
            last = p
            wasUp = up
            if inside && actor.roam.phase == .stopped && CatAfternoons.place(view, actor)?.id == "garden.planter" { break }
        }
        #expect(overGate >= 1 && inside, "in over the gate \(overGate) times")
        #expect(CatAfternoons.place(view, actor)?.id == "garden.planter", "and sitting on the planter")
        #expect(simd_distance(gate.middle, Vec2(middle.x - half, middle.y + 1.125)) < 0.01, "the gate where the pen's west side has it")
    }

    @Test("called home in the middle of its bound over the gate, a cat lands first, then runs home, over the gate again if it must")
    func calledHomeMidLeap() {
        let (view, _, _) = Self.penned(gate: true)
        let village = view.stage.village!
        let actor = Roaming.actor(view)
        Roaming.setOutNow(view)
        guard CatAfternoons.until(view, 240, { actor.roam.leaping && actor.cat.height > 1 }) else {
            Issue.record("never over the gate")
            return
        }
        view.world = CatAfternoons.alone(.reading)
        var last = actor.cat.position, wasUp = actor.cat.height
        let home = CatAfternoons.until(view, 12) {
            let p = actor.cat.position
            if let crossing = village.fences.firstCrossing(Vec2(last.x, last.z), Vec2(p.x, p.z)) {
                #expect(crossing.gate && max(actor.cat.height, wasUp) > 2.04, "through the fence at \(crossing.at), \(max(actor.cat.height, wasUp)) high")
            }
            last = p
            wasUp = actor.cat.height
            return !actor.roam.out
        }
        #expect(home && actor.cat.height == 0 && simd_distance(actor.rootLocal, actor.spot) < 0.05, "home, on its paws, in its seat")
    }

    @Test("a pen with no gate: no cat ever gets in, and the planter in it is never taken")
    func noGateNoWayIn() {
        let (view, middle, half) = Self.penned(gate: false)
        let village = view.stage.village!
        Roaming.setOutNow(view)
        for _ in 0..<(180 * 20) {
            view.advance(seconds: 0.05)
            for actor in village.plot("home")!.actors.values {
                let p = actor.cat.position
                #expect(!(abs(p.x - middle.x) < half && abs(p.z - middle.y) < half), "\(actor.view.id) in the pen at \(p)")
                #expect(actor.roam.spot.map { village.places[$0].id } != "garden.planter")
            }
            for actor in village.plot("home")!.actors.values where actor.roam.out { actor.roam.rested = 0 }
        }
    }

    @Test("a fence that has made way for a blanket come over it is neither gone round nor leapt")
    func madeWay() {
        let view = garden([MeadowScenery.Thing(id: "garden.fence", points: [CatAfternoons.front(-1, 6), CatAfternoons.front(-1, -6)], gate: 0)])
        let village = view.stage.village!
        guard let line = village.fences.runs.first?.barriers.first(where: { simd_distance($0.middle, Vec2(village.plot("home")!.middle.x, village.plot("home")!.middle.z)) < 6 }) else {
            Issue.record("a span under the blanket")
            return
        }
        #expect(!village.stands(line, view.stage), "under the blanket it has made way")
        #expect(!village.fences.crosses(line.middle - line.across, line.middle + line.across, standing: { village.stands($0, view.stage) }))
    }

    @Test("`MeadowView.crossesFence` answers as the routes do")
    func publicAnswer() {
        let (view, middle, half) = Self.penned(gate: true)
        let west = middle.x - half
        #expect(view.crossesFence(from: SIMD2(west - 1, middle.y - 2), to: SIMD2(west + 1, middle.y - 2)))
        #expect(!view.crossesFence(from: SIMD2(west - 1, middle.y + 1), to: SIMD2(west + 1, middle.y + 1)), "through the gate")
        #expect(!view.crossesFence(from: SIMD2(west - 2, middle.y + half + 2), to: SIMD2(west + 2, middle.y + half + 2)), "past it")
    }
}

@MainActor
@Suite(.serialized) struct CatsAndLamps {
    @Test("cats go round lamp posts: never into a post's footing, never stopping against one, and a lamp is no spot of theirs")
    func roundLampPosts() {
        let lamps = [CatAfternoons.front(2.0, 0.5), CatAfternoons.front(3.4, 2.6), CatAfternoons.front(2.4, -2.2), CatAfternoons.front(4.5, -0.6)]
        let view = garden(lamps.map { thing("work.lampPost", $0) })
        let village = view.stage.village!
        let plot = village.plot("home")!
        let posts = lamps.map { $0 + Vec2(plot.middle.x, plot.middle.z) }
        #expect(village.places.isEmpty, "a lamp offers a cat nothing")
        Roaming.setOutNow(view)
        var outFrames = 0, near: Float = .infinity
        for _ in 0..<(200 * 20) {
            view.advance(seconds: 0.05)
            for actor in plot.actors.values where actor.roam.out {
                outFrames += 1
                let p = Vec2(actor.cat.position.x, actor.cat.position.z)
                for post in posts {
                    let d = simd_distance(p, post)
                    near = min(near, d)
                    #expect(d > 0.8 + 0.2 * actor.size, "into a lamp post at \(post): \(d)")
                    if actor.roam.phase == .stopped { #expect(d > 0.8 + 0.6 * actor.size, "stopped against a lamp post: \(d)") }
                }
            }
            for actor in plot.actors.values where actor.roam.out { actor.roam.rested = 0 }
        }
        #expect(outFrames > 100 && near < 4, "cats went out among the lamps: \(outFrames) frames, nearest \(near)")
    }
}

@MainActor
@Suite(.serialized) struct AskedOutings {
    @Test("asked (`MeadowView.sendOut`), a cat sets off at once on one outing: a stop out in the grass reached in bounds, then home")
    func askedOuting() {
        for round in 0..<4 {
            // A stump near by: asked, the cat leaves it be and goes into the grass.
            let view = garden([thing("wood.stump", CatAfternoons.front(5.9, 1.5))])
            let cat = MeadowItem.cat(blanket: "home", agent: "main")
            let actor = Roaming.actor(view)
            view.advance(seconds: Double(round))
            let before = view.outings(cat)!
            #expect(view.sendOut(cat), "round \(round)")
            var spots = 0
            let back = CatAfternoons.until(view, 40) {
                if actor.roam.spot != nil { spots += 1 }
                return view.outings(cat)!.grassStops > before.grassStops && !actor.roam.out
            }
            let after = view.outings(cat)!
            #expect(back, "round \(round): out, a stop in the grass, home: \(after)")
            #expect(after.grassStops == before.grassStops + 1 && after.hops > before.hops, "round \(round): one stop, in bounds: \(after)")
            #expect(spots == 0 && !actor.roam.asked, "round \(round): no spot, and asked no more")
        }
    }

    @Test("asked while out, or for no such cat, nothing is asked")
    func notWhileOut() {
        let view = garden([])
        let cat = MeadowItem.cat(blanket: "home", agent: "main")
        #expect(!view.sendOut(.cat(blanket: "home", agent: "nobody")))
        #expect(view.sendOut(cat))
        _ = CatAfternoons.until(view, 10) { Roaming.actor(view).roam.out }
        #expect(!view.sendOut(cat), "already out")
    }
}

// MARK: Pictures (MEADOW_SNAPSHOTS)

/// A picture of each of the garden's spots in use, a cat over a gate, and the garden lit by its lamps at night
/// beside a kettle's blanket. Written only when MEADOW_SNAPSHOTS names a folder.
@MainActor
@Suite(.serialized) struct GardenCatPictures {
    nonisolated static let folder = CatalogPictures.folder

    @Test(.enabled(if: folder != nil)) func spots() {
        for (id, kind) in CatsInTheGarden.spots {
            let view = garden([thing(id, CatsInTheGarden.spot(id))])
            let actor = Roaming.actor(view)
            Roaming.setOutNow(view)
            if kind == .nap {
                _ = CatAfternoons.until(view, 60) { actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 1.5 }
                view.world = CatAfternoons.alone(.napping)
                view.stage.village!.letCatsDozeOff()
                _ = CatAfternoons.until(view, 60) { actor.roam.phase == .asleep }
            } else {
                _ = CatAfternoons.until(view, 240) { actor.roam.phase == .stopped && CatAfternoons.place(view, actor)?.id == id }
                view.advance(seconds: 0.6)
            }
            let head = view.stage.screen(actor.head)
            view.simulateZoom(by: 0.5, at: CGPoint(x: CGFloat(head.x), y: CGFloat(head.y)))
            view.advance(seconds: 0.4)
            Roaming.save(view, "spot-\(id)")
        }
    }

    /// The garden at night beside a plain terminal's blanket whose command runs (its kettle lit): lamps among the
    /// garden's and the workplace's things and a gated fence, from the editor's height and close; with the lamps'
    /// switch off beside it, and by day and at dusk, to see what the lamps alone light.
    @Test(.enabled(if: folder != nil)) func nightGarden() {
        let world = MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "shell", title: "shell", color: MeadowColor(hex: 0xa9a9ae),
                          lanterns: [MeadowLantern(id: "t0", title: "zsh", state: .running, command: .running)]),
            MeadowBlanket(id: "home", title: "home", color: .account(0), agents: [MeadowAgent(id: "main", activity: .idle)]),
        ])])])
        func view(_ time: MeadowSettings.TimeOfDay, lamps: Bool = true) -> (MeadowView, Vec2) {
            let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 720, height: 450), mode: .meadow)
            view.settings = MeadowSettings(timeOfDay: time, effects: MeadowSettings.Effects.all.subtracting(lamps ? [.moonPhase] : [.moonPhase, .lamps]),
                                           picnic: .hamper)
            view.world = world
            view.advance(seconds: 0.5)
            let plot = view.stage.village!.plot("shell")!
            // West of the kettle's blanket, away from the other: the garden runs out from its edge.
            let o = Vec2(plot.middle.x - plot.radius, plot.middle.z)
            func at(_ id: String, _ x: Float, _ z: Float, turn: Float = 0) -> MeadowScenery.Thing { MeadowScenery.Thing(id: id, x: o.x - x, z: o.y + z, turn: turn) }
            let fence = MeadowScenery.Thing(id: "garden.fence", points: [Vec2(o.x - 3, o.y + 9), Vec2(o.x - 3, o.y + 4), Vec2(o.x - 13, o.y + 4)], gate: 2)
            view.scenery = MeadowScenery(things: [
                at("work.lampPost", 3.6, -2.5), at("work.lampPost", 9.5, 1.5), at("work.lampPost", 5.5, 8.5),
                at("work.bench", 6.4, -3.2, turn: 0.2), at("garden.planter", 7.6, 2.2, turn: -0.3), at("work.desk", 11.5, -1.2, turn: 0.4),
                at("work.bookshelf", 12.6, 2.4, turn: -0.5), at("place.shed", 12.5, -7.5, turn: 0.3), at("place.tent", 4.5, -9, turn: 0.6),
                at("garden.birdhouse", 8.4, 6.6), at("garden.flowerPot", 4.8, 1.2), at("garden.wateringCan", 5.4, 0.4, turn: 1.2),
                at("work.mailbox", 2.6, 6.2), at("work.signpost", 9.6, 9.5), at("work.noticeboard", 13.6, 8.4, turn: -0.3), at("garden.skep", 15, -2.5),
                fence,
            ])
            view.advance(seconds: 2)
            return (view, o)
        }
        var pictures: [(String, CGImage)] = []
        for (name, time, lamps) in [("night", MeadowSettings.TimeOfDay.night, true), ("night, lamps off", .night, false), ("dusk", .hour(19.6), true), ("day", .day, true)] {
            let (v, o) = view(time, lamps: lamps)
            if let image = LampPictures.shot(v, x: o.x - 7, z: o.y, distance: 44, pitch: 0.62, bearing: -0.2, size: (720, 450)) { pictures.append(("garden, \(name)", image)) }
            if time == .night, let image = LampPictures.shot(v, x: o.x - 2, z: o.y - 1, distance: 20, pitch: 0.34, bearing: -0.35, size: (720, 450)) {
                pictures.append(("kettle and lamp, \(name)", image))
            }
        }
        CatalogPictures.sheet(pictures, columns: 2, to: "garden-lamps-night")
    }

    @Test(.enabled(if: folder != nil)) func overTheGate() {
        let (view, _, _) = CatsAndFences.penned(gate: true)
        let actor = Roaming.actor(view)
        Roaming.setOutNow(view)
        guard CatAfternoons.until(view, 240, { actor.roam.leaping && actor.cat.height > 1.6 }) else { return }
        let head = view.stage.screen(actor.head)
        view.simulateZoom(by: 0.55, at: CGPoint(x: CGFloat(head.x), y: CGFloat(head.y)))
        Roaming.save(view, "gate-leap")
    }
}
