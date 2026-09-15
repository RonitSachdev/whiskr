import Testing
@testable import WhiskrKit

@Suite("Tab row")
struct TabRowLayoutTests {
    private func layout(_ width: Double, _ tabs: [TabRowLayout.Tab], selected: Int, previous: Int = 0) -> TabRowLayout {
        TabRowLayout(width: width, tabs: tabs, selected: selected, previousStart: previous, minimum: 128, maximum: 220, iconWidth: 36, listWidth: 32)
    }

    /// Tabs of one pane each.
    private func layout(_ width: Double, _ tabs: Int, selected: Int, previous: Int = 0) -> TabRowLayout {
        layout(width, Array(repeating: TabRowLayout.Tab(), count: tabs), selected: selected, previous: previous)
    }

    private func row(_ start: Int, _ count: Int, _ share: Double, compact: Bool = false, overflowing: Bool) -> TabRowLayout {
        TabRowLayout(start: start, count: count, share: share, compact: compact, overflowing: overflowing, iconWidth: 36)
    }

    @Test("tabs that fit share the row, up to their widest")
    func fitting() {
        #expect(layout(800, 2, selected: 0) == row(0, 2, 220, overflowing: false))
        #expect(layout(800, 5, selected: 4) == row(0, 5, 160, overflowing: false))
        #expect(layout(800, 0, selected: 0).count == 0)
    }

    @Test("too many: as many as fit, always holding the selected tab whole, moving only as far as it must")
    func overflowing() {
        // 800 − 32 for the list leaves room for 6 tabs of 128.
        let last = layout(800, 10, selected: 9)
        #expect(last == row(4, 6, 128, compact: true, overflowing: true))
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
        #expect(layout(100, 3, selected: 2) == row(2, 1, 68, compact: true, overflowing: true))
        // One tab is never "out of sight": it takes the row, however narrow.
        #expect(layout(100, 1, selected: 0) == row(0, 1, 100, overflowing: false))
        #expect(layout(150, 1, selected: 0).overflowing == false)
        // Just under two tabs' worth: one, as wide as tabs go, and the list.
        #expect(layout(255, 2, selected: 1) == row(1, 1, 220, compact: true, overflowing: true))
    }

    @Test("a split tab is one segment per pane, each titled while there is room, as wide as a tab")
    func splitTabs() {
        let split = TabRowLayout.Tab(panes: 2, focused: 1)
        let wide = layout(1000, [TabRowLayout.Tab(), split], selected: 1)
        #expect(wide == row(0, 2, 220, overflowing: false))
        #expect(wide.segmentWidths(split) == [220, 220])
        #expect(wide.width(split) == 440)
        // Three titled segments at 128 need 384: in 380 the split tab keeps only its focused pane's title,
        // and its other pane is an icon, before anything goes out of sight.
        let tight = layout(380, [TabRowLayout.Tab(), split], selected: 0)
        #expect(tight.compact && !tight.overflowing && tight.count == 2)
        #expect(tight.segmentWidths(split) == [36, tight.share])
        #expect(tight.segmentWidths(TabRowLayout.Tab()) == [tight.share])
        #expect(tight.share == 172)
        // Tighter still: tabs go out of sight, the split tab staying compact.
        let full = layout(380, [TabRowLayout.Tab(), TabRowLayout.Tab(), split], selected: 2)
        #expect(full.overflowing && full.range.contains(2) && full.compact)
        #expect(full.segmentWidths(split).first == 36)
    }

    @Test("a name you gave a split tab leads it, and takes its room in the row")
    func namedSplit() {
        let named = TabRowLayout.Tab(panes: 2, label: 60)
        let wide = layout(1000, [named], selected: 0)
        #expect(wide.width(named) == 60 + 2 * wide.share)
        let tight = layout(300, [named], selected: 0)
        #expect(tight.width(named) <= 300)
    }

    @Test("whatever the room, what is shown fits in it, holds the selected tab, and lists tabs only when some are out of sight")
    func fitsTheRoom() {
        let kinds = [TabRowLayout.Tab(), TabRowLayout.Tab(panes: 2), TabRowLayout.Tab(panes: 3, focused: 2), TabRowLayout.Tab(panes: 2, label: 40)]
        for width in stride(from: 32.0, through: 1200, by: 7) {
            for count in 1...14 {
                for mix in 0..<kinds.count {
                    let tabs = (0..<count).map { mix == 0 ? TabRowLayout.Tab() : kinds[($0 + mix) % kinds.count] }
                    for selected in [0, count / 2, count - 1] {
                        let row = layout(width, tabs, selected: selected, previous: count / 3)
                        let used = tabs[row.range].reduce(0) { $0 + row.width($1) } + (row.overflowing ? 32 : 0)
                        // Only a selected tab that cannot fit even alone may run past the room.
                        let alone = row.count == 1 && tabs[selected].label + Double(tabs[selected].panes - 1) * 36 > width - 32
                        #expect(used <= width || alone, "\(width) pt, \(count) tabs, mix \(mix)")
                        #expect(row.range.contains(selected))
                        #expect(row.range.lowerBound >= 0 && row.range.upperBound <= count)
                        #expect(row.overflowing == (row.count < count))
                        // Nothing goes out of sight while compacting the split tabs would make them fit.
                        if row.overflowing { #expect(row.compact) }
                    }
                }
            }
        }
    }
}
