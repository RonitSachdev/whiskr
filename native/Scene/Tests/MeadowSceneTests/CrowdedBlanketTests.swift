import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import simd
@testable import MeadowScene

// Many plain terminals on one blanket (thirteen tabs at night): the lanterns stand in one tidy row along
// the front of the hem, at most `MOST_LANTERNS` of them, the failed first; the rest are counted on the
// flag ("+N", after dark only). Clear of each other, the cats, the picnic and the flag, all on the cloth,
// each keeping its place as others come and go. `MEADOW_SNAPSHOTS=<folder>` also writes pictures.

@MainActor
enum Crowd {
    static func lanterns(_ count: Int, failedLast: Bool = false) -> [MeadowLantern] {
        (0..<count).map { i in
            let failed = failedLast ? i == count - 1 : i == 3
            return MeadowLantern(id: "t\(i)", title: "zsh", state: failed ? .failed : i % 3 == 1 ? .finished : .running)
        }
    }
    static func world(_ count: Int, helpers: Bool, failedLast: Bool = false) -> MeadowWorld {
        var agents = [MeadowAgent(id: "main", activity: .editing)]
        if helpers {
            agents += [MeadowAgent(id: "h1", parentID: "main", activity: .reading), MeadowAgent(id: "h2", parentID: "main", activity: .searching)]
        }
        return MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: [MeadowSpace(id: "s", name: "s", blankets: [
            MeadowBlanket(id: "shop", title: "shop-web", color: .account(0), agents: agents, lanterns: lanterns(count, failedLast: failedLast), detail: "main"),
        ])])])
    }
    static func view(_ world: MeadowWorld, column: Bool, time: MeadowSettings.TimeOfDay) -> MeadowView {
        let size = column ? NSSize(width: 300, height: 520) : NSSize(width: 480, height: 320)
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(arrangement: column ? .column : .picnic, timeOfDay: time, picnic: .hamper)
        view.world = world
        view.advance(seconds: 0.5)
        view.frame(nil, besidePanelWidth: 0, animated: false)
        view.advance(seconds: 4)
        return view
    }
    static func save(_ view: MeadowView, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["MEADOW_SNAPSHOTS"] else { return }
        let w = Int(view.bounds.width * 2), h = Int(view.bounds.height * 2)
        guard let image = view.renderImage(width: w, height: h) else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

@MainActor
@Suite(.serialized) struct CrowdedBlanket {
    static let reach = Picnic.lanternReach * LANTERN_SIZE

    func standing(_ plot: Plot) -> [LanternPlace] { plot.lanterns.filter { !$0.leaving && !$0.hidden } }

    @Test(arguments: [1, 5, 13, 30])
    func tidyAndClear(_ count: Int) throws {
        for column in [false, true] {
            for helpers in [false, true] {
                for time in [MeadowSettings.TimeOfDay.day, .night] {
                    let where_ = "\(count) lanterns, \(column ? "column" : "picnic"), \(helpers ? "with helpers" : "alone"), \(time)"
                    let view = Crowd.view(Crowd.world(count, helpers: helpers), column: column, time: time)
                    let village = view.stage.village!, plot = village.plots[0]
                    let up = standing(plot)
                    // A sensible cap, and every lantern either standing or counted.
                    #expect(up.count <= MOST_LANTERNS, "\(where_)")
                    #expect(up.count >= min(count, 4), "\(where_): only \(up.count) stand")
                    #expect(up.count + plot.lanternsHidden == count, "\(where_)")
                    for (k, a) in up.enumerated() {
                        let p = Vec2(a.spot.x, a.spot.z)
                        // On the cloth, wholly.
                        let out = Vec2(p.x - plot.center.x, p.y - plot.center.z)
                        let edge = village.clothReach(plot, toward: simd_normalize(out))
                        #expect(simd_length(out) + Self.reach <= edge + 1e-3, "\(where_): \(a.view.id) off the cloth")
                        // Clear of the other lanterns, the cats and the picnic, by the scene's own reaches.
                        for b in up[(k + 1)...] { #expect(hypot(p.x - b.spot.x, p.y - b.spot.z) >= 2 * Self.reach, "\(where_): \(a.view.id) on \(b.view.id)") }
                        for actor in plot.actors.values {
                            #expect(hypot(p.x - actor.spot.x, p.y - actor.spot.z) >= 1.35 * actor.size + Self.reach, "\(where_): \(a.view.id) on cat \(actor.view.id)")
                        }
                        for t in plot.treats where t.wanted {
                            #expect(hypot(p.x - t.spot.x, p.y - t.spot.z) >= t.reach + Self.reach, "\(where_): \(a.view.id) on the picnic")
                        }
                    }
                    if time == .day {
                        // By day nothing says they are there: none drawn, nothing counted on the flag.
                        for l in plot.lanterns { #expect(village.shown(l) == 0, "\(where_)") }
                        #expect(plot.label.more == 0, "\(where_)")
                        continue
                    }
                    #expect(plot.label.more == plot.lanternsHidden, "\(where_): the flag counts what has no room")
                    let flag = try #require(village.flagBox(plot, view.stage))
                    for l in up {
                        #expect(village.shown(l) > 0.95, "\(where_)")
                        // Never over the flag on screen.
                        let box = try #require(view.stage.screenBox(of: .lantern(blanket: "shop", lantern: l.view.id)))
                        let apart = box.right < flag.left || box.left > flag.right || box.bottom < flag.top || box.top > flag.bottom
                        #expect(apart, "\(where_): \(l.view.id) over the flag")
                        // And every one can be pointed at.
                        let c = view.stage.screen(plot.group + l.at + Vec3(0, 0.5, 0))
                        #expect(view.stage.pick(Vec2(c.x, c.y)) == .lantern(blanket: "shop", lantern: l.view.id), "\(where_): \(l.view.id) not picked")
                    }
                    for l in plot.lanterns where l.hidden {
                        #expect(view.stage.screenBox(of: .lantern(blanket: "shop", lantern: l.view.id)) == nil, "\(where_)")
                    }
                }
            }
        }
    }

    /// With more than the cap, the failed lantern stands, wherever it comes in the list; then the lit.
    @Test(arguments: [13, 30])
    func failedFirst(_ count: Int) {
        for column in [false, true] {
            let plot = Crowd.view(Crowd.world(count, helpers: true, failedLast: true), column: column, time: .night).stage.village!.plots[0]
            let up = standing(plot)
            #expect(plot.lanternsHidden > 0)
            #expect(up.contains { $0.view.state == .failed }, "the failed lantern is hidden")
            if up.contains(where: { $0.view.state == .finished }) {
                #expect(!plot.lanterns.contains { $0.hidden && $0.view.state == .running }, "a dark one stands while a lit one is hidden")
            }
            #expect(plot.label.more == plot.lanternsHidden && !plot.label.moreFailed)
        }
    }

    /// One coming or going leaves every other where it stood.
    @Test func placesAreKept() {
        for column in [false, true] {
            let view = Crowd.view(Crowd.world(6, helpers: true), column: column, time: .night)
            let plot = view.stage.village!.plots[0]
            let before = Dictionary(uniqueKeysWithValues: standing(plot).map { ($0.view.id, $0.spot) })
            var world = Crowd.world(6, helpers: true)
            world.machines[0].spaces[0].blankets[0].lanterns.remove(at: 2)
            view.world = world
            view.advance(seconds: 1)
            for l in standing(plot) { #expect(l.spot == before[l.view.id], "\(l.view.id) moved when one left") }
            world.machines[0].spaces[0].blankets[0].lanterns.append(MeadowLantern(id: "new", state: .running))
            view.world = world
            view.advance(seconds: 1)
            for l in standing(plot) where l.view.id != "new" { #expect(l.spot == before[l.view.id], "\(l.view.id) moved when one came") }
            #expect(standing(plot).contains { $0.view.id == "new" })
        }
    }

    /// Pictures to look at, written only when asked for.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEADOW_SNAPSHOTS"] != nil))
    func snapshots() {
        for column in [false, true] {
            for n in [1, 5, 13, 30] {
                Crowd.save(Crowd.view(Crowd.world(n, helpers: true), column: column, time: .night), "\(column ? "column" : "picnic")-\(n)-night")
            }
            Crowd.save(Crowd.view(Crowd.world(13, helpers: true), column: column, time: .day), "\(column ? "column" : "picnic")-13-day")
            Crowd.save(Crowd.view(Crowd.world(13, helpers: false), column: column, time: .night), "\(column ? "column" : "picnic")-13-alone-night")
        }
    }
}
