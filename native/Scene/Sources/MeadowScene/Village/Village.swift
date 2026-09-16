import Foundation
import simd

// Port of src/village/Village.ts: one picnic blanket per tab, with its cats sat about on it, a picnic
// laid out by the hamper and a name flag behind it. Extended for the Mac design: blankets of one space
// share a mown patch, other machines sit across a stream, plain terminal panes are lanterns, and a cat
// shows when it needs you (red bubble) or finished unseen (check bubble).

let MAX_CATS = 24
private let MIN_DWELL: Float = 1.4             // every activity is shown at least this long so it can be read
private let SIZES: [Float] = [1, 0.72, 0.55, 0.45]
private func sizeAt(_ depth: Int) -> Float { SIZES[min(depth, SIZES.count - 1)] }
private let SEAT: Float = 1.35                 // room a full-size cat takes round its middle
private let GAP_ON_BLANKET: Float = 0.65
private let HUDDLE_GAP: Float = 1.8            // clear strip between one huddle and the next
private let SMALLEST: Float = 2.6              // the smallest blanket, as half its width
private let HEM: Float = 0.35
private let PICNIC_SPREAD: Float = 1.8
private let MOST_TREATS = 5
private let SPREAD_GAP: Float = 0.25
let TREAT_SIZE: Float = 1.4
private let GAP: Float = 5.5                   // standing grass between blankets
private let SPACE_GAP: Float = 4               // more between spaces, so each mown patch reads as its own
private let OBSTACLE_GAP: Float = 1.5
private let REPORT_SECONDS: Float = 1.3           // a finished helper faces its boss this long before leaving
private let ROW_GAP: Float = 1.6                // grass between blankets side by side in a row
private let COLUMN_GLANCE = 5                   // rows framed at once in a sidebar: what one glance holds
private let COLUMN_FEWEST = 3                   // and the fewest it is framed for, however few there are
private let COLUMN_SMALLEST: Float = 1.8       // a sidebar's smallest blanket, as half its width
private let COLUMN_SPREAD: Float = 1.0         // how far the picnic may reach beyond the cats there
private let COLUMN_FLAG_BACK: Float = 0.25        // the flag's foot, behind its blanket's far edge
private let COLUMN_FLAG_LOW: Float = 0.15         // and its height above the grass
private let COLUMN_FLAG_BAND: Float = 1.6         // ground a row keeps behind its blanket for its flag
private let COLUMN_GAP: Float = 1.3              // grass between rows in a sidebar's column
private let COLUMN_SWAY: Float = 0.2             // each row's offset from the lane, as a share of a typical blanket
private let COLUMN_MARGIN: Float = 0.3           // grass either side of the column in view
private let ROW_FLAG_AIR: Float = 0.4            // clear grass between two flags side by side in a row
private let FLAG_EDGE: Float = 10                // points a column's flag keeps from the view's sides
private let JOINED_GAP: Float = 2.6              // grass between a worktree's blanket and its repository's, in a loose picnic
private let COLUMN_JOINED_GAP: Float = 0.35      // and between their rows in a column, which is tighter than between workspaces
private let COLUMN_INDENT: Float = 0.6           // a worktree's row set in from its repository's, as a share of a typical blanket
let MOWN_MARGIN: Float = 3.2                   // how far a space's mown patch reaches past its blankets
private let STREAM_MARGIN: Float = 6           // clear ground each side of a stream
let STREAM_HALF_WIDTH: Float = 1.6
let FLAG_PIXELS: Float = 26
private let FLAG_RAISE: Float = 1.9
let LAMP_SIZE: Float = 1.5
let LAMP_HEIGHT: Float = 0.95 * TREAT_SIZE
let LANTERN_SIZE: Float = 1.0
let MOST_LANTERNS = 8                          // stood on one blanket at most; the rest are counted on its flag
private let LANTERN_SPACING: Float = 1.0       // between neighbours along the hem, middle to middle
private let LANTERN_HEM: Float = 0.12          // cloth left between a lantern and the edge
private let LANTERN_SPAN: Float = 0.55 * .pi   // how far round the hem from its front, either way

final class Actor {
    let cat: Cat
    var view: MeadowAgent
    var depth = 0
    var queue: [AgentActivity] = []
    var shownAt: Float
    var spot = Vec3.zero        // where on the blanket it sits
    var rootLocal = Vec3.zero   // where it is now, eased toward `spot`
    var size: Float = 1
    var shownSize: Float
    var pop = Sprung()
    var leaving = false
    /// A finished helper turns to its boss (its report) and leaves only after this time.
    var departAt: Float = 0
    var helpers: [Actor] = []
    /// A walk on its blanket under way: being handed its task, reporting, saying goodbye (`Errand`).
    var errand: Errand?
    /// Its life off the blanket while its Claude has nothing for it (`Roam.swift`).
    var roam: Roam
    var head = Vec3.zero
    /// Which way from the face its bubble sits on screen (a unit vector, y down), eased; whether it was
    /// placed last frame.
    var bubbleSide = Village.bubbleSides[0]
    var bubbleSeen = false
    init(cat: Cat, view: MeadowAgent, shownAt: Float, shownSize: Float, seed: String) {
        self.cat = cat; self.view = view; self.shownAt = shownAt; self.shownSize = shownSize
        roam = Roam(seed: seed)
        queue.reserveCapacity(4)
    }
}

struct TreatPlace {
    var kind: Int
    var spot = Vec3.zero
    var at = Vec3.zero          // eased
    var turn: Float
    var reach: Float
    var shown = Sprung()
    var wanted = false
    var placed = false
}

struct LanternPlace {
    var view: MeadowLantern
    var spot = Vec3.zero
    var at = Vec3.zero
    var shown = Sprung()
    var leaving = false
    var placed = false
    /// Not stood on the cloth: more lanterns than the hem has room for, counted on the flag instead.
    var hidden = false
    /// Its place along the hem (`Village.hemPlaces`), kept while it stays free so neighbours never shuffle.
    var slot: Int?
    var lit: Float = 1          // eased: 1 lit, 0 dark
    var red: Float = 0          // eased: 1 red
    let phase: Float
}

final class Plot {
    var view: MeadowBlanket
    var space: String
    var spaceIndex = 0
    var machine = 0
    let cloth: Int
    let turn: Float
    var actors: [String: Actor] = [:]
    var order: [String] = []           // launch order
    var treats: [TreatPlace] = []
    var lanterns: [LanternPlace] = []
    /// Lanterns with no room on the hem, and whether one of them failed: "+N" on the flag after dark.
    var lanternsHidden = 0
    var hiddenFailed = false
    /// The camp kettle its plain terminals share while no cat is on it (`Kettle.swift`).
    var kettle: KettlePlace
    var at: Vec2? = nil               // where in the meadow the middle of the blanket lies, once placed
    var home = Vec3.zero               // where the group sits so that its middle lands there
    var group = Vec3.zero              // eased toward home
    var center = Vec3.zero             // middle of its cats, relative to the group
    var size = SMALLEST                // half the blanket's width
    var radius = SMALLEST * Picnic.corner
    var middle = Vec3.zero             // the middle of the blanket in the world
    var blanketSize: Float = 0.01      // eased
    var blanketAt = Vec3.zero          // eased, group-local
    // Flag
    var label = FlagLabel()
    var flagAt = Vec3.zero             // world position of the flag's bottom middle
    var flagHeight: Float = 1          // world height of the pill
    var room: Float = FlagLabel.roomMost
    /// How wide its flag may be, in world units, beside its neighbours in a row (the column's rows form).
    var rowShare: Float = .infinity
    var lift: Float = 0
    var away: Float = 0
    var clear: Float = 1
    // Ladybird
    var ladybird = Vec3.zero
    var ladybirdTurn: Float = 0
    /// Its stepping stones' variety, and where its path to the blanket it is joined to begins and ends
    /// this frame (on the ground, x and z), when it has one.
    let pebbles: Pebbles
    var trailEnds: (Vec2, Vec2)?
    init(view: MeadowBlanket, space: String) {
        self.view = view
        self.space = space
        pebbles = Pebbles(view.id)
        kettle = KettlePlace(id: view.id)
        var r = chance(view.id)
        let pick = r.float()
        cloth = Int(pick * Float(Picnic.clothSeeds.count)) % Picnic.clothSeeds.count
        turn = pick * .pi * 7
    }
    var liveActors: some Sequence<Actor> { order.lazy.compactMap { self.actors[$0] } }
}

final class Village {
    private(set) var plots: [Plot] = []
    private var byID: [String: Plot] = [:]
    private(set) var time: Float = 0
    /// Reduce Motion: helpers do not trot and notes do not float; cats only look at each other, and stay on
    /// their blankets.
    var reduceMotion = false { didSet { if !wanders { bringEveryoneHome() } } }
    /// Ambient motion on (`MeadowView.animatesAmbient`). Off, every cat's own clock stops (`Cat.frozen`)
    /// and the ladybirds keep still; arrivals, departures and changes of state still show.
    var ambient = true {
        didSet {
            guard ambient != oldValue else { return }
            for plot in plots { for actor in plot.actors.values { actor.cat.frozen = !ambient } }
            if !wanders { bringEveryoneHome() }
        }
    }
    /// Cats wander when idle (Settings › Meadow; `MeadowSettings.catsWander`), with the motion playing and
    /// Reduce Motion off (`wanders`). Off, they stay on their blankets.
    var catsWander = true { didSet { if !wanders { bringEveryoneHome() } } }
    /// How much cats like walking on a spot of ground (x, z), 0 (plain grass) to 1, for the routes they take:
    /// painted paths and stepping stones, say. Nil: all ground alike.
    var liking: ((Vec2) -> Float)?
    /// What cats out in the grass go round, sniff and nap under (`lay`): the scenery's footprints, its
    /// flowers' blooms (x, height, z) and its trees' shade (x, z, reach).
    var footing: [SceneryRules.Circle] = []
    var blooms: [Vec3] = []
    var treeShade: [Vec3] = []
    /// The spots the scenery's things offer cats (a stump, a box, a bed, a post, a bowl).
    var places: [CatPlace] = []
    /// Seconds by the wall clock (the meadow's own time slows while it rests): what a cat's day goes by.
    var clock: Float = 0
    /// The grid a route is found on, kept from route to route; and the camera's projection as it was when
    /// last laid (`Roam.swift`).
    var roamField = RoamField()
    var screenMatrix = Mat4.identity
    var screenSize = Vec2(1, 1)
    /// Reduce Motion or ambient motion off: no trots or floating notes, and a helper appears in its seat
    /// rather than walking there from its boss.
    var hushed: Bool { reduceMotion || !ambient }
    /// The ladybirds' clock, which stops with ambient motion.
    private var strollTime: Float = 0
    /// Notes floating between cats, and notes waiting for their cats to be free (two at most).
    var notes: [FlyingNote] = []
    var waitingNotes: [(MeadowItem, MeadowItem)] = []
    /// The camera's right, along the ground, as of the last frame: where "beside" a cat is.
    var viewRight = Vec3(1, 0, 0)
    /// The stepping stones joining worktrees to their repositories, this frame: x, z, size, turn; and the
    /// strips of trodden grass under them (start and end, x and z), for the shaders.
    var stones: [Vec4] = []
    var stoneCount = 0
    var trodden: [Vec4] = []
    var troddenCount = 0
    /// Scratch for laying the paths: a route's corners, and the route with its bends rounded.
    var trailCorners: [Vec2] = []
    var trailPoints: [Vec2] = []
    /// The open view's width over its height: blankets spread out to match (wide in a wide window, in a
    /// column in a tall sidebar), so the camera can frame them all without shrinking them to dots.
    private(set) var aspect: Float = 1.6
    /// The aspect the blankets were last laid out for, all together.
    private var laidAspect: Float = 1.6
    var flagSize: Float = 1
    private(set) var picnic: MeadowSettings.Picnic = .hamper
    /// Ground blankets must keep off: tree roots, the fallen log.
    var obstacles: [Clearing] = []
    /// What is chosen: ringed blanket, ringed cat or lantern.
    var chosen: MeadowItem? { didSet { if chosen != oldValue { relabel() } } }
    /// Streams between machines: x at z = 0, wander, phase, half width.
    private(set) var streams: [Vec4] = []
    private(set) var spaceOrder: [String] = []
    /// Reused every frame when spacing flags.
    private var heads: [(x: Float, y: Float, r: Float, plot: Int)] = []
    private var marks: [(left: Float, top: Float, right: Float, bottom: Float)] = []
    /// Every flag's pill on screen this frame, in plot order; what bubbles keep off.
    private var flagBoxes: [ScreenBox] = []
    private var nearest: [Int] = []
    private var spaceSizes: [String: Int] = [:]
    private var spaceSizesVersion = -1
    /// Bumped when the ground the blankets cover changes.
    private(set) var layoutVersion = 0
    /// Bumped when workspaces join, leave or change places: what the sidebar's framing follows (never a
    /// blanket growing as helpers come and go).
    private(set) var lineup = 0

    var count: Int { plots.count }
    /// How much further the hamper may reach each time it finds no free cloth.
    static let hamperStep: Float = 0.3

    init() {
        heads.reserveCapacity(256)
        notes.reserveCapacity(16)
        waitingNotes.reserveCapacity(4)
        stones = [Vec4](repeating: .zero, count: MAX_STONES)
        trodden = [Vec4](repeating: .zero, count: MAX_TRODDEN)
        trailPoints.reserveCapacity(64)
        trailCorners.reserveCapacity(8)
        marks.reserveCapacity(64)
        flagBoxes.reserveCapacity(64)
        nearest.reserveCapacity(64)
    }

    func plot(_ id: String) -> Plot? { byID[id] }

    /// How many blankets share a row in the column arrangement: one in a sidebar, more as it widens.
    var perRow = 1 {
        didSet {
            guard perRow != oldValue, arrangement == .column, !plots.isEmpty else { return }
            arrange(relayingAll: true)
        }
    }

    /// A loose picnic, or one column in the given order (the app's sidebar).
    var arrangement: MeadowSettings.Arrangement = .picnic {
        didSet {
            guard arrangement != oldValue, !plots.isEmpty else { return }
            for plot in plots { layout(plot) }
            arrange(relayingAll: true)
        }
    }

    /// The column's lane (its middle's x), where its first blanket's far edge lies, and how wide it is
    /// with room either side: what a sidebar's camera frames.
    /// `glance` is how deep the rows framed at once reach (the first five, and never fewer than three).
    private(set) var column: (lane: Float, top: Float, width: Float, glance: Float)?

    /// The view's shape changed. New blankets follow it at once; a big change (a sidebar widened into a
    /// window, a window narrowed into a sidebar) lays every blanket out afresh, gliding to its new place.
    func fit(aspect proposed: Float) {
        guard proposed.isFinite, proposed > 0 else { return }
        aspect = clamp(proposed, 0.25, 4)
        if plots.isEmpty {
            laidAspect = aspect
        } else if abs(log(aspect / laidAspect)) > log(1.5) {
            laidAspect = aspect
            arrange(relayingAll: true)
        }
    }

    func setPicnic(_ to: MeadowSettings.Picnic) {
        if to == picnic { return }
        picnic = to
        for plot in plots { layout(plot) }
        arrange()
    }

    // MARK: what the meadow is told

    /// The world as given: blankets arrive, change and leave.
    func show(_ world: MeadowWorld) {
        var alive = Set<String>()
        var ordered: [Plot] = []
        var spaces: [String] = []
        for (m, machine) in world.machines.sorted(by: { $0.isLocal && !$1.isLocal }).enumerated() {
            for space in machine.spaces {
                let spaceKey = "\(machine.id)/\(space.id)"
                if !spaces.contains(spaceKey) { spaces.append(spaceKey) }
                for blanket in space.blankets {
                    alive.insert(blanket.id)
                    let plot = upsert(blanket, space: spaceKey)
                    plot.machine = m
                    plot.spaceIndex = spaces.firstIndex(of: spaceKey) ?? 0
                    ordered.append(plot)
                }
            }
        }
        for plot in plots where !alive.contains(plot.view.id) { byID[plot.view.id] = nil }
        if !ordered.elementsEqual(plots, by: { $0 === $1 }) { lineup += 1 }
        plots = ordered
        spaceOrder = spaces
        arrange()
        relabel()
    }

    private func upsert(_ view: MeadowBlanket, space: String) -> Plot {
        let plot: Plot
        let isNew = byID[view.id] == nil
        if let found = byID[view.id] { plot = found } else {
            plot = Plot(view: view, space: space)
            byID[view.id] = plot
        }
        plot.view = view
        plot.space = space

        // When a session ends its cats pop away, leaving the empty blanket.
        let shown = view.state == .ended ? [] : Array(view.agents.prefix(MAX_CATS))
        let present = Set(shown.map(\.id))
        for actor in plot.actors.values {
            if !actor.leaving && !present.contains(actor.view.id) {
                // A helper reports back before it goes: it trots over to its boss, hands over a note, the
                // boss nods, then it hops off (with Reduce Motion it only turns to its boss and the boss
                // looks over). Anyone else just gives one last happy hop.
                if let boss = actor.view.parentID.flatMap({ plot.actors[$0] }), boss !== actor, present.contains(boss.view.id),
                   let seconds = farewell(actor, to: boss) {
                    actor.departAt = time + seconds
                } else if let boss = actor.view.parentID.flatMap({ plot.actors[$0] }), boss !== actor, present.contains(boss.view.id) {
                    actor.cat.glance(boss.head, REPORT_SECONDS)
                    boss.cat.glance(actor.head, REPORT_SECONDS)
                    actor.departAt = time + REPORT_SECONDS
                } else {
                    actor.cat.hop()
                    actor.departAt = time
                }
            }
            actor.leaving = !present.contains(actor.view.id)
        }
        // Depth: how many launches from the blanket's own agent.
        var depthOf: [String: Int] = [:]
        for agent in shown {
            depthOf[agent.id] = agent.parentID.flatMap { depthOf[$0] }.map { $0 + 1 } ?? (agent.parentID == nil ? 0 : 1)
        }
        var arrivals: [Actor] = []
        for agent in shown {
            let effective: AgentActivity = agent.failed ? .error : agent.activity
            if let actor = plot.actors[agent.id] {
                actor.view = agent
                enqueue(actor, display(effective, for: actor))
            } else {
                let cat = Cat(seed: "\(view.id)/\(agent.id)")
                cat.frozen = !ambient
                cat.setActivity(effective)
                let actor = Actor(cat: cat, view: agent, shownAt: time, shownSize: sizeAt(depthOf[agent.id] ?? 0), seed: "\(view.id)/\(agent.id)")
                meet(actor)
                plot.actors[agent.id] = actor
                plot.order.append(agent.id)
                arrivals.append(actor)
            }
            let actor = plot.actors[agent.id]!
            actor.depth = depthOf[agent.id] ?? 0
            actor.cat.needsYou = agent.needsYou
            actor.cat.doneUnseen = agent.doneUnseen
            // Work, a request or a word from its Claude: a cat out in the grass runs home for it.
            reconsider(actor, in: plot)
        }
        // Lanterns: lit while running, dark when finished, red if failed.
        let lanternIDs = Set(view.lanterns.map(\.id))
        for i in plot.lanterns.indices { plot.lanterns[i].leaving = view.state == .ended || !lanternIDs.contains(plot.lanterns[i].view.id) }
        for lantern in view.lanterns where view.state != .ended {
            if let i = plot.lanterns.firstIndex(where: { $0.view.id == lantern.id }) {
                plot.lanterns[i].view = lantern
            } else {
                var r = chance("\(view.id)/lantern/\(lantern.id)")
                plot.lanterns.append(LanternPlace(view: lantern, phase: r.float() * 10))
            }
        }
        tellKettle(plot, view)
        layout(plot)
        for actor in arrivals {
            // A new helper appears beside whoever launched it and arrives with a hop. On a blanket that was
            // already there its boss hands it the task, it listens, then trots off to its seat; with the
            // whole blanket new (the app opening) everyone simply settles in, the boss watching.
            let boss = actor.view.parentID.flatMap { plot.actors[$0] }
            actor.rootLocal = hushed ? actor.spot : boss.map { $0 !== actor ? $0.rootLocal : actor.spot } ?? actor.spot
            actor.cat.jump(4, 1.5)
            if let boss, boss !== actor, !isNew, !arrivals.contains(where: { $0 === boss }), !boss.leaving {
                handOver(to: actor, from: boss)
            } else {
                boss?.cat.glance(plot.group + actor.spot + Vec3(0, 1.4, 0), 2)
            }
        }
        return plot
    }

    func enqueue(_ actor: Actor, _ activity: AgentActivity) {
        if activity == (actor.queue.last ?? actor.cat.activity) { return }
        if activity == .asking {
            // Needing you jumps the queue: it must never be hidden behind a backlog.
            actor.queue.removeAll(keepingCapacity: true)
            actor.queue.append(activity)
            actor.shownAt = -.infinity
            return
        }
        actor.queue.append(activity)
        if actor.queue.count > 2 { actor.queue.removeFirst(actor.queue.count - 2) }
    }

    // MARK: seating

    /// The blanket's own agent: the first with no parent.
    private func main(of plot: Plot) -> Actor? {
        plot.liveActors.first { $0.view.parentID == nil && !$0.leaving } ?? plot.liveActors.first { !$0.leaving }
    }

    // Sat about as if they had wandered over: the main cat near the middle, its helpers round it, and each
    // helper's own helpers huddled beside it. Every cat draws its place from its own name, and later
    // arrivals fit in around those already sitting, so nobody moves when someone new sits down. Then the
    // lanterns and a few things from the picnic basket, and the blanket is laid to fit.
    private func layout(_ plot: Plot) {
        let actors = plot.liveActors.filter { !$0.leaving }
        var seated: [Spot] = []
        let id = plot.view.id
        if let main = main(of: plot) {
            var helpers: [String: [Actor]] = [:]
            for actor in actors where actor !== main {
                let boss = actor.view.parentID.flatMap { plot.actors[$0] }
                let bossID = boss.map { !$0.leaving && $0 !== actor ? $0.view.id : main.view.id } ?? main.view.id
                helpers[bossID, default: []].append(actor)
            }
            var random = chance("\(id)/\(main.view.id)")
            main.size = 1
            main.spot = Vec3((random.float() - 0.5) * 1.2, 0, (random.float() - 0.5) * 1.2)
            main.cat.aside = (random.float() - 0.5) * 0.4
            main.cat.toward = nil
            seated.append(Spot(x: main.spot.x, z: main.spot.z, reach: SEAT))

            // Each helper of the main cat brings its own helpers along as one huddle. The huddles sit round
            // the main cat with a clear gap between them, so the picnic spreads over the cloth in little
            // groups with room for food between, rather than one crowd in the middle.
            var placed = Set<ObjectIdentifier>([ObjectIdentifier(main)])
            func family(_ boss: Actor, _ depth: Int, _ into: inout [Actor]) {
                boss.helpers = (helpers[boss.view.id] ?? []).filter { !placed.contains(ObjectIdentifier($0)) }
                for kid in boss.helpers {
                    placed.insert(ObjectIdentifier(kid))
                    kid.size = sizeAt(depth)
                    into.append(kid)
                    family(kid, depth + 1, &into)
                }
            }
            var huddles = [Spot(x: main.spot.x, z: main.spot.z, reach: SEAT)]
            main.helpers = (helpers[main.view.id] ?? []).filter { $0 !== main }
            for leader in main.helpers {
                placed.insert(ObjectIdentifier(leader))
                leader.size = sizeAt(1)
                var members: [Actor] = []
                family(leader, 2, &members)
                // Room for everyone in it, packed loosely.
                var packed: Float = 0
                for cat in [leader] + members {
                    let r: Float = SEAT * cat.size + GAP_ON_BLANKET / 2
                    packed += r * r
                }
                let room: Float = (packed * 1.35).squareRoot()
                var own = chance("\(id)/\(leader.view.id)")
                let near = SEAT + room + HUDDLE_GAP
                let aside = { (x: Float, z: Float) in !Self.before(x, z, main.spot) }
                var middle = settle(&own, huddles, room, HUDDLE_GAP, main.spot.x, main.spot.z, near, near + 1.5, fits: aside)
                var wider = 1
                while !middle.clear && wider < 10 {
                    middle = settle(&own, huddles, room, HUDDLE_GAP, main.spot.x, main.spot.z, near, near + 1.5 + Float(wider) * 1.5, fits: aside)
                    wider += 1
                }
                huddles.append(Spot(x: middle.x, z: middle.z, reach: room))
                // The leader near the middle of its huddle; its helpers close round whoever launched them.
                let reach = SEAT * leader.size
                let at = settle(&own, seated, reach, GAP_ON_BLANKET, middle.x, middle.z, 0, max(0.01, room - reach))
                leader.spot = Vec3(at.x, 0, at.z)
                leader.cat.aside = (own.float() - 0.5) * 0.5
                seated.append(Spot(x: at.x, z: at.z, reach: reach))
                let mx = middle.x, mz = middle.z
                for kid in members {
                    let boss = kid.view.parentID.flatMap { plot.actors[$0] } ?? leader
                    var mine = chance("\(id)/\(kid.view.id)")
                    let size = SEAT * kid.size, close = SEAT * boss.size + size + GAP_ON_BLANKET
                    var spot = settle(&mine, seated, size, GAP_ON_BLANKET, boss.spot.x, boss.spot.z, close, close + 1) { x, z in
                        hypot(x - mx, z - mz) <= room + 0.4 && !Self.before(x, z, boss.spot)
                    }
                    var w = 1
                    while !spot.clear && w < 8 {
                        spot = settle(&mine, seated, size, GAP_ON_BLANKET, boss.spot.x, boss.spot.z, close, close + 1 + Float(w) * 1.2)
                        w += 1
                    }
                    kid.spot = Vec3(spot.x, 0, spot.z)
                    kid.cat.aside = (mine.float() - 0.5) * 0.5
                    seated.append(Spot(x: spot.x, z: spot.z, reach: size))
                }
            }
        } else if plot.kettle.wanted {
            // No cat: the kettle stands where one would sit, near the middle, and the picnic is set out round it.
            var random = chance("\(id)/kettle/seat")
            let spot = Vec3((random.float() - 0.5) * 1.2, 0, (random.float() - 0.5) * 1.2)
            if !plot.kettle.placed || plot.kettle.shown.x < 0.01 { plot.kettle.at = spot; plot.kettle.placed = true }
            plot.kettle.spot = spot
            seated.append(Spot(x: spot.x, z: spot.z, reach: KETTLE_REACH))
        }

        // The blanket is laid around the middle of the family, with a hem of cloth beyond the outermost one.
        if !seated.isEmpty {
            let xs = seated.map(\.x), zs = seated.map(\.z)
            plot.center = Vec3((xs.min()! + xs.max()!) / 2, 0, (zs.min()! + zs.max()!) / 2)
        }
        let cx = plot.center.x, cz = plot.center.z
        let people = seated.map { hypot($0.x - cx, $0.z - cz) + $0.reach }.max() ?? 0
        // The picnic may spread a little beyond the cats; the blanket then grows to hold all of it.
        // In a sidebar's column the cloth is cut closer, so five workspaces fit in a glance with cats
        // still large enough to read.
        let smallest = arrangement == .column ? COLUMN_SMALLEST : SMALLEST
        let room = arrangement == .column ? COLUMN_SPREAD : PICNIC_SPREAD
        let spread = setTable(plot, seated, max(smallest - HEM, people + room))
        plot.size = max(smallest, max(people, spread) + HEM)
        plot.radius = plot.size * Picnic.corner
        placeLanterns(plot, seated)
    }

    // Lanterns only show after dark, so they take no part in the seating: they are set down last, in
    // cloth left free by the cats and the picnic, and never move anyone or make the blanket bigger. By day
    // nothing on the blanket says they are there.
    //
    // They stand in one row along the front of the hem (the side toward you as the meadow is usually
    // seen; the flag stands at the back), like lights along a stage: in front of every cat, so none hides
    // one, and far from the flag. The row starts straight in front and grows right, then left, a lantern
    // apart, passing over any place a cat or the picnic takes. Each keeps its place while it stays free,
    // so one coming or going never moves the others. At most `MOST_LANTERNS` stand (fewer if the hem has
    // less room): the failed first, then the lit, then the dark; the rest are counted on the flag.
    private func placeLanterns(_ plot: Plot, _ seated: [Spot]) {
        let reach = Picnic.lanternReach * LANTERN_SIZE
        var taken = seated
        for t in plot.treats where t.wanted { taken.append(Spot(x: t.spot.x, z: t.spot.z, reach: t.reach)) }
        func free(_ p: Vec2) -> Bool {
            taken.allSatisfy { hypot(p.x - $0.x, p.y - $0.z) >= $0.reach + reach + GAP_ON_BLANKET * 0.6 } && !Self.behind(p.x, p.y, reach, seated)
        }
        var places = hemPlaces(plot, inset: reach + LANTERN_HEM)
        var open = places.indices.filter { free(places[$0]) }
        // A crowded or small blanket may have no cloth wholly free along its hem: the lanterns then stand
        // on the edge, more than half on the cloth.
        if open.isEmpty {
            places = hemPlaces(plot, inset: reach * 0.5)
            open = places.indices.filter { free(places[$0]) }
        }
        func rank(_ l: LanternPlace) -> Int { l.view.state == .failed ? 0 : l.view.state == .running ? 1 : 2 }
        let live = plot.lanterns.indices.filter { !plot.lanterns[$0].leaving }
        let ranked = live.sorted { (rank(plot.lanterns[$0]), $0) < (rank(plot.lanterns[$1]), $1) }
        let standing = ranked.prefix(min(MOST_LANTERNS, open.count))
        // Those already standing keep their places; newcomers take the free place nearest the front.
        var claimed = Set<Int>()
        for i in standing {
            if let slot = plot.lanterns[i].slot, open.contains(slot), claimed.insert(slot).inserted { continue }
            plot.lanterns[i].slot = nil
        }
        for i in standing where plot.lanterns[i].slot == nil {
            let slot = open.first { !claimed.contains($0) }!
            claimed.insert(slot)
            plot.lanterns[i].slot = slot
        }
        var hidden = 0, hiddenFailed = false
        for i in live {
            guard let slot = plot.lanterns[i].slot, standing.contains(i) else {
                plot.lanterns[i].hidden = true
                plot.lanterns[i].slot = nil
                hidden += 1
                hiddenFailed = hiddenFailed || plot.lanterns[i].view.state == .failed
                continue
            }
            let at = places[slot]
            // Set down where it first stands rather than sliding along the hem from where it last stood.
            if !plot.lanterns[i].placed || plot.lanterns[i].hidden { plot.lanterns[i].at = Vec3(at.x, 0, at.y); plot.lanterns[i].placed = true }
            plot.lanterns[i].hidden = false
            plot.lanterns[i].spot = Vec3(at.x, 0, at.y)
        }
        if hidden != plot.lanternsHidden || hiddenFailed != plot.hiddenFailed {
            plot.lanternsHidden = hidden
            plot.hiddenFailed = hiddenFailed
            label(plot)
        }
    }

    /// Places for lanterns along the front of a blanket's hem, `inset` in from its edge: straight in front
    /// first, then alternately to the right and the left, `LANTERN_SPACING` apart along the hem, as far
    /// round as `LANTERN_SPAN`. Group-local, as the blanket is laid now.
    func hemPlaces(_ plot: Plot, inset: Float) -> [Vec2] {
        func point(_ phi: Float) -> Vec2 {
            let toward = Vec2(sin(phi), cos(phi))
            return Vec2(plot.center.x, plot.center.z) + toward * (clothReach(plot, toward: toward) - inset)
        }
        var sides: [[Vec2]] = [[], []]
        for (k, sign) in [Float(1), -1].enumerated() {
            var walked: Float = 0, last = point(0), next = LANTERN_SPACING
            for step in 1...200 {
                let p = point(sign * LANTERN_SPAN * Float(step) / 200)
                walked += simd_distance(p, last)
                last = p
                if walked >= next { sides[k].append(p); next += LANTERN_SPACING }
            }
        }
        var places = [point(0)]
        for k in 0..<max(sides[0].count, sides[1].count) {
            if k < sides[0].count { places.append(sides[0][k]) }
            if k < sides[1].count { places.append(sides[1][k]) }
        }
        return places
    }

    /// How far the cloth reaches from its middle along a direction on the ground (x, z), as laid now: its
    /// outline turned the blanket's way and scaled to its size.
    func clothReach(_ plot: Plot, toward: Vec2) -> Float {
        // Into the cloth's own frame (`Mat4.rotationY(turn)` undone), whose outline lies in (x, −z).
        let c = cos(plot.turn), s = sin(plot.turn)
        let x = c * toward.x - s * toward.y, z = s * toward.x + c * toward.y
        return Picnic.clothReach(Picnic.clothSeeds[plot.cloth], atan2(-z, x)) * plot.size
    }

    /// How far the lanterns are out, 0 by day to 1 at night: the same night amount the picnic light uses,
    /// eased so a change of setting fades them rather than popping them.
    private(set) var lanternLight: Float = 0
    /// How much of a lantern shows now, 0…1 (its own pop in and out, and the dark).
    func shown(_ lantern: LanternPlace) -> Float { max(lantern.shown.x, 0) * lanternLight }
    /// Whether it is dark enough for lanterns: flags then count those with no room on their blankets.
    private(set) var lanternsOut = false

    // The picnic, laid out as one spread the way people set one down: the hamper first, to one side of the
    // cats, and a few things unpacked beside it. Which things, and where, come from the tab's name so the
    // spread is the same every time. Returns how far from the middle the spread reaches.
    //
    // The hamper is always set down: where the cats leave no free cloth for it (a lone cat on the smallest
    // blanket), the reach it may have grows a little at a time until it fits, and the blanket then grows to
    // hold it, as it does for a spread. Nobody is moved for it; only the cloth gets bigger.
    private func setTable(_ plot: Plot, _ seated: [Spot], _ given: Float) -> Float {
        var room = given
        var random = chance("\(plot.view.id)/picnic")
        var kinds = Array(1..<Picnic.treats.count)
        for i in stride(from: kinds.count - 1, to: 0, by: -1) {
            let j = Int(random.float() * Float(i + 1))
            kinds.swapAt(i, j)
        }
        kinds.insert(0, at: 0)
        let count = plot.view.state == .ended || picnic == .none ? 0 : picnic == .hamper ? 1 : clamp(Int((room * 0.6).rounded()), 2, MOST_TREATS)
        let cx = plot.center.x, cz = plot.center.z
        var taken = seated
        var reach: Float = 0
        var hamper: Spot? = nil
        for i in 0..<max(count, plot.treats.count) {
            let kind = kinds[i % kinds.count]
            if i >= plot.treats.count {
                plot.treats.append(TreatPlace(kind: kind, turn: random.float() * .pi * 2, reach: Picnic.treats[kind].reach * TREAT_SIZE))
            }
            let treatReach = plot.treats[i].reach
            var own = chance("\(plot.view.id)/picnic/\(i)")
            let limit = room
            let fits = { (x: Float, z: Float) in hypot(x - cx, z - cz) + treatReach <= limit && !Self.behind(x, z, treatReach, seated) }
            // The hamper goes out toward the edge; everything else is set down within arm's reach of it.
            var at: (x: Float, z: Float, clear: Bool)? = nil
            if i < count {
                if let hamper {
                    let beside = hamper.reach + treatReach + SPREAD_GAP
                    at = settle(&own, taken, treatReach, SPREAD_GAP, hamper.x, hamper.z, beside, beside + 1.2, fits: fits)
                } else {
                    var found = settle(&own, taken, treatReach, GAP_ON_BLANKET, cx, cz, room * 0.45, room, fits: fits)
                    var wider = room
                    while !found.clear && wider < given + 6 * treatReach {
                        wider += Self.hamperStep
                        let reaching = wider
                        found = settle(&own, taken, treatReach, GAP_ON_BLANKET, cx, cz, given * 0.45, reaching) { x, z in
                            hypot(x - cx, z - cz) + treatReach <= reaching && !Self.behind(x, z, treatReach, seated)
                        }
                    }
                    // Whatever is unpacked beside it may use the cloth it needed.
                    if found.clear { room = max(room, wider) }
                    at = found
                }
            }
            if let at, at.clear, hamper == nil { hamper = Spot(x: at.x, z: at.z, reach: treatReach) }
            plot.treats[i].wanted = at?.clear ?? false
            guard let at, at.clear else { continue }
            // Set down where it first lands rather than sliding across from the middle.
            if !plot.treats[i].placed || plot.treats[i].shown.x < 0.01 { plot.treats[i].at = Vec3(at.x, 0, at.z); plot.treats[i].placed = true }
            plot.treats[i].spot = Vec3(at.x, 0, at.z)
            taken.append(Spot(x: at.x, z: at.z, reach: treatReach))
            reach = max(reach, hypot(at.x - cx, at.z - cz) + treatReach)
        }
        return reach
    }

    /// Whether a seat lies straight in front of a boss as the meadow is usually seen (from +z): a helper
    /// there, turned toward its boss, would sit with its back to you. Helpers sit beside and behind their
    /// boss instead, so turning in toward it is also turning toward you.
    static func before(_ x: Float, _ z: Float, _ boss: Vec3) -> Bool {
        let ahead = z - boss.z
        return ahead > 0 && abs(x - boss.x) < ahead * 0.7
    }

    /// Whether something of this reach set down here would stand just behind a cat as the meadow is
    /// usually seen (from +z, above): on screen it would rise behind the cat's head, against its face and
    /// its bubble. The picnic keeps out of that strip.
    static func behind(_ x: Float, _ z: Float, _ reach: Float, _ seated: [Spot]) -> Bool {
        seated.contains { cat in z < cat.z && cat.z - z < cat.reach * 2 + reach && abs(x - cat.x) < cat.reach * 0.8 + reach }
    }

    // Blankets keep the places they were given. A new one, or one that has grown into a neighbour, is laid
    // in the nearest free patch: beside its own space's blankets if it has any, clear of every other
    // blanket by a strip of grass (a wider one between spaces) and clear of trees and the log; another
    // machine's blankets lie across a stream. Searching outward in a slightly stretched spiral, turned
    // differently for each tab, keeps the spread loose rather than a grid.
    private func arrange(relayingAll: Bool = false) {
        if arrangement == .column { return arrangeColumn() }
        column = nil
        for plot in plots { plot.rowShare = .infinity }
        var laid: [(x: Float, z: Float, r: Float, space: String, id: String, home: String?)] = []
        // Across over deep is stretch²; on screen the ground's depth is foreshortened, so a tall view
        // wants the blankets laid deeper still than its own shape.
        let stretch = sqrt(clamp(aspect, 0.25, 3))
        let machines = (plots.map(\.machine).max() ?? 0) + 1
        var streamAt = [Float](repeating: 0, count: machines)
        var newStreams: [Vec4] = []
        for m in 0..<machines {
            let left: Float? = m > 0 ? streamAt[m - 1] + STREAM_MARGIN : nil
            for plot in plots where plot.machine == m {
                // A worktree's blanket goes beside its repository's (laid already), a little closer than
                // workspaces usually lie, and its fellow worktrees as close.
                let home = plot.view.joinedTo.flatMap { id in laid.contains { $0.id == id } ? id : nil }
                func gap(_ o: (x: Float, z: Float, r: Float, space: String, id: String, home: String?)) -> Float {
                    if o.space == plot.space { return GAP }
                    if let home, o.id == home || o.home == home { return JOINED_GAP }
                    return GAP + SPACE_GAP
                }
                func free(_ x: Float, _ z: Float, _ r: Float) -> Bool {
                    if let left, x - r < left { return false }
                    for o in laid where hypot(x - o.x, z - o.z) < r + o.r + gap(o) { return false }
                    for o in obstacles where hypot(x - o.x, z - o.z) < r + o.r + OBSTACLE_GAP { return false }
                    return true
                }
                let fresh = plot.at == nil
                if relayingAll || plot.at == nil || !free(plot.at!.x, plot.at!.y, plot.radius) {
                    var turnRandom = chance("\(plot.view.id)/place")
                    let turn = turnRandom.float() * .pi * 2
                    // Beside its repository, or its space if the space has blankets already; else where its
                    // machine's ground starts.
                    let mate = laid.first { $0.id == home } ?? laid.first { $0.space == plot.space }
                    let origin = mate.map { Vec2($0.x, $0.z) } ?? Vec2(left.map { $0 + plot.radius + 2 } ?? 0, 0)
                    var found = origin
                    var out: Float = 0
                    search: while out < 160 {
                        let steps = max(1, Int(2 * .pi * out / 2.5))
                        for i in 0..<steps {
                            let angle = turn + Float(i) / Float(steps) * 2 * .pi
                            let x = origin.x + cos(angle) * out * stretch, z = origin.y + sin(angle) * out / stretch
                            if free(x, z, plot.radius) { found = Vec2(x, z); break search }
                        }
                        out += 1.5
                    }
                    plot.at = found
                }
                laid.append((plot.at!.x, plot.at!.y, plot.radius, plot.space, plot.view.id, home))
                plot.home = Vec3(plot.at!.x, 0, plot.at!.y) - plot.center
                if fresh {
                    plot.group = plot.home
                    plot.middle = Vec3(plot.at!.x, 0, plot.at!.y)
                    plot.blanketAt = plot.center
                }
            }
            // The stream past this machine's ground, if another machine follows.
            if m < machines - 1 {
                let right = plots.filter { $0.machine == m }.map { $0.at!.x + $0.radius }.max() ?? 0
                streamAt[m] = right + STREAM_MARGIN
                var r = chance("stream/\(m)")
                newStreams.append(Vec4(streamAt[m], 2.5, r.float() * 6.28, STREAM_HALF_WIDTH))
            }
        }
        streams = Array(newStreams.prefix(MAX_STREAMS))
        layoutVersion += 1
    }

    /// One blanket per row, in the order given, top to bottom, swaying a little left and right of the
    /// lane so the column reads as a loose picnic rather than a list. The order never changes by itself.
    /// The lane runs down the middle of the picnic ground (x = 0), which the meadow's editor keeps big things
    /// off (`SceneryRules.picnicGround`); it never looks at the scenery, which can be moved: whatever stands
    /// where a blanket comes makes way for it.
    private func arrangeColumn() {
        guard !plots.isEmpty else { column = nil; return }
        // Framed for a typical blanket (the median), so one big crowd does not shrink every cat; a bigger
        // blanket reaches past the sides a little.
        let radii = plots.map(\.radius).sorted()
        let typical = radii[radii.count / 2]
        let perRow = max(1, perRow)
        let rows = stride(from: 0, to: plots.count, by: perRow).map { Array(plots[$0..<min($0 + perRow, plots.count)]) }
        // A row's width: its blankets side by side with grass between; the widest row sets the lane's reach.
        func rowWidth(_ row: [Plot]) -> Float { row.reduce(Float(0)) { $0 + $1.radius * 2 } + Float(row.count - 1) * ROW_GAP }
        // Rows start from a fixed left edge worked out from a nominal blanket, not from the blankets there
        // now, so a workspace joining (or a blanket growing) never moves the ones before it.
        let unit = COLUMN_SMALLEST * Picnic.corner
        let nominalRow = Float(perRow) * unit * 2 + Float(perRow - 1) * ROW_GAP
        let sway = perRow == 1 ? typical * COLUMN_SWAY : unit * 0.35
        // In one column a worktree's row is set in from its repository's (toward the lane), so it reads as
        // nested beneath it; it needs a little more room on that side.
        let indent = typical * COLUMN_INDENT
        var homes: [ObjectIdentifier: Plot] = [:]
        if perRow == 1 {
            var before: [String: Plot] = [:]
            for plot in plots {
                if let id = plot.view.joinedTo, let home = before[id] { homes[ObjectIdentifier(plot)] = home }
                before[plot.view.id] = plot
            }
        }
        var reach = perRow == 1 ? (rows.map(rowWidth).max() ?? typical * 2) / 2 + sway : nominalRow / 2 + sway
        for plot in plots where homes[ObjectIdentifier(plot)] != nil { reach = max(reach, indent - sway + plot.radius) }
        let length = rows.reduce(Float(0)) { $0 + ($1.map(\.radius).max() ?? typical) * 2 + COLUMN_FLAG_BAND } + Float(rows.count - 1) * COLUMN_GAP
        let lane = Self.columnLane
        var z: Float = 0
        var previousDepth: Float?
        var index = 0
        for (r, row) in rows.enumerated() {
            let depth = row.map(\.radius).max() ?? typical
            let home = row.count == 1 ? homes[ObjectIdentifier(row[0])] : nil
            // Between rows: grass (less under a worktree's), then the row's flag band, then its cloth.
            let between = home == nil ? COLUMN_GAP : COLUMN_JOINED_GAP
            if let previousDepth { z += previousDepth + between + COLUMN_FLAG_BAND + depth } else { z = COLUMN_FLAG_BAND + depth }
            // Read left to right; every other row set a little aside, and each blanket nudged by its own
            // name, so the rows read as a loose picnic rather than a grid. A single column sways instead.
            var x = lane - nominalRow / 2 + (perRow > 1 && r % 2 == 1 ? sway : 0)
            for plot in row {
                var nudge = chance("\(plot.view.id)/row")
                let px: Float, pz: Float
                if perRow == 1, let homeAt = home?.at {
                    // Set in from its repository toward the lane; the column's sway carries on after it.
                    px = homeAt.x + (homeAt.x <= lane ? indent : -indent)
                    pz = z
                    index -= 1
                } else if perRow == 1 {
                    px = lane + (index % 2 == 0 ? -sway : sway)
                    pz = z
                } else {
                    px = x + plot.radius + (nudge.float() - 0.5) * plot.radius * 0.3
                    pz = z + (nudge.float() - 0.5) * (depth - plot.radius + 0.6)
                }
                x += plot.radius * 2 + ROW_GAP
                index += 1
                let fresh = plot.at == nil
                plot.at = Vec2(px, pz)
                plot.home = Vec3(px, 0, pz) - plot.center
                if fresh {
                    plot.group = plot.home
                    plot.middle = Vec3(px, 0, pz)
                    plot.blanketAt = plot.center
                }
            }
            // Each flag stands over its blanket's middle; it may be as wide as the nearer neighbour is far,
            // less a strip of grass, so flags side by side never meet.
            for (k, plot) in row.enumerated() {
                guard let at = plot.at else { continue }
                let left = k > 0 ? row[k - 1].at.map { at.x - $0.x } : nil
                let right = k + 1 < row.count ? row[k + 1].at.map { $0.x - at.x } : nil
                plot.rowShare = Swift.min(left ?? .infinity, right ?? .infinity) - ROW_FLAG_AIR
                // A worktree's flag keeps over its own cloth, leaving room beside it for the path in.
                if home != nil { plot.rowShare = 2 * (plot.radius + 0.2) }
            }
            previousDepth = depth
        }
        // A single column is framed for five rows when it has five or more, so blankets keep one size
        // however many follow; with fewer, for three, so one or two workspaces sit large in the middle of
        // the meadow rather than small in a field of grass. Wider, the whole set is framed.
        let shown = plots.prefix(COLUMN_GLANCE)
        let framed = max(shown.count, COLUMN_FEWEST)
        let glance = shown.reduce(Float(0)) { $0 + $1.radius * 2 + COLUMN_FLAG_BAND }
            + Float(framed - shown.count) * (typical * 2 + COLUMN_FLAG_BAND) + Float(framed - 1) * COLUMN_GAP
        column = (lane, 0, 2 * (reach + COLUMN_MARGIN), perRow == 1 ? glance : length)
        streams = []
        layoutVersion += 1
    }

    /// Where the column's lane runs: down the middle of the picnic ground.
    static let columnLane: Float = 0

    /// What a sidebar's camera frames in the column, as the blankets lie now: the middle of the lane or of
    /// the rows (x), how far either way the ground to fit reaches (`across`, `deep`), and the content's
    /// top (the foot of the first row's flags, in the world) and bottom (the nearest cloth's edge).
    struct ColumnFrame {
        var x: Float, across: Float, deep: Float
        var top: Vec3, bottom: Vec3
        /// The left and right edges of each blanket framed at once (on the ground, at its middle's depth):
        /// what must stay inside the view's sides.
        var sides: [Vec3]
    }
    var columnFrame: ColumnFrame? {
        guard let column, !plots.isEmpty else { return nil }
        let rows = max(1, perRow)
        let first = plots.prefix(rows), last = plots.suffix(from: (plots.count - 1) / rows * rows)
        let top = first.compactMap { $0.at.map { p in p.y } }.min() ?? 0
        let flagFoot = top - (first.map(\.size).max() ?? 0) - COLUMN_FLAG_BACK
        let bottom = last.compactMap { p in p.at.map { $0.y + p.radius } }.max() ?? 0
        let framedPlots = plots.prefix(rows == 1 ? COLUMN_GLANCE : rows * COLUMN_FEWEST)
        let sides = framedPlots.flatMap { p in p.at.map { [Vec3($0.x - p.radius, 0, $0.y), Vec3($0.x + p.radius, 0, $0.y)] } ?? [] }
        if rows == 1 {
            // Five rows, or the column's width, whichever needs the camera further back. `fit` frames a
            // patch seen from above; along a column seen at this pitch the far rows shrink, so five rows
            // need a little less depth than it asks for.
            // Across the middle of the blankets there, so one that sways aside is not left off centre.
            let xs = plots.compactMap { $0.at?.x }
            let middle = ((xs.min() ?? column.lane) + (xs.max() ?? column.lane)) / 2
            return ColumnFrame(x: middle, across: column.width / 2, deep: column.glance / 2 * 0.88,
                               top: Vec3(middle, COLUMN_FLAG_LOW, flagFoot), bottom: Vec3(middle, 0, bottom), sides: sides)
        }
        // Wider than a sidebar: the whole width, and as deep as the first three rows (more scroll, as in a
        // sidebar, rather than every cat shrinking), never closer than about two blankets across, so one
        // workspace sits in a meadow rather than a close-up.
        let b = bounds
        let near = framedPlots.compactMap { p in p.at.map { $0.y + p.radius } }.max() ?? bottom
        let deep = (near - flagFoot) / 2 + 0.7
        return ColumnFrame(x: b.x, across: max(b.across + 1.2, 10), deep: max(deep, 7.5),
                           top: Vec3(b.x, COLUMN_FLAG_LOW, flagFoot), bottom: Vec3(b.x, 0, bottom), sides: sides)
    }

    /// The ground each blanket covers, in the shaders' order: x, z, radius, mown radius; and each one's
    /// patch: stripe angle, space index.
    func clearings(into world: inout WorldUniforms, eased: Bool, dt: Float) -> Int {
        let n = min(plots.count, MAX_CLEARINGS)
        if spaceSizesVersion != layoutVersion {
            spaceSizesVersion = layoutVersion
            spaceSizes.removeAll(keepingCapacity: true)
            for plot in plots { spaceSizes[plot.space, default: 0] += 1 }
        }
        for i in 0..<n {
            let plot = plots[i], at = plot.at ?? .zero
            var slot = world.clearings[i]
            let wasNew = slot.z < 0
            slot.x = at.x; slot.y = at.y
            if wasNew { slot.z = 0 }
            // A newly laid blanket presses the grass down from nothing; one that only moved keeps its size.
            slot.z += (plot.radius - slot.z) * (eased ? min(1, dt * 4) : 1)
            // A mown patch only groups blankets: a space with one blanket has none.
            slot.w = (spaceSizes[plot.space] ?? 0) > 1 ? slot.z + MOWN_MARGIN : 0
            world.clearings[i] = slot
            var r = chance("space/\(plot.space)")
            // A column's flag stands low, in grass trodden along it (as of the last frame's flag).
            let flag = arrangement == .column ? Vec2(plot.flagHeight * plot.label.aspect / 2 + 0.2, plot.flagAt.z - at.y) : .zero
            world.patches[i] = Vec4(r.float() * .pi, Float(plot.spaceIndex), flag.x, flag.y)
        }
        for i in n..<MAX_CLEARINGS { world.clearings[i] = Vec4(0, 0, -100, 0) }
        return n
    }

    // MARK: each frame

    func update(_ dt: Float, _ around: Surroundings, stage: Stage) {
        time += dt
        if ambient { strollTime += dt }
        lanternLight += (stage.light.night - lanternLight) * min(1, dt * 2)
        if lanternLight < 0.002 { lanternLight = 0 }
        if (lanternLight > 0.5) != lanternsOut {
            lanternsOut = lanternLight > 0.5
            relabel()
        }
        for plot in plots {
            plot.group += (plot.home - plot.group) * min(1, dt * 4)
            plot.blanketSize += (plot.size - plot.blanketSize) * min(1, dt * 5)
            plot.blanketAt += (plot.center - plot.blanketAt) * min(1, dt * 5)
            plot.middle = plot.blanketAt + plot.group
            raiseFlag(plot, stage)
            crawl(plot)
            for i in plot.treats.indices {
                plot.treats[i].shown.spring(plot.treats[i].wanted ? 1 : 0, 180, 16, dt)
                plot.treats[i].at += (plot.treats[i].spot - plot.treats[i].at) * min(1, dt * 3)
            }
            for i in plot.lanterns.indices {
                plot.lanterns[i].shown.spring(plot.lanterns[i].leaving || plot.lanterns[i].hidden ? 0 : 1, 180, 16, dt)
                plot.lanterns[i].at += (plot.lanterns[i].spot - plot.lanterns[i].at) * min(1, dt * 3)
                let state = plot.lanterns[i].view.state
                plot.lanterns[i].lit += ((state == .finished ? 0 : 1) - plot.lanterns[i].lit) * min(1, dt * 4)
                plot.lanterns[i].red += ((state == .failed ? 1 : 0) - plot.lanterns[i].red) * min(1, dt * 4)
            }
            plot.lanterns.removeAll { $0.leaving && $0.shown.x < 0.02 }
            runKettle(plot, dt)

            var gone: [String] = []
            for id in plot.order {
                guard let actor = plot.actors[id] else { continue }
                if !actor.leaving && !actor.queue.isEmpty && time - actor.shownAt >= MIN_DWELL {
                    actor.cat.setActivity(actor.queue.removeFirst())
                    actor.shownAt = time
                    // Something went wrong: everyone else on the blanket looks over.
                    if actor.cat.activity == .error { for other in plot.actors.values where other !== actor { other.cat.glance(actor.head, 2) } }
                }
                // A boss keeps an eye on its helpers; a cat that is done spins on its way out.
                actor.cat.wards.removeAll(keepingCapacity: true)
                if actor.cat.activity == .supervising { for helper in actor.helpers where !helper.leaving { actor.cat.wards.append(helper.head) } }
                let going = actor.leaving && time >= actor.departAt
                if going && ambient { actor.cat.spin += dt * 11 }
                actor.pop.spring(going ? 0 : 1, 180, 16, dt)
                actor.shownSize += (actor.size - actor.shownSize) * min(1, dt * 5)
                if actor.errand != nil { runErrand(actor, in: plot) } else { roam(actor, in: plot, dt, stage) }
                actor.cat.position = plot.group + actor.rootLocal
                actor.cat.size = max(actor.pop.x, 0.001) * actor.shownSize
                actor.cat.update(dt, around)
                actor.head = actor.cat.head
                // Helpers lean toward their boss where it is now (it may be moving), not where it sat once.
                for helper in actor.helpers { helper.cat.toward = actor.leaving ? nil : actor.head }
                if actor.leaving && actor.pop.x < 0.03 { gone.append(id) }
            }
            for id in gone { plot.actors[id] = nil; plot.order.removeAll { $0 == id } }
        }
        spaceFlags(dt, stage)
        placeBubbles(dt, stage)
        updateNotes(stage)
        layTrails(stage)
    }

    /// Every cat to draw this frame.
    func collectCats(into cats: inout [Cat]) {
        for plot in plots { for actor in plot.liveActors { cats.append(actor.cat) } }
    }

    /// Nothing moving fast: every cat at rest and fully arrived.
    var restful: Bool {
        if !notes.isEmpty || !waitingNotes.isEmpty { return false }
        for plot in plots {
            for actor in plot.actors.values where actor.leaving || actor.errand != nil || actor.pop.x < 0.98 || !actor.cat.restful { return false }
            // Running home for work is drawn at the full rate.
            for actor in plot.actors.values where actor.roam.phase == .recalled || actor.roam.phase == .settling { return false }
        }
        return true
    }

    /// Nothing under way but each cat's own slow loop: no arrival, departure, errand or note, and every
    /// cat `still`.
    var still: Bool {
        if !notes.isEmpty || !waitingNotes.isEmpty { return false }
        for plot in plots {
            if abs(plot.blanketSize - plot.size) > 0.01 || simd_distance(plot.group, plot.home) > 0.01 || !kettleStill(plot) { return false }
            for actor in plot.actors.values where actor.leaving || actor.errand != nil || actor.pop.x < 0.98 || !actor.cat.still { return false }
        }
        return true
    }

    // The ladybird ambles round the blanket in a slow wobbly loop, always heading the way it faces.
    private func crawl(_ plot: Plot) {
        let t = strollTime * 0.22 + plot.middle.x
        let out = plot.blanketSize * (0.55 + 0.3 * sin(t * 1.7))
        let was = plot.ladybird
        plot.ladybird = Vec3(plot.blanketAt.x + cos(t) * out, 0.005, plot.blanketAt.z + sin(t) * out)
        plot.ladybirdTurn = atan2(plot.ladybird.x - was.x, plot.ladybird.z - was.z)
    }

    // MARK: flags

    /// The chat's own name, the colour dot (hollow when watched from outside), dark when chosen.
    private func relabel() {
        for plot in plots { label(plot) }
    }
    private func label(_ plot: Plot) {
        let more = lanternsOut ? plot.lanternsHidden : 0
        plot.label.update(FlagLabel.Inputs(name: plot.view.title, detail: plot.view.detail, pinned: plot.view.pinned, color: plot.view.color,
                                           chosen: chosen?.blanketID == plot.view.id, hollow: plot.view.state == .watchOnly,
                                           remote: plot.machine > 0, more: more, moreFailed: more > 0 && plot.hiddenFailed, room: plot.room))
    }

    // The flag stands just past the far edge of the blanket as you look at it, raised above the height of a
    // cat. Every cat on the blanket is nearer to you than it, so is drawn over it: a flag can never cover one
    // of its own cats, from any angle. Like a label on a map it keeps one size on screen however far you
    // zoom, cut shorter rather than shrunk when its name will not fit beside its neighbours.
    private func raiseFlag(_ plot: Plot, _ stage: Stage) {
        let eye = stage.camera.eye
        if arrangement == .column {
            // In a sidebar's column the flag stands in its own row's band of grass, just behind its blanket
            // and low, so it never reaches the row above.
            plot.flagAt = plot.group + plot.blanketAt + Vec3(0, 0, -(plot.blanketSize + COLUMN_FLAG_BACK))
            plot.flagAt.y = COLUMN_FLAG_LOW
        } else {
        var edge = plot.middle - eye
        edge.y = 0
        if simd_length_squared(edge) < 1e-6 { edge = Vec3(0, 0, -1) }
        edge = simd_normalize(edge) * plot.blanketSize * 1.05
        plot.flagAt = plot.group + plot.blanketAt + edge
        plot.flagAt.y = FLAG_RAISE
        }
        let perPixel = 2 * tan(MapCamera.fovY / 2) / max(stage.camera.viewport.y, 1)
        let away = simd_distance(eye, plot.flagAt)
        let perPoint = perPixel * away, pixel = perPoint * flagSize
        // The ground a flag may span: in a loose picnic, its blanket and the grass round it; in the column,
        // its share of its row and never past the view's sides (which it would be cut by).
        var share = 2 * plot.radius + GAP - 1
        if arrangement == .column {
            // Points on screen per world unit across, where the flag stands.
            let at = stage.screen(plot.flagAt), aside = stage.screen(plot.flagAt + stage.surroundings.right)
            let open = stage.camera.viewport.x - stage.camera.cover.x
            let edges = at.z > 1 ? Float.infinity : 2 * (min(at.x, open - at.x) - FLAG_EDGE) / max(abs(aside.x - at.x), 1e-3)
            share = max(min(plot.rowShare, edges), 0)
        }
        let room = clamp(floor(share / pixel / 10) * 10, FlagLabel.roomLeast, FlagLabel.roomMost)
        if room != plot.room {
            plot.room = room
            label(plot)
        }
        plot.flagHeight = min(FLAG_PIXELS * pixel, share / plot.label.aspect)
    }

    // Flags must never sit on another session's cats or on another flag, from any angle. Every frame,
    // nearest first, each flag takes the lowest of a few heights up its own line that is clear on screen of
    // the flags already placed and of every other blanket's cats; if none is, it stays put and goes faint.
    private func spaceFlags(_ dt: Float, _ stage: Stage) {
        heads.removeAll(keepingCapacity: true)
        let up = stage.surroundings.up
        for (p, plot) in plots.enumerated() {
            for actor in plot.liveActors where !actor.leaving {
                let point = stage.screen(actor.head), edge = stage.screen(actor.head + up * (1.1 * actor.shownSize))
                if point.z > 1 { continue }
                heads.append((point.x, point.y, hypot(edge.x - point.x, edge.y - point.y), p))
            }
        }
        nearest.removeAll(keepingCapacity: true)
        let eye = stage.camera.eye
        for (p, plot) in plots.enumerated() {
            plot.away = simd_distance_squared(plot.flagAt, eye)
            nearest.append(p)
        }
        nearest.sort { plots[$0].away < plots[$1].away }
        marks.removeAll(keepingCapacity: true)
        let step = min(1, dt * 6)
        for p in nearest {
            let plot = plots[p]
            if arrangement == .column {
                // Each flag has its row's band to itself: it stays put and stays clear.
                plot.lift += (0 - plot.lift) * step
                plot.clear += (1 - plot.clear) * step
                plot.flagAt.y += plot.lift
                continue
            }
            let point = stage.screen(plot.flagAt), edge = stage.screen(plot.flagAt + Vec3(0, 1, 0))
            // Screen pixels per world unit straight up, here, so a height on screen can be turned into a lift.
            let perUnit = max(point.y - edge.y, 1e-3)
            let tall = plot.flagHeight * perUnit, half = tall * plot.label.aspect / 2
            var lift: Float = 0
            var clear = point.z > 1
            var raise = 0
            while raise < 4 && !clear {
                let bottom = point.y - Float(raise) * tall * 1.25
                if isClear(point.x - half, bottom - tall, point.x + half, bottom, p) { lift = Float(raise); clear = true }
                raise += 1
            }
            let bottom = point.y - lift * tall * 1.25
            marks.append((point.x - half, bottom - tall, point.x + half, bottom))
            plot.lift += (lift * tall * 1.25 / perUnit - plot.lift) * step
            plot.clear += ((clear ? 1 : 0.25) - plot.clear) * step
            plot.flagAt.y += plot.lift
        }
    }

    private func isClear(_ left: Float, _ top: Float, _ right: Float, _ bottom: Float, _ own: Int) -> Bool {
        let air: Float = 4
        for m in marks where left < m.right + air && right > m.left - air && top < m.bottom + air && bottom > m.top - air { return false }
        for h in heads where h.plot != own {
            let dx = h.x - clamp(h.x, left, right), dy = h.y - clamp(h.y, top, bottom)
            if dx * dx + dy * dy < (h.r + air) * (h.r + air) { return false }
        }
        return true
    }

    // MARK: bubbles

    /// Where a bubble may sit round the face, in order of preference, as directions on screen (y down):
    /// up and to the left first, as a thought bubble trails down toward its thinker, then lower on the
    /// left, then the same on the right.
    static let bubbleSides: [Vec2] = [Vec2(-0.6, -0.8), Vec2(-0.93, -0.36), Vec2(-0.97, 0.25),
                                      Vec2(0.6, -0.8), Vec2(0.93, -0.36), Vec2(0.97, 0.25)]

    // Every bubble keeps a readable size on screen however far away its cat is, and sits just beside the
    // face, wherever the face is (sitting, lying, turned away) and however the view is turned, so it never
    // covers the face. It never covers a flag's name either: when one is in the way it moves round the
    // face to the first side that is clear, easing there.
    private func placeBubbles(_ dt: Float, _ stage: Stage) {
        flagBoxes.removeAll(keepingCapacity: true)
        for plot in plots { flagBoxes.append(flagBox(plot, stage) ?? .empty) }
        let eye = stage.camera.eye, right = stage.surroundings.right, up = stage.surroundings.up
        let perPixel = 2 * tan(MapCamera.fovY / 2) / max(stage.camera.viewport.y, 1)
        let step = min(1, dt * 10)
        for plot in plots {
            for actor in plot.liveActors {
                let cat = actor.cat
                guard cat.bubbleShown else { actor.bubbleSeen = false; continue }
                let full = 0.78 * cat.size
                let smallest = CatDrawer.smallestBubble * perPixel * simd_distance(cat.bubbleAt, eye)
                let size = cat.bubbleScale * max(1, smallest / max(full, 1e-4))
                // Measured at the front of the head, so the head never hides any of it.
                let face = cat.face
                let anchor = face + simd_normalize(eye - face) * cat.faceReach
                let middle = stage.screen(anchor)
                if middle.z > 1 { continue }
                let perPoint = perPixel * simd_distance(anchor, eye)
                let radius = size * CatDrawer.bubbleDisc / 2 / perPoint
                // Touching the head, just over the tips of the ears.
                let out = cat.faceReach / perPoint + radius * 0.85
                var want = Self.bubbleSides[0], least = Float.infinity
                for side in Self.bubbleSides {
                    let covered = flagsCovered(Vec2(middle.x, middle.y) + side * out, radius + 2)
                    if covered < least { least = covered; want = side }
                    if covered == 0 { break }
                }
                if actor.bubbleSeen {
                    let eased = actor.bubbleSide + (want - actor.bubbleSide) * step
                    actor.bubbleSide = simd_length(eased) > 1e-3 ? simd_normalize(eased) : want
                } else {
                    actor.bubbleSide = want
                    actor.bubbleSeen = true
                }
                let offset = actor.bubbleSide * out * perPoint
                cat.bubbleDrawn = Vec4(anchor + right * offset.x - up * offset.y + Vec3(0, cat.bubbleBob * cat.size, 0), size)
            }
        }
    }

    /// How much of the flags' pills a disc on screen would cover (a rough area; 0 for none).
    private func flagsCovered(_ c: Vec2, _ r: Float) -> Float {
        var area: Float = 0
        for f in flagBoxes where !f.isEmpty {
            let w = min(c.x + r, f.right) - max(c.x - r, f.left), h = min(c.y + r, f.bottom) - max(c.y - r, f.top)
            if w > 0 && h > 0 { area += w * h }
        }
        return area
    }

    // MARK: where things are on screen

    /// The flag's pill on screen (points, origin top left), nil when behind the camera. It faces the
    /// camera, so its height runs along the view's `up`. `project` is `Stage.screen`, through the camera
    /// as it is or as it would be.
    func flagBox(_ plot: Plot, up: Vec3, _ project: (Vec3) -> Vec3) -> ScreenBox? {
        let bottom = project(plot.flagAt), top = project(plot.flagAt + up * plot.flagHeight)
        if bottom.z > 1 { return nil }
        let tall = hypot(bottom.x - top.x, bottom.y - top.y), half = tall * plot.label.aspect / 2
        return ScreenBox(left: bottom.x - half, top: bottom.y - tall, right: bottom.x + half, bottom: bottom.y)
    }
    func flagBox(_ plot: Plot, _ stage: Stage) -> ScreenBox? { flagBox(plot, up: stage.surroundings.up) { stage.screen($0) } }

    /// The cloth on screen, from its outline as laid now; nil when any of it is behind the camera.
    func blanketBox(_ plot: Plot, _ project: (Vec3) -> Vec3) -> ScreenBox? {
        let model = Mat4.translation(plot.group + Vec3(plot.blanketAt.x, 0, plot.blanketAt.z)) * .rotationY(plot.turn)
        let outline = Picnic.outlines[plot.cloth]
        var box = ScreenBox.empty
        for i in stride(from: 0, to: outline.count, by: 6) {
            let p = outline[i] * plot.blanketSize
            let s = project(model.point(Vec3(p.x, 0, -p.y)))
            if s.z > 1 { return nil }
            box.add(Vec2(s.x, s.y))
        }
        return box
    }

    /// A blanket and its flag together: what must be seen for it to count as in view.
    func blanketAndFlagBox(_ plot: Plot, up: Vec3, _ project: (Vec3) -> Vec3) -> ScreenBox? {
        guard let cloth = blanketBox(plot, project), let flag = flagBox(plot, up: up, project) else { return nil }
        return cloth.union(flag)
    }
    func blanketAndFlagBox(_ plot: Plot, _ stage: Stage) -> ScreenBox? { blanketAndFlagBox(plot, up: stage.surroundings.up) { stage.screen($0) } }

    // MARK: picking and seeing

    /// The cat whose head is under a screen point.
    func pickCat(_ point: Vec2, _ stage: Stage) -> (Plot, Actor)? {
        var best: (Plot, Actor)?, bestDistance = Float.infinity
        let up = stage.surroundings.up
        for plot in plots {
            for actor in plot.liveActors where !actor.leaving {
                let head = stage.screen(actor.head)
                if head.z > 1 { continue }
                let edge = stage.screen(actor.head + up * (1.1 * actor.size))
                let reach = hypot(edge.x - head.x, edge.y - head.y)
                let d = hypot(head.x - point.x, head.y - point.y)
                if d < reach && d < bestDistance { best = (plot, actor); bestDistance = d }
            }
        }
        return best
    }

    /// The blanket whose flag is under a screen point.
    func pickFlag(_ point: Vec2, _ stage: Stage) -> Plot? {
        plots.first { flagBox($0, stage)?.contains(point) ?? false }
    }

    /// The lantern under a screen point.
    func pickLantern(_ point: Vec2, _ stage: Stage) -> (Plot, LanternPlace)? {
        for plot in plots {
            for lantern in plot.lanterns where !lantern.leaving && !lantern.hidden && shown(lantern) > 0.5 {
                let c = stage.screen(plot.group + lantern.at + Vec3(0, 0.5, 0)), e = stage.screen(plot.group + lantern.at + Vec3(0, 1.05, 0))
                if c.z > 1 { continue }
                if hypot(c.x - point.x, c.y - point.y) < max(hypot(e.x - c.x, e.y - c.y), 6) { return (plot, lantern) }
            }
        }
        return nil
    }

    /// The blanket under a screen point: where the ray meets the ground, inside its cloth.
    func pickBlanket(_ point: Vec2, _ stage: Stage) -> Plot? {
        let (o, d) = stage.camera.ray(point)
        guard d.y < -1e-4 else { return nil }
        let t = -o.y / d.y, hit = o + d * t
        var best: Plot?, bestDistance = Float.infinity
        for plot in plots {
            let local = hit - plot.middle
            // Into the cloth's own turned frame; its squircle reaches 1 at the edges, CORNER at the corners.
            let c = cos(-plot.turn), s = sin(-plot.turn)
            let x = (local.x * c - local.z * s) / plot.blanketSize, z = (local.x * s + local.z * c) / plot.blanketSize
            let inside = pow(pow(abs(x), 4.5) + pow(abs(z), 4.5), 1 / 4.5) <= 1.02
            let dist = hypot(local.x, local.z)
            if inside && dist < bestDistance { best = plot; bestDistance = dist }
        }
        return best
    }

    /// What the camera should always be able to see, as balls: each blanket with its cats, its flag, every
    /// cat out in the grass, and the chosen cat's head.
    func sights(into balls: inout [Ball]) -> Int {
        // Written into a list kept from frame to frame; it only grows when blankets are added or cats go out.
        var out = 0
        for plot in plots { for actor in plot.actors.values where actor.roam.out { out += 1 } }
        let needed = plots.count * 2 + 1 + out
        if balls.count < needed { balls.append(contentsOf: repeatElement(Ball(center: .zero, radius: 0), count: needed - balls.count)) }
        var n = 0
        for plot in plots {
            balls[n] = Ball(center: Vec3(plot.middle.x, 1, plot.middle.z), radius: plot.blanketSize)
            // Its flag too, so a tree in front of the name fades as well.
            balls[n + 1] = Ball(center: plot.flagAt + Vec3(0, plot.flagHeight * 0.5, 0), radius: plot.flagHeight * plot.label.aspect * 0.5)
            n += 2
            // A tree between you and a cat out in the grass fades too.
            for actor in plot.actors.values where actor.roam.out {
                balls[n] = Ball(center: actor.cat.position + Vec3(0, 1.1 * actor.shownSize, 0), radius: 1.3 * actor.shownSize)
                n += 1
            }
        }
        if case .cat(let b, let a) = chosen, let actor = byID[b]?.actors[a], !actor.leaving {
            balls[n] = Ball(center: actor.head, radius: 1)
            n += 1
        }
        return n
    }

    /// Things nothing on the wing may fly in front of: every flag, every bubble and every waking cat,
    /// as balls. Kept in a list that only grows, so a frame allocates nothing.
    func keepClear(into balls: inout [Ball]) -> Int {
        var n = 0
        func add(_ ball: Ball) {
            if n < balls.count { balls[n] = ball } else { balls.append(ball) }
            n += 1
        }
        for plot in plots {
            add(Ball(center: plot.flagAt + Vec3(0, plot.flagHeight * 0.5, 0), radius: plot.flagHeight * plot.label.aspect * 0.55))
            for actor in plot.liveActors {
                let cat = actor.cat
                if cat.bubbleShown {
                    let b = cat.bubbleDrawn
                    add(Ball(center: Vec3(b.x, b.y, b.z), radius: max(b.w, 0.3) * 0.75))
                }
                if !cat.isNapping { add(Ball(center: cat.bodyMatrix.point(Vec3(0, 1.1, 0)), radius: 1.2 * cat.size)) }
            }
        }
        return n
    }

    /// Sleeping cats, as places a butterfly might land.
    func sleepers(into list: inout [Perch]) {
        list.removeAll(keepingCapacity: true)
        // From a sidebar's high camera a butterfly on a cat's crown sits between its eyes, where it reads
        // as a mouth (never wanted); there they keep to the flowers.
        if arrangement == .column && perRow == 1 { return }
        for plot in plots {
            for actor in plot.liveActors where !actor.leaving && actor.cat.isNapping { list.append(Perch(cat: actor.cat, at: actor.cat.crown)) }
        }
    }

    /// The ground all the blankets cover together: its middle and how far it reaches either way.
    var bounds: Ground {
        // Asked every frame by the camera, so one pass and nothing allocated.
        var left = Float.infinity, right = -Float.infinity, back = Float.infinity, front = -Float.infinity
        for plot in plots {
            guard let at = plot.at else { continue }
            left = min(left, at.x - plot.radius); right = max(right, at.x + plot.radius)
            back = min(back, at.y - plot.radius); front = max(front, at.y + plot.radius)
        }
        guard left <= right else { return Ground(x: 0, z: 0, across: 0, deep: 0) }
        return Ground(x: (left + right) / 2, z: (back + front) / 2, across: (right - left) / 2, deep: (front - back) / 2)
    }

    /// The patch of ground a blanket covers, for flying the camera to it.
    func ground(of id: String) -> Clearing? {
        guard let plot = byID[id], let at = plot.at else { return nil }
        return Clearing(x: at.x, z: at.y, r: plot.radius)
    }

    func actor(_ blanket: String, _ agent: String) -> Actor? { byID[blanket]?.actors[agent] }
}
