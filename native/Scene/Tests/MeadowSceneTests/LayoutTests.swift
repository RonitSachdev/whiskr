import Foundation
import Testing
import simd
@testable import MeadowScene

// Village layout: blankets never overlap each other or the trees and log, keep their places when others
// come and go, come out the same every time, gather by space, and lie across a stream from other machines.

@Suite struct VillageLayout {
    func blanket(_ id: String, cats: Int = 1, lanterns: Int = 0) -> MeadowBlanket {
        var agents = [MeadowAgent(id: "main", activity: .editing)]
        for k in 1..<max(cats, 1) { agents.append(MeadowAgent(id: "h\(k)", parentID: k > 3 ? "h1" : "main", activity: .reading)) }
        return MeadowBlanket(id: id, title: id, color: .account(0), agents: agents,
                             lanterns: (0..<lanterns).map { MeadowLantern(id: "l\($0)", title: "npm run dev") })
    }
    func world(_ spaces: [[MeadowBlanket]], machines: Int = 1) -> MeadowWorld {
        var list: [MeadowMachine] = []
        for m in 0..<machines {
            let mine = spaces.enumerated().filter { $0.offset % machines == m }
            list.append(MeadowMachine(id: "m\(m)", name: "m\(m)", isLocal: m == 0,
                                      spaces: mine.map { MeadowSpace(id: "s\($0.offset)", name: "s\($0.offset)", blankets: $0.element) }))
        }
        return MeadowWorld(machines: list)
    }
    func village(_ w: MeadowWorld) -> Village {
        let v = Village()
        v.obstacles = Meadow.obstaclesForTests
        v.show(w)
        return v
    }

    @Test func blanketsNeverOverlapEachOtherOrObstacles() {
        let spaces = (0..<5).map { s in (0..<(s % 3 + 1)).map { blanket("s\(s)-b\($0)", cats: ($0 * 7 + s) % 9 + 1, lanterns: $0 % 2) } }
        let v = village(world(spaces))
        let plots = v.plots
        for i in plots.indices {
            for j in plots.indices where j > i {
                let a = plots[i], b = plots[j]
                let d = simd_distance(a.at!, b.at!)
                let gap: Float = a.space == b.space ? 5.5 : 9.5
                #expect(d >= a.radius + b.radius + gap - 1e-3, "\(a.view.id) and \(b.view.id) are \(d) apart")
            }
            for o in Meadow.obstaclesForTests {
                #expect(hypot(plots[i].at!.x - o.x, plots[i].at!.y - o.z) >= plots[i].radius + o.r + 1.5 - 1e-3)
            }
        }
    }

    @Test func catsOnABlanketNeverOverlap() {
        let v = village(world([[blanket("crowd", cats: 20, lanterns: 2)]]))
        let plot = v.plots[0]
        let actors = Array(plot.actors.values)
        for i in actors.indices {
            for j in actors.indices where j > i {
                let a = actors[i], b = actors[j]
                let d = hypot(a.spot.x - b.spot.x, a.spot.z - b.spot.z)
                #expect(d >= 1.35 * a.size + 1.35 * b.size - 0.05, "\(a.view.id) and \(b.view.id) at \(d)")
            }
            // Everyone sits on the cloth.
            #expect(hypot(actors[i].spot.x - plot.center.x, actors[i].spot.z - plot.center.z) + 1.35 * actors[i].size <= plot.size + 1e-3)
        }
    }

    @Test func layoutIsTheSameEveryTime() {
        let w = world([[blanket("a", cats: 3), blanket("b")], [blanket("c", cats: 5, lanterns: 1)]])
        let one = village(w).plots.map { $0.at! }, two = village(w).plots.map { $0.at! }
        #expect(one == two)
    }

    /// Nobody moves when someone new arrives or someone leaves.
    @Test func blanketsKeepTheirPlaces() {
        let v = village(world([[blanket("a", cats: 2)], [blanket("b")], [blanket("c", cats: 4)]]))
        let before = Dictionary(uniqueKeysWithValues: v.plots.map { ($0.view.id, $0.at!) })
        v.show(world([[blanket("a", cats: 2)], [blanket("b")], [blanket("c", cats: 4)], [blanket("d", cats: 3)]]))
        for plot in v.plots where plot.view.id != "d" { #expect(plot.at == before[plot.view.id]) }
        v.show(world([[blanket("a", cats: 2)], [blanket("c", cats: 4)], [blanket("d", cats: 3)]]))
        for plot in v.plots where plot.view.id != "d" { #expect(plot.at == before[plot.view.id]) }
    }

    /// Cats keep their seats when a helper arrives.
    @Test func catsKeepTheirSeats() {
        let v = village(world([[blanket("a", cats: 3)]]))
        let seats = Dictionary(uniqueKeysWithValues: v.plots[0].actors.map { ($0.key, $0.value.spot) })
        v.show(world([[blanket("a", cats: 4)]]))
        for (id, spot) in seats { #expect(v.plots[0].actors[id]!.spot == spot) }
    }

    /// Blankets of one space lie closer to each other than to other spaces' blankets.
    @Test func spacesGather() {
        let v = village(world([[blanket("a1"), blanket("a2"), blanket("a3")], [blanket("b1"), blanket("b2")]]))
        let a = v.plots.filter { $0.space.hasSuffix("s0") }, b = v.plots.filter { $0.space.hasSuffix("s1") }
        func centre(_ p: [Plot]) -> Vec2 { p.reduce(Vec2.zero) { $0 + $1.at! } / Float(p.count) }
        let ca = centre(a), cb = centre(b)
        for p in a { #expect(simd_distance(p.at!, ca) < simd_distance(p.at!, cb)) }
    }

    /// With one machine there is no stream; another machine's blankets lie across one.
    @Test func streamOnlyBetweenMachines() {
        #expect(village(world([[blanket("a")], [blanket("b")]])).streams.isEmpty)
        let v = village(world([[blanket("a")], [blanket("b")], [blanket("c")]], machines: 2))
        #expect(v.streams.count == 1)
        let x = v.streams[0].x
        for plot in v.plots {
            if plot.machine == 0 { #expect(plot.at!.x + plot.radius < x) } else { #expect(plot.at!.x - plot.radius > x) }
        }
    }

    /// A space's mown patch only when it has more than one blanket.
    @Test func mownOnlyForSpacesOfSeveral() {
        let v = village(world([[blanket("a1"), blanket("a2")], [blanket("b")]]))
        var w = WorldUniforms()
        let n = v.clearings(into: &w, eased: false, dt: 0)
        #expect(n == 3)
        for (i, plot) in v.plots.enumerated() {
            #expect((w.clearings[i].w > 0) == plot.space.hasSuffix("s0"))
        }
    }
}
