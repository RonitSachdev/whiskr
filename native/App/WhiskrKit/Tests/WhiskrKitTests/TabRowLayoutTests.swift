import Testing
@testable import WhiskrKit

@Suite("Tab row")
struct TabRowLayoutTests {
    private func layout(_ width: Double, _ tabs: Int, selected: Int, previous: Int = 0) -> TabRowLayout {
        TabRowLayout(width: width, tabs: tabs, selected: selected, previousStart: previous, minimum: 128, maximum: 220, listWidth: 32)
    }

    @Test("tabs that fit share the row, up to their widest")
    func fitting() {
        #expect(layout(800, 2, selected: 0) == TabRowLayout(start: 0, count: 2, tabWidth: 220, overflowing: false))
        #expect(layout(800, 5, selected: 4) == TabRowLayout(start: 0, count: 5, tabWidth: 160, overflowing: false))
        #expect(layout(800, 0, selected: 0).count == 0)
    }

    @Test("too many: as many as fit, always holding the selected tab whole, moving only as far as it must")
    func overflowing() {
        // 800 − 32 for the list leaves room for 6 tabs of 128.
        let last = layout(800, 10, selected: 9)
        #expect(last == TabRowLayout(start: 4, count: 6, tabWidth: 128, overflowing: true))
        #expect(last.range.contains(9))
        // Choosing one already in sight keeps the run where it was.
        #expect(layout(800, 10, selected: 5, previous: 4).start == 4)
        // Choosing one before the run brings the run to it.
        #expect(layout(800, 10, selected: 1, previous: 4).start == 1)
        // A tab closing leaves the run inside the tabs there are.
        #expect(layout(800, 7, selected: 6, previous: 4).range == 1..<7)
    }

    @Test("a row narrower than one tab narrows the selected tab to fit beside the list, and one tab alone gets no list")
    func narrow() {
        // 100 pt for 3 tabs: the selected one, narrowed to what the list leaves.
        #expect(layout(100, 3, selected: 2) == TabRowLayout(start: 2, count: 1, tabWidth: 68, overflowing: true))
        // One tab is never "out of sight": it takes the row, however narrow.
        #expect(layout(100, 1, selected: 0) == TabRowLayout(start: 0, count: 1, tabWidth: 100, overflowing: false))
        #expect(layout(150, 1, selected: 0).overflowing == false)
        // Just under two tabs' worth: one, as wide as tabs go, and the list.
        #expect(layout(255, 2, selected: 1) == TabRowLayout(start: 1, count: 1, tabWidth: 220, overflowing: true))
    }

    @Test("whatever the room, what is shown fits in it, holds the selected tab, and lists tabs only when some are out of sight")
    func fitsTheRoom() {
        for width in stride(from: 32.0, through: 1200, by: 7) {
            for tabs in 1...14 {
                for selected in [0, tabs / 2, tabs - 1] {
                    let row = layout(width, tabs, selected: selected, previous: tabs / 3)
                    let used = Double(row.count) * row.tabWidth + (row.overflowing ? 32 : 0)
                    #expect(used <= width, "\(width) pt, \(tabs) tabs")
                    #expect(row.range.contains(selected))
                    #expect(row.range.lowerBound >= 0 && row.range.upperBound <= tabs)
                    #expect(row.overflowing == (row.count < tabs))
                }
            }
        }
    }
}
