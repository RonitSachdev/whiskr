#if DEBUG
import AppKit
import WhiskrKit

/// `--perf-flows home` (`make perf`'s checks): New Workspace from every place it is offered, on Home with no
/// workspace and with some open, must visibly do something: a workspace made and shown, its terminal with
/// the keyboard (on Home, ⌘N once did nothing at all). From a workspace, it shows Home with New Terminal
/// ready for Return. Open Folder… asks for the folder chooser from each place.
extension PerfSuite {
    func homeEntryCheck() async {
        ActionStandIn.install()
        // Actions sent to no one in particular reach the window's controller, as in front of a person.
        KeyWindowStandIn.install()
        let openFolder = #selector(MainWindowController.openFolder(_:))
        ActionStandIn.swallowing.insert(openFolder)
        defer { ActionStandIn.swallowing.remove(openFolder) }
        // From a workspace: Home, with New Terminal ready, and Return makes the workspace. First: Home's Return
        // is SwiftUI's, and once the command palette has been used it no longer reaches Home in this run
        // (in the old version too; on a screen, not seen).
        await homeWith(workspaces: 1)
        if let workspace = workbench.workspaces.first { workbench.select(workspace: workspace) }
        _ = await PerfWait.until(1500) { !self.workbench.isHome }
        shortcut("cmd+n")
        let home = await PerfWait.until(1500) { self.workbench.isHome && self.window.firstResponder === self.controller.terminals.home }
        check("home: from a workspace, ⌘N shows Home with the keyboard on it", home != nil, "home \(workbench.isHome), first responder \(responderText(window.firstResponder))")
        let before = workbench.workspaces.count
        await PerfWait.sleep(800)
        typeKeys("\r")
        check("home: …and Return there makes the new workspace, its terminal with the keyboard",
              await PerfWait.until(3000) { self.workbench.workspaces.count == before + 1 && self.workbench.focusedPane.map(self.focused) == true } != nil)
        let newWorkspace = String(localized: "New Workspace")
        let ways: [(String, () async -> Void)] = [
            ("Home's New Terminal (Return)", {
                self.controller.terminals.focusHome()
                await PerfWait.sleep(800)
                self.typeKeys("\r")
            }),
            ("⌘N", { self.shortcut("cmd+n") }),
            ("File › New Workspace", { self.mainMenuItem(#selector(MainWindowController.newWorkspace(_:))) }),
            ("the top bar's +", { await self.barMenuItem("bar.new", title: newWorkspace) }),
            ("the Home button's menu", { await self.barMenuItem("bar.place-home", title: newWorkspace) }),
        ]
        let palette: (String, () async -> Void) = ("the command palette", {
                self.controller.palette?.show(.commands, query: newWorkspace)
                await PerfWait.sleep(200)
                if self.controller.palette?.debugChoose(title: newWorkspace) != true { print("home: the palette has no “\(newWorkspace)”") }
            })
        func attempt(_ name: String, some: Bool, _ act: () async -> Void) async {
            await homeWith(workspaces: some ? 1 : 0)
            let before = workbench.workspaces.count
            await act()
            let made = await PerfWait.until(3000) {
                self.workbench.workspaces.count == before + 1 && !self.workbench.isHome && self.workbench.focusedPane.map(self.focused) == true
            }
            check("home: on Home with \(some ? "a workspace open" : "no workspace"), New Workspace from \(name) makes one and shows it, its terminal with the keyboard",
                  made != nil, "workspaces \(before) → \(workbench.workspaces.count), home \(workbench.isHome), first responder \(responderText(window.firstResponder))")
            if let pane = workbench.focusedPane { _ = await shellReady(pane, timeout: 4000) }
        }
        for some in [false, true] {
            for (name, act) in ways { await attempt(name, some: some, act) }
            // Open Folder… asks for the chooser, from each place.
            for (name, act) in [("⌘O", { self.shortcut("cmd+o") }),
                                ("the top bar's +", { await self.barMenuItem("bar.new", title: String(localized: "Open Folder…")) }),
                                ("the Home button's menu", { await self.barMenuItem("bar.place-home", title: String(localized: "Open Folder…")) })] as [(String, () async -> Void)] {
                await homeWith(workspaces: some ? 1 : 0)
                ActionStandIn.sent = []
                await act()
                check("home: on Home with \(some ? "a workspace open" : "no workspace"), Open Folder… from \(name) asks for the folder chooser",
                      ActionStandIn.sent.contains(openFolder), "sent \(ActionStandIn.sent.map(NSStringFromSelector))")
            }
        }
        // The palette last (see above).
        for some in [false, true] { await attempt(palette.0, some: some, palette.1) }
    }

    /// Home, with exactly `count` workspaces open.
    private func homeWith(workspaces count: Int) async {
        while workbench.workspaces.count > count, let last = workbench.workspaces.last { workbench.close(workspace: last) }
        while workbench.workspaces.count < count {
            let pane = workbench.newWorkspace(folder: folder("home-\(workbench.workspaces.count)"))
            _ = await shellReady(pane)
        }
        workbench.goHome()
        _ = await PerfWait.until(1500) { self.workbench.isHome }
        await PerfWait.sleep(200)
        _ = MenuStandIn.take()
    }

    /// A main menu item, chosen by its action, as a click on it does.
    private func mainMenuItem(_ action: Selector) {
        func find(_ menu: NSMenu) -> (NSMenu, Int)? {
            for (index, item) in menu.items.enumerated() {
                if item.action == action { return (menu, index) }
                if let sub = item.submenu, let found = find(sub) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu, let (menu, index) = find(main) else { return print("home: no menu item for \(action)") }
        menu.update()
        menu.performActionForItem(at: index)
    }

    /// A control's menu in the bars, popped by a click, and its item `title` chosen.
    private func barMenuItem(_ id: String, title: String) async {
        guard let rect = barControl(id)?.1 else { return print("home: no \(id)") }
        _ = MenuStandIn.take()
        press(at: NSPoint(x: rect.midX, y: rect.midY))
        guard let popped = MenuStandIn.take().first, let index = popped.menu.items.firstIndex(where: { $0.title == title }) else {
            return print("home: \(id)'s menu has no “\(title)”")
        }
        popped.menu.performActionForItem(at: index)
    }
}
#endif
