import AppKit
import Foundation
import Testing
import simd
@testable import MeadowScene

// Cats dealing with each other (PLAN step 5): a boss hands a new helper its task and the helper trots to
// its seat; a helper trots over to report and back; one finishing reports before it goes; a note floats
// between any two. All on the blanket, all over in a couple of seconds, none on a cat that needs you, and
// with Reduce Motion nothing travels.

@MainActor
@Suite(.serialized) struct Errands {
    func world(helper: Bool, helperNeedsYou: Bool = false, bossNeedsYou: Bool = false) -> MeadowWorld {
        var agents = [MeadowAgent(id: "boss", activity: .supervising, needsYou: bossNeedsYou)]
        if helper { agents.append(MeadowAgent(id: "kid", parentID: "boss", activity: .reading, needsYou: helperNeedsYou)) }
        return MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [
            MeadowSpace(id: "team", name: "team", blankets: [MeadowBlanket(id: "team", title: "team", color: .account(0), agents: agents)]),
            MeadowSpace(id: "pals", name: "pals", blankets: [MeadowBlanket(id: "pals", title: "pals", color: .account(1), agents: [MeadowAgent(id: "pal", activity: .thinking)])]),
        ])])
    }

    func view(helper: Bool, reduceMotion: Bool = false) -> MeadowView {
        let view = MeadowView(frame: NSRect(x: 0, y: 0, width: 300, height: 820), mode: .meadow)
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .day)
        view.reduceMotion = reduceMotion
        view.world = world(helper: helper)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 3)
        return view
    }

    func onCloth(_ village: Village, _ plot: Plot, _ actor: Actor) -> Bool {
        let p = plot.group + actor.rootLocal
        let d = Vec2(p.x - plot.middle.x, p.z - plot.middle.z)
        return simd_length(d) < 1e-3 || simd_length(d) < village.edge(plot, simd_normalize(d))
    }

    @Test("a helper launched beside its boss is handed its task, then trots to its seat, staying on the blanket")
    func handOver() throws {
        let view = view(helper: false)
        view.world = world(helper: true)
        let village = view.stage.village!
        let plot = try #require(village.plot("team"))
        let kid = try #require(plot.actors["kid"]), boss = try #require(plot.actors["boss"])
        let errand = try #require(kid.errand)
        #expect(errand.kind == .arrive)
        #expect(errand.end <= 2.5)
        #expect(simd_distance(kid.rootLocal, boss.rootLocal) < 3.5, "it starts at its boss's side")
        #expect(village.notes.count == 1)
        var trotted = false
        for _ in 0..<180 {
            view.advance(seconds: 1.0 / 60)
            #expect(onCloth(village, plot, kid))
            if kid.errand != nil, kid.cat.trotting { trotted = true }
        }
        #expect(trotted)
        #expect(kid.errand == nil)
        #expect(simd_distance(kid.rootLocal, kid.spot) < 0.05)
        #expect(village.notes.isEmpty)
    }

    @Test("a blanket arriving whole (the app opening) has no hand-overs")
    func noHandOverOnArrival() throws {
        let village = view(helper: true).stage.village!
        #expect(village.plot("team")!.actors["kid"]!.errand == nil)
    }

    @Test("nothing plays on a cat that needs you", arguments: [(true, false), (false, true)])
    func notWhenNeeded(_ needs: (helper: Bool, boss: Bool)) throws {
        let view = view(helper: false)
        if needs.boss { view.world = world(helper: false, bossNeedsYou: true); view.advance(seconds: 0.5) }
        view.world = world(helper: true, helperNeedsYou: needs.helper, bossNeedsYou: needs.boss)
        #expect(view.stage.village!.plot("team")!.actors["kid"]!.errand == nil)
        view.passNote(from: .cat(blanket: "team", agent: "kid"), to: .cat(blanket: "team", agent: "boss"))
        #expect(view.stage.village!.notes.isEmpty)
    }

    @Test("with Reduce Motion nothing travels: no trot, no floating note")
    func reducedMotion() throws {
        let view = view(helper: false, reduceMotion: true)
        view.world = world(helper: true)
        let village = view.stage.village!
        #expect(village.plot("team")!.actors["kid"]!.errand == nil)
        view.advance(seconds: 2)
        view.passNote(from: .cat(blanket: "team", agent: "kid"), to: .cat(blanket: "team", agent: "boss"))
        view.passNote(from: .cat(blanket: "team", agent: "boss"), to: .cat(blanket: "pals", agent: "pal"))
        #expect(village.notes.isEmpty)
        #expect(village.plot("team")!.actors["kid"]!.errand == nil)
    }

    @Test("a helper's note to its boss: it trots over, hands it, and trots back to its seat")
    func report() throws {
        let view = view(helper: true)
        let village = view.stage.village!
        let plot = village.plot("team")!, kid = plot.actors["kid"]!, boss = plot.actors["boss"]!
        let seat = kid.spot
        view.passNote(from: .cat(blanket: "team", agent: "kid"), to: .cat(blanket: "team", agent: "boss"))
        let errand = try #require(kid.errand)
        #expect(errand.kind == .report)
        var nearest = Float.infinity, noted = false
        for _ in 0..<240 {
            view.advance(seconds: 1.0 / 60)
            nearest = min(nearest, simd_distance(kid.rootLocal, boss.rootLocal))
            if !village.notes.isEmpty { noted = true }
            #expect(onCloth(village, plot, kid))
        }
        #expect(nearest < simd_distance(seat, boss.rootLocal) - 0.5, "it went over to its boss")
        #expect(noted)
        #expect(kid.errand == nil)
        #expect(simd_distance(kid.rootLocal, seat) < 0.05, "and came back to its seat")
    }

    @Test("a note between blankets: both look, the note floats across, nobody travels")
    func noteAcross() throws {
        let view = view(helper: true)
        let village = view.stage.village!
        let boss = village.plot("team")!.actors["boss"]!
        let before = boss.rootLocal
        view.passNote(from: .cat(blanket: "team", agent: "boss"), to: .cat(blanket: "pals", agent: "pal"))
        #expect(village.notes.count == 1)
        #expect(boss.errand == nil)
        view.advance(seconds: 0.3)
        #expect(village.notes.first.map { $0.drawn.w > 0 } == true)
        view.advance(seconds: 1)
        #expect(village.notes.isEmpty)
        #expect(simd_distance(boss.rootLocal, before) < 0.05)
    }

    @Test("unknown cats are ignored; notes for a busy cat wait their turn, two at most")
    func queueing() {
        let view = view(helper: true)
        let village = view.stage.village!
        view.passNote(from: .cat(blanket: "team", agent: "nobody"), to: .cat(blanket: "team", agent: "boss"))
        view.passNote(from: .cat(blanket: "gone", agent: "kid"), to: .cat(blanket: "team", agent: "boss"))
        #expect(village.notes.isEmpty)
        for _ in 0..<4 { view.passNote(from: .cat(blanket: "team", agent: "boss"), to: .cat(blanket: "pals", agent: "pal")) }
        #expect(village.notes.count == 1)
        #expect(village.waitingNotes.count == 2)
        view.advance(seconds: 4)
        #expect(village.notes.isEmpty && village.waitingNotes.isEmpty, "the waiting notes were passed in turn")
    }

    @Test("a helper finishing trots over and reports before it goes")
    func farewell() throws {
        let view = view(helper: true)
        let village = view.stage.village!
        let plot = village.plot("team")!, kid = plot.actors["kid"]!
        view.world = world(helper: false)
        #expect(kid.leaving)
        #expect(kid.errand?.kind == .farewell)
        #expect(plot.actors["kid"] != nil)
        view.advance(seconds: 1)
        #expect(plot.actors["kid"] != nil, "still reporting")
        view.advance(seconds: 3)
        #expect(plot.actors["kid"] == nil, "gone after reporting")
    }
}
