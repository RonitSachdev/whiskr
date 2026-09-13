import AppKit
import Foundation
import Testing
import simd
@testable import MeadowScene

// Every cat reads as a cat with a face from the cameras it is usually seen from: both eyes turned toward
// the camera, whatever it is doing, boss or helper, in the sidebar and in the open meadow. A napping cat is
// the one exception: its eyes are shut and its "z" shows.

@MainActor
@Suite(.serialized) struct Faces {
    nonisolated static let states: [(String, MeadowAgent)] = [
        ("working: reading", MeadowAgent(id: "boss", activity: .reading)),
        ("working: editing", MeadowAgent(id: "boss", activity: .editing)),
        ("working: running", MeadowAgent(id: "boss", activity: .running)),
        ("working: searching", MeadowAgent(id: "boss", activity: .searching)),
        ("working: tidying", MeadowAgent(id: "boss", activity: .tidying)),
        ("thinking", MeadowAgent(id: "boss", activity: .thinking)),
        ("supervising helpers", MeadowAgent(id: "boss", activity: .supervising)),
        ("asking", MeadowAgent(id: "boss", activity: .running, needsYou: true)),
        ("error", MeadowAgent(id: "boss", activity: .error, failed: true)),
        ("finished", MeadowAgent(id: "boss", activity: .awake, doneUnseen: true)),
        ("idle loaf", MeadowAgent(id: "boss", activity: .idle)),
        ("awake", MeadowAgent(id: "boss", activity: .awake)),
        ("napping", MeadowAgent(id: "boss", activity: .napping)),
    ]

    /// The boss in the given state with three helpers at work round it, on the selected blanket among
    /// four others.
    static func world(_ boss: MeadowAgent) -> MeadowWorld {
        let team = [boss,
                    MeadowAgent(id: "h1", parentID: "boss", activity: .reading),
                    MeadowAgent(id: "h2", parentID: "boss", activity: .searching),
                    MeadowAgent(id: "h3", parentID: "boss", activity: .running)]
        let others: [[MeadowAgent]] = [[MeadowAgent(id: "c", activity: .editing)], [MeadowAgent(id: "c", activity: .tidying)],
                                       [MeadowAgent(id: "c", activity: .thinking)], [MeadowAgent(id: "c", activity: .idle)]]
        let blankets = [MeadowBlanket(id: "team", title: "team", color: .account(0), agents: team)]
            + others.enumerated().map { MeadowBlanket(id: "w\($0.offset)", title: "w\($0.offset)", color: .account($0.offset + 1), agents: $0.element) }
        return MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: blankets.map { MeadowSpace(id: $0.id, name: $0.id, blankets: [$0]) })])
    }

    enum Camera: String, CaseIterable, Sendable { case sidebar300, sidebarDefault, sidebar240, overview }

    static func view(_ camera: Camera, _ world: MeadowWorld) -> MeadowView {
        let size: NSSize = switch camera {
        case .sidebar300: NSSize(width: 300, height: 820)
        case .sidebar240: NSSize(width: 240, height: 820)
        case .sidebarDefault: NSSize(width: 605, height: 900)
        case .overview: NSSize(width: 1280, height: 800)
        }
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(arrangement: camera == .overview ? .picnic : .column, timeOfDay: .day, picnic: .hamper)
        view.world = world
        view.selection = .blanket("team")
        view.advance(seconds: 0.5)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 3)
        return view
    }

    /// How squarely an eye faces the camera: the cosine of the angle between its face and the line to the
    /// camera (1 straight on, 0 edge on, below 0 turned away).
    static func facing(_ white: Mat4, eye: Vec3) -> Float {
        let normal = simd_normalize(white.direction(Vec3(0, 0, 1)))
        return simd_dot(normal, simd_normalize(eye - white.position))
    }

    /// Well within view, not just edge on: an eye at most about 70° from facing the camera.
    static let readable: Float = 0.34

    @Test("both eyes face the camera in every state, boss and helpers alike, at every usual camera",
          arguments: Camera.allCases, states.indices)
    func eyesInView(_ camera: Camera, _ state: Int) {
        let (name, boss) = Self.states[state]
        let view = Self.view(camera, Self.world(boss))
        let stage = view.stage
        // Sampled over a few seconds, so sweeps, glances, sips and fidgets are all caught.
        for _ in 0..<16 {
            view.advance(seconds: 0.37)
            for plot in stage.village!.plots {
                for actor in plot.liveActors where !actor.leaving {
                    let cat = actor.cat, eye = stage.camera.eye
                    let who = "\(camera) \(name): \(plot.view.id)/\(actor.view.id) (\(cat.activity))"
                    if cat.isNapping {
                        // Asleep: eyes shut and the "z" up.
                        #expect(cat.eyesOpen < 0.2, "\(who) naps with its eyes open")
                        #expect(cat.bubbleShown && cat.bubbleMark == .sleeping, "\(who) naps with no z")
                        continue
                    }
                    let left = Self.facing(cat.eyeWhites.0, eye: eye), right = Self.facing(cat.eyeWhites.1, eye: eye)
                    #expect(min(left, right) > Self.readable, "\(who): eyes face the camera by \(left), \(right)")
                    #expect(cat.eyesOpen > 0.25, "\(who): eyes shut (\(cat.eyesOpen))")
                }
            }
        }
    }
}
