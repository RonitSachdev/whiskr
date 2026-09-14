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
        layout.toggleNavigator(window: 1440)
        #expect(layout.mode == .terminalsOnly)
        layout.toggleNavigator(window: 1440)
        #expect(layout == WindowLayout())
        // Meadow Only: hiding the meadow leaves the terminals.
        layout = WindowLayout(mode: .meadowOnly)
        layout.toggleNavigator(window: 1440)
        #expect(layout.frame(window: 1440) == .init(navigator: 0, showsTerminals: true))
    }

    @Test("the meadow button shows and hides the meadow at every width the window can have, and says what is on screen",
          arguments: [720.0, 800, 880, 1440])
    func toggleAtEveryWidth(width: Double) {
        let usual = WindowLayout().frame(window: width)
        var layout = WindowLayout()
        #expect(layout.showsNavigator(window: width) == (usual.navigator > 0))
        // Hidden for lack of room, the first press shows it; otherwise the first hides it and the second
        // brings it back.
        if !layout.showsNavigator(window: width) {
            layout.toggleNavigator(window: width)
        } else {
            layout.toggleNavigator(window: width)
            #expect(!layout.showsNavigator(window: width))
            #expect(layout.frame(window: width).showsTerminals)
            layout.toggleNavigator(window: width)
        }
        let shown = layout.frame(window: width)
        #expect(layout.showsNavigator(window: width))
        #expect(shown.showsTerminals)
        #expect(shown.navigator >= WindowLayout.navigatorMinimum)
        // The terminals never go under their least.
        #expect(width - shown.navigator >= WindowLayout.terminalMinimum)
        // Where there was room, it came back as it was.
        if usual.navigator > 0 { #expect(shown == usual) }
        layout.toggleNavigator(window: width)
        #expect(!layout.showsNavigator(window: width))
        #expect(layout.frame(window: width).showsTerminals)
    }

    @Test("under 880 pt the meadow asked for takes its narrowest sidebar, kept as the window grows; Reset Layout gives the default again")
    func narrowWindow() {
        var layout = WindowLayout()
        #expect(layout.frame(window: 720).navigator == 0)
        layout.showNavigator(window: 720)
        #expect(layout.frame(window: 720) == .init(navigator: WindowLayout.navigatorMinimum, showsTerminals: true))
        #expect(layout.frame(window: 1440).navigator == WindowLayout.navigatorMinimum)
        // From Terminals Only too.
        var hidden = WindowLayout(mode: .terminalsOnly)
        hidden.showNavigator(window: 800)
        #expect(hidden.frame(window: 800) == .init(navigator: WindowLayout.navigatorMinimum, showsTerminals: true))
        // Already shown: nothing changes.
        var wide = WindowLayout()
        wide.showNavigator(window: 1440)
        #expect(wide == WindowLayout())
        layout.reset()
        #expect(layout.frame(window: 720).navigator == 0)
        // Narrower than the app allows: the meadow alone, rather than not at all.
        var tiny = WindowLayout()
        tiny.showNavigator(window: 500)
        #expect(tiny.frame(window: 500) == .init(navigator: 500, showsTerminals: false))
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

    @Test("the status bar can be hidden and is remembered; Reset Layout brings every region back but keeps the list form")
    func statusBarAndReset() {
        var layout = WindowLayout(navigator: .list, mode: .terminalsOnly, navigatorWidth: 500, showsStatusBar: false)
        #expect(WindowLayout(data: layout.data) == layout)
        // A file saved before the status bar could hide shows it.
        #expect(WindowLayout(data: Data(#"{"navigator":"meadow","mode":"split"}"#.utf8)).showsStatusBar)
        layout.reset()
        #expect(layout == WindowLayout(navigator: .list))
        #expect(layout.showsStatusBar)
    }
}
