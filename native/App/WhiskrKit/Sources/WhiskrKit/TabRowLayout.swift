import Foundation

/// Which tabs the tab row shows, and how wide. A tab of one pane is one segment; a tab split into several
/// panes is one segment per pane, joined (as Chrome draws a split view), led by the name you gave it, if
/// any. Every titled segment gets an equal share of the row, up to `maximum`. When even `minimum` each
/// will not fit, tabs of several panes keep only their focused pane's title and show the others as icons
/// (`compact`); when even that will not fit, the row shows as many tabs as fit (a run of neighbours that
/// always holds the selected tab, whole) and a menu of every tab takes `listWidth` at its end. The run
/// moves only when the selected tab would leave it, so choosing a tab already in sight never shifts the row.
public struct TabRowLayout: Equatable, Sendable {
    /// One tab, as the row lays it out.
    public struct Tab: Equatable, Sendable {
        /// Its panes, one segment each (at least one).
        public var panes: Int
        /// The pane with the keyboard: its segment keeps its title in a compact row.
        public var focused: Int
        /// The width of the name leading a tab of several panes that you named; 0 for none.
        public var label: Double

        public init(panes: Int = 1, focused: Int = 0, label: Double = 0) {
            self.panes = max(panes, 1)
            self.focused = min(max(focused, 0), self.panes - 1)
            self.label = max(label, 0)
        }
    }

    /// The first tab shown.
    public var start: Int
    /// How many are shown, from `start`.
    public var count: Int
    /// A titled segment's width (a tab of one pane is one titled segment).
    public var share: Double
    /// Tabs of several panes show only their focused pane's title; their other segments are icons.
    public var compact: Bool
    /// Some tabs are out of sight: the list of every tab is shown.
    public var overflowing: Bool
    /// An icon segment's width (`compact`).
    public var iconWidth: Double

    public var range: Range<Int> { start..<(start + count) }

    /// The widths of a tab's segments, in its panes' order.
    public func segmentWidths(_ tab: Tab) -> [Double] {
        (0..<tab.panes).map { compact && tab.panes > 1 && $0 != tab.focused ? iconWidth : share }
    }

    /// A tab's whole width: its name, if it leads the tab, and its segments.
    public func width(_ tab: Tab) -> Double { tab.label + segmentWidths(tab).reduce(0, +) }

    /// `width`: the room for tabs (and the list, if needed). What is shown always fits it (the sum of the
    /// shown tabs' `width(_:)`, plus `listWidth` while overflowing), except a selected tab that cannot fit
    /// even alone. `selected`: the selected tab's index. `previousStart`: where the run began last time, so
    /// it moves no more than it must.
    public init(width: Double, tabs: [Tab], selected: Int, previousStart: Int, minimum: Double, maximum: Double, iconWidth: Double, listWidth: Double) {
        let n = tabs.count
        guard n > 0, width > 0 else {
            self.init(start: 0, count: 0, share: 0, compact: false, overflowing: false, iconWidth: iconWidth)
            return
        }
        let labels = tabs.reduce(0) { $0 + $1.label }
        let segments = tabs.reduce(0) { $0 + $1.panes }
        let icons = Double(segments - n) * iconWidth
        // Every segment titled, at `minimum` or more: everything in sight. A single tab of one pane is never
        // out of sight: a row narrower than it narrows it rather than run past its end.
        if Double(segments) * minimum + labels <= width || segments == 1 {
            let share = min(maximum, ((width - labels) / Double(segments)).rounded(.down))
            self.init(start: 0, count: n, share: share, compact: false, overflowing: false, iconWidth: iconWidth)
            return
        }
        // Only each tab's focused pane titled: still everything in sight. One tab alone takes the row.
        if Double(n) * minimum + icons + labels <= width || n == 1 {
            let share = max(0, min(maximum, ((width - icons - labels) / Double(n)).rounded(.down)))
            self.init(start: 0, count: n, share: share, compact: true, overflowing: false, iconWidth: iconWidth)
            return
        }
        // Some are out of sight: as many as fit beside the list, compact, and always the selected one,
        // narrowed if even it has not the room.
        let room = max(width - listWidth, 0)
        let needed = tabs.map { $0.label + minimum + Double($0.panes - 1) * iconWidth }
        func fits(_ from: Int, _ to: Int) -> Bool { needed[from..<to].reduce(0, +) <= room }
        let selected = min(max(selected, 0), n - 1)
        var start = min(max(previousStart, 0), n - 1)
        if selected < start { start = selected }
        var end = start + 1
        while end < n, fits(start, end + 1) { end += 1 }
        if selected >= end {
            // The run ends at the selected tab, reaching back as far as it fits.
            start = selected
            end = selected + 1
        }
        // Then as far back and on as there is room (the run ends with the last tab once tabs close).
        while start > 0, fits(start - 1, end) { start -= 1 }
        while end < n, fits(start, end + 1) { end += 1 }
        let shown = tabs[start..<end]
        let shownIcons = Double(shown.reduce(0) { $0 + $1.panes - 1 }) * iconWidth
        let shownLabels = shown.reduce(0) { $0 + $1.label }
        let share = max(0, min(maximum, ((room - shownIcons - shownLabels) / Double(shown.count)).rounded(.down)))
        self.init(start: start, count: end - start, share: share, compact: true, overflowing: true, iconWidth: iconWidth)
    }

    public init(start: Int, count: Int, share: Double, compact: Bool, overflowing: Bool, iconWidth: Double) {
        self.start = start
        self.count = count
        self.share = share
        self.compact = compact
        self.overflowing = overflowing
        self.iconWidth = iconWidth
    }
}
