import Foundation
import simd

// Port of src/cat/Cat.ts: one squishy cat. It faces +z, stands on y = 0 of its root, and acts out
// whatever activity it is given, with springs, hops, blinks, glances and a ton of small whims.

/// What every cat can sense of the world around it.
struct Surroundings {
    var eye = Vec3(0, 10, 20)       // camera position
    var right = Vec3(1, 0, 0)       // camera's right and up, in the world
    var up = Vec3(0, 1, 0)
    var pointer = Vec2.zero         // cursor in −1…1 screen space
    var critters: ContiguousArray<Vec3> = []   // butterflies and bees worth watching
    var swirl: Float = 0            // how fast the camera is swinging round, radians a second
    var gust: (Float, Float) -> Float = { _, _ in 0 }  // how hard the wind is blowing at a spot, 0…1
    var frame = 0                   // counts drawn frames, so distant cats take turns reshaping
}

/// Loose springs everywhere: things overshoot and settle, which is what reads as squishy.
struct Sprung {
    var x: Float = 0, v: Float = 0
    init(_ x: Float = 0) { self.x = x }
    mutating func spring(_ target: Float, _ stiffness: Float, _ damping: Float, _ dt: Float) {
        v += ((target - x) * stiffness - v * damping) * dt
        x += v * dt
    }
}

// What a cat with nothing to do gets up to, and for how long. It is a picnic, so there is food.
private enum Fidget: Int, CaseIterable {
    case wash, stretch, wiggle, peek, nibble, sip
    var seconds: Float { [2.4, 1.8, 1.0, 2.6, 3.4, 2.4][rawValue] }
}

private let PUPIL: Float = 0.172
/// How fast a hop falls back, units a second squared (a bound through the grass is timed by it, `Roam.swift`).
let GRAVITY: Float = -26
private let TAILS: [[Vec3]] = [
    [Vec3(0.25, 0.3, -0.5), Vec3(0.85, 0.16, -0.8), Vec3(1.32, 0.42, -0.7), Vec3(1.45, 0.98, -0.55), Vec3(1.4, 1.52, -0.45)],
    [Vec3(0.25, 0.3, -0.5), Vec3(0.7, 0.25, -0.85), Vec3(1.0, 0.7, -0.88), Vec3(1.06, 1.4, -0.78), Vec3(1.0, 2.0, -0.68)],
    [Vec3(0.25, 0.22, -0.5), Vec3(0.98, 0.14, -0.4), Vec3(1.12, 0.13, 0.35), Vec3(0.68, 0.13, 0.9), Vec3(0.05, 0.13, 1.0)],
]
let TAIL_RINGS = 32, TAIL_SIDES = 10
let TAIL_INDEX: [UInt32] = {
    var out: [UInt32] = []
    for i in 0..<TAIL_RINGS {
        for j in 0..<TAIL_SIDES {
            let a = UInt32(i * TAIL_SIDES + j), b = UInt32(i * TAIL_SIDES + (j + 1) % TAIL_SIDES)
            out += [a, b, a + UInt32(TAIL_SIDES), b, b + UInt32(TAIL_SIDES), a + UInt32(TAIL_SIDES)]
        }
    }
    return out
}()
let TAIL_VERTS = (TAIL_RINGS + 1) * TAIL_SIDES

private let WORK: Set<AgentActivity> = [.reading, .editing, .running, .searching, .thinking, .tidying]

final class Cat: Performer {
    // ---- placed by whoever stages the cat
    /// Where its root stands in the world, and its size (helpers are smaller).
    var position = Vec3.zero
    var size: Float = 1
    private(set) var activity: AgentActivity = .awake
    /// Set by whoever handles the mouse: the cursor is on this cat, or is being held down on it.
    var watched = false
    var petting = false
    /// Extra turning added by whoever is staging the cat, such as a twirl on the way out.
    var spin: Float = 0
    /// Where on the blanket its attention is (its boss), and its own slight turn away from straight on.
    var toward: Vec3? = nil
    var aside: Float = 0
    /// Done and not yet seen: sits up facing you with a check bubble (the Mac design).
    var doneUnseen = false
    /// Waiting on you, whatever it was doing: the asking pose with a red bubble (the Mac design).
    var needsYou = false
    var wards: [Vec3] = []
    var presses = 0
    /// Where it is going, or turning to, on a blanket errand (being handed a task, reporting back): its
    /// whole body faces that way, and while `trotting` it trots in little bounces on its stubby paws, which
    /// keep their shape. Whoever stages the cat moves it there; nil while it simply sits.
    var going: Vec3? = nil
    var trotting = false
    /// Out in the grass while its Claude has nothing for it (`Roam.swift`): how it gets about. Whoever moves
    /// it advances `stride`, the step's phase, and moves it on only while its body is up off its paws, so a
    /// step never slides; a bound is one of its hops (`jump`), carried forward while it is in the air.
    var gait = Gait.none
    var stride: Float = 0
    /// A bound under way: how high it is and how fast it rises (falling: below 0), given every frame of it.
    var leap: (height: Float, speed: Float)? = nil
    /// What it does at a stop out in the grass; nil on its blanket or on the move.
    var outing: Outing? = nil

    enum Gait { case none, walk, bound, run }
    enum Outing: Equatable {
        /// Sitting up, looking about and following whatever flies past.
        case watch
        /// Leaning in to a flower, nose to it.
        case sniff(Vec3)
        /// Down as a loaf in the grass.
        case loaf
        /// Up on its hind legs at a scratching post (this point on it), stroking down it with one paw, then
        /// the other.
        case scratch(Vec3)
    }
    /// Which way to face where it stops out in the grass (a stump's front, a bowl, a post), rather than toward
    /// you; nil to face you as always. Its head still keeps its face to you.
    var facingSpot: Vec3? = nil
    /// How each gait moves the body: its bounce with every step, its squash on landing, its rock from side
    /// to side, its lean into the way it goes, and how flat its ears lie.
    private struct Carriage {
        var bounce: Float = 0, landing: Float = 0, rock: Float = 0, lean: Float = 0, ears: Float = 0
        static func of(_ gait: Gait) -> Carriage {
            switch gait {
            case .none, .bound: Carriage()
            // A waddle: little lifts, rolling from side to side on its short paws.
            case .walk: Carriage(bounce: 0.13, landing: 0.05, rock: 0.11, lean: 0.06)
            // Urgent: big low bounds, leaning hard into it, ears flat back.
            case .run: Carriage(bounce: 0.42, landing: 0.1, rock: 0.05, lean: 0.28, ears: 0.7)
            }
        }
        mutating func ease(toward c: Carriage, _ k: Float) {
            bounce += (c.bounce - bounce) * k; landing += (c.landing - landing) * k; rock += (c.rock - rock) * k
            lean += (c.lean - lean) * k; ears += (c.ears - ears) * k
        }
    }
    /// Ambient motion is switched off (`MeadowView.animatesAmbient`): its own clock stops, so breathing,
    /// blinks, twitches, fidgets, glances, the tail and the loop of its work all hold still, and it never
    /// hops. A change of state still shows, easing into the new pose. Its clock carries on from where it
    /// stopped when switched back on, so nothing jumps.
    var frozen = false {
        didSet {
            guard frozen, !oldValue else { return }
            // Nothing left half done: no glance, nod or listening held for ever, no blink held.
            glanceUntil = time; attendUntil = time; listenUntil = time; shakeUntil = time; wiggleUntil = time
            fidgetUntil = time; nodAt = -10; blinkAt = -1; twitchAt = -1
        }
    }

    // ---- what the renderer reads each frame (all in the world unless said otherwise)
    private(set) var posed = PoseInputs()
    /// The pose changed since it was last written to a buffer.
    private(set) var poseVersion = 0
    private(set) var rootMatrix = Mat4.identity
    private(set) var bodyMatrix = Mat4.identity
    private(set) var faceMatrix = Mat4.identity
    private(set) var eyeWhites: (Mat4, Mat4) = (.identity, .identity)
    private(set) var pupils: (Mat4, Mat4) = (.identity, .identity)
    private(set) var shadowMatrix = Mat4.identity
    private(set) var shadowOpacity: Float = 1
    /// Tail tube: interleaved position + normal in body space, TAIL_VERTS vertices.
    private(set) var tailVertices = [Float](repeating: 0, count: TAIL_VERTS * 6)
    private(set) var propScale = [Float](repeating: 0, count: PropName.allCases.count)
    private(set) var propMatrix = [Mat4](repeating: .identity, count: PropName.allCases.count)
    private(set) var buttonDepth: Float = 0
    private(set) var steam = [Vec4](repeating: .zero, count: 6)  // xyz, scale; opacity in steamAlpha
    private(set) var steamAlpha = [Float](repeating: 0, count: 6)
    private(set) var bubbleMark: BubbleMark? = nil
    private(set) var bubbleAt = Vec3.zero
    private(set) var bubbleScale: Float = 0
    var bubbleShown: Bool { bubbleScale > 0.01 && bubbleMark != nil }
    /// Its gentle bob up and down, already in `bubbleAt`.
    private(set) var bubbleBob: Float = 0
    /// Where the bubble is drawn (xyz) and how large (w): its own spot unless whoever stages the cat
    /// places it after the cat's update (the village keeps it beside the face and off the flags).
    var bubbleDrawn = Vec4.zero

    // ---- inner state
    private var random: Seeded
    private var now = Eased()
    private var yaw = Sprung(), pitch = Sprung(), squash = Sprung()
    private var armPush = ARM_REST
    private var pupilAt = Vec2.zero
    private var time: Float
    private var started: Float
    private(set) var height: Float = 0
    private var velocity: Float = 0
    private var nextBlink: Float, blinkAt: Float = -1
    private var nextTwitch: Float, twitchAt: Float = -1, twitchEar = 0
    private var glancing = Vec3.zero, glanceUntil: Float = 0
    /// Until when it looks up at you, listening, before it starts on a prompt.
    private var listenUntil: Float = 0
    /// Until when it gives a spot its full attention, whatever it is doing (a boss handing it a task).
    private var attending = Vec3.zero, attendUntil: Float = 0
    /// When its last nod began, and how far into its trot it is (eased 0…1 in and out, and the step's phase).
    private var nodAt: Float = -10
    private var trot: Float = 0, trotPhase: Float = 0
    private var wasGoing = false
    /// How far into a gait of its own it is (eased 0…1), and that gait's carriage, eased from the last.
    private var moving: Float = 0
    private var carriage = Carriage()
    /// When it last skidded to a stop on arriving at a run.
    private var skidAt: Float = -10
    private var fidget = Fidget.wash, fidgetFrom: Float = 0, fidgetUntil: Float = 0, nextFidget: Float
    private var nextStartle: Float = 0, shakeUntil: Float = 0, wiggleUntil: Float = 0
    /// Which way this cat cocks its head, so a crowd doesn't all tilt the same way.
    private let lean: Float
    private let beat: Int
    private var heading: Float = 0
    private var facing: Float? = nil
    private var tailPhase: Float
    private var tailLine = TAILS[0]
    private let tailCurve = CatmullRom(TAILS[0])
    private var pops = [Sprung](repeating: Sprung(), count: PropName.allCases.count)
    private var bubblePop = Sprung()
    private var steamLife = [Float](repeating: 1, count: 6)
    private var steamDrift = [Vec2](repeating: .zero, count: 6)
    // Scratch for the tail, kept so a frame allocates nothing.
    private var tailTangents = [Vec3](repeating: .zero, count: TAIL_RINGS + 1)
    private var tailNormals = [Vec3](repeating: .zero, count: TAIL_RINGS + 1)
    private var tailBinormals = [Vec3](repeating: .zero, count: TAIL_RINGS + 1)
    private var tailPositions = [Vec3](repeating: .zero, count: TAIL_VERTS)
    private var tailVertexNormals = [Vec3](repeating: .zero, count: TAIL_VERTS)

    /// Each cat keeps its own time, started at a random moment so a crowd doesn't blink in unison. The
    /// randomness is seeded by its name, so a cat behaves the same every run.
    init(seed: String) {
        random = chance("cat/" + seed)
        time = random.float() * 10
        started = time
        nextBlink = time + 1 + random.float() * 3
        nextTwitch = time + 2 + random.float() * 4
        nextFidget = time + 4 + random.float() * 8
        lean = random.float() < 0.5 ? -1 : 1
        beat = Int(random.float() * 6)
        tailPhase = random.float() * 6
        wards.reserveCapacity(32)
    }

    private func rnd() -> Float { random.float() }

    func setActivity(_ next: AgentActivity) {
        if next == activity { return }
        let was = activity
        activity = next
        started = time
        presses = 0
        fidgetUntil = 0
        States.enter(next, self)
        if frozen { return }
        // Woken up: shake the sleep off. Work finished: a little hop and wiggle of satisfaction.
        if was == .napping { shakeUntil = time + 0.45 }
        // Given something to do while at rest (you sent a prompt): it looks up at you first, listening.
        if [.awake, .idle, .napping].contains(was) && WORK.contains(next) { listenUntil = time + 0.8 }
        if next == .awake && WORK.contains(was) {
            jump(4.2, 2)
            wiggleUntil = time + 0.7
        }
    }

    /// Look at a spot in the world for a moment, if not busy.
    func glance(_ at: Vec3, _ seconds: Float) {
        if frozen { return }
        glancing = at
        glanceUntil = time + seconds
    }

    /// Gives a spot its full attention for a moment, whatever it is doing: it sits up, puts down what it
    /// holds and looks there (being handed a task, or listening to a report). Not while it needs you.
    func attend(_ at: Vec3, _ seconds: Float) {
        if frozen { return }
        attending = at
        attendUntil = time + seconds
    }

    /// A small dip of the head: "got it". `after` seconds from now.
    func nod(after: Float = 0) { if !frozen { nodAt = time + after } }

    /// Something touched an ear.
    func tickle() {
        if frozen { return }
        twitchAt = time
        twitchEar = rnd() < 0.5 ? 0 : 1
    }

    /// The highest point of the cat in the world: where a butterfly lands. Upright that is the top of the
    /// head; flopped on its side it is the flank, which is lower and off to one side with the body.
    var crown: Vec3 {
        var p = bodyMatrix.point(Vec3(0, lerp(2.2, 1.15, now.lie), 0))
        p.y += now.lie * 0.92 * size
        return p
    }

    func hop() { jump(7.5, 2.5) }

    /// Starts one of its fidgets now (`wash`, `stretch`, `nibble`, `sip`, `wiggle`, `peek`), for pictures of each.
    func fidget(_ name: String) {
        guard let kind = Fidget.allCases.first(where: { "\($0)" == name }) else { return }
        fidget = kind
        fidgetFrom = time
        fidgetUntil = time + kind.seconds
        nextFidget = fidgetUntil + 5
    }

    /// Arriving at a run: it skids, leaning back on its paws and squashing down, before it settles.
    func skid() {
        if frozen { return }
        skidAt = time
        squash.v = -2.2
    }

    /// How far its body is turned from facing `spot`, in radians: a cat turns before it sets off.
    func turned(from spot: Vec3) -> Float {
        guard hypot(spot.x - position.x, spot.z - position.z) > 0.05 else { return 0 }
        return abs(turnFrom(heading, atan2(spot.x - position.x, spot.z - position.z)))
    }

    func jump(_ speed: Float, _ stretch: Float) {
        if frozen { return }
        if height == 0 { velocity = speed }
        squash.v = stretch
    }

    func pressButton(_ depth: Float) { buttonDepth = depth }

    func thump() {
        // Steam, flinch and blink.
        if frozen { return }
        for i in 0..<6 {
            steamLife[i] = -Float(i) * 0.07
            steamDrift[i] = Vec2((rnd() - 0.5) * 0.5, (rnd() - 0.5) * 0.5)
        }
        squash.v = -1.8
        blinkAt = time
    }

    /// Where the head is in the world, for aiming at it or picking it with the cursor.
    var head: Vec3 { position + Vec3(0, (1.6 + height) * size, 0) }
    /// The middle of the face as posed (sitting, lying or stretched out), and about how far the head
    /// reaches round it, ears included: what a bubble must keep clear of.
    var face: Vec3 { faceMatrix.point(Vec3(0, 0.5, 0.1)) }
    var faceReach: Float { 0.95 * size }
    /// How open its eyes are meant to be (blinks aside): 1 wide open, near 0 shut.
    var eyesOpen: Float { now.lid }
    var isNapping: Bool { activity == .napping && !needsYou && !doneUnseen }
    /// Doing nothing but its own slow loop (breathing, a pose's anchored work, a tail): no hop, trot, nod,
    /// shake or turn to listen under way, nothing that would read as a stutter drawn at a resting rate.
    var still: Bool {
        height == 0 && velocity == 0 && trot < 0.01 && going == nil && time >= attendUntil && time >= listenUntil
            && time >= shakeUntil && time >= wiggleUntil && time - nodAt >= 0.5 && abs(turnFrom(heading, facing ?? heading)) < 0.05
            && gait == .none && moving < 0.01 && time - skidAt >= 0.5
    }
    /// Nothing on it moves fast, so the scene can be drawn at a gentler pace.
    var restful: Bool {
        if needsYou || trot > 0.01 || time < attendUntil || gait == .run || time - skidAt < 0.5 { return false }
        // A walk or a bound through the grass is unhurried: the calm rate draws it well.
        switch activity { case .awake, .idle, .napping, .supervising, .thinking: return height == 0 || gait == .bound
        default: return false }
    }

    // MARK: - update

    func update(_ dt: Float, _ around: Surroundings) {
        if !frozen { time += dt }
        let t = time
        let ease = min(1, dt * 7)

        // A cat never keeps its back to you. The head covers small angles; once you have moved well round
        // to one side it shuffles its whole body about to face you again. Sleeping cats stay put.
        var toYou = atan2(around.eye.x - position.x, around.eye.z - position.z)
        if let toward {
            let toThem = atan2(toward.x - position.x, toward.z - position.z)
            toYou += clamp(turnFrom(toYou, toThem), -0.75, 0.75) * 0.7
        }
        toYou += aside
        if facing == nil { facing = toYou; heading = toYou }
        // On an errand the whole body turns the way it goes; back in its seat it turns to you again.
        let errand = going.flatMap { g in hypot(g.x - position.x, g.z - position.z) > 0.05 ? atan2(g.x - position.x, g.z - position.z) : nil }
        if let errand { facing = errand }
        else if let spot = facingSpot, hypot(spot.x - position.x, spot.z - position.z) > 0.05 { facing = atan2(spot.x - position.x, spot.z - position.z) }
        else if wasGoing { facing = toYou }
        else if !isNapping, facingSpot == nil, abs(turnFrom(facing!, toYou)) > 0.95 {
            facing = toYou
            if activity == .awake { jump(2.4, 1) }
        }
        wasGoing = going != nil
        heading += turnFrom(heading, facing!) * min(1, dt * (errand == nil ? 5 : 9))
        trot += ((trotting ? 1 : 0) - trot) * min(1, dt * 8)
        trotPhase += dt * 11 * trot
        moving += ((gait == .none ? 0 : 1) - moving) * min(1, dt * 8)
        carriage.ease(toward: .of(gait), min(1, dt * 8))
        let turnY = heading + spin

        var want = Want()
        let acting: AgentActivity = needsYou ? .asking : activity
        if doneUnseen && !needsYou {
            States.doneUnseen(&want, t - started)
        } else {
            States.act(acting, &want, t - started, self)
        }
        whims(&want, t, around)
        // On an errand, or attending to someone: sitting up, paws free, looking where it goes or at them. On its
        // way across the grass the same, whatever it is called back for (its bubble already up), and running
        // home with its ears flat.
        if (t < attendUntil || trot > 0.05 || going != nil) && !needsYou || gait != .none {
            want.aim = gait == .run ? .angles(0, 0.14) : t < attendUntil && !needsYou ? .at(attending) : .angles(0, 0.08)
            want.look = Vec2(0, 0)
            want.earPerk = gait == .run ? 0 : 1
            want.earFlat = max(want.earFlat, carriage.ears * moving)
            want.lid = 1
            want.prop = nil
            want.hands = Paws()
            want.prone = 0
            want.lie = 0
            want.tall = max(want.tall, 0.02)
            if gait == .run || gait == .bound { want.tail = .up }
        } else if let outing, !isNapping, !needsYou, !doneUnseen, !petting {
            Self.out(outing, &want, t, around, near: head, size: size)
        } else if t < listenUntil && !needsYou && !doneUnseen {
            want.aim = .camera
            want.look = Vec2(0, 0)
            want.earPerk = 1
            want.lid = 1
            want.prop = nil
            want.hands = Paws()
            want.prone = 0
            want.lie = 0
        }
        now.ease(toward: want, ease)
        if needsYou, want.bubble == .alert { want.bubble = .needsYou }

        // Hop: stretch in the air, then a landing thump that jiggles out. A bound through the grass is carried
        // by whoever moves the cat (`leap`), so it is up exactly while it is carried forward.
        if let leap {
            if height == 0 && leap.height > 0 { squash.v = 1.2 }
            if leap.height <= 0 && height > 0 { squash.v = min(leap.speed * 0.5, -3) }
            height = max(0, leap.height)
            velocity = height > 0 ? leap.speed : 0
        } else if height > 0 || velocity > 0 {
            velocity += GRAVITY * dt
            height += velocity * dt
            if height <= 0 {
                height = 0
                squash.v = min(velocity * 0.5, -3)
                velocity = 0
            }
        }
        let stretch: Float = height > 0 ? clamp(abs(velocity) * 0.012, 0, 0.1) : 0
        squash.spring(stretch, 190, 9, dt)
        let tall = squash.x + now.tall
        // Flopping over: tips onto one side, shifted back so it still lies on its own patch of blanket. Or
        // stretches out on its front, leaning over whatever it holds, shifted back the same way.
        // Trotting: a bounce with every step, the whole body lifting off its paws (which keep their shape),
        // squashing a little as it lands, leaning into the way it goes and rocking side to side.
        // Out in the grass, the same with its own gait's carriage, stepping with `stride`; a bound pitches the
        // body with the leap, nose up as it rises and down as it comes in to land; a skid leans it back.
        let step = abs(sin(trotPhase)), pace = abs(sin(stride))
        let bounce = step * 0.3 * trot + pace * carriage.bounce * moving
        let landing = (1 - step) * 0.07 * trot + (1 - pace) * carriage.landing * moving
        let leap = gait == .bound ? clamp(-velocity * 0.03, -0.2, 0.22) : 0
        let skidding = sin(.pi * clamp((t - skidAt) / 0.45, 0, 1))
        let tip = now.lie * 1.3 * lean + sin(trotPhase) * 0.07 * trot + sin(stride) * carriage.rock * moving
        let forward = now.prone * 0.55 + 0.12 * trot + carriage.lean * moving + leap - 0.26 * skidding
        let bodyPos = Vec3(sin(t * 60) * 0.014 * now.shiver + sin(tip) * 0.9, height + bounce, -sin(forward) * 0.7)
        let bodyScale = Vec3(1 - tall * 0.55 + landing * 0.5, 1 + tall + sin(t * 2.1) * now.breath - landing, 1 - tall * 0.55 + landing * 0.5)
        rootMatrix = .translation(position) * .rotationY(turnY) * .scale(size)
        let bodyLocal = Mat4.translation(bodyPos) * Mat4.euler(forward, 0, tip) * Mat4.scale(bodyScale)
        bodyMatrix = rootMatrix * bodyLocal

        let lift = clamp((height + bounce) / 2, 0, 1)
        shadowMatrix = rootMatrix * .translation(Vec3(0.2, 0.002, -0.05)) * .scale(Vec3(3.4 - lift * 1.4 + now.lie * 1.2, 1, 2.4 - lift))
        shadowOpacity = 1 - lift * 0.55

        // Head.
        var aim: (Float, Float)
        switch want.aim {
        case .angles(let y, let p): aim = (y, p)
        case .camera: aim = aimAt(0, 0, around)
        case .cursor: aim = aimAt(around.pointer.x, around.pointer.y, around)
        case .at(let spot): aim = aimToward(spot)
        }
        // Whatever it attends to, it keeps its face to you: asleep, or on its way somewhere, it may not.
        // Walking or bounding about it glances back at you, as far as its neck turns; running home it looks ahead.
        if !isNapping && (going == nil && trot < 0.05 || gait == .walk || gait == .bound) { aim = facingYou(aim, turnY: turnY, forward: forward, tip: tip, around) }
        // A nod: the head dips once and comes back up.
        let nodding = clamp((t - nodAt) / 0.5, 0, 1)
        let dip = nodding > 0 && nodding < 1 ? sin(nodding * .pi) * 0.34 : 0
        yaw.spring(aim.0 + sin(t * 0.9) * now.sway, 70, 10, dt)
        pitch.spring(aim.1 + dip, nodding > 0 && nodding < 1 ? 160 : 70, 12, dt)

        // Eyes: pupils drift to their target; a quick blink now and then.
        let look = want.look ?? Vec2(around.pointer.x * 0.035, around.pointer.y * 0.03)
        pupilAt += (look - pupilAt) * ease
        if t > nextBlink {
            blinkAt = t
            nextBlink = t + 2.2 + rnd() * 3.5
        }
        let blink = clamp((t - blinkAt) / 0.16, 0, 1)
        let lid = now.lid * (blinkAt < 0 ? 1 : max(0.06, abs(blink * 2 - 1)))

        // Each paw swings toward whatever it is reaching for, and back down to the belly when it lets go.
        for n in 0..<2 {
            var reach = ARM_REST[n]
            if let target = want.hands[n] {
                let d = target - ARM_BASE[n]
                let len = simd_length(d)
                reach = len > 0 ? d * (clamp(len, ARM_MIN, ARM_MAX) / len) : d
            }
            armPush[n] += (reach - armPush[n]) * min(1, dt * 10)
        }

        // Ear twitch.
        if t > nextTwitch {
            twitchAt = t
            twitchEar = rnd() < 0.5 ? 0 : 1
            nextTwitch = t + 2.5 + rnd() * 4
        }
        let phase: Float = twitchAt < 0 ? 1 : clamp((t - twitchAt) / 0.3, 0, 1)
        let twitch = sin(phase * .pi * 2) * (1 - phase)
        // Reshaping the body is the costly part. A cat far from the camera only does it every second or
        // third frame, each in its own turn, which nobody can see from there.
        let away = simd_distance(around.eye, head)
        let every = away < 32 ? 1 : away < 70 ? 2 : 3
        if (around.frame + beat) % every == 0 {
            let inputs = PoseInputs(yaw: yaw.x, pitch: pitch.x, roll: now.roll, earFlat: now.earFlat, earPerk: now.earPerk,
                                    flickL: twitchEar == 0 ? twitch : 0, flickR: twitchEar == 1 ? twitch : 0,
                                    pushL: armPush[0], pushR: armPush[1])
            if !inputs.close(to: posed) || poseVersion == 0 {
                posed = inputs
                poseVersion &+= 1
            }
        }
        faceMatrix = bodyMatrix * .translation(Vec3(0, PIVOT, 0)) * .eulerYXZ(posed.pitch, posed.yaw, posed.roll)
        for k in 0..<2 {
            let eye = Sculpt.shared.eyes[k]
            let spot = faceMatrix * .translation(eye.position) * Mat4(eye.facing) * .scale(Vec3(now.eye, now.eye * max(lid, 0.06), 1))
            let white = spot * .scale(Vec3(0.26, 0.26, 0.07))
            let pupil = spot * .translation(Vec3(pupilAt.x, pupilAt.y, 0.03)) * .scale(Vec3(PUPIL * now.pupil, PUPIL * now.pupil, 0.06))
            if k == 0 { eyeWhites.0 = white; pupils.0 = pupil } else { eyeWhites.1 = white; pupils.1 = pupil }
        }
        updateTail(dt, want)

        // Props and the bubble pop in and out with a little bounce.
        for prop in PropName.allCases {
            pops[prop.rawValue].spring(want.prop == prop ? 1 : 0, 210, 17, dt)
            propScale[prop.rawValue] = max(pops[prop.rawValue].x, 0)
        }
        placeProps()
        if want.bubble != nil || bubbleMark != nil {
            if let mark = want.bubble { bubbleMark = mark }
            bubblePop.spring(want.bubble != nil ? 1 : 0, 210, 17, dt)
            bubbleScale = max(bubblePop.x, 0) * 0.78 * size
            // Above the head, wherever it is: upright, or down on the blanket when lying on its side.
            bubbleBob = sin(t * 2.4) * 0.05
            let local = Vec3(lerp(-1.3, -sin(tip) * 1.0, now.lie),
                             lerp(2.95 + now.tall * 2.2, cos(tip) * 1.6 + 1.4, now.lie) - now.prone * 0.6 + height + bubbleBob,
                             0.3 + now.prone * 0.6)
            bubbleAt = rootMatrix.point(local)
            if bubbleScale < 0.005 && want.bubble == nil { bubbleMark = nil }
            bubbleDrawn = Vec4(bubbleAt, bubbleScale)
        }
        // Steam from the machine's chimney.
        for i in 0..<6 {
            steamLife[i] += dt / 1.1
            let life = steamLife[i]
            if life > 0 && life < 1 {
                steam[i] = Vec4(0.36 + steamDrift[i].x * life, 0.94 + life * 0.95, 1.3 + steamDrift[i].y * life, 0.07 + life * 0.15)
                steamAlpha[i] = (1 - life) * 0.9
            } else {
                steamAlpha[i] = 0
            }
        }
    }

    /// Food and furniture follow the paws, the body or the head (props.ts / Cat.ts `prop`).
    private func placeProps() {
        // The book is held, so it moves with the body; furniture stands on the floor; the spyglass goes
        // wherever the head turns.
        propMatrix[PropName.book.rawValue] = bodyMatrix * .translation(Vec3(0, 1.0, 1.02)) * .rotationX(0.45) * .scale(propScale[PropName.book.rawValue])
        propMatrix[PropName.desk.rawValue] = rootMatrix * .scale(propScale[PropName.desk.rawValue])
        propMatrix[PropName.papers.rawValue] = rootMatrix * .scale(propScale[PropName.papers.rawValue])
        propMatrix[PropName.machine.rawValue] = rootMatrix * .scale(propScale[PropName.machine.rawValue])
        propMatrix[PropName.spyglass.rawValue] = faceMatrix * .translation(Vec3(0.43, 0.62, 1.3)) * .scale(propScale[PropName.spyglass.rawValue])
        // Food is held, so it goes where the paws are: the cup in the right paw, the rice ball between both.
        let cupAt = ARM_BASE[1] + armPush[1]
        propMatrix[PropName.cup.rawValue] = bodyMatrix * .translation(cupAt) * .scale(propScale[PropName.cup.rawValue])
        let snackAt = (ARM_BASE[0] + armPush[0] + ARM_BASE[1] + armPush[1]) * 0.5
        propMatrix[PropName.snack.rawValue] = bodyMatrix * .translation(snackAt) * .scale(propScale[PropName.snack.rawValue])
    }

    // MARK: - whims

    // The small unprompted things that make a cat a cat. They only ever nudge what the current state
    // asked for, and the busier the cat, the fewer of them apply.
    private func whims(_ want: inout Want, _ t: Float, _ around: Surroundings) {
        if watched { want.earPerk = max(want.earPerk, 1) }
        // A strong gust: ears press back until it passes (the eyes stay round).
        let h = head
        let gust = max(0, around.gust(h.x, h.z) - 0.72) / 0.28
        if gust > 0 && !isNapping {
            want.earFlat = max(want.earFlat, gust * 0.45)
        }
        if t < shakeUntil { want.shiver = 1 }
        if t < wiggleUntil { want.roll = sin((wiggleUntil - t) * 22) * 0.14 }
        // Dreaming: now and then the tail thrashes for a moment.
        if isNapping && sin(t * 0.83 + lean) > 0.965 {
            want.tailAmp = 0.6
            want.tailSpeed = 9
        }
        if needsYou || doneUnseen { return }
        let idle = activity == .awake
        if !idle && activity != .thinking && activity != .supervising { return }

        // Being petted: eyes squeeze shut and it leans into your hand.
        if petting {
            want.aim = .camera
            want.lid = 0.14
            want.roll = sin(t * 3) * 0.12
            want.tall = -0.05
            want.tailSpeed = 0.9
            want.bubble = .heart
            return
        }
        if t < glanceUntil {
            want.aim = .at(glancing)
            want.look = Vec2(0, 0)
            return
        }

        // A butterfly or bee going past is far more interesting than anything else.
        var critter: Vec3? = nil
        var closest = 6.5 * size
        for spot in around.critters {
            let away = simd_distance(spot, h)
            if away < closest { critter = spot; closest = away }
        }
        if let critter {
            want.aim = .at(critter)
            want.look = Vec2(0, 0)
            want.earPerk = max(want.earPerk, 0.7)
            // Close enough in front: have a swat at it.
            let nearby = rootMatrix.inverse.point(critter)
            if idle && nearby.z > 0.3 && nearby.y > 0.4 && simd_length(nearby) < 2.6 {
                want.hands[nearby.x < 0 ? 0 : 1] = nearby
            }
            return
        }
        if !idle { return }

        // You swung the camera round fast: a startled hop.
        if around.swirl > 1.5 && height == 0 && t > nextStartle {
            jump(3.4, 1.5)
            nextStartle = t + 2.5
        }
        // You came in close: it cocks its head at you.
        if simd_distance(around.eye, h) < 8.5 * size { want.roll = 0.2 * lean }

        if t > nextFidget {
            fidget = Fidget.allCases[Int(rnd() * Float(Fidget.allCases.count)) % Fidget.allCases.count]
            fidgetFrom = t
            fidgetUntil = t + fidget.seconds
            nextFidget = fidgetUntil + 5 + rnd() * 9
        }
        if t >= fidgetUntil { return }
        let p = (t - fidgetFrom) / (fidgetUntil - fidgetFrom)
        switch fidget {
        case .wash:
            // One paw rubbing in circles at its cheek, head tipped into it.
            want.hands[1] = Vec3(0.42 + cos(p * 20) * 0.05, 1.3 + sin(p * 20) * 0.07, 0.86)
            want.roll = 0.14
            want.aim = .angles(0.18, 0.1)
        case .stretch:
            want.tall = sin(.pi * p) * 0.13
            want.hands = Paws(Vec3(SIDES[0] * 0.3, 1.3, 0.92), Vec3(SIDES[1] * 0.3, 1.3, 0.92))
            want.aim = .angles(0, -0.22)
        case .nibble:
            // A rice ball held up in both paws, nibbled at in little dips of the head.
            let bite = max(0, sin(p * .pi * 7)) * smoothstep(p, 0.1, 0.25) * (1 - smoothstep(p, 0.85, 1))
            want.hands = Paws(Vec3(SIDES[0] * 0.2, 1.08 + bite * 0.05, 0.98), Vec3(SIDES[1] * 0.2, 1.08 + bite * 0.05, 0.98))
            want.prop = .snack
            want.aim = .angles(0, 0.22 + bite * 0.08)
            want.earPerk = 0.5
        case .sip:
            // A cup of tea lifted for a slow sip.
            let sip = sipping(p * 2.4)
            want.hands[1] = cupPaw(sip)
            want.prop = .cup
            want.aim = .angles(0, lerp(0.2, -0.12, sip))
        case .wiggle:
            want.roll = sin(p * .pi * 6) * 0.13 * (1 - p)
            want.tailSpeed = 8
        case .peek:
            // Has a slow look around.
            want.aim = .angles(sin(p * .pi * 2) * 0.7, 0.05)
        }
    }

    /// What it does at a stop out in the grass (real cats' sit-and-watch, a sniff at a flower, a loaf in the
    /// sun), over whatever its state asked: no prop and nothing in its paws out there.
    private static func out(_ outing: Outing, _ want: inout Want, _ t: Float, _ around: Surroundings, near head: Vec3, size: Float) {
        want.prop = nil
        want.hands = Paws()
        want.lie = 0
        want.lid = 1
        switch outing {
        case .watch:
            // Sitting up tall, tail wrapped round, looking about; anything on the wing nearby gets watched.
            want.prone = 0
            want.tall = 0.03
            want.earPerk = 0.8
            want.tail = .curl
            want.tailAmp = 0.35
            want.look = Vec2(0, 0)
            var closest = 7 * size
            var seen: Vec3?
            for spot in around.critters where simd_distance(spot, head) < closest {
                closest = simd_distance(spot, head)
                seen = spot
            }
            want.aim = seen.map { .at($0) } ?? .angles(sin(t * 0.45) * 0.55, 0.02 + sin(t * 0.31) * 0.05)
        case .sniff(let flower):
            // Leaning in, nose down to the bloom, ears forward.
            want.prone = 0.3
            want.tall = -0.05
            want.earPerk = 0.7
            want.aim = .at(flower)
            want.look = Vec2(0, -0.03)
            want.tailSpeed = 2.2
        case .scratch(let post):
            // Up tall against the post, both paws on it, one stroking down while the other reaches up, in turn;
            // the paws only turn toward the post, as they always do, never lengthen.
            let stroke = sin(t * 7.5)
            want.prone = 0
            want.tall = 0.14
            want.earPerk = 1
            want.tail = .up
            want.tailSpeed = 3
            want.aim = .at(post)
            want.look = Vec2(0, 0)
            want.hands = Paws(Vec3(SIDES[0] * 0.28, 1.42 + stroke * 0.13, 1.02), Vec3(SIDES[1] * 0.28, 1.42 - stroke * 0.13, 1.02))
        case .loaf:
            // Down as a loaf in the grass, as on its blanket.
            want.prone = 0.45
            want.tall = -0.06
            want.aim = .camera
            want.look = Vec2(0, 0)
            want.earPerk = 0.3
            want.sway = 0.008
            want.breath = 0.018
            want.tail = .curl
            want.tailAmp = 0.1
            want.tailSpeed = 0.7
        }
    }

    /// How far a face may point from straight at you, in radians: a three-quarter view of its work, its boss
    /// or a butterfly, never so far round that an eye (each sits a little out on the curve of the face) slips
    /// out of sight. From the sidebar's steep camera a head bowed over a book would show only its crown.
    static let faceCone: Float = 0.7
    /// How far the head turns and nods on its neck before the skin would crease.
    static let headTurn: Float = 1.1, headUp: Float = -0.75, headDown: Float = 0.45

    /// The head's yaw and pitch, turned toward you as little as keeps its face within `faceCone` of you,
    /// wherever the camera is. Every pose and whim aims first; this has the last word. The body leaning
    /// forward (`forward`) or tipped (`tip`) counts, so a cat lying over its book still looks up enough.
    private func facingYou(_ aim: (Float, Float), turnY: Float, forward: Float, tip: Float, _ around: Surroundings) -> (Float, Float) {
        // The body's turn; a rotation, so its transpose takes the world into it.
        let body = Mat4.rotationY(turnY) * Mat4.euler(forward, 0, tip)
        let gaze = around.eye - head
        guard simd_length_squared(gaze) > 1e-6 else { return aim }
        let you = simd_normalize(body.transpose.direction(gaze))
        var face = Vec3(cos(aim.1) * sin(aim.0), -sin(aim.1), cos(aim.1) * cos(aim.0))
        let along = simd_dot(face, you)
        if along < cos(Self.faceCone) {
            // Swung toward you along the shortest way, to the edge of the cone.
            var aside = face - you * along
            if simd_length_squared(aside) < 1e-6 { aside = Vec3(0, -1, 0) - you * -you.y }
            face = you * cos(Self.faceCone) + simd_normalize(aside) * sin(Self.faceCone)
        }
        return (clamp(atan2(face.x, face.z), -Self.headTurn, Self.headTurn), clamp(-asin(clamp(face.y, -1, 1)), Self.headUp, Self.headDown))
    }

    // Yaw and pitch that turn the head toward a spot in the world.
    private func aimToward(_ spot: Vec3) -> (Float, Float) {
        let gaze = spot - head
        return (clamp(turnFrom(heading, atan2(gaze.x, gaze.z)), -1, 1), clamp(-atan2(gaze.y, hypot(gaze.x, gaze.z)), -0.45, 0.4))
    }

    // Yaw and pitch that point the head at a spot on screen, from wherever the camera currently is.
    private func aimAt(_ px: Float, _ py: Float, _ around: Surroundings) -> (Float, Float) {
        let gaze = around.eye + around.right * (px * 4) + around.up * (py * 3) - head
        return (clamp(turnFrom(heading, atan2(gaze.x, gaze.z)), -0.8, 0.8), clamp(-atan2(gaze.y, hypot(gaze.x, gaze.z)), -0.32, 0.26))
    }

    // MARK: - tail

    // Tapered tube rebuilt each frame from a swaying curve.
    private func updateTail(_ dt: Float, _ want: Want) {
        tailPhase += (frozen ? 0 : dt) * want.tailSpeed
        let sway = sin(tailPhase) * want.tailAmp
        let flick = sin(tailPhase - 0.9) * want.tailAmp
        let follow = min(1, dt * 5)
        let goal = TAILS[want.tail.rawValue]
        for i in 0..<5 {
            tailLine[i] += (goal[i] - tailLine[i]) * follow
            tailCurve.points[i] = tailLine[i]
        }
        tailCurve.points[2].x += sway * 0.05
        tailCurve.points[3].x += sway * 0.14
        tailCurve.points[3].z += flick * 0.06
        tailCurve.points[4].x += flick * 0.3
        tailCurve.points[4].z += flick * 0.1

        tailCurve.frenetFrames(TAIL_RINGS, &tailTangents, &tailNormals, &tailBinormals)
        for i in 0...TAIL_RINGS {
            // Rings bunch up toward the end so the rounded tip gets enough of them to look smooth.
            let u = 1 - pow(1 - Float(i) / Float(TAIL_RINGS), 2)
            let center = tailCurve.pointAt(u)
            // Thick where it leaves the body, slimmer along its length, rounded off at the tip.
            let taper = lerp(0.17, 0.115, smoothstep(u, 0, 0.55)) * lerp(1, now.tailPuff, smoothstep(u, 0.1, 0.4))
            let radius = taper * (u > 0.92 ? sqrt(max(0, 1 - pow((u - 0.92) / 0.08, 2))) : 1)
            let nearest = Int((u * Float(TAIL_RINGS)).rounded())
            let n = tailNormals[nearest], b = tailBinormals[nearest]
            for j in 0..<TAIL_SIDES {
                let angle = Float(j) / Float(TAIL_SIDES) * 2 * .pi
                let c = cos(angle) * radius, s = sin(angle) * radius
                tailPositions[i * TAIL_SIDES + j] = center + n * c + b * s
            }
        }
        // computeVertexNormals over the tube.
        for i in 0..<TAIL_VERTS { tailVertexNormals[i] = .zero }
        var k = 0
        while k < TAIL_INDEX.count {
            let a = Int(TAIL_INDEX[k]), bb = Int(TAIL_INDEX[k + 1]), c = Int(TAIL_INDEX[k + 2])
            let f = simd_cross(tailPositions[c] - tailPositions[bb], tailPositions[a] - tailPositions[bb])
            tailVertexNormals[a] += f; tailVertexNormals[bb] += f; tailVertexNormals[c] += f
            k += 3
        }
        for i in 0..<TAIL_VERTS {
            let p = tailPositions[i]
            let nl = simd_length_squared(tailVertexNormals[i]) > 0 ? simd_normalize(tailVertexNormals[i]) : Vec3(0, 1, 0)
            tailVertices[i * 6] = p.x; tailVertices[i * 6 + 1] = p.y; tailVertices[i * 6 + 2] = p.z
            tailVertices[i * 6 + 3] = nl.x; tailVertices[i * 6 + 4] = nl.y; tailVertices[i * 6 + 5] = nl.z
        }
    }
}
