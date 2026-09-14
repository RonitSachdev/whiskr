import AppKit
import Foundation
import Testing
import simd
@testable import MeadowScene

// Plain terminal panes are lanterns, and lanterns only come out after dark (the user: "no need for lamp
// in morning"); by day a tab's terminals show only in the app's panel.

@MainActor
@Suite(.serialized) struct Lanterns {
    func world(lanterns: Int) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "shop", title: "shop", color: .account(0),
                          agents: [MeadowAgent(id: "main", activity: .editing), MeadowAgent(id: "h", parentID: "main", activity: .reading)],
                          lanterns: (0..<lanterns).map { MeadowLantern(id: "l\($0)", title: "npm run dev", state: $0 == 1 ? .failed : .running) }),
        ])])])
    }
    func stage(_ time: MeadowSettings.TimeOfDay, lanterns: Int = 2) -> Stage {
        let s = Stage(mode: .meadow)
        s.camera.viewport = Vec2(800, 600)
        s.settings = MeadowSettings(timeOfDay: time)
        s.show(world(lanterns: lanterns))
        s.camera.settle()
        for _ in 0..<240 { s.update(1.0 / 60) }
        return s
    }

    @Test func outAtNightForPlainTerminals() {
        let s = stage(.night)
        let plot = s.village!.plots[0]
        #expect(plot.lanterns.count == 2)
        for l in plot.lanterns { #expect(s.village!.shown(l) > 0.95) }
        // And they can be pointed at.
        let l = plot.lanterns[0]
        let p = s.screen(plot.group + l.at + Vec3(0, 0.5, 0))
        #expect(s.pick(Vec2(p.x, p.y)) == .lantern(blanket: "shop", lantern: l.view.id))
    }

    @Test func absentByDay() {
        let s = stage(.day)
        let plot = s.village!.plots[0]
        for l in plot.lanterns {
            #expect(s.village!.shown(l) == 0)
            // Nothing there to point at: the spot is plain cloth (or the blanket).
            let p = s.screen(plot.group + l.at + Vec3(0, 0.5, 0))
            if case .lantern = s.pick(Vec2(p.x, p.y)) { Issue.record("a lantern was picked by day") }
        }
    }

    /// Whether lanterns are out or not, and however many there are, the cats keep their seats and the
    /// blanket its size.
    @Test func lanternsNeverMoveAnyone() {
        let with = stage(.night, lanterns: 3).village!.plots[0], without = stage(.night, lanterns: 0).village!.plots[0]
        #expect(with.size == without.size)
        for (id, a) in with.actors { #expect(a.spot == without.actors[id]!.spot) }
        // On the cloth, clear of the cats.
        let village = stage(.night, lanterns: 3).village!
        for l in with.lanterns {
            let out = Vec2(l.spot.x - with.center.x, l.spot.z - with.center.z)
            #expect(simd_length(out) + Picnic.lanternReach <= village.clothReach(with, toward: simd_normalize(out)) + 1e-3)
            for a in with.actors.values { #expect(hypot(l.spot.x - a.spot.x, l.spot.z - a.spot.z) >= 1.35 * a.size + Picnic.lanternReach) }
        }
    }

    /// Dusk brings them out gradually rather than all at once.
    @Test func fadeWithTheDark() {
        let s = stage(.day)
        s.settings = MeadowSettings(timeOfDay: .night)
        var seen: [Float] = []
        for _ in 0..<90 { s.update(1.0 / 60); seen.append(s.village!.shown(s.village!.plots[0].lanterns[0])) }
        #expect(seen.first! < 0.1 && seen.last! > 0.7)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $1 >= $0 - 1e-4 })
    }
}
