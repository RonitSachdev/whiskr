import AppKit
import Foundation
import Testing
import simd
@testable import MeadowScene

// How the app's meadow is framed, from the narrow sidebar to the meadow alone: workspaces that fit are
// centred with room to spare at every edge; more than fit start a little below the top edge and scroll.
// The framing follows the workspaces and the view, never what the cats are doing.

@MainActor
@Suite(.serialized) struct Framing {
    nonisolated static let shapes: [NSSize] = [NSSize(width: 240, height: 820), NSSize(width: 300, height: 820), NSSize(width: 605, height: 900),
                                               NSSize(width: 900, height: 820), NSSize(width: 1000, height: 600), NSSize(width: 1440, height: 900)]

    /// Every blanket with its flag, in the view's own coordinates.
    static func boxes(_ view: MeadowView, _ count: Int) -> [CGRect] {
        (0..<count).compactMap { view.screenRect(of: .blanket("w\($0)")) }
    }

    @Test("workspaces that fit are centred, with room at every edge; more start at the top and scroll",
          arguments: shapes, [1, 2, 3, 5, 12])
    func framed(_ size: NSSize, _ count: Int) {
        // One workspace busy with helpers, so its blanket is the widest (and, low in a column, the nearest).
        var world = Sidebar.world(count)
        let busy = min(3, count - 1), boss = world.machines[0].spaces[busy].blankets[0].agents[0].id
        world.machines[0].spaces[busy].blankets[0].agents += (1...3).map { MeadowAgent(id: "h\($0)", parentID: boss, activity: .reading) }
        let view = Sidebar.view(size, world, after: 4)
        let out = view.blanketsOutOfView
        let boxes = Self.boxes(view, count)
        let fits = out.above.isEmpty && out.below.isEmpty
        // One, two or three always fit, whatever the shape; twelve do in a wide meadow.
        if count <= 3 || (count == 12 && size.width >= 1440) { #expect(fits, "\(count) at \(size) should all be in view: out \(out)") }
        guard let first = boxes.first else { Issue.record("nothing laid out"); return }
        let all = boxes.dropFirst().reduce(first) { $0.union($1) }
        // Whatever is in view keeps clear of the sides, near the bottom (and the camera) as at the top.
        let margin: CGFloat = 8
        for box in boxes where box.minY >= 0 && box.maxY <= size.height {
            #expect(box.minX >= margin - 1 && box.maxX <= size.width - margin + 1, "\(count) at \(size): \(box) reaches the sides")
        }
        if fits {
            #expect(boxes.count == count)
            #expect(all.minY >= margin && all.maxY <= size.height - margin, "\(count) at \(size): \(all) reaches the top or bottom")
            // The middle of everything near the middle of the view.
            #expect(abs(all.midY - size.height / 2) < size.height * 0.05, "\(count) at \(size): middle \(all.midY) of \(size.height)")
            #expect(abs(all.midX - size.width / 2) < size.width * 0.08, "\(count) at \(size): middle \(all.midX) of \(size.width)")
        } else {
            // Too many for one glance: the first row's flags just below the top, the rest further down.
            #expect(out.above.isEmpty, "\(count) at \(size): something is above the top")
            let top = size.height - all.maxY
            #expect(abs(top - CGFloat(Stage.columnTopMargin)) < 4, "\(count) at \(size): first row \(top) pt from the top")
        }
    }

    @Test("helpers coming and going never move the camera", arguments: [NSSize(width: 300, height: 820), NSSize(width: 605, height: 900)])
    func agentsDoNotReframe(_ size: NSSize) {
        var world = Sidebar.world(2)
        let view = Sidebar.view(size, world, after: 6)
        let before = view.stage.camera.view
        world.machines[0].spaces[0].blankets[0].agents += (1...4).map { MeadowAgent(id: "h\($0)", parentID: "c", activity: .reading) }
        view.world = world
        view.advance(seconds: 3)
        let after = view.stage.camera.view
        #expect(abs(after.x - before.x) < 0.01 && abs(after.z - before.z) < 0.01 && abs(after.distance - before.distance) < 0.01,
                "\(before) became \(after)")
    }

    @Test("a workspace joining reframes, gliding there")
    func workspacesReframe() {
        let view = Sidebar.view(NSSize(width: 605, height: 900), Sidebar.world(1), after: 4)
        let before = view.stage.camera.view
        view.world = Sidebar.world(3)
        view.advance(seconds: 0.2)
        let gliding = view.stage.camera.view
        view.advance(seconds: 4)
        let after = view.stage.camera.view
        #expect(after.distance > before.distance + 1, "three workspaces are framed from further back")
        #expect(gliding.distance > before.distance && gliding.distance < after.distance, "it glides there, not jumps")
    }
}
