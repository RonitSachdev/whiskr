import AppKit
import Foundation
import Testing
import simd
@testable import MeadowScene

// Out in the grass a cat's face follows the Faces rule from every side: both eyes toward the camera, or, its back
// to you further than its neck turns (at a post, a bowl, on its way home), both out of sight; never one eye alone
// on the side of its head, as the sidebar's steep camera once showed a cat at its post.

@MainActor
@Suite(.serialized) struct RoamingFaces {
    /// The editor's and a sidebar's steepness, each from all round.
    nonisolated static let cameras: [(String, Float)] = [("editor", Stage.editPitch), ("sidebar", MapCamera.columnPitch)]
    nonisolated static let bearings: [Float] = (0..<8).map { Float($0) * .pi / 4 + 0.1 }
    /// Turned at least this far from the camera, an eye is out of sight behind the curve of the head.
    static let hidden: Float = 0.05

    /// How the eyes look from the camera as it is: both readable, or both turned away; not one alone.
    static func eyes(_ view: MeadowView, _ actor: Actor) -> (left: Float, right: Float, ok: Bool) {
        let eye = view.stage.camera.eye, cat = actor.cat
        let left = Faces.facing(cat.eyeWhites.0, eye: eye), right = Faces.facing(cat.eyeWhites.1, eye: eye)
        return (left, right, min(left, right) > Faces.readable || max(left, right) < Self.hidden)
    }

    /// Whether its head is still swinging round to the camera (a moment's turn on the way from one side to the
    /// other is not a face held that way): how far its eyes turn in a sixtieth of a second.
    static func swinging(_ view: MeadowView, _ actor: Actor) -> Bool {
        let was = Self.eyes(view, actor)
        view.advance(seconds: 1.0 / 60)
        let now = Self.eyes(view, actor)
        return max(abs(now.left - was.left), abs(now.right - was.right)) > 0.012
    }

    static func look(_ view: MeadowView, at actor: Actor, pitch: Float, bearing: Float) {
        let at = actor.cat.position
        view.stage.camera.setView(CameraView(x: at.x, z: at.z, distance: 30, pitch: pitch, bearing: bearing))
    }

    @Test("at a post, a bowl, a stump and in a box, both eyes face the camera from every side, or neither shows",
          arguments: ["cat.scratchingPost", "cat.bowl", "wood.stump", "cat.box"])
    func atAThing(_ id: String) {
        let view = CatAfternoons.view([(id, CatAfternoons.front(6.6, 1.0))])
        let actor = Roaming.actor(view)
        Roaming.setOutNow(view)
        guard CatAfternoons.until(view, 240, { actor.roam.phase == .stopped && CatAfternoons.place(view, actor)?.id == id }) else {
            Issue.record("\(id) never used")
            return
        }
        view.advance(seconds: 0.8)
        var checked = 0
        for (camera, pitch) in Self.cameras {
            for bearing in Self.bearings {
                Self.look(view, at: actor, pitch: pitch, bearing: bearing)
                // Kept at its spot while it is looked at from all round, a moment for its head to turn.
                for _ in 0..<40 {
                    actor.roam.until = max(actor.roam.until, view.stage.village!.clock + 5)
                    view.advance(seconds: 1.0 / 60)
                }
                guard CatAfternoons.place(view, actor)?.id == id else { continue }
                let (left, right, ok) = Self.eyes(view, actor)
                #expect(ok, "\(id), \(camera) camera from \(bearing): eyes face it by \(left), \(right)")
                checked += 1
            }
        }
        #expect(checked == Self.cameras.count * Self.bearings.count, "\(id): looked at from \(checked) sides")
    }

    @Test("walking out and running home, both eyes face the camera from every side, or neither shows")
    func onTheWay() {
        let view = CatAfternoons.view([])
        let actor = Roaming.actor(view)
        let cameras = Self.cameras.flatMap { c in Self.bearings.map { (c.0, c.1, $0) } }
        var checked = 0, ran = 0, k = 0
        for _ in 0..<24 where ran < 8 {
            Roaming.setOutNow(view)
            // Out, from stop to stop: each moment on the way seen from the next camera round.
            let before = checked
            for _ in 0..<(30 * 40) where checked - before < 6 {
                if actor.roam.phase == .travelling, actor.roam.out, actor.roam.ramp > 0.9 {
                    let (camera, pitch, bearing) = cameras[k % cameras.count]
                    k += 1
                    Self.look(view, at: actor, pitch: pitch, bearing: bearing)
                    view.advance(seconds: 0.4)
                    guard actor.roam.phase == .travelling, actor.roam.ramp > 0.9, !Self.swinging(view, actor) else { continue }
                    let (left, right, ok) = Self.eyes(view, actor)
                    #expect(ok, "\(actor.roam.gait) out, \(camera) camera from \(bearing): eyes face it by \(left), \(right)")
                    checked += 1
                } else {
                    view.advance(seconds: 1.0 / 30)
                }
            }
            // Called home: the run, seen the same way.
            view.world = CatAfternoons.alone(.reading)
            for _ in 0..<(60 * 6) where actor.roam.out {
                if actor.roam.phase == .recalled, actor.roam.ramp > 0.9 {
                    let (camera, pitch, bearing) = cameras[k % cameras.count]
                    k += 1
                    Self.look(view, at: actor, pitch: pitch, bearing: bearing)
                    view.advance(seconds: 0.3)
                    guard actor.roam.phase == .recalled, actor.roam.ramp > 0.9, !Self.swinging(view, actor) else { continue }
                    let (left, right, ok) = Self.eyes(view, actor)
                    #expect(ok, "running home, \(camera) camera from \(bearing): eyes face it by \(left), \(right)")
                    checked += 1
                    ran += 1
                } else {
                    view.advance(seconds: 1.0 / 60)
                }
            }
            view.world = CatAfternoons.alone()
            view.advance(seconds: 2)
        }
        #expect(checked > 30 && ran > 3, "\(checked) moments on the way, \(ran) running home")
    }
}
