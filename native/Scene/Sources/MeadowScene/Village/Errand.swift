import Foundation
import simd

// PLAN step 5, cats that interact: a boss hands a new helper its task (a little note floats over), the
// helper listens, then trots off to its seat; a helper trots back to report and its boss nods; one agent's
// message to another floats across as a note while both look. Every walk stays on its blanket and is over
// in about two seconds; none starts on a cat that needs you, and with Reduce Motion nothing travels: the
// cats only look at each other.

/// A helper's trip on its blanket, timed from when it began (village time).
struct Errand {
    enum Kind {
        /// Just launched: its boss hands it the task (a note), it listens and nods, then trots to its seat.
        case arrive
        /// Trots over, hands its boss a note, the boss nods, and it trots back to its seat.
        case report
        /// Done: trots over and reports, the boss nods, and it hops off.
        case farewell
    }
    let kind: Kind
    let began: Float
    /// Whom it goes to: its boss, or whoever it reports to.
    unowned let boss: Actor
    /// Seconds of trotting each way.
    let walk: Float

    /// When the note sets off, and how long it floats.
    var noteAt: Float { kind == .arrive ? 0.1 : walk }
    static let noteSeconds: Float = 0.7
    /// The nod that answers the note: the helper's "got it" when arriving, else the boss's.
    var nodAt: Float { noteAt + Self.noteSeconds - 0.1 }
    /// Arriving, it sets off once it has listened; otherwise it waits by its boss this long.
    var outAt: Float { kind == .arrive ? 1.25 : walk }
    static let stay: Float = 1.05
    var end: Float {
        switch kind {
        case .arrive: outAt + walk
        case .report: walk + Self.stay + walk
        case .farewell: walk + Self.stay
        }
    }

    /// Where it is at `t` seconds in, between its seat and its boss's side (blanket-local), and whether it
    /// is on the move.
    func place(at t: Float, seat: Vec3, meet: Vec3) -> (at: Vec3, moving: Bool) {
        func trot(_ from: Vec3, _ to: Vec3, _ start: Float) -> Vec3 {
            let u = clamp((t - start) / max(walk, 0.01), 0, 1)
            // Brisk in the middle, easing off at either end.
            return lerp(from, to, u * u * (3 - 2 * u))
        }
        switch kind {
        case .arrive:
            return t < outAt ? (meet, false) : (trot(meet, seat, outAt), t < end)
        case .report:
            if t < walk { return (trot(seat, meet, 0), true) }
            if t < walk + Self.stay { return (meet, false) }
            return (trot(meet, seat, walk + Self.stay), t < end)
        case .farewell:
            return t < walk ? (trot(seat, meet, 0), true) : (meet, false)
        }
    }
}

/// A note passing from one cat to another: a small white speech bubble with three dots, floating in an
/// arc from head to head. It holds on to both cats for the moment it floats (a cat that leaves meanwhile
/// still gets it where it last was).
struct FlyingNote {
    let from: Actor
    let to: Actor
    /// When it sets off (village time).
    let at: Float
    /// Where it is drawn this frame and how large (w); w is 0 while it is not shown.
    var drawn = Vec4.zero
}

/// How close a helper comes to whomever it visits: side by side, nearly touching.
private func besideDistance(_ a: Actor, _ b: Actor) -> Float { 1.35 * (a.size + b.size) * 0.85 }
/// How quickly a cat trots, in world units a second, and how long a walk may take.
private let TROT_SPEED: Float = 2.6

extension Village {
    // MARK: starting

    /// A helper just launched beside its boss, on a blanket that was already there: the hand-over.
    func handOver(to helper: Actor, from boss: Actor) {
        guard !helper.cat.needsYou, !boss.cat.needsYou else { return }
        if reduceMotion {
            helper.cat.attend(boss.head, 1.2)
            boss.cat.attend(helper.head, 1.2)
            return
        }
        let meet = beside(boss, helper)
        helper.rootLocal = meet
        start(Errand(kind: .arrive, began: time, boss: boss, walk: walkTime(from: meet, to: helper.spot, least: 0.8)), for: helper)
    }

    /// A helper finishing while its boss is there: it trots over and reports before it goes. Returns how
    /// long until it leaves, or nil when it should leave as before (its boss is not there, or busy, or
    /// motion is reduced).
    func farewell(_ helper: Actor, to boss: Actor) -> Float? {
        guard !reduceMotion, !helper.cat.needsYou, !boss.cat.needsYou, helper.errand == nil else { return nil }
        let errand = Errand(kind: .farewell, began: time, boss: boss, walk: walkTime(from: helper.rootLocal, to: beside(boss, helper), least: 0.5))
        start(errand, for: helper)
        return errand.end
    }

    /// One agent messaging another (`MeadowView.passNote`). A helper writing to anyone above it on its
    /// blanket trots over to report and back; otherwise both turn to each other while the note floats
    /// across. One already busy with a note gets this one after it (two at most wait).
    func passNote(from sender: MeadowItem, to receiver: MeadowItem) {
        guard case .cat(let fromBlanket, let fromAgent) = sender, case .cat(let toBlanket, let toAgent) = receiver,
              let from = actor(fromBlanket, fromAgent), let to = actor(toBlanket, toAgent), from !== to,
              !from.leaving, !to.leaving, !from.cat.needsYou, !to.cat.needsYou else { return }
        if busy(from) || busy(to) {
            if waitingNotes.count < 2 { waitingNotes.append((sender, receiver)) }
            return
        }
        if reduceMotion {
            from.cat.attend(to.head, 1.4)
            to.cat.attend(from.head, 1.4)
            return
        }
        if fromBlanket == toBlanket, let plot = plot(fromBlanket), reportsTo(from, to, in: plot) {
            start(Errand(kind: .report, began: time, boss: to, walk: walkTime(from: from.spot, to: beside(to, from), least: 0.5)), for: from)
            return
        }
        from.cat.attend(to.head, Errand.noteSeconds + 0.9)
        to.cat.attend(from.head, Errand.noteSeconds + 0.9)
        to.cat.nod(after: Errand.noteSeconds)
        notes.append(FlyingNote(from: from, to: to, at: time))
    }

    private func start(_ errand: Errand, for helper: Actor) {
        helper.errand = errand
        let arriving = errand.kind == .arrive
        notes.append(FlyingNote(from: arriving ? errand.boss : helper, to: arriving ? helper : errand.boss, at: time + errand.noteAt))
        (arriving ? helper : errand.boss).cat.nod(after: errand.nodAt)
    }

    /// Seconds to trot between two spots: a steady pace, never dawdling or dashing.
    private func walkTime(from a: Vec3, to b: Vec3, least: Float) -> Float {
        clamp(hypot(b.x - a.x, b.z - a.z) / TROT_SPEED, least, 1.2)
    }

    /// The spot at `boss`'s side (as you look at them, on the side where `helper` sits, a little toward
    /// you), so the two face each other side on and you see both faces (blanket-local).
    func beside(_ boss: Actor, _ helper: Actor) -> Vec3 {
        let right = Vec2(viewRight.x, viewRight.z)
        let across = simd_length(right) > 1e-3 ? simd_normalize(right) : Vec2(1, 0)
        let toward = Vec2(-across.y, across.x)
        let side: Float = simd_dot(Vec2(helper.spot.x - boss.rootLocal.x, helper.spot.z - boss.rootLocal.z), across) < 0 ? -1 : 1
        let away = simd_normalize(across * side + toward * 0.35) * besideDistance(boss, helper)
        return Vec3(boss.rootLocal.x + away.x, 0, boss.rootLocal.z + away.y)
    }

    /// Whether `receiver` launched `sender`, or launched whoever did, on this blanket.
    private func reportsTo(_ sender: Actor, _ receiver: Actor, in plot: Plot) -> Bool {
        var at = sender.view.parentID
        var steps = 0
        while let id = at, steps < 32 {
            if id == receiver.view.id { return true }
            at = plot.actors[id]?.view.parentID
            steps += 1
        }
        return false
    }

    private func busy(_ actor: Actor) -> Bool {
        if actor.errand != nil { return true }
        for note in notes where note.from === actor || note.to === actor { return true }
        return false
    }

    // MARK: each frame

    /// Moves a helper along its errand; it ends, or is called off when either cat comes to need you.
    func runErrand(_ actor: Actor, in plot: Plot) {
        guard let errand = actor.errand else { return }
        let t = time - errand.began
        let boss = errand.boss
        let bossGone = plot.actors[boss.view.id] !== boss || boss.leaving
        if t >= errand.end || actor.cat.needsYou || boss.cat.needsYou || bossGone {
            actor.errand = nil
            actor.cat.going = nil
            actor.cat.trotting = false
            if !bossGone { actor.cat.toward = boss.head }
            return
        }
        let meet = beside(boss, actor)
        let (at, moving) = errand.place(at: t, seat: actor.spot, meet: meet)
        actor.rootLocal = at
        actor.cat.trotting = moving
        let bossAt = plot.group + boss.rootLocal
        if moving {
            // Heading for its seat or for its boss: whichever it is trotting toward.
            let goingOut = errand.kind == .arrive || (errand.kind == .report && t > errand.walk)
            actor.cat.going = plot.group + (goingOut ? actor.spot : meet)
        } else {
            // Beside its boss: turned toward it (and still to you), listening or reporting.
            actor.cat.going = nil
            actor.cat.toward = bossAt
            actor.cat.attend(boss.head, 0.2)
        }
        // The boss watches it come and go.
        boss.cat.attend(actor.head, 0.2)
    }

    /// Notes in flight: where each is, and the ones that have landed let go. Then any note that was
    /// waiting for its cats to be free.
    func updateNotes(_ stage: Stage) {
        let eye = stage.camera.eye, up = stage.surroundings.up
        viewRight = stage.surroundings.right
        let perPixel = 2 * tan(MapCamera.fovY / 2) / max(stage.camera.viewport.y, 1)
        for i in notes.indices {
            let from = notes[i].from, to = notes[i].to
            let u = (time - notes[i].at) / Errand.noteSeconds
            guard u >= 0, u < 1 else { notes[i].drawn = .zero; continue }
            // Off the top of one head, in a little arc, onto the top of the other.
            let a = from.head + up * (0.75 * from.cat.size), b = to.head + up * (0.75 * to.cat.size)
            let rise = clamp(simd_distance(a, b) * 0.35, 0.6, 3) * 4 * u * (1 - u)
            let at = lerp(a, b, u * u * (3 - 2 * u)) + Vec3(0, rise, 0)
            // Pops out, sails, and shrinks into the one it is for; never smaller than a bubble can be read.
            let swell = min(1, u / 0.15, (1 - u) / 0.2)
            let full = 1.05 * (from.cat.size + to.cat.size) / 2
            let smallest = CatDrawer.smallestBubble * 1.05 * perPixel * simd_distance(at, eye)
            notes[i].drawn = Vec4(at, max(full, smallest) * max(swell, 0))
        }
        notes.removeAll { time - $0.at >= Errand.noteSeconds }
        if let next = waitingNotes.first {
            if case .cat(let b, let a) = next.0, let from = actor(b, a), busy(from) { return }
            if case .cat(let b, let a) = next.1, let to = actor(b, a), busy(to) { return }
            waitingNotes.removeFirst()
            passNote(from: next.0, to: next.1)
        }
    }
}
