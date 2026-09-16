import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import simd
@_spi(Diagnostics) @testable import MeadowScene

// Cats out in the grass (docs/DESIGN.md, "Idle cats wander"): a cat with nothing to do wanders near its blanket
// in short bursts with long still stops, never into anything or anyone, never out of its own patch or out of
// view, and never sliding; work calls it home at a run with its state readable from the first moment; it naps
// out there when long idle; the meadow still rests between bursts; and with the switch off, Reduce Motion or
// the animation held, cats stay on their blankets as they always did. Routes may prefer liked ground.

@MainActor
@Suite(.serialized) struct Roaming {
    static let size = NSSize(width: 900, height: 600)

    /// Three workspaces in a loose picnic: an idle cat on the first (with a helper), working cats on the others.
    static func world(_ activity: AgentActivity = .idle, needsYou: Bool = false, helper: AgentActivity = .awake) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "home", title: "home", color: .account(0), agents: [
                MeadowAgent(id: "main", activity: activity, needsYou: needsYou),
                MeadowAgent(id: "h", parentID: "main", activity: helper),
            ]),
            MeadowBlanket(id: "busy", title: "busy", color: .account(1), agents: [MeadowAgent(id: "main", activity: .reading)]),
            MeadowBlanket(id: "other", title: "other", color: .account(2), agents: [MeadowAgent(id: "main", activity: .editing)]),
        ])])])
    }

    static func view(_ world: MeadowWorld = world(), arrangement: MeadowSettings.Arrangement = .picnic, size: NSSize = size,
                     time: MeadowSettings.TimeOfDay = .day) -> MeadowView {
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(arrangement: arrangement, timeOfDay: time, picnic: .hamper)
        view.world = world
        view.advance(seconds: 0.5)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 2)
        return view
    }

    static func actor(_ view: MeadowView, _ blanket: String = "home", _ agent: String = "main") -> Actor { view.stage.village!.actor(blanket, agent)! }

    /// Lets the first outing come now rather than after its rest.
    static func setOutNow(_ view: MeadowView) {
        for plot in view.stage.village!.plots { for actor in plot.actors.values { actor.roam.until = view.stage.village!.time } }
    }

    // MARK: Where a cat goes

    @Test("left idle, a cat gets up after a while and goes out into the grass, then comes home")
    func goesOutAndBack() {
        let view = Self.view()
        let actor = Self.actor(view)
        view.advance(seconds: 10)
        #expect(!actor.roam.out, "not straight away: it rests on its blanket first")
        var wentOut = false, cameBack = false, offCloth = false
        let plot = view.stage.village!.plot("home")!
        for _ in 0..<(180 * 10) {
            view.advance(seconds: 0.1)
            if actor.roam.out { wentOut = true }
            let p = Vec2(actor.cat.position.x - plot.middle.x, actor.cat.position.z - plot.middle.z)
            if simd_length(p) > view.stage.village!.clothReach(plot, toward: simd_normalize(p)) + 0.3 { offCloth = true }
            if wentOut && !actor.roam.out { cameBack = true; break }
        }
        #expect(wentOut && offCloth, "out in the grass: \(wentOut), off its cloth: \(offCloth)")
        #expect(cameBack, "and home again")
    }

    @Test("out in the grass a cat keeps to its own patch: near its blanket, nearer it than any other, clear of other blankets, footprints, picnic things and cats",
          arguments: [MeadowSettings.Arrangement.picnic, .column])
    func keepsToItsPatch(_ arrangement: MeadowSettings.Arrangement) {
        let view = Self.view(arrangement: arrangement, size: arrangement == .column ? NSSize(width: 605, height: 900) : Self.size)
        let village = view.stage.village!
        Self.setOutNow(view)
        var outFrames = 0
        for _ in 0..<(150 * 20) {
            view.advance(seconds: 0.05)
            for plot in village.plots {
                for actor in plot.actors.values where actor.roam.out {
                    outFrames += 1
                    let p = Vec2(actor.cat.position.x, actor.cat.position.z), middle = Vec2(plot.middle.x, plot.middle.z)
                    let away = p - middle, far = simd_length(away)
                    let edge = far - (far > 1e-3 ? village.clothReach(plot, toward: away / far) : 0)
                    #expect(edge <= ROAM_RANGE + 0.6, "\(plot.view.id)/\(actor.view.id) \(edge) past its blanket")
                    for other in village.plots where other !== plot {
                        let theirs = simd_distance(p, Vec2(other.middle.x, other.middle.z)) - other.radius
                        #expect(theirs > 0.3, "on \(other.view.id)'s blanket")
                    }
                    for f in village.footing where village.plots.allSatisfy({ simd_distance(Vec2(f.x, f.z), Vec2($0.middle.x, $0.middle.z)) >= $0.radius }) {
                        #expect(simd_distance(p, Vec2(f.x, f.z)) > f.r + 0.2 * actor.size, "through a footprint at \(f)")
                    }
                    for q in village.plots {
                        for treat in q.treats where treat.wanted {
                            #expect(simd_distance(p, Vec2(q.group.x + treat.at.x, q.group.z + treat.at.z)) > treat.reach * 0.8, "through a picnic thing")
                        }
                        for other in q.actors.values where other !== actor && !other.leaving {
                            #expect(simd_distance(p, Vec2(other.cat.position.x, other.cat.position.z)) > 0.6 * (actor.size + other.size), "into another cat")
                        }
                    }
                }
            }
        }
        #expect(outFrames > 100, "cats went out: \(outFrames) frames")
    }

    @Test("a cat out in the grass stays in view, where whose it is can be seen")
    func staysInView() {
        let view = Self.view()
        Self.setOutNow(view)
        let actor = Self.actor(view)
        for _ in 0..<(120 * 10) {
            view.advance(seconds: 0.1)
            guard actor.roam.out, actor.roam.phase == .stopped, let r = view.screenRect(of: .cat(blanket: "home", agent: "main")) else { continue }
            #expect(view.bounds.insetBy(dx: -4, dy: -4).contains(r), "out of view at \(r)")
        }
    }

    // MARK: How it moves

    @Test("walking and running, a cat moves on only while its body is up off its paws: no step slides")
    func stepsNeverSlide() {
        let view = Self.view()
        let actor = Self.actor(view)
        Self.setOutNow(view)
        var checked = 0
        var last = actor.cat.position
        for _ in 0..<(120 * 60) {
            view.advance(seconds: 1.0 / 60)
            defer { last = actor.cat.position }
            guard actor.roam.phase == .travelling || actor.roam.phase == .recalled, actor.roam.gait != .bound, actor.cat.gait != .none else { continue }
            let moved = simd_distance(actor.cat.position, last)
            // Down on its paws (the step's lift near nothing), it stays put.
            if abs(sin(actor.cat.stride)) < 0.12 {
                #expect(moved < 0.012 * actor.size, "slid \(moved) while down")
                checked += 1
            }
        }
        #expect(checked > 10, "checked \(checked) grounded frames")
    }

    @Test("bounding through the grass, a cat moves on only while in the air, and lands where it was going")
    func hopsCarryOnlyInTheAir() {
        let view = Self.view()
        let actor = Self.actor(view)
        Self.setOutNow(view)
        var hops = 0, grounded = 0
        var last = actor.cat.position, wasUp = false
        for _ in 0..<(150 * 60) {
            view.advance(seconds: 1.0 / 60)
            defer { last = actor.cat.position; wasUp = actor.cat.height > 0 }
            guard actor.roam.gait == .bound, actor.roam.phase == .travelling else { continue }
            let up = actor.cat.height > 0
            if up && !wasUp { hops += 1 }
            let moved = simd_distance(Vec2(actor.cat.position.x, actor.cat.position.z), Vec2(last.x, last.z))
            if !up && !wasUp {
                #expect(moved < 0.01, "moved \(moved) on the ground between hops")
                grounded += 1
            }
        }
        #expect(hops >= 3, "\(hops) hops")
        #expect(grounded > 10)
    }

    // MARK: Called home

    @Test("work comes: a cat out in the grass turns and runs home at once, its state on show from the first moment, then works",
          arguments: [AgentActivity.reading, .running])
    func runsHomeForWork(_ work: AgentActivity) {
        let view = Self.view()
        let actor = Self.actor(view)
        Self.setOutNow(view)
        for _ in 0..<600 where !(actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 2) { view.advance(seconds: 0.1) }
        try? #require(actor.roam.out, "out first")
        let far = simd_distance(actor.rootLocal, actor.spot)
        view.world = Self.world(work)
        #expect(actor.roam.phase == .recalled, "called back the moment the world says so")
        var ran = false, fastest: Float = 0, last = actor.cat.position
        var arrived: Double?
        for frame in 0..<(6 * 60) {
            view.advance(seconds: 1.0 / 60)
            if actor.cat.gait == .run { ran = true }
            fastest = max(fastest, simd_distance(actor.cat.position, last) * 60)
            last = actor.cat.position
            if arrived == nil && !actor.roam.out { arrived = Double(frame) / 60 }
        }
        #expect(ran, "it runs")
        #expect(fastest > 4, "with urgency: \(fastest) units a second at best")
        #expect(arrived != nil && arrived! < Double(far) / 2.5 + 1.6, "home in \(arrived ?? -1) s from \(far) away")
        #expect(simd_distance(actor.rootLocal, actor.spot) < 0.05, "in its seat")
        #expect(actor.cat.activity == work, "and at work")
    }

    @Test("a request: the cat runs home with its bubble up all the way")
    func requestBubbleShowsOnTheWay() {
        let view = Self.view()
        let actor = Self.actor(view)
        Self.setOutNow(view)
        for _ in 0..<600 where !(actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 2) { view.advance(seconds: 0.1) }
        try? #require(actor.roam.out)
        view.world = Self.world(.running, needsYou: true)
        view.advance(seconds: 0.25)
        #expect(actor.roam.phase == .recalled)
        #expect(actor.cat.bubbleShown && actor.cat.bubbleMark == .needsYou, "the request shows while it runs")
    }

    @Test("long idle, a cat naps out in the grass (or in shade, or back on its blanket); woken by work it runs home the same way")
    func napsAndWakesForWork() {
        let view = Self.view()
        let actor = Self.actor(view)
        Self.setOutNow(view)
        for _ in 0..<600 where !(actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 2) { view.advance(seconds: 0.1) }
        view.world = Self.world(.napping)
        view.advance(seconds: 12)
        #expect(actor.cat.isNapping)
        #expect(actor.roam.phase == .asleep || actor.roam.phase == .home, "asleep somewhere: \(actor.roam.phase)")
        #expect(actor.cat.still, "lying still")
        view.world = Self.world(.editing)
        view.advance(seconds: 5)
        #expect(!actor.roam.out && simd_distance(actor.rootLocal, actor.spot) < 0.05)
    }

    // MARK: Staying home

    @Test("with the switch off, Reduce Motion or the animation held, cats stay on their blankets; turned off while out, they are home at once",
          arguments: ["switch", "reduceMotion", "ambient"])
    func staysHomeWhenAsked(_ how: String) {
        func hold(_ view: MeadowView, _ on: Bool) {
            switch how {
            case "switch": view.settings.catsWander = !on
            case "reduceMotion": view.reduceMotion = on
            default: view.animatesAmbient = !on
            }
        }
        let view = Self.view()
        let actor = Self.actor(view)
        Self.setOutNow(view)
        for _ in 0..<600 where !actor.roam.out { view.advance(seconds: 0.1) }
        try? #require(actor.roam.out)
        hold(view, true)
        view.advance(seconds: 1.0 / 60)
        #expect(!actor.roam.out && actor.rootLocal == actor.spot, "home at once")
        Self.setOutNow(view)
        for _ in 0..<1200 {
            view.advance(seconds: 0.1)
            #expect(!actor.roam.out)
        }
    }

    // MARK: The meadow rests

    @Test("between bursts the meadow rests at its slow tick, as it always did")
    func meadowRestsBetweenBursts() {
        final class Clock { var now: CFTimeInterval = 1000 }
        let clock = Clock()
        let view = MeadowView(frame: NSRect(origin: .zero, size: Self.size), mode: .meadow)
        view.clock = { clock.now }
        view.keepsFullRateWhenInactive = true
        view.settings = MeadowSettings(timeOfDay: .day, picnic: .hamper)
        view.world = Self.world()
        var resting = 0, frames = 0, bursts = 0, wasStill = true
        var elapsed = 0.0
        while elapsed < 240 {
            let dt = 1 / Double(view.targetRate)
            clock.now += dt
            elapsed += dt
            view.step(Float(dt))
            view.updateRate()
            guard elapsed > 10 else { continue }
            frames += 1
            if view.isResting { resting += 1 }
            let still = view.stage.still
            if wasStill && !still { bursts += 1 }
            wasStill = still
        }
        #expect(bursts >= 2, "cats went out: \(bursts) bursts")
        // Frames are fewer while resting; in time, most of the four minutes are rest.
        #expect(Double(resting) / Double(frames) > 0.3, "rested \(resting) of \(frames) frames")
    }

    // MARK: Picking

    @Test("a cat out in the grass is picked, hovered and framed where it is")
    func pickedWhereItIs() {
        let view = Self.view()
        let actor = Self.actor(view)
        Self.setOutNow(view)
        for _ in 0..<600 where !(actor.roam.out && actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 2) { view.advance(seconds: 0.1) }
        try? #require(actor.roam.out)
        let head = view.stage.screen(actor.head)
        #expect(view.stage.pick(Vec2(head.x, head.y)) == .cat(blanket: "home", agent: "main"))
        let rect = view.screenRect(of: .cat(blanket: "home", agent: "main"))
        #expect(rect.map { $0.contains(CGPoint(x: CGFloat(head.x), y: view.bounds.height - CGFloat(head.y))) } ?? false)
    }

    // MARK: Routes

    @Test("a route goes round what is in the way and never through it")
    func routeGoesRound() {
        var field = RoamField()
        field.reset(center: .zero, half: 10)
        field.mark { _ in (true, 1) }
        field.close(Vec2(0, 0), 2.5)
        var path: [Vec2] = []
        #expect(field.route(from: Vec2(-6, 0.2), to: Vec2(6, -0.2), into: &path))
        var at = Vec2(-6, 0.2)
        for corner in path {
            for s in 0...40 {
                let p = at + (corner - at) * Float(s) / 40
                #expect(simd_length(p) > 2.2, "through the obstacle at \(p)")
            }
            at = corner
        }
        #expect(path.last == Vec2(6, -0.2))
        // Walled in: no way.
        field.close(Vec2(6, -0.2), 0.01)
        for a in stride(from: Float(0), to: 2 * .pi, by: 0.05) { field.close(Vec2(6, -0.2) + Vec2(cos(a), sin(a)) * 1.2, 0.4) }
        #expect(!field.route(from: Vec2(-6, 0.2), to: Vec2(6, -0.2), into: &path))
    }

    /// The share of a route's length that runs within a strip along z = 0.
    static func shareOnStrip(_ liking: ((Vec2) -> Float)?, routes: Int) -> Float {
        var field = RoamField()
        field.reset(center: .zero, half: 12)
        field.mark { p in (true, RoamField.cost(liking: liking?(p) ?? 0)) }
        var random = chance("roam/strip")
        var path: [Vec2] = []
        var on: Float = 0, all: Float = 0
        for _ in 0..<routes {
            let a = Vec2(-8 + random.float() * 3, (random.float() - 0.5) * 7), b = Vec2(5 + random.float() * 3, (random.float() - 0.5) * 7)
            guard field.route(from: a, to: b, into: &path) else { continue }
            var at = a
            for corner in path {
                for s in 0..<20 {
                    let p = at + (corner - at) * (Float(s) + 0.5) / 20, piece = simd_distance(at, corner) / 20
                    all += piece
                    if abs(p.y) < 0.75 { on += piece }
                }
                at = corner
            }
        }
        return on / max(all, 1e-3)
    }

    @Test("routes follow ground cats like (a path) more often than plain grass")
    func likedGroundIsFollowed() {
        let grass = Self.shareOnStrip(nil, routes: 60)
        let liked = Self.shareOnStrip({ abs($0.y) < 0.75 ? 1 : 0 }, routes: 60)
        #expect(liked > grass * 2 && liked > 0.4, "on the strip: \(liked) liked, \(grass) as grass")
    }

    @Test("a cat's own outings take the ground it likes (`Village.liking`)")
    func villageRoutesUseLiking() {
        func share(_ liking: ((Vec2) -> Float)?) -> Float {
            let view = Self.view()
            let village = view.stage.village!
            let plot = village.plot("home")!
            // A path running across the grass in front of the blanket.
            let lane = plot.middle.z + plot.radius + 1.5
            village.liking = liking.map { like in { like(Vec2($0.x, $0.y - lane)) } }
            Self.setOutNow(view)
            let actor = Self.actor(view)
            var on: Float = 0, all: Float = 0, last = actor.cat.position
            for _ in 0..<(240 * 20) {
                view.advance(seconds: 0.05)
                let p = actor.cat.position, piece = simd_distance(Vec2(p.x, p.z), Vec2(last.x, last.z))
                if actor.roam.phase == .travelling, abs(Vec2(p.x, p.z).y - lane) > -1 {
                    all += piece
                    if abs(p.z - lane) < 0.75 { on += piece }
                }
                last = p
            }
            return on / max(all, 1e-3)
        }
        let grass = share(nil), liked = share { abs($0.y) < 0.75 ? 1 : 0 }
        #expect(liked > grass * 1.5, "on the path: \(liked) liked, \(grass) as grass")
    }

    // MARK: Faces

    @Test("stopped out in the grass, sitting or loafing, both eyes face the camera")
    func facesAtStops() {
        let view = Self.view()
        Self.setOutNow(view)
        var seen = 0
        for _ in 0..<(150 * 10) {
            view.advance(seconds: 0.1)
            for plot in view.stage.village!.plots {
                for actor in plot.actors.values where actor.roam.phase == .stopped && !actor.cat.isNapping {
                    let cat = actor.cat, eye = view.stage.camera.eye
                    // Once it has turned round to face you.
                    guard cat.still else { continue }
                    let left = Faces.facing(cat.eyeWhites.0, eye: eye), right = Faces.facing(cat.eyeWhites.1, eye: eye)
                    #expect(min(left, right) > Faces.readable, "\(actor.view.id) at a stop: \(left), \(right)")
                    seen += 1
                }
            }
        }
        #expect(seen > 20)
    }

    // MARK: Pictures

    static func save(_ view: MeadowView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MEADOW_SNAPSHOTS"] else { return }
        let w = Int(view.bounds.width * 2), h = Int(view.bounds.height * 2)
        guard let image = view.renderImage(width: w, height: h) else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Pictures to look at, written only when asked for: cats out, mid-hop, frame by frame through a hop and a
    /// run home, asleep in the grass.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEADOW_SNAPSHOTS"] != nil))
    func snapshots() {
        let view = Self.view(size: NSSize(width: 640, height: 420))
        view.simulateZoom(by: 0.6, at: CGPoint(x: 320, y: 210))
        view.advance(seconds: 1)
        let actor = Self.actor(view)
        Self.setOutNow(view)
        var hopFrames = 0, outPicture = false
        for _ in 0..<(200 * 30) {
            view.advance(seconds: 1.0 / 30)
            if !outPicture && actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 2 {
                Self.save(view, "roam-out-\(actor.roam.outing)")
                outPicture = true
            }
            if actor.roam.gait == .bound && actor.roam.phase == .travelling && hopFrames < 24 {
                Self.save(view, String(format: "roam-hop-%02d", hopFrames))
                hopFrames += 1
            }
            if hopFrames >= 24 && outPicture { break }
        }
        // Out, then called home: every frame of the run.
        for _ in 0..<600 where !(actor.roam.phase == .stopped && simd_distance(actor.rootLocal, actor.spot) > 2.5) { view.advance(seconds: 0.1) }
        view.world = Self.world(.running, needsYou: true)
        for k in 0..<36 {
            view.advance(seconds: 1.0 / 30)
            Self.save(view, String(format: "roam-run-%02d", k))
        }
        // Asleep in the grass.
        let sleeper = Self.view(size: NSSize(width: 640, height: 420))
        sleeper.simulateZoom(by: 0.6, at: CGPoint(x: 320, y: 210))
        Self.setOutNow(sleeper)
        let cat = Self.actor(sleeper)
        for _ in 0..<600 where !(cat.roam.phase == .stopped && simd_distance(cat.rootLocal, cat.spot) > 2) { sleeper.advance(seconds: 0.1) }
        sleeper.world = Self.world(.napping)
        sleeper.advance(seconds: 10)
        Self.save(sleeper, "roam-napping")
    }
}
