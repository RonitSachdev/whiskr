import Foundation
import Testing
@testable import WhiskrKit

@Suite("The window's layout")
struct WindowLayoutTests {
    @Test("by default the meadow takes 42 % of the window (380 to 780) and the terminals keep 90 columns")
    func defaults() {
        let layout = WindowLayout()
        #expect(layout.frame(window: 1440) == .init(navigator: 1440 * 0.42, showsTerminals: true))
        #expect(layout.frame(window: 2400).navigator == 780)
        #expect(layout.frame(window: 1280).navigator == 1280 * 0.42)
        // 1200: 42 % would leave the terminals under 90 columns (718 pt), so the meadow gets the rest.
        #expect(layout.frame(window: 1200).navigator == 1200 - WindowLayout.terminalComfort)
        // Short of room: a 300 pt sidebar beside 80 columns, then narrower, down to 240.
        #expect(layout.frame(window: 1000).navigator == WindowLayout.sidebarForm)
        #expect(layout.frame(window: 900).navigator == 900 - WindowLayout.terminalCompact)
        #expect(layout.frame(window: 880).navigator == WindowLayout.navigatorMinimum)
        // Too narrow for both: the meadow steps aside.
        #expect(layout.frame(window: 870) == .init(navigator: 0, showsTerminals: true))
    }

    @Test("the three forms: meadow and terminals, terminals only, meadow only")
    func forms() {
        #expect(WindowLayout(mode: .terminalsOnly).frame(window: 1440) == .init(navigator: 0, showsTerminals: true))
        #expect(WindowLayout(mode: .meadowOnly).frame(window: 1440) == .init(navigator: 1440, showsTerminals: false))
        var layout = WindowLayout()
        layout.toggleNavigator()
        #expect(layout.mode == .terminalsOnly)
        layout.toggleNavigator()
        #expect(layout.mode == .split)
    }

    @Test("the divider drags from a 240 pt sidebar up to the meadow alone; its width is kept; double-click restores the default")
    func dragging() {
        var layout = WindowLayout()
        layout.dragDivider(to: 260, window: 1440)
        #expect(layout.frame(window: 1440).navigator == 260)
        layout.dragDivider(to: 200, window: 1440)
        #expect(layout.frame(window: 1440).navigator == WindowLayout.navigatorMinimum)
        layout.dragDivider(to: 1000, window: 1440)
        #expect(layout.frame(window: 1440).navigator == 1000)
        // Kept as the window grows; giving way to the terminals' minimum as it shrinks.
        #expect(layout.frame(window: 1800).navigator == 1000)
        #expect(layout.frame(window: 1100).navigator == 1100 - WindowLayout.terminalMinimum)
        layout.dragDivider(to: 1400, window: 1440)
        #expect(layout.mode == .meadowOnly)
        layout.dragDivider(to: 40, window: 1440)
        #expect(layout.mode == .terminalsOnly)
        layout.resetSplit()
        #expect(layout == WindowLayout())
    }

    @Test("saved and read back; unknown or broken values keep their defaults")
    func saving() {
        let layout = WindowLayout(navigator: .list, mode: .meadowOnly, navigatorWidth: 610)
        #expect(WindowLayout(data: layout.data) == layout)
        #expect(WindowLayout(data: Data(#"{"navigator":"rail","navigatorWidth":-3,"mode":"panel"}"#.utf8)) == WindowLayout())
        // What earlier windows saved reads as the default.
        #expect(WindowLayout(data: Data(#"{"style":"meadow","panel":"open","panelWidth":560,"listOpen":true}"#.utf8)) == WindowLayout())
        #expect(WindowLayout(data: nil) == WindowLayout())
    }
}
