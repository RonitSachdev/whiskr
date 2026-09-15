#if DEBUG
import AppKit
@_spi(Diagnostics) import MeadowScene
import WhiskrKit
import WhiskrMeadow

/// `--perf-flows meadow` (`make perf`'s checks): the meadow follows what you choose on the right (docs/DESIGN.md,
/// "The meadow follows what you choose"). Nine workspaces, more than the sidebar's column shows at once, three of
/// them with a Claude (a stand-in, told its state by simulated hooks). Then every way of choosing on the right,
/// through the app's own event path (clicks on tabs and on a terminal, ⌥⌘n, ⌃⌘[ and ⌃⌘], ⌘n, ⌃Tab, ⌘⇧], the
/// workspace button's menu, Go to, Home), each judged by what a person at the window would see once the meadow
/// is still: the chosen blanket, and the cat of the chosen Claude, wholly inside the meadow with
/// `MeadowView.comfortableInset` to spare, and ringed. Before each choice the meadow is moved by hand so the
/// target is out of sight, so a meadow that does not follow fails. Also: a quick run of choices moves the view
/// once, after the last; an agent's news elsewhere never moves it; a choice made while the meadow is hidden is in
/// view the moment it shows; and the same in the meadow alone (rows), zoomed in by hand.
extension PerfSuite {
    func meadowFollowCheck() async {
        let meadow = controller.navigator.meadow
        // The meadow draws as on a visible window (`MeadowView.assumesOnScreen`, set for every measuring run):
        // when macOS gives this unseen window no frames, its stand-in clock draws them, so what is checked is
        // what a visible meadow would show.
        // A window 1000 pt wide: the meadow is the sidebar's narrow column, one workspace to a row.
        window.setContentSize(NSSize(width: 1000, height: 900))
        await PerfWait.sleep(500)
        var spaces: [(workspace: Workspace, pane: Pane)] = []
        for i in 0..<9 {
            let pane = workbench.newWorkspace(folder: folder("follow-\(i)"))
            guard await shellReady(pane), let workspace = workbench.workspace(of: pane.id)?.0 else { return check("meadow: nine shells ready", false) }
            spaces.append((workspace, pane))
        }
        // Claudes in the third, seventh and ninth; the seventh split with a shell beside its Claude, the ninth
        // with a second tab.
        for i in [2, 6, 8] { pretendClaude(spaces[i].pane) }
        workbench.select(workspace: spaces[6].workspace)
        workbench.split(.horizontal)
        guard let split = workbench.focusedPane, split !== spaces[6].pane, await shellReady(split) else { return check("meadow: a split beside the seventh's Claude", false) }
        workbench.select(workspace: spaces[8].workspace)
        let secondTab = workbench.newTab()
        guard await shellReady(secondTab) else { return check("meadow: a second tab in the ninth", false) }
        let cats = [2, 6, 8].map { cat(spaces[$0]) }
        let laid = await PerfWait.until(5000) { cats.allSatisfy { meadow.screenRect(of: $0) != nil } }
        check("meadow: three cats and nine blankets laid out", laid != nil && spaces.allSatisfy { meadow.screenRect(of: blanket($0.workspace)) != nil })
        shortcut("cmd+shift+h")
        await still()
        print("meadow: \(Int(meadow.bounds.width))×\(Int(meadow.bounds.height)) pt, out of view below \(meadow.blanketsOutOfView.below.count), drawn by the display \(meadow.timings.map { String(format: "%.0f", $0.framesPerSecond) } ?? "-") fps, camera \(meadow.followState)")
        check("meadow: a column, taller than the sidebar shows", meadow.bounds.width < 420 && meadow.blanketsOutOfView.below.count >= 3,
              "\(Int(meadow.bounds.width)) pt wide, below \(meadow.blanketsOutOfView.below.count)")

        // Workspaces by key, by menu, by Go to.
        // The ninth comes back on the tab last shown in it: the shell's.
        await follows("⌥⌘9", blanket(spaces[8].workspace), ring: lantern(spaces[8].workspace, secondTab)) { self.shortcut("cmd+opt+9") }
        await follows("⌥⌘1", blanket(spaces[0].workspace), ring: blanket(spaces[0].workspace)) { self.shortcut("cmd+opt+1") }
        await follows("the workspace button's menu", blanket(spaces[6].workspace), ring: lantern(spaces[6].workspace, split)) {
            if let item = WorkspaceMenu.make(workbench: self.workbench).items.first(where: { $0.title == spaces[6].workspace.name }), let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
        }
        // A pane: a click on the Claude's terminal beside the shell, then Go › Next Pane (⌘]) to the shell and
        // back.
        await follows("a click on a terminal", cat(spaces[6]), ring: cat(spaces[6])) {
            let surface = spaces[6].pane.surface
            self.click(surface, at: NSPoint(x: surface.bounds.midX, y: surface.bounds.midY))
        }
        await follows("⌘] (the next pane)", blanket(spaces[6].workspace), ring: lantern(spaces[6].workspace, split)) { self.shortcut("cmd+]") }
        await follows("⌘] again", cat(spaces[6]), ring: cat(spaces[6])) { self.shortcut("cmd+]") }
        await follows("⌃⌘[", blanket(spaces[5].workspace), ring: blanket(spaces[5].workspace)) { self.shortcut("cmd+ctrl+[") }
        await follows("Go to (⌘P)", blanket(spaces[8].workspace), ring: nil) { await self.goTo(spaces[8].workspace.name) }

        // Tabs: a click on one, ⌘1, ⌃Tab, ⌘⇧].
        guard workbench.selectedWorkspace === spaces[8].workspace, spaces[8].workspace.tabs.count == 2 else { return check("meadow: on the ninth, with its two tabs", false) }
        let claudeTab = spaces[8].workspace.tabs[0], shellTab = spaces[8].workspace.tabs[1]
        if workbench.selectedTab !== claudeTab { workbench.select(tab: claudeTab) }
        await still()
        await follows("a click on a tab", blanket(spaces[8].workspace), ring: lantern(spaces[8].workspace, secondTab)) {
            if let view = self.tabView(shellTab) { self.click(view, at: NSPoint(x: view.bounds.midX, y: view.bounds.midY)) }
        }
        await follows("⌘1", cat(spaces[8]), ring: cat(spaces[8])) { self.shortcut("cmd+1") }
        await follows("⌃Tab", blanket(spaces[8].workspace), ring: lantern(spaces[8].workspace, secondTab)) {
            // A tap: ⌃ held, Tab, ⌃ let go.
            self.hold(.control, code: 59)
            self.shortcut("ctrl+tab")
            await PerfWait.sleep(60)
            self.hold([], code: 59)
        }
        await follows("⌘⇧]", cat(spaces[8]), ring: cat(spaces[8])) { self.shortcut("cmd+shift+]") }

        await quickChoices(spaces.map(\.workspace))
        await agentsDoNotMove(spaces)
        await hiddenCatchesUp(spaces)
        await rows(spaces)

        // Home: nothing ringed, and the column framed from its top again.
        shortcut("cmd+shift+h")
        await still()
        let top = meadow.screenRect(of: blanket(spaces[0].workspace)).map { meadow.bounds.height - $0.maxY } ?? -1
        check("meadow: Home rings nothing and frames the column from its top again", meadow.selection == nil && meadow.blanketsOutOfView.above.isEmpty && top >= 0,
              "selection \(String(describing: meadow.selection)), above \(meadow.blanketsOutOfView.above.count), first flag \(Int(top)) pt from the top")
    }

    // MARK: Choosing and looking

    /// Moves the meadow by hand so `item` is out of sight, makes a choice, waits for the meadow to be still and
    /// checks the choice is in comfortable view and ringed (`ring`; nil: not checked).
    private func follows(_ name: String, _ item: MeadowItem, ring: MeadowItem?, choose: () async -> Void) async {
        let meadow = controller.navigator.meadow
        await handAway(from: item)
        let before = margin(item)
        await choose()
        await still()
        let after = margin(item)
        check("meadow: \(name) brings it comfortably into view", (after ?? -1) >= MeadowView.comfortableInset - 0.5,
              "\(describe(item)) \(before.map { "\(Int($0))" } ?? "off") → \(after.map { "\(Int($0))" } ?? "off") pt from the edge; at \(rects(item)) in \(Int(meadow.bounds.width))×\(Int(meadow.bounds.height))")
        if let ring {
            check("meadow: \(name) rings it", meadow.selection == ring, "ringed \(String(describing: meadow.selection)), expected \(ring)")
        }
    }

    /// The meadow slid by hand (as a ⌘-drag does) until `item` is out of comfortable view, and still again.
    private func handAway(from item: MeadowItem) async {
        let meadow = controller.navigator.meadow
        for _ in 0..<8 {
            guard (margin(item) ?? -1) >= MeadowView.comfortableInset - 0.5 else { break }
            // Content moves the way the hand does: push it toward the nearer end, out past that edge.
            let rect = meadow.screenRect(of: .blanket(item.blanketID))
            let low = rect.map { $0.midY < meadow.bounds.midY } ?? true
            meadow.simulateDrag(dx: 0, dy: low ? 120 : -120, slide: true)
            await PerfWait.sleep(50)
        }
        await still()
    }

    /// How comfortably `item` (its blanket with its flag, and its cat for a cat) sits in the meadow: the least of
    /// its margins to the edges, in points; nil when it is not drawn. In the sidebar's column only the top and
    /// bottom count: its framing lays the blankets from side to side, the nearer ones a little past them.
    private func margin(_ item: MeadowItem) -> CGFloat? {
        let meadow = controller.navigator.meadow
        var rects = [meadow.screenRect(of: .blanket(item.blanketID))]
        if case .cat = item { rects.append(meadow.screenRect(of: item)) }
        let column = meadow.bounds.width < 420
        var least = CGFloat.infinity
        for rect in rects {
            guard let r = rect else { return nil }
            // In the column, across is the framing's: its middle in view is enough.
            let side = column ? (r.midX > 0 && r.midX < meadow.bounds.width ? CGFloat.infinity : -1) : min(r.minX, meadow.bounds.width - r.maxX)
            least = min(least, side, r.minY, meadow.bounds.height - r.maxY)
        }
        return least
    }

    /// Where `item` is drawn (its blanket, and its cat), rounded, for the report.
    private func rects(_ item: MeadowItem) -> String {
        let meadow = controller.navigator.meadow
        var found = [meadow.screenRect(of: .blanket(item.blanketID))]
        if case .cat = item { found.append(meadow.screenRect(of: item)) }
        return found.map { $0.map { "(\(Int($0.minX)), \(Int($0.minY)), \(Int($0.width))×\(Int($0.height)))" } ?? "nowhere" }.joined(separator: " ")
    }

    /// Every blanket's place on screen, as the last frame drew it.
    private var picture: [CGRect] {
        let meadow = controller.navigator.meadow
        return workbench.workspaces.compactMap { meadow.screenRect(of: .blanket($0.id.uuidString)) }
    }

    /// Waits until nothing in the meadow has moved for a quarter of a second (at most `limit` ms).
    private func still(limit: Double = 4000) async {
        let start = perfNow()
        var last = picture, since = perfNow()
        while perfNow() - start < limit {
            await PerfWait.sleep(25)
            let now = picture
            if !Self.same(now, last) { last = now; since = perfNow() } else if perfNow() - since >= 250 { return }
        }
    }

    private static func same(_ a: [CGRect], _ b: [CGRect], within: CGFloat = 0.5) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0.minX - $1.minX) <= within && abs($0.minY - $1.minY) <= within }
    }

    // MARK: The rules around following

    /// ⌃⌘] eight times, 50 ms apart (a key held down), from the first workspace: nothing moves while choices keep
    /// coming; then one glide, to the last.
    private func quickChoices(_ spaces: [Workspace]) async {
        let meadow = controller.navigator.meadow
        shortcut("cmd+opt+1")
        await still()
        let start = picture
        var movedEarly = false
        for _ in 0..<8 {
            shortcut("cmd+ctrl+]")
            for _ in 0..<5 {
                await PerfWait.sleep(10)
                if !Self.same(picture, start) { movedEarly = true }
            }
        }
        let target = blanket(spaces[8])
        // Count how many times it set off: moving after a tenth of a second or more of standing still (a
        // sample can fall between two frames, which is not a stop).
        var starts = 0, movedAt = -Double.infinity, last = picture
        let begin = perfNow()
        while perfNow() - begin < 2500 {
            await PerfWait.sleep(16)
            let now = picture
            if !Self.same(now, last, within: 0.3) {
                if perfNow() - movedAt > 100 { starts += 1 }
                movedAt = perfNow()
            }
            last = now
        }
        check("meadow: eight quick ⌃⌘] move nothing until they stop", !movedEarly)
        check("meadow: then one glide, to the last", starts == 1 && (margin(target) ?? -1) >= MeadowView.comfortableInset - 0.5 && meadow.selection?.blanketID == target.blanketID,
              "set off \(starts) times; \(describe(target)) \(margin(target).map { "\(Int($0))" } ?? "off") pt from the edge")
    }

    /// A Claude in another workspace asks for you and another finishes: the ring stays and nothing moves.
    private func agentsDoNotMove(_ spaces: [(workspace: Workspace, pane: Pane)]) async {
        let meadow = controller.navigator.meadow
        await still()
        let before = picture, ring = meadow.selection
        hook(spaces[8].pane, "PreToolUse", ["tool_name": "Bash", "tool_use_id": "f1", "tool_input": ["command": "make test"]])
        hook(spaces[8].pane, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "make test"]])
        hook(spaces[2].pane, "Stop", [:])
        let asked = await PerfWait.until(3000) { self.workbench.status(of: spaces[8].pane) == .blocked }
        await PerfWait.sleep(1500)
        let moved = zip(before, picture).map { hypot($0.minX - $1.minX, $0.minY - $1.minY) }.max() ?? 0
        check("meadow: an agent's news elsewhere moves neither the view nor the ring", asked != nil && Self.same(before, picture, within: 1) && meadow.selection == ring,
              "asked \(asked != nil), moved \(String(format: "%.1f", moved)) pt, ring \(String(describing: meadow.selection))")
    }

    /// The meadow hidden (⌃⌘S), the last workspace chosen, the meadow shown: in view at once, with no glide.
    private func hiddenCatchesUp(_ spaces: [(workspace: Workspace, pane: Pane)]) async {
        let meadow = controller.navigator.meadow
        shortcut("cmd+opt+1")
        await still()
        shortcut("cmd+ctrl+s")
        let hidden = await PerfWait.until(2000) { meadow.isHiddenOrHasHiddenAncestor || meadow.bounds.width < 1 }
        shortcut("cmd+opt+9")
        await PerfWait.sleep(400)
        shortcut("cmd+ctrl+s")
        let shown = await PerfWait.until(2000) { !meadow.isHiddenOrHasHiddenAncestor && meadow.bounds.width >= 200 }
        // From its first frames on, what was chosen is in view: it was there already, not on its way.
        let target = blanket(spaces[8].workspace)
        var worst = CGFloat.infinity
        let begin = perfNow()
        await PerfWait.sleep(80)
        while perfNow() - begin < 700 {
            worst = min(worst, margin(target) ?? -.infinity)
            await PerfWait.sleep(16)
        }
        check("meadow: chosen while hidden, it is in view the moment the meadow shows", hidden != nil && shown != nil && worst >= 0,
              "hidden \(hidden != nil), shown \(shown != nil), least margin over its first 0.7 s \(worst.isFinite ? "\(Int(worst))" : "off") pt")
        await still()
    }

    /// The meadow alone (View › Meadow Only): the workspaces in rows. Zoomed in by hand, a choice still comes into view.
    private func rows(_ spaces: [(workspace: Workspace, pane: Pane)]) async {
        let meadow = controller.navigator.meadow
        controller.showMeadowOnly(nil)
        let wide = await PerfWait.until(3000) { meadow.bounds.width > 900 }
        await still()
        meadow.simulateZoom(by: 0.5, at: CGPoint(x: meadow.bounds.width * 0.25, y: meadow.bounds.height * 0.75))
        await still()
        await follows("in the meadow alone, zoomed in, ⌥⌘1", blanket(spaces[0].workspace), ring: blanket(spaces[0].workspace)) { self.shortcut("cmd+opt+1") }
        await follows("in the meadow alone, zoomed in, ⌥⌘3", cat(spaces[2]), ring: cat(spaces[2])) { self.shortcut("cmd+opt+3") }
        await follows("in the meadow alone, zoomed in, ⌥⌘9", blanket(spaces[8].workspace), ring: nil) { self.shortcut("cmd+opt+9") }
        check("meadow: the meadow alone is wide", wide != nil, "\(Int(meadow.bounds.width)) pt")
        controller.showMeadowAndTerminals(nil)
        _ = await PerfWait.until(3000) { meadow.bounds.width < 600 }
        await still()
    }

    // MARK: Pieces

    private func blanket(_ workspace: Workspace) -> MeadowItem { .blanket(workspace.id.uuidString) }
    private func cat(_ space: (workspace: Workspace, pane: Pane)) -> MeadowItem {
        .cat(blanket: space.workspace.id.uuidString, agent: MeadowMapping.catID(pane: space.pane.id, agent: nil))
    }
    private func lantern(_ workspace: Workspace, _ pane: Pane) -> MeadowItem { .lantern(blanket: workspace.id.uuidString, lantern: pane.id.uuidString) }

    private func describe(_ item: MeadowItem) -> String {
        let index = workbench.workspaces.firstIndex { $0.id.uuidString == item.blanketID }.map { "workspace \($0 + 1)" } ?? "?"
        if case .cat = item { return "\(index)'s cat" }
        return index
    }

    /// A Claude stand-in in the pane: the pane says Claude runs in it, and a hook says it is at work.
    private func pretendClaude(_ pane: Pane) {
        pane.debugPretendsClaude = true
        hook(pane, "UserPromptSubmit", [:])
    }

    private func hook(_ pane: Pane, _ event: String, _ extra: [String: JSONValue]) {
        var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string("follow-\(pane.id.uuidString)"), "cwd": .string(pane.folder)]
        payload.merge(extra) { _, new in new }
        workbench.monitor.simulate(paneID: pane.id, payload: .object(payload))
    }

    /// Go to (⌘P): the name typed into its field, then Return, each key sent to its panel as the window
    /// server would.
    private func goTo(_ name: String) async {
        shortcut("cmd+p")
        let panel = { self.window.childWindows?.last { $0 is NSPanel && $0.firstResponder is NSText } }
        guard await PerfWait.until(1000, { panel() != nil }) != nil, let panel = panel() else { return check("meadow: ⌘P opens Go to", false) }
        func key(_ characters: String, _ code: UInt16) {
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                panel.sendEvent(event)
            }
        }
        for character in name { key(String(character), 0) }
        await PerfWait.sleep(300)
        key("\r", 36)
    }
}
#endif
