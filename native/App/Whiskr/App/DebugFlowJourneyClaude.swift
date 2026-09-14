#if DEBUG
import AppKit
import MeadowScene
import WhiskrKit

/// The journey's Claude (`Journey`): one in a tab of the repository's workspace, through every state by
/// the hook events Claude Code posts (`AgentMonitor.simulate`, the payloads as Claude Code sends them),
/// with every surface that shows it checked against the model at each step: the cat (the scene's world),
/// the tab's mark, the workspace menu's count, the status bar, Home's Open row, Go to, the Dock badge and
/// ⌘J. Then the answer card, helpers, a nap, and a Claude started by a shell function of the user's with
/// its own `--settings`, through the real shim and hooks.
extension Journey {
    /// What a person can be expected to see of a Claude.
    enum Expected: CustomStringConvertible {
        case unknown, working(Activity), request, error, finished, idle, napping

        var status: AgentStatus {
            switch self {
            case .unknown: .unknown
            case .working: .working
            case .request, .error: .blocked
            case .finished: .done
            case .idle, .napping: .idle
            }
        }

        var description: String {
            switch self {
            case .unknown: "starting"
            case .working(let activity): "working (\(activity.rawValue))"
            case .request: "request"
            case .error: "error"
            case .finished: "finished"
            case .idle: "idle"
            case .napping: "napping"
            }
        }
    }

    /// Everything that shows one Claude's state, read as each surface reads it.
    struct Surfaces {
        let status: AgentStatus?
        let failed: Bool
        let activity: Activity?
        let cat: MeadowAgent?
        let tabStatus: AgentStatus?
        /// The mark in the tab's place, as `TabKindMark` chooses it: "!", "×", "✓", or none.
        let tabMark: String?
        let menuCount: Int?
        let summary: StatusSummary
        let needsYouCount: Int
        let home: HomeList.State?
        /// Go to's row for the Claude in its Waiting section (requests and finished turns), and whether it
        /// carries "×".
        let goToWaiting: AgentStatus?
        let goToFailed: Bool
        let dock: String?
        let next: Workbench.NextThing
        let helpers: Int

        init(workbench: Workbench, controller: MainWindowController, pane: Pane) {
            let place = workbench.workspace(of: pane.id)
            let session = workbench.session(of: pane)
            status = workbench.status(of: pane)
            failed = session?.failed ?? false
            activity = session?.main.activity
            let world = controller.navigator.meadow.world
            cat = world.machines.flatMap(\.spaces).flatMap(\.blankets).flatMap(\.agents).first { $0.id == pane.id.uuidString }
            helpers = world.machines.flatMap(\.spaces).flatMap(\.blankets).flatMap(\.agents).filter { $0.id.hasPrefix(pane.id.uuidString + "/") }.count
            tabStatus = place.flatMap { workbench.status(of: $0.1) }
            let tabFailed = place?.1.tree.panes.compactMap { workbench.panes[$0] }.contains { workbench.session(of: $0)?.failed ?? false } ?? false
            tabMark = switch tabStatus {
            case .blocked: tabFailed ? "×" : "!"
            case .done: "✓"
            default: nil
            }
            if let workspace = place?.0 {
                menuCount = WorkspaceMenu.make(workbench: workbench).items.first { $0.title == workspace.name }.map { $0.badge?.itemCount ?? 0 }
            } else {
                menuCount = nil
            }
            summary = StatusSummary(statuses: workbench.agentRows.map(\.status))
            needsYouCount = workbench.needsYouCount
            home = place.flatMap { place in workbench.homeRows.first { $0.id == place.0.id }?.state }
            // Go to as ⌘P opens it, nothing typed yet.
            let goTo = PaletteModel(workbench: workbench, mode: .goTo, menu: nil, window: nil)
            goTo.refresh()
            goToWaiting = goTo.sections.first { $0.id == "waiting" }?.rows.first { $0.id == "claude:\(pane.id)" }?.entry.status
            goToFailed = goTo.failed.contains("claude:\(pane.id)")
            dock = NSApp.dockTile.badgeLabel
            next = workbench.nextThing
        }

        var line: String {
            "model \(status.map { "\($0)" } ?? "none")\(failed ? " failed" : "") \(activity?.rawValue ?? "-")"
                + " · cat \(cat.map { "\($0.activity.rawValue)\($0.needsYou ? " !" : "")\($0.doneUnseen ? " ✓" : "")\($0.failed ? " ×" : "")" } ?? "none") helpers \(helpers)"
                + " · tab \(tabStatus.map { "\($0)" } ?? "none") \(tabMark ?? "")"
                + " · menu \(menuCount.map(String.init) ?? "-")"
                + " · status bar \(summary.claudes) Claudes, \(summary.needYou) need you"
                + " · home \(home.map { "\($0)" } ?? "-")"
                + " · go to's waiting \(goToWaiting.map { "\($0)" } ?? "-")\(goToFailed ? " ×" : "")"
                + " · dock \(dock ?? "none") · ⌘J \(next)"
        }
    }

    /// Whether every surface shows `expected` for this pane, and if not, which disagree.
    func disagreements(_ surfaces: Surfaces, _ expected: Expected, pane: Pane) -> [String] {
        var wrong: [String] = []
        let status = expected.status
        if surfaces.status != status { wrong.append("model") }
        if case .error = expected { if !surfaces.failed { wrong.append("model's error") } } else if case .request = expected, surfaces.failed { wrong.append("model's error") }
        switch expected {
        case .working(let activity):
            if surfaces.activity != activity { wrong.append("model's activity") }
            if surfaces.cat?.activity.rawValue != activity.rawValue || surfaces.cat?.needsYou == true { wrong.append("cat") }
        case .request:
            if surfaces.cat?.needsYou != true || surfaces.cat?.failed == true { wrong.append("cat") }
        case .error:
            if surfaces.cat?.failed != true { wrong.append("cat") }
        case .finished:
            if surfaces.cat?.doneUnseen != true { wrong.append("cat") }
        case .idle:
            if surfaces.cat?.activity != .idle || surfaces.cat?.doneUnseen == true { wrong.append("cat") }
        case .napping:
            if surfaces.activity != .napping { wrong.append("model's activity") }
            if surfaces.cat?.activity != .napping || surfaces.cat?.doneUnseen == true { wrong.append("cat") }
        case .unknown:
            if surfaces.cat == nil { wrong.append("cat") }
        }
        if surfaces.tabStatus != status && !(status == .unknown && surfaces.tabStatus == .unknown) { wrong.append("tab") }
        // The tab's mark: "!", "×" or "✓"; nothing for the rest.
        let mark: String? = switch expected {
        case .request: "!"
        case .error: "×"
        case .finished: "✓"
        default: nil
        }
        if surfaces.tabMark != mark { wrong.append("tab's mark") }
        let blockedHere = workbench.workspace(of: pane.id).map { place in workbench.agentRows.filter { $0.workspaceID == place.0.id && $0.status == .blocked }.count } ?? 0
        if surfaces.menuCount != blockedHere { wrong.append("workspace menu") }
        if surfaces.summary.needYou != surfaces.needsYouCount || surfaces.summary.claudes != workbench.panes.values.filter(\.agentRunning).count { wrong.append("status bar") }
        let home: HomeList.State = switch expected {
        case .request: .needsYou(failed: false)
        case .error: .needsYou(failed: true)
        case .finished: .finished
        case .working: .working
        case .idle, .napping, .unknown: .idle
        }
        // Home's row shows the workspace's most urgent Claude; this one is the workspace's only Claude.
        if surfaces.home != home { wrong.append("Home's row") }
        let waiting: AgentStatus? = status == .blocked || status == .done ? status : nil
        if surfaces.goToWaiting != waiting || surfaces.goToFailed != (mark == "×") { wrong.append("Go to") }
        let dock = surfaces.needsYouCount > 0 && Preferences.shared.dockBadge ? "\(surfaces.needsYouCount)" : nil
        if surfaces.dock != dock { wrong.append("Dock badge") }
        switch expected {
        case .request, .error:
            // At it already, ⌘J goes on, not to it again.
            let atIt = workbench.focusedPane?.id == pane.id
            if atIt ? surfaces.next == .request(pane.id) : surfaces.next != .request(pane.id) { wrong.append("⌘J") }
        case .finished where workbench.focusedPane?.id != pane.id:
            if surfaces.next != .finished(pane.id) { wrong.append("⌘J") }
        default:
            if case .request(pane.id) = surfaces.next { wrong.append("⌘J") }
            if case .finished(pane.id) = surfaces.next { wrong.append("⌘J") }
        }
        return wrong
    }

    /// Waits up to two seconds for every surface to show `expected`, then says which did not.
    func agree(_ name: String, _ pane: Pane, _ expected: Expected) async {
        workbench.isLookingAtWindow = true
        var wrong: [String] = []
        _ = await PerfWait.until(2000) {
            wrong = self.disagreements(Surfaces(workbench: self.workbench, controller: self.controller, pane: pane), expected, pane: pane)
            return wrong.isEmpty
        }
        let surfaces = Surfaces(workbench: workbench, controller: controller, pane: pane)
        wrong = disagreements(surfaces, expected, pane: pane)
        check("\(name): every surface shows \(expected)", wrong.isEmpty, (wrong.isEmpty ? "" : "disagreeing: \(wrong.joined(separator: ", ")); ") + surfaces.line)
    }

    // MARK: Step 2: a Claude through every state

    func hook(_ pane: Pane, _ session: String, _ event: String, _ extra: [String: JSONValue] = [:]) {
        var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string(session), "cwd": .string(pane.currentFolder),
                                            "transcript_path": .string(place.appendingPathComponent("transcripts/\(session).jsonl").path)]
        payload.merge(extra) { _, new in new }
        workbench.monitor.simulate(paneID: pane.id, payload: .object(payload))
    }

    /// A terminal with the stand-in Claude in front (`JourneyFakeClaude.stay`): the terminal says Claude
    /// is there, as it does for the real one, before any hook event.
    func startClaude(in pane: Pane) async -> Bool {
        let stay = JourneyFakeClaude.stayer(in: place)
        pane.type("\(ShellQuote.quote(stay.path)) 86400\r")
        return await PerfWait.until(5000) { pane.agentRunning } != nil
    }

    func claudeStates() async {
        step("a Claude starts")
        guard let workspace = workbench.selectedWorkspace, let shell = workbench.focusedPane else { return check("Claude: a workspace to start it in", false) }
        let pane = workbench.newTab()
        guard await suite.shellReady(pane), await startClaude(in: pane) else { return check("Claude: the terminal says Claude is in front", false) }
        guard let tab = workbench.workspace(of: pane.id)?.1 else { return }
        claudePane = pane.id
        await agree("Claude just started, nothing reported", pane, .unknown)
        let session = "journey-claude"
        hook(pane, session, "SessionStart", ["source": "startup"])
        await agree("SessionStart", pane, .idle)
        check("notifications: not asked for at launch, nor when a Claude has only started", !workbench.notifier.askedThisRun)

        step("Claude works")
        hook(pane, session, "UserPromptSubmit", ["prompt": "fix the cart"])
        await agree("UserPromptSubmit", pane, .working(.thinking))
        check("notifications: asked for once a Claude is at work (in a test run, never shown)", workbench.notifier.askedThisRun)
        for (index, (tool, input, activity)) in [("Read", ["file_path": JSONValue.string("cart.ts")], Activity.reading),
                                                 ("Edit", ["file_path": .string("cart.ts"), "old_string": "a", "new_string": "b"], .editing),
                                                 ("Bash", ["command": "npm test"], .running),
                                                 ("Grep", ["pattern": "getCart"], .reading),
                                                 ("WebSearch", ["query": "swift observation"], .searching)].enumerated() {
            hook(pane, session, "PreToolUse", ["tool_name": .string(tool), "tool_use_id": .string("t\(index)"), "tool_input": .object(input)])
            await agree("PreToolUse \(tool)", pane, .working(activity))
            hook(pane, session, "PostToolUse", ["tool_name": .string(tool), "tool_use_id": .string("t\(index)"), "tool_input": .object(input)])
            await agree("PostToolUse \(tool)", pane, .working(.thinking))
        }

        step("Claude asks (a request), its tab out of sight")
        // Another tab is shown, so the request's terminal is not on screen and its cat offers the card.
        workbench.select(tab: workspace.tabs.first { $0.tree.contains(shell.id) }!)
        _ = await PerfWait.until(2000) { self.suite.focused(shell) }
        hook(pane, session, "PreToolUse", ["tool_name": "Bash", "tool_use_id": "b9", "tool_input": ["command": "rm -rf build"]])
        hook(pane, session, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"], "permission_suggestions": []])
        hook(pane, session, "Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])
        await agree("PermissionRequest", pane, .request)
        check("a request moves nothing: the shown tab and the keyboard stay", workbench.selectedTab?.tree.contains(shell.id) == true && suite.focused(shell),
              "first responder \(describe(window.firstResponder))")
        await answerCard(pane: pane, session: session)

        step("Claude finishes, out of sight")
        hook(pane, session, "PostToolUse", ["tool_name": "Bash", "tool_use_id": "b9", "tool_input": ["command": "rm -rf build"]])
        hook(pane, session, "Stop", [:])
        await agree("Stop, its tab out of sight", pane, .finished)
        await PerfWait.sleep(1500)
        await agree("1.5 s later, still out of sight", pane, .finished)
        step("⌘J to the finished Claude")
        let jumped = perfNow()
        shortcut("cmd+j")
        _ = await PerfWait.until(2000) { self.workbench.selectedTab === tab && self.suite.focused(pane) }
        check("⌘J goes to the finished Claude's terminal, with the keyboard", workbench.selectedTab === tab && suite.focused(pane), "first responder \(describe(window.firstResponder))")
        // Seen only once on screen for a second.
        await PerfWait.sleep(400)
        let stillDone = workbench.status(of: pane) == .done
        let seen = await PerfWait.until(3000) { self.workbench.status(of: pane) == .idle }
        check("✓ stays until the pane has been on screen a second, then goes", stillDone && seen.map { $0 - jumped >= 900 } ?? false,
              "still finished at 400 ms \(stillDone), idle after \(seen.map { PerfSuite.ms($0 - jumped) } ?? "never") ms")
        await agree("finished and seen", pane, .idle)
        shortcut("cmd+j")
        _ = await PerfWait.until(2000) { self.suite.focused(shell) }
        check("⌘J again goes back where it came from", suite.focused(shell), "first responder \(describe(window.firstResponder))")

        step("Claude stops on an error")
        hook(pane, session, "UserPromptSubmit", ["prompt": "again"])
        await agree("a second turn", pane, .working(.thinking))
        hook(pane, session, "StopFailure", ["error": "rate_limit", "error_message": "Rate limited"])
        await agree("StopFailure", pane, .error)
        workbench.select(tab: tab)
        let errorSeen = await PerfWait.until(3000) { self.workbench.status(of: pane) == .idle }
        check("an error, once seen for a second, is no longer news", errorSeen != nil, "status \(workbench.status(of: pane).map { "\($0)" } ?? "-")")

        step("Claude's helpers")
        hook(pane, session, "UserPromptSubmit", ["prompt": "map the code"])
        hook(pane, session, "PreToolUse", ["tool_name": "Agent", "tool_use_id": "a1", "tool_input": ["subagent_type": "Explore", "description": "Map the cart"]])
        hook(pane, session, "SubagentStart", ["agent_id": "h1", "agent_type": "Explore"])
        hook(pane, session, "PreToolUse", ["tool_name": "Grep", "tool_use_id": "g1", "agent_id": "h1", "tool_input": ["pattern": "cart"]])
        await agree("a helper started", pane, .working(.supervising))
        let helperCat = await PerfWait.until(2000) { Surfaces(workbench: self.workbench, controller: self.controller, pane: pane).helpers == 1 }
        check("a helper's cat sits beside its boss", helperCat != nil, Surfaces(workbench: workbench, controller: controller, pane: pane).line)
        hook(pane, session, "PostToolUse", ["tool_name": "Grep", "tool_use_id": "g1", "agent_id": "h1", "tool_input": ["pattern": "cart"]])
        hook(pane, session, "SubagentStop", ["agent_id": "h1", "agent_type": "Explore"])
        hook(pane, session, "PostToolUse", ["tool_name": "Agent", "tool_use_id": "a1", "tool_input": ["subagent_type": "Explore"]])
        let helperGone = await PerfWait.until(2000) { Surfaces(workbench: self.workbench, controller: self.controller, pane: pane).helpers == 0 }
        check("the helper's cat leaves when it stops", helperGone != nil)
        hook(pane, session, "Stop", [:])
        // On screen and looked at: seen after a second.
        _ = await PerfWait.until(3000) { self.workbench.status(of: pane) == .idle }
        await agree("the turn ends on screen", pane, .idle)

        step("Claude naps")
        // `AgentWorld.napAfter` after its turn ended, waiting: it curls up.
        let napped = await PerfWait.until((AgentWorld.napAfter + 8) * 1000) { self.workbench.session(of: pane)?.main.activity == .napping }
        check("after \(Int(AgentWorld.napAfter)) s idle the Claude naps", napped != nil)
        await agree("napping", pane, .napping)

        step("a waiting Claude's tab closed")
        // Its request goes with it: from the Dock's count and the status bar too.
        let other = workbench.newTab()
        if await suite.shellReady(other), await startClaude(in: other) {
            hook(other, "journey-closed", "UserPromptSubmit", ["prompt": "x"])
            hook(other, "journey-closed", "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "ls"]])
            await agree("a second Claude asks", other, .request)
            shortcut("cmd+opt+w")
            let gone = await PerfWait.until(2000) { self.workbench.panes[other.id] == nil }
            await PerfWait.sleep(300)
            let summary = StatusSummary(statuses: workbench.agentRows.map(\.status))
            check("closing a waiting Claude's tab takes its request off the Dock badge and the status bar",
                  gone != nil && NSApp.dockTile.badgeLabel == nil && summary.needYou == 0,
                  "Dock “\(NSApp.dockTile.badgeLabel ?? "none")”, status bar \(summary.claudes)/\(summary.needYou)")
            shortcut("cmd+z")
            let back = await PerfWait.until(2000) { self.workbench.panes[other.id] != nil }
            await agree("⌘Z brings the waiting Claude back, still asking", other, .request)
            if back != nil { workbench.close(tab: workbench.workspace(of: other.id)!.1) }
            _ = await PerfWait.until(2000) { NSApp.dockTile.badgeLabel == nil }
        }

        step("a request for the relaunch")
        // Left waiting, its tab not shown, for the next run to bring back as it is.
        hook(pane, session, "UserPromptSubmit", ["prompt": "deploy"])
        hook(pane, session, "PreToolUse", ["tool_name": "Bash", "tool_use_id": "d1", "tool_input": ["command": "make deploy"]])
        hook(pane, session, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "make deploy"]])
        workbench.select(tab: workspace.tabs.first { $0.tree.contains(shell.id) }!)
        await agree("a request waiting", pane, .request)
    }

    /// The pane of the journey's Claude, kept for the relaunch.
    var claudePane: UUID? {
        get { Self.claude }
        set { Self.claude = newValue }
    }
    private static var claude: UUID?

    // MARK: The answer card

    /// A click on the asking cat (its terminal out of sight) opens the card beside the meadow; 1 before
    /// 400 ms does nothing; 1 after it types Claude's "1" into the terminal. Again, with the request
    /// settled while the card is up: 1 types nothing.
    private func answerCard(pane: Pane, session: String) async {
        step("the answer card")
        let meadow = controller.navigator.meadow
        guard let workspace = workbench.workspace(of: pane.id)?.0 else { return }
        let cat = MeadowItem.cat(blanket: workspace.id.uuidString, agent: pane.id.uuidString)
        meadowTakesItsClicks("with a request out of sight")
        guard let landed = await clickInMeadow(cat), var rect = meadow.screenRect(of: cat) else { return check("answer card: the asking cat is laid out", false) }
        let shown = await PerfWait.until(2000) { self.controller.navigator.answerCardWindow != nil }
        guard shown != nil, let card = controller.navigator.answerCardWindow else {
            return check("answer card: a click on the asking cat opens it", false, "the click went to \(describe(landed)); selected tab \(workbench.selectedTab.map(workbench.title(of:)) ?? "-")")
        }
        let opened = perfNow()
        check("answer card: a click on the asking cat opens it, beside the meadow", card.frame.minX >= meadow.window!.convertToScreen(meadow.convert(meadow.bounds, to: nil)).maxX - 24,
              "card \(card.frame.integral), meadow ends at \(Int(meadow.window!.convertToScreen(meadow.convert(meadow.bounds, to: nil)).maxX))")
        check("answer card: nothing else moved", workbench.selectedTab?.tree.contains(pane.id) == false)
        let before = suite.screen(pane).joined(separator: "\n")
        press("1", code: 18, in: card)
        await PerfWait.sleep(100)
        let early = suite.screen(pane).joined(separator: "\n") != before
        check("answer card: 1 within 400 ms of opening sends nothing", !early && perfNow() - opened < 400, "sent \(early) at \(PerfSuite.ms(perfNow() - opened)) ms")
        await PerfWait.sleep(450)
        press("1", code: 18, in: card)
        let sent = await PerfWait.until(2000) { self.suite.screen(pane).joined(separator: "\n") != before }
        check("answer card: 1 once armed types Claude's “1” into its terminal and the card closes", sent != nil && controller.navigator.answerCardWindow == nil,
              "typed \(sent != nil), card still up \(controller.navigator.answerCardWindow != nil); first responder of the card \(describe(card.firstResponder))")

        // A request settled meanwhile.
        hook(pane, session, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])
        _ = await PerfWait.until(2000) { self.workbench.openRequest(pane: pane.id) != nil }
        // Where the cat is now (it hopped when clicked, and asks again).
        await PerfWait.sleep(1200)
        rect = meadow.screenRect(of: cat) ?? rect
        await suite.hover(meadow, at: NSPoint(x: rect.midX, y: rect.midY))
        suite.click(meadow, at: NSPoint(x: rect.midX, y: rect.midY))
        guard await PerfWait.until(2000, { self.controller.navigator.answerCardWindow != nil }) != nil, let again = controller.navigator.answerCardWindow else {
            return check("answer card: opens again for the next request", false, "request open \(workbench.openRequest(pane: pane.id) != nil), status \(workbench.status(of: pane).map { "\($0)" } ?? "-"), shown tab “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")”, the click went to \(describe(suite.hit(meadow, at: NSPoint(x: rect.midX, y: rect.midY)))), the meadow chose \(meadow.selection.map { "\($0)" } ?? "nothing")")
        }
        await PerfWait.sleep(500)
        hook(pane, session, "PostToolUse", ["tool_name": "Bash", "tool_use_id": "b9", "tool_input": ["command": "rm -rf build"]])
        let settled = suite.screen(pane).joined(separator: "\n")
        press("1", code: 18, in: again)
        await PerfWait.sleep(400)
        check("answer card: 1 after the request was settled types nothing", suite.screen(pane).joined(separator: "\n") == settled)
        press("\u{1b}", code: 53, in: again)
        _ = await PerfWait.until(1000) { self.controller.navigator.answerCardWindow == nil }
        if let open = controller.navigator.answerCardWindow { open.close() }
        // Claude asks again, as it would after being answered "yes" and running on.
        hook(pane, session, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]])
        await agree("asking again after the card", pane, .request)
    }

    /// A click on a blanket or a cat, as a person makes it: one whose blanket is out of view shows as a
    /// capsule at the meadow's edge ("↓ 1 need you"), clicked first to bring it into view; then a click on
    /// it. The keyboard stays where it was through the capsule's click. The view the last click went to;
    /// nil when the item is not laid out.
    func clickInMeadow(_ item: MeadowItem) async -> NSView? {
        let meadow = controller.navigator.meadow
        // The meadow draws as if on screen (`DebugPerf`): its last frame says where things are.
        _ = await PerfWait.until(3000) { meadow.screenRect(of: item) != nil }
        // Where it is once the meadow has stopped moving (a workspace chosen just now scrolls into view).
        var rect: CGRect?
        for _ in 0..<20 {
            let before = meadow.screenRect(of: item)
            await PerfWait.sleep(150)
            rect = meadow.screenRect(of: item)
            if rect != nil, rect == before { break }
        }
        guard var rect else { return nil }
        if let over = suite.hit(meadow, at: NSPoint(x: rect.midX, y: rect.midY)), over !== meadow {
            let keyboard = window.firstResponder
            print("journey: \(item) at \(rect.integral) is under \(describe(over)); out of view \(meadow.blanketsOutOfView)")
            await suite.hover(meadow, at: NSPoint(x: rect.midX, y: rect.midY))
            suite.click(meadow, at: NSPoint(x: rect.midX, y: rect.midY))
            await PerfWait.sleep(800)
            check("a click on the meadow's capsule leaves the keyboard where it was", window.firstResponder === keyboard,
                  "\(describe(keyboard)) → \(describe(window.firstResponder))")
            rect = meadow.screenRect(of: item) ?? rect
        }
        await suite.hover(meadow, at: NSPoint(x: rect.midX, y: rect.midY))
        return suite.click(meadow, at: NSPoint(x: rect.midX, y: rect.midY))
    }

    /// Every point of the meadow but its capsules and its hint takes its own clicks: nothing laid over it
    /// catches a click meant for a cat or a blanket.
    func meadowTakesItsClicks(_ when: String) {
        let meadow = controller.navigator.meadow
        guard let container = meadow.superview else { return }
        let others = container.subviews.filter { $0 !== meadow && !$0.isHidden && $0.frame.width > 0 }.map { meadow.convert($0.bounds, from: $0) }
        var caught: [String] = []
        for column in 1...5 {
            for row in 1...5 {
                let point = NSPoint(x: meadow.bounds.width * CGFloat(column) / 6, y: meadow.bounds.height * CGFloat(row) / 6)
                guard !others.contains(where: { $0.contains(point) }), let hit = suite.hit(meadow, at: point), hit !== meadow else { continue }
                caught.append("\(Int(point.x)),\(Int(point.y)) by \(describe(hit))")
            }
        }
        check("\(when): every point of the meadow takes its own clicks", caught.isEmpty, caught.joined(separator: "; "))
    }

    // MARK: A Claude started by your own shell function, with your own settings

    /// The "cat didn't do anything" kind: `claude` run from a shell function that passes `--settings` (a
    /// file, then inline JSON). The shim must merge the pane's hooks into them, and the hooks must report.
    /// The stand-in `claude` records its arguments and posts SessionStart, UserPromptSubmit, a Read and
    /// Stop through the hook command it was given, as Claude Code would.
    func shimMerge() async {
        step("Claude from a shell function with --settings")
        let bin = JourneyFakeClaude.install(in: place)
        let records = place.appendingPathComponent("records", isDirectory: true)
        try? FileManager.default.removeItem(at: records)
        try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let mine = place.appendingPathComponent("my-settings.json")
        try? Data(#"{"env":{"JOURNEY_MINE":"file"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}"#.utf8).write(to: mine)
        let pane = workbench.newTab()
        guard await suite.shellReady(pane) else { return check("shim: the shell drew its prompt", false) }
        let setup = "export PATH=\(ShellQuote.quote(bin.path)):$PATH JOURNEY_RECORDS=\(ShellQuote.quote(records.path)); "
            // The caller's name, for the records: a function's own name is not passed on to the program it runs.
            + "ccf() { JOURNEY_CALLER=ccf command claude --settings \(ShellQuote.quote(mine.path)) \"$@\"; }; "
            + "cci() { JOURNEY_CALLER=cci command claude --settings='{\"env\":{\"JOURNEY_MINE\":\"inline\"}}' \"$@\"; }; clear\r"
        pane.type(setup)
        await PerfWait.sleep(500)
        for (name, function, mineSays) in [("a settings file", "ccf", "file"), ("inline JSON", "cci", "inline")] {
            let before = Set(workbench.monitor.sessions.map(\.id))
            let fromHere = { self.workbench.monitor.sessions.filter { $0.paneID == pane.id.uuidString && $0.id.hasPrefix("fake-") && !before.contains($0.id) } }
            pane.type("\(function) -p hello\r")
            let reported = await PerfWait.until(8000) { !fromHere().isEmpty }
            let ran = await PerfWait.until(5000) { (try? FileManager.default.contentsOfDirectory(atPath: records.path))?.contains { $0.hasPrefix("argv-\(function)") } ?? false }
            let argv = (try? FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil))?
                .first { $0.lastPathComponent.hasPrefix("argv-\(function)") }.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let arguments = argv.split(separator: "\n").map(String.init)
            let settingsPath = arguments.firstIndex(of: "--settings").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                ?? arguments.first { $0.hasPrefix("--settings=") }.map { String($0.dropFirst("--settings=".count)) }
            let merged = settingsPath.flatMap { FileManager.default.contents(atPath: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let keptMine = ((merged?["env"] as? [String: Any])?["JOURNEY_MINE"] as? String) == mineSays
            let hooks = merged?["hooks"] as? [String: Any]
            let ours = (hooks?["Stop"] as? [[String: Any]])?.contains { (($0["hooks"] as? [[String: Any]])?.first?["command"] as? String)?.contains(ShellIntegration.Key.pane) == true } ?? false
            let inFolder = settingsPath.map { $0.hasPrefix(Workbench.hooksFolder.path) && URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("merged-") } ?? false
            check("shim, \(name): Claude Code gets one --settings, yours with the pane's hooks added, in the app's private folder",
                  ran != nil && keptMine && ours && inFolder && arguments.filter({ $0.hasPrefix("--settings") }).count == 1,
                  "argv \(arguments), merged \(settingsPath ?? "none"): yours kept \(keptMine), hooks added \(ours)")
            check("shim, \(name): its hooks reach the app, so the cat shows what it does", reported != nil,
                  "sessions from this pane \(workbench.monitor.sessions.filter { $0.paneID == pane.id.uuidString }.map { "\($0.id) \($0.status)" })")
            _ = await PerfWait.until(5000) { pane.foreground == nil }
        }
        workbench.close(tab: workbench.workspace(of: pane.id)!.1)
    }
}

/// The stand-in for Claude Code: never the real one. `claude` (a script) writes its arguments to
/// `$JOURNEY_RECORDS/argv-<caller>-<pid>`, finds the hook command among the settings it was given and
/// posts SessionStart, UserPromptSubmit, PreToolUse and PostToolUse of a Read, and Stop through it, as
/// Claude Code runs a command hook; then it ends. `stay/claude` is `sleep` under Claude's name: in front
/// of a shell, the terminal says Claude is there.
enum JourneyFakeClaude {
    static func install(in folder: URL) -> URL {
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        # The journey's stand-in for Claude Code (DebugFlowJourneyClaude.swift): never the real one.
        printf '%s\n' "$@" > "$JOURNEY_RECORDS/argv-$JOURNEY_CALLER-$$"
        settings=
        previous=
        for argument in "$@"; do
          [ "$previous" = "--settings" ] && settings=$argument
          case $argument in --settings=*) settings=${argument#--settings=} ;; esac
          previous=$argument
        done
        [ -r "$settings" ] || exit 0
        command=$(/usr/bin/jq -r '.hooks.Stop[].hooks[].command' "$settings" | /usr/bin/grep WHISKR_PANE | /usr/bin/head -1)
        [ -n "$command" ] || exit 0
        post() {
          printf '{"hook_event_name":"%s","session_id":"fake-%s","cwd":"%s"%s}' "$1" "$$" "$PWD" "$2" | /bin/sh -c "$command"
        }
        post SessionStart ',"source":"startup"'
        post UserPromptSubmit ',"prompt":"hello"'
        post PreToolUse ',"tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"README.md"}'
        post PostToolUse ',"tool_name":"Read","tool_use_id":"r1","tool_input":{"file_path":"README.md"}'
        post Stop ''
        post SessionEnd ',"reason":"other"'
        """#
        let file = bin.appendingPathComponent("claude")
        try? Data(script.utf8).write(to: file)
        chmod(file.path, 0o755)
        return bin
    }

    /// `sleep` under Claude's name (a link: a copy of a system binary is not allowed to run): the terminal's
    /// foreground program is then `claude`, as its arguments say.
    static func stayer(in folder: URL) -> URL {
        let stay = folder.appendingPathComponent("stay", isDirectory: true)
        try? FileManager.default.createDirectory(at: stay, withIntermediateDirectories: true)
        let file = stay.appendingPathComponent("claude")
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == nil { try? FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "/bin/sleep") }
        return file
    }
}
#endif
