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
        // A window too narrow for even one tab and the list still shows the selected tab.
        #expect(layout(100, 3, selected: 2).range == 2..<3)
    }
}
