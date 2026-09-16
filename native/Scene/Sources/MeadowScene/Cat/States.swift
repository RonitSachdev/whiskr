import Foundation
import simd

// Port of src/cat/states.ts: what a cat is trying to look like this frame, per activity. The cat eases
// toward it, so states can just declare.

enum TailPose: Int { case rest, up, curl }
enum PropName: Int, CaseIterable { case book, desk, machine, spyglass, papers, cup, snack }

/// The symbol in a cat's bubble. The first five are the web's; `needsYou` (white on red) and `done` (a
/// check) are the marks of the approved Mac design.
public enum BubbleMark: Int, CaseIterable, Sendable {
    case thinking, alert, sleeping, error, heart, needsYou, done
    var symbol: String {
        switch self {
        case .thinking: "…"
        case .alert, .needsYou: "!"
        case .sleeping: "z"
        case .error: "×"
        case .heart: "♥"
        case .done: "✓"
        }
    }
}

struct Want {
    enum Aim { case cursor, camera, angles(Float, Float), at(Vec3) }
    var aim: Aim = .cursor
    var roll: Float = 0
    var look: Vec2? = nil                 // pupil offset; nil follows the cursor
    var lid: Float = 1
    var eye: Float = 1
    var pupil: Float = 1
    var earFlat: Float = 0
    var earPerk: Float = 0
    var tail: TailPose = .rest
    var tailSpeed: Float = 1.6
    var tailAmp: Float = 1
    var tailPuff: Float = 1
    var tall: Float = 0
    var lie: Float = 0                    // 0 sitting up, 1 flopped over on its side
    var prone: Float = 0                  // 0 sitting up, 1 stretched out on its front
    var breath: Float = 0.012
    var shiver: Float = 0
    var sway: Float = 0.03                // idle head drift
    var hands = Paws()                    // a point for each paw to reach for, or nil to rest on the belly
    var prop: PropName? = nil
    var bubble: BubbleMark? = nil

    static let relaxed = Want()
}

/// The values that ease toward what the state wants (Cat.ts EASED).
struct Eased {
    var lid: Float = 1, eye: Float = 1, pupil: Float = 1, earFlat: Float = 0, earPerk: Float = 0, tailPuff: Float = 1
    var tall: Float = 0, lie: Float = 0, prone: Float = 0, breath: Float = 0.012, shiver: Float = 0, sway: Float = 0.03, roll: Float = 0

    mutating func ease(toward w: Want, _ k: Float) {
        lid += (w.lid - lid) * k; eye += (w.eye - eye) * k; pupil += (w.pupil - pupil) * k
        earFlat += (w.earFlat - earFlat) * k; earPerk += (w.earPerk - earPerk) * k; tailPuff += (w.tailPuff - tailPuff) * k
        tall += (w.tall - tall) * k; lie += (w.lie - lie) * k; prone += (w.prone - prone) * k
        breath += (w.breath - breath) * k; shiver += (w.shiver - shiver) * k; sway += (w.sway - sway) * k; roll += (w.roll - roll) * k
    }
}

/// The parts of a cat a state may reach into.
protocol Performer: AnyObject {
    var wards: [Vec3] { get }
    var presses: Int { get set }
    func pressButton(_ depth: Float)
    func thump()
    func jump(_ speed: Float, _ stretch: Float)
}

/// How far into a sip the cup is, 0…1, over the first two seconds of every `t` that counts up from 0.
func sipping(_ t: Float) -> Float { smoothstep(t, 0, 0.5) - smoothstep(t, 1.5, 2) }
/// The paw that holds the cup: resting low with it, or raised toward the face for a sip.
func cupPaw(_ sip: Float) -> Vec3 { Vec3(lerp(0.3, 0.2, sip), lerp(0.98, 1.3, sip), lerp(0.96, 0.9, sip)) }

/// What each paw reaches for: left (0) and right (1). A fixed pair, so wanting costs no allocation.
struct Paws {
    var left: Vec3? = nil
    var right: Vec3? = nil
    init(_ left: Vec3? = nil, _ right: Vec3? = nil) { self.left = left; self.right = right }
    subscript(n: Int) -> Vec3? {
        get { n == 0 ? left : right }
        set { if n == 0 { left = newValue } else { right = newValue } }
    }
}

private func bothPaws(_ at: (Float, Int) -> Vec3) -> Paws { Paws(at(SIDES[0], 0), at(SIDES[1], 1)) }

enum States {
    static let buttonX: Float = -0.3, buttonY: Float = 0.68, buttonZ: Float = 1.04
    static let buttonTravel: Float = 0.06

    static func enter(_ activity: AgentActivity, _ cat: Performer) {
        switch activity {
        case .asking: cat.jump(4, 0)
        case .error: cat.jump(3.5, 3)
        default: break
        }
    }

    // `t` is seconds since the state began. Anything left alone falls back to the relaxed default.
    static func act(_ activity: AgentActivity, _ want: inout Want, _ t: Float, _ cat: Performer) {
        switch activity {
        case .awake:
            break

        case .idle:
            // A loaf: down on its front with the paws tucked under (they rest against the belly, as
            // always), head up and turned to you, eyes round and open, tail wrapped round. Only its
            // breathing moves.
            // Half down: low enough to read as a loaf, not so far that the head bows below the eyes'
            // line from the sidebar's high camera.
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

        case .reading:
            // Leaning forward on its front over the book, the way you read lying on a blanket, eyes up
            // enough to stay in view.
            want.prone = 1
            want.aim = .angles(0, -0.18)
            want.look = Vec2(lerp(-0.04, 0.04, (t * 0.55).truncatingRemainder(dividingBy: 1)), -0.035)
            // Every few seconds the right paw flicks across to turn the page.
            let m = t.truncatingRemainder(dividingBy: 4.4)
            let turning = max(0, sin((m / 0.5) * .pi)) * (m < 0.5 ? 1 : 0)
            want.hands = bothPaws { side, n in
                Vec3(side * 0.36 - (n == 1 ? turning * 0.3 : 0), 0.95 + (n == 1 ? turning * 0.12 : 0), 0.95)
            }
            want.prop = .book
            want.tailSpeed = 1

        case .editing:
            // Types in bursts, then looks up for a moment to think about the next line.
            let typing = smoothstep(sin(t * 1.1), -0.55, -0.3)
            want.aim = .angles(sin(t * 0.7) * 0.08, lerp(-0.12, 0.2, typing))
            want.look = Vec2(sin(t * 5) * 0.02 * typing, lerp(0.03, -0.03, typing))
            want.earPerk = 1
            want.hands = bothPaws { side, n in
                Vec3(side * 0.3, 0.79 + max(0, sin(t * 13 + Float(n) * .pi)) * 0.11 * typing, 1.0)
            }
            want.prop = .desk

        case .running:
            // One press every 1.5s, starting the moment the command does: wind the paw up high, thump the
            // button, hold, let go.
            let cycle = t / 1.5, p = cycle.truncatingRemainder(dividingBy: 1)
            let lifted = p < 0.16 ? sin((.pi * p) / 0.16) * 0.24 : 0
            let pressed = (smoothstep(p, 0.16, 0.22) - smoothstep(p, 0.5, 0.7)) * buttonTravel
            cat.pressButton(pressed)
            if p > 0.22 && Int(floor(cycle)) >= cat.presses {
                cat.presses = Int(floor(cycle)) + 1
                cat.thump()
            }
            want.aim = .angles(-0.14, 0.22)
            want.look = Vec2(-0.02, -0.03)
            // Left paw works the button; the right one rests on the machine.
            want.hands = Paws(Vec3(buttonX, buttonY + 0.15 + lifted - pressed, 1.0), Vec3(0.3, 0.74, 1.0))
            want.prop = .machine

        case .searching:
            // Looking something up on the web: scanning the distance through a spyglass.
            let sweep = sin(t * 0.8) * 0.32
            want.aim = .angles(sweep, -0.06)
            want.look = Vec2(0, 0)
            want.earPerk = 1
            want.tailSpeed = 2.4
            // Both paws steady the spyglass and follow it round.
            want.hands = bothPaws { side, _ in Vec3(side * 0.26 + 0.1 + sweep * 0.6, 1.3, 0.95) }
            want.prop = .spyglass

        case .tidying:
            // Compacting its memory: patting a loose stack of papers into shape.
            want.aim = .angles(sin(t * 1.3) * 0.1, 0.3)
            want.look = Vec2(sin(t * 1.3) * 0.02, -0.035)
            want.hands = bothPaws { side, n in Vec3(side * 0.26, 0.5 + max(0, sin(t * 7 + Float(n) * .pi)) * 0.15, 0.98) }
            want.prop = .papers
            want.tailSpeed = 2

        case .thinking:
            // Gazing off over a cup of tea held up near the chin.
            want.aim = .angles(0.3, -0.24)
            want.look = Vec2(0.03, 0.035)
            want.hands[1] = cupPaw(0.55)
            want.prop = .cup
            want.bubble = .thinking
            want.tailSpeed = 3.2
            want.tailAmp = 1.3

        case .supervising:
            // Waiting on its helpers over a cup of tea: it looks from one to the next, and every so often
            // lifts the cup for a sip. With none in sight it just looks about.
            let wards = cat.wards
            let ward: Vec3? = wards.isEmpty ? nil : wards[Int(floor(t / 2.6)) % wards.count]
            let sip = sipping(t.truncatingRemainder(dividingBy: 7))
            if sip > 0.5 { want.aim = .angles(0, -0.12) } else if let ward { want.aim = .at(ward) } else { want.aim = .angles(sin(t * 0.6) * 0.5, 0.12) }
            want.look = ward != nil ? Vec2(0, 0) : Vec2(sin(t * 0.6) * 0.025, -0.015)
            want.hands[1] = cupPaw(sip)
            want.prop = .cup
            want.tall = 0.03
            want.earPerk = 0.6
            want.tailSpeed = 1.1

        case .asking:
            // Up tall and facing you, one paw raised: the tallest silhouette on the blanket. It hops when
            // it starts asking, again at two minutes and at ten, and otherwise holds still (an alert that
            // never stops moving soon goes unseen).
            want.aim = .camera
            want.look = Vec2(0, 0)
            want.tall = 0.16
            want.hands = bothPaws { side, n in
                n == 0 ? Vec3(side * 0.55, 1.42, 0.86) : Vec3(side * 0.62, 1.05, 0.9)
            }
            let hops = (t > 120 ? 1 : 0) + (t > 600 ? 1 : 0)
            if hops > cat.presses {
                cat.presses = hops
                cat.jump(3.2, 1)
            }
            want.bubble = .alert
            want.eye = 1.08
            want.earPerk = 1
            want.tail = .up

        case .napping:
            // Eyes close slowly as it drifts off (one unbroken close, never held half shut), then slow
            // breathing. Flopped over on its side in the sun.
            want.lid = lerp(1, 0.06, smoothstep(t, 0, 0.9))
            want.aim = .angles(0, 0.24)
            want.look = Vec2(0, -0.02)
            want.sway = 0
            want.lie = 1
            want.tall = -0.08
            want.breath = 0.03
            want.tail = .curl
            want.tailAmp = 0.12
            want.tailSpeed = 0.8
            if t > 1.4 { want.bubble = .sleeping }

        case .error:
            want.aim = .camera
            want.look = Vec2(0, 0)
            want.eye = 1.15
            want.pupil = 0.6
            want.earFlat = 1
            want.shiver = t < 1.2 ? 1 : 0.25
            want.hands = bothPaws { side, _ in Vec3(side * 0.72, 1.07, 0.88) }
            want.bubble = .error
            want.tail = .up
            want.tailPuff = 1.8
            want.tailSpeed = 14
            want.tailAmp = 0.25
        }
    }

    /// Done, and you have not looked yet: it sits upright and still facing you with a check bubble, tail
    /// wrapped round its paws, the paws resting. Calm: nothing about it moves but its breathing.
    static func doneUnseen(_ want: inout Want, _ t: Float) {
        want.aim = .camera
        want.look = Vec2(0, 0)
        want.tall = 0.05
        want.lie = 0
        want.prone = 0
        want.lid = 1
        want.earPerk = 0.5
        want.sway = 0
        want.tail = .curl
        want.tailAmp = 0.06
        want.tailSpeed = 0.6
        want.hands = Paws()
        want.prop = nil
        want.bubble = .done
    }
}
