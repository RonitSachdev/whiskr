import Foundation

/// Which tabs the tab row shows, and how wide. Tabs share the row equally up to `maximum` each; when even
/// `minimum` each will not fit them all, the row shows as many as fit (a run of neighbours that always
/// holds the selected tab, whole) and a menu of every tab takes `listWidth` at its end. The run moves only
/// when the selected tab would leave it, so choosing a tab already in sight never shifts the row.
public struct TabRowLayout: Equatable, Sendable {
    /// The first tab shown.
    public var start: Int
    /// How many are shown, from `start`.
    public var count: Int
    public var tabWidth: Double
    /// Some tabs are out of sight: the list of every tab is shown.
    public var overflowing: Bool

    public var range: Range<Int> { start..<(start + count) }

    /// `width`: the room for tabs (and the list, if needed). `selected`: the selected tab's index.
    /// `previousStart`: where the run began last time, so it moves no more than it must.
    public init(width: Double, tabs: Int, selected: Int, previousStart: Int, minimum: Double, maximum: Double, listWidth: Double) {
        guard tabs > 0, width > 0 else {
            self.init(start: 0, count: 0, tabWidth: 0, overflowing: false)
            return
        }
        if Double(tabs) * minimum <= width {
            self.init(start: 0, count: tabs, tabWidth: min(maximum, (width / Double(tabs)).rounded(.down)), overflowing: false)
            return
        }
        let room = max(width - listWidth, minimum)
        let fit = max(1, min(tabs, Int(room / minimum)))
        let selected = min(max(selected, 0), tabs - 1)
        var start = min(max(previousStart, 0), tabs - fit)
        if selected < start { start = selected }
        if selected >= start + fit { start = selected - fit + 1 }
        self.init(start: start, count: fit, tabWidth: min(maximum, (room / Double(fit)).rounded(.down)), overflowing: true)
    }

    public init(start: Int, count: Int, tabWidth: Double, overflowing: Bool) {
        self.start = start
        self.count = count
        self.tabWidth = tabWidth
        self.overflowing = overflowing
    }
}
