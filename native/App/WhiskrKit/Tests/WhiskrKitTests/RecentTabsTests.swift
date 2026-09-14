import Testing
@testable import WhiskrKit

@Suite("⌃Tab: tabs by how recently they were shown")
struct RecentTabsTests {
    @Test("the tab shown, then the most recent, then those never shown in the row's order")
    func order() {
        let order = RecentTabs.order(["a", "b", "c", "d", "e"], visited: ["c", "x", "a", "c", "b"], shown: "a")
        #expect(order == ["a", "c", "b", "d", "e"])
        #expect(RecentTabs.order(["a", "b"], visited: [], shown: nil) == ["a", "b"])
        #expect(RecentTabs.order([String](), visited: ["a"], shown: "a").isEmpty)
    }

    @Test("steps wrap round both ways")
    func steps() {
        #expect(RecentTabs.step(0, by: 1, count: 3) == 1)
        #expect(RecentTabs.step(2, by: 1, count: 3) == 0)
        #expect(RecentTabs.step(0, by: -1, count: 3) == 2)
        #expect(RecentTabs.step(0, by: -7, count: 3) == 2)
        #expect(RecentTabs.step(0, by: 1, count: 0) == 0)
    }
}
