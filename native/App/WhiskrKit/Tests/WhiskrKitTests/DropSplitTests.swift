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
