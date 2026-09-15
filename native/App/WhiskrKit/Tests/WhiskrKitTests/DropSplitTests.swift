import CoreGraphics
import Foundation
import Testing
@testable import WhiskrKit

@Suite("A tab dropped on a pane's edge splits it")
struct DropSplitTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test("the outer tenth of each side, the nearest side in a corner, the middle elsewhere")
    func sides() {
        let frame = CGRect(x: 100, y: 0, width: 400, height: 200)
        #expect(PaneTree.dropSide(at: CGPoint(x: 490, y: 100), in: frame) == .right)
        #expect(PaneTree.dropSide(at: CGPoint(x: 110, y: 100), in: frame) == .left)
        #expect(PaneTree.dropSide(at: CGPoint(x: 300, y: 5), in: frame) == .up)
        #expect(PaneTree.dropSide(at: CGPoint(x: 300, y: 195), in: frame) == .down)
        #expect(PaneTree.dropSide(at: CGPoint(x: 300, y: 100), in: frame) == nil)
        // 39 pt from the left of 400 (9.75 %) but 3 pt from the top of 200 (1.5 %): the top.
        #expect(PaneTree.dropSide(at: CGPoint(x: 139, y: 3), in: frame) == .up)
        #expect(PaneTree.dropSide(at: .zero, in: .zero) == nil)
    }

    @Test("under a moving pointer the zone holds a little past its boundary, so its preview never flickers")
    func steady() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        // 45 pt from the right (11 %): the middle when coming fresh or from the middle, still the right side
        // when it was there (under 15 %), and the middle once past that.
        let near = CGPoint(x: 355, y: 100)
        #expect(PaneTree.dropSide(at: near, in: frame, after: nil) == nil)
        #expect(PaneTree.dropSide(at: near, in: frame, after: .middle) == nil)
        #expect(PaneTree.dropSide(at: near, in: frame, after: .side(.right)) == .right)
        #expect(PaneTree.dropSide(at: CGPoint(x: 330, y: 100), in: frame, after: .side(.right)) == nil)
        // From the middle, a side only once well inside its tenth (under 8 %).
        #expect(PaneTree.dropSide(at: CGPoint(x: 365, y: 100), in: frame, after: .middle) == nil)
        #expect(PaneTree.dropSide(at: CGPoint(x: 370, y: 100), in: frame, after: .middle) == .right)
        // Along a boundary, back and forth by a point, the answer stays.
        var zone: PaneTree.DropZone? = nil
        var answers: [PaneTree.Direction?] = []
        for x in [359.0, 361, 359, 361, 359, 361, 341, 339, 341, 339] {
            let side = PaneTree.dropSide(at: CGPoint(x: x, y: 100), in: frame, after: zone)
            answers.append(side)
            zone = side.map { .side($0) } ?? .middle
        }
        let switches = zip(answers, answers.dropFirst()).filter { $0 != $1 }.count
        #expect(switches <= 1, "\(answers)")
    }

    @Test("a closed pane brought back goes where it was, keeping what came since")
    func restoring() {
        let before = PaneTree.pane(a).splitting(a, axis: .horizontal, new: b)
        let after = before.removing(b)!
        // Nothing changed meanwhile: exactly as it was.
        #expect(after.restoring(b, as: before) == before)
        // A pane added since (c below a): b comes back to a's right, and c stays.
        let changed = after.splitting(a, axis: .vertical, new: c)
        let back = changed.restoring(b, as: before)
        #expect(Set(back.panes) == [a, b, c])
        #expect(back.neighbor(of: a, toward: .right) == b)
        // Already there: unchanged.
        #expect(before.restoring(b, as: before) == before)
        // Nothing of its old place left: still put back, beside what is there.
        #expect(PaneTree.pane(c).restoring(b, as: before).panes == [c, b])
        // Split from a group that has gone: beside a pane it had beside it, wherever that is now.
        let three = PaneTree.pane(a).splitting(a, axis: .horizontal, new: b).splitting(b, axis: .horizontal, new: c)
        let d = UUID()
        let now = PaneTree.pane(a).splitting(a, axis: .vertical, new: d)
        #expect(Set(now.restoring(b, as: three).panes) == [a, b, d])
    }

    @Test("the preview is the half the tab will take")
    func preview() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        #expect(PaneTree.dropPreview(.right, in: frame) == CGRect(x: 200, y: 0, width: 200, height: 200))
        #expect(PaneTree.dropPreview(.up, in: frame) == CGRect(x: 0, y: 0, width: 400, height: 100))
        #expect(PaneTree.dropPreview(nil, in: frame) == frame)
    }

    @Test("another tab's panes go beside the pane, whole, on the side dropped")
    func inserts() {
        let tree = PaneTree.split(.init(axis: .horizontal, ratio: 0.3, first: .pane(a), second: .pane(b)))
        let moved = PaneTree.pane(c)
        let right = tree.inserting(moved, beside: b, on: .right)
        #expect(right.panes == [a, b, c])
        let up = tree.inserting(moved, beside: a, on: .up)
        guard case .split(let outer) = up, case .split(let inner) = outer.first else { Issue.record("not split"); return }
        #expect(outer.ratio == 0.3)
        #expect(inner.axis == .vertical)
        #expect(inner.first == moved)
        // A whole split moves as it is.
        let pair = PaneTree.split(.init(axis: .vertical, ratio: 0.5, first: .pane(UUID()), second: .pane(UUID())))
        #expect(PaneTree.pane(a).inserting(pair, beside: a, on: .left).panes == pair.panes + [a])
        #expect(PaneTree.pane(a).inserting(pair, beside: b, on: .left) == .pane(a))
    }
}
