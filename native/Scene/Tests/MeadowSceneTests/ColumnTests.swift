import AppKit
import Foundation
import Testing
import simd
@testable import MeadowScene

// The app's meadow: one blanket per workspace, in the user's order. A sidebar holds them in one column;
// a wider meadow spreads the same order into rows, read top to bottom, then left to right. The order
// never reshuffles by itself, and a new workspace only ever joins at the end.

@MainActor
@Suite(.serialized) struct ColumnArrangement {
    func world(_ count: Int) -> MeadowWorld {
        MeadowWorld(machines: [MeadowMachine(id: "m", name: "m", spaces: (0..<count).map { i in
            MeadowSpace(id: "w\(i)", name: "w\(i)", blankets: [
                MeadowBlanket(id: "w\(i)", title: "workspace \(i)", color: .account(i),
                              agents: i % 2 == 0 ? [MeadowAgent(id: "c", activity: .reading)] : []),
            ])
        })])
    }

    func view(_ size: NSSize, count: Int) -> MeadowView {
        let view = MeadowView(frame: NSRect(origin: .zero, size: size), mode: .meadow)
        view.settings = MeadowSettings(arrangement: .column, timeOfDay: .day, picnic: .hamper)
        view.world = world(count)
        view.advance(seconds: 1)
        return view
    }

    @Test("a sidebar holds one column; a wide meadow, rows")
    func rowsFollowWidth() {
        #expect(view(NSSize(width: 300, height: 820), count: 5).stage.village!.perRow == 1)
        #expect(view(NSSize(width: 605, height: 860), count: 5).stage.village!.perRow == 2)
        #expect(view(NSSize(width: 1440, height: 860), count: 5).stage.village!.perRow == 4)
    }

    @Test("read top to bottom, then left to right, with grass between every pair", arguments: [NSSize(width: 300, height: 820), NSSize(width: 1440, height: 860)])
    func readingOrder(_ size: NSSize) {
        let village = view(size, count: 7).stage.village!
        let plots = village.plots
        let perRow = village.perRow
        for (i, plot) in plots.enumerated() {
            guard i + 1 < plots.count, let a = plot.at, let b = plots[i + 1].at else { continue }
            if (i + 1) % perRow == 0 {
                // A new row starts further down.
                #expect(b.y > a.y + 1, "row break after \(i)")
            } else {
                #expect(b.x > a.x, "left to right within a row at \(i)")
            }
        }
        for (i, p) in plots.enumerated() {
            for q in plots[(i + 1)...] {
                guard let a = p.at, let b = q.at else { continue }
                #expect(simd_distance(a, b) > (p.radius + q.radius) * 0.75, "\(p.view.id) and \(q.view.id) overlap")
            }
        }
    }

    @Test("a new workspace joins at the end and nobody moves")
    func stable() {
        let view = view(NSSize(width: 1440, height: 860), count: 5)
        let before = view.stage.village!.plots.map(\.at)
        view.world = world(6)
        view.advance(seconds: 0.5)
        #expect(Array(view.stage.village!.plots.prefix(5).map(\.at)) == before)
    }
}
