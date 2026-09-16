#if DEBUG
import AppKit
@_spi(Diagnostics) import MeadowScene
import WhiskrKit
import WhiskrMeadow

/// `--perf-flows meadow`, after the following checks: the meadow's own life, driven by real state changes.
/// - **The kettle** on a plain terminal's blanket, from a real shell's command marks: cold at the prompt; lit
///   and steaming while `sleep` runs; out again (after its whistle) when it ends; flagged when `false` fails out
///   of sight, until the terminal is looked at; gone while a Claude (a stand-in) runs there, back when it ends.
///   VoiceOver reads each ("Command running", "Command finished", "Command failed").
/// - **Idle cats wander**: a stand-in Claude's cat, finished and seen, goes out into the grass; clicked out
///   there it chooses its terminal; work (its hooks) calls it home at a run, the tab's state there at once,
///   the cat in its seat in a second or two; left long idle it naps out there and wakes for work the same way.
/// - Pictures (`meadow-pictures` in the run's folder) in whiskr-light, whiskr-dark and graphite: the kettle in
///   each state, cats out in the grass, mid-hop, running home and asleep in the grass, and the round eyes of a
///   cat washing, stretching, sipping tea, nibbling and lying as a loaf.
extension PerfSuite {
    func meadowLifeCheck() async {
        let meadow = controller.navigator.meadow
        // The window as it opens by default: the meadow its usual 42 %, workspaces two to a row.
        window.setContentSize(NSSize(width: 1440, height: 900))
        // You are at the window throughout: what is shown is seen (a failed command's flag, a finished turn).
        let looking = workbench.isLookingAtWindow
        workbench.isLookingAtWindow = true
        defer { workbench.isLookingAtWindow = looking }
        await PerfWait.sleep(400)
        let shell = workbench.newWorkspace(folder: folder("life-kettle"))
        guard await shellReady(shell), let kettleSpace = workbench.workspace(of: shell.id)?.0 else { return check("meadow life: a plain terminal's workspace", false) }
        let claude = workbench.newWorkspace(folder: folder("life-cat"))
        guard await shellReady(claude), let catSpace = workbench.workspace(of: claude.id)?.0 else { return check("meadow life: a Claude's workspace", false) }
        // A plain prompt, so the pictures show no name of the Mac or its user.
        for pane in [shell, claude] { pane.type("PROMPT='$ '; PS1='$ '; clear\r") }
        await PerfWait.sleep(400)
        let kettleID = kettleSpace.id.uuidString
        let cat = MeadowItem.cat(blanket: catSpace.id.uuidString, agent: MeadowMapping.catID(pane: claude.id, agent: nil))
        func kettle() -> (shown: Float, flame: Float, flag: Float, steaming: Bool) { meadow.kettle(kettleID) ?? (0, 0, 0, false) }
        func spoken(_ space: Workspace) -> String {
            (meadow.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }.first { $0.hasPrefix(space.name) } ?? ""
        }

        // The kettle, by the shell's own marks.
        workbench.select(workspace: kettleSpace)
        let cold = await PerfWait.until(4000) { kettle().shown > 0.95 }
        check("kettle: a plain terminal's blanket has its kettle, cold at the prompt", cold != nil && kettle().flame == 0 && !kettle().steaming && kettle().flag < 0.01,
              "\(kettle())")
        await lifePictures("kettle-cold")
        shell.type("sleep 4\r")
        let lit = await PerfWait.until(3000) { kettle().flame > 0.8 && kettle().steaming }
        check("kettle: a command running lights it and it steams", shell.commandRunning && lit != nil, "running \(shell.commandRunning), \(kettle())")
        check("kettle: VoiceOver says a command runs", spoken(kettleSpace).contains(String(localized: "Command running")), spoken(kettleSpace))
        await lifePictures("kettle-running")
        let ended = await PerfWait.until(6000) { !shell.commandRunning }
        await PerfWait.sleep(250)
        await lifePictures("kettle-whistle")
        let out = await PerfWait.until(3000) { kettle().flame == 0 }
        check("kettle: the command ends well, the flame goes out", ended != nil && out != nil && kettle().flag < 0.01, "\(kettle())")
        check("kettle: VoiceOver says it finished", spoken(kettleSpace).contains(String(localized: "Command finished")), spoken(kettleSpace))
        // Failing out of sight: the flag stands until the terminal has been looked at.
        workbench.select(workspace: catSpace)
        await PerfWait.sleep(300)
        shell.type("false\r")
        let flagged = await PerfWait.until(4000) { kettle().flag > 0.9 && kettle().flame < 0.02 }
        check("kettle: a command failing out of sight puts up the flag", flagged != nil && shell.failedCommand == 1, "\(kettle())")
        check("kettle: VoiceOver says it failed", spoken(kettleSpace).contains(String(localized: "Command failed")), spoken(kettleSpace))
        await PerfWait.sleep(1500)
        check("kettle: unseen, the flag stays", kettle().flag > 0.95)
        await lifePictures("kettle-failed")
        workbench.select(workspace: kettleSpace)
        // At the window again (the pictures' theme changes can tell it it was covered a moment): seen.
        let seen = await PerfWait.until(5000) {
            if !self.workbench.isLookingAtWindow { self.workbench.isLookingAtWindow = true }
            return kettle().flag < 0.02
        }
        check("kettle: looked at, the flag comes down", seen != nil, "\(kettle())")
        // A Claude in that terminal: the kettle makes way for its cat, and comes back when it has gone.
        shell.debugPretendsClaude = true
        lifeHook(shell, "UserPromptSubmit", [:])
        let gone = await PerfWait.until(4000) { kettle().shown < 0.02 && meadow.screenRect(of: .cat(blanket: kettleID, agent: shell.id.uuidString)) != nil }
        check("kettle: a Claude starting there, it makes way for the cat", gone != nil, "\(kettle())")
        shell.debugPretendsClaude = false
        lifeHook(shell, "SessionEnd", [:])
        let back = await PerfWait.until(8000) { kettle().shown > 0.95 }
        check("kettle: the Claude gone, the kettle is back, cold", back != nil && kettle().flame == 0, "\(kettle()), status \(String(describing: workbench.status(of: shell)))")

        // Idle cats wander.
        claude.debugPretendsClaude = true
        lifeHook(claude, "UserPromptSubmit", [:])
        lifeHook(claude, "Stop", [:])
        workbench.select(workspace: catSpace)
        _ = await PerfWait.until(4000) { self.workbench.status(of: claude) == .idle }
        await PerfWait.sleep(1600)
        await lifePictures("eyes-loaf")
        let away = await outing(claude, cat) { self.outInTheGrass(cat, catSpace) && meadow.roaming(cat)?.hopping == false }
        check("roaming: a cat with nothing to do goes out into the grass beside its blanket", away != nil, "\(String(describing: meadow.roaming(cat)))")
        await lifePictures("roam-out")
        // Clicked out there, it chooses its terminal.
        workbench.select(workspace: kettleSpace)
        await PerfWait.sleep(600)
        if let rect = meadow.screenRect(of: cat), meadow.roaming(cat)?.out == true {
            click(meadow, at: NSPoint(x: rect.midX, y: rect.midY - rect.height * 0.15))
        }
        let chosen = await PerfWait.until(2000) { self.workbench.focusedPane === claude }
        await pointerAway()
        check("roaming: clicked out in the grass, the cat chooses its terminal", chosen != nil)
        // Mid-hop, in each theme.
        for (index, theme) in Self.lifeThemes.enumerated() {
            setLifeTheme(theme)
            // Checked once; the other themes' pictures are taken when a bound comes along.
            let hop = await outing(claude, cat, tries: index == 0 ? 5 : 2) { meadow.roaming(cat)?.hopping == true }
            if index == 0 { check("roaming: out in the grass it bounds", hop != nil) }
            if hop != nil { await lifePicture("roam-hop", theme) }
        }
        setLifeTheme(Self.lifeThemes[0])
        // Work calls it home at a run.
        _ = await outing(claude, cat) { self.outInTheGrass(cat, catSpace) && meadow.roaming(cat)?.hopping == false }
        let before = meadow.roaming(cat)?.out ?? false
        lifeHook(claude, "UserPromptSubmit", [:])
        lifeHook(claude, "PreToolUse", ["tool_name": "Read", "tool_use_id": "life-r1", "tool_input": ["file_path": "/tmp/notes.md"]])
        let called = await PerfWait.until(1000) { meadow.roaming(cat)?.running == true }
        check("roaming: work comes and the cat out in the grass runs home at once, its tab working already",
              before && called != nil && workbench.status(of: claude) == .working, "out \(before), \(String(describing: meadow.roaming(cat))), \(String(describing: workbench.status(of: claude)))")
        await PerfWait.sleep(150)
        await lifePicture("roam-running", Self.lifeThemes[0])
        let home = await PerfWait.until(4000) { meadow.roaming(cat)?.out == false && !self.outInTheGrass(cat, catSpace) }
        check("roaming: and is in its seat, at work, in a second or two", home != nil, "\(String(describing: meadow.roaming(cat)))")
        for theme in Self.lifeThemes.dropFirst() {
            setLifeTheme(theme)
            _ = await outing(claude, cat, tries: 2) { self.outInTheGrass(cat, catSpace) && meadow.roaming(cat)?.hopping == false }
            lifeHook(claude, "UserPromptSubmit", [:])
            _ = await PerfWait.until(1000) { meadow.roaming(cat)?.running == true }
            await PerfWait.sleep(150)
            await lifePicture("roam-running", theme)
            _ = await PerfWait.until(4000) { meadow.roaming(cat)?.out == false }
        }
        setLifeTheme(Self.lifeThemes[0])

        // Long idle: it naps out there, and wakes for work the same way.
        _ = await outing(claude, cat) { self.outInTheGrass(cat, catSpace) }
        // Its Claude lets it nap after a while; it would stay up and about some minutes more: it dozes off now.
        _ = await PerfWait.until((AgentWorld.napAfter + 30) * 1000) { self.workbench.session(of: claude)?.main.activity == .napping }
        meadow.letCatsDozeOff()
        let asleep = await PerfWait.until(15000) { meadow.roaming(cat)?.running == false && meadow.roaming(cat)?.asleep == true || meadow.roaming(cat)?.out == false }
        _ = await PerfWait.until(15000) { meadow.roaming(cat).map { $0.asleep || !$0.out } ?? false }
        let where_ = meadow.roaming(cat).map { $0.asleep ? "in the grass" : $0.out ? "out, on its way" : "on its blanket" } ?? "nowhere"
        check("roaming: left long idle it naps where it is, in shade or on its blanket", asleep != nil && where_ != "out, on its way", where_)
        await lifePictures("roam-napping")
        lifeHook(claude, "UserPromptSubmit", [:])
        let woke = await PerfWait.until(5000) { meadow.roaming(cat)?.out == false && !self.outInTheGrass(cat, catSpace) }
        check("roaming: woken by work it runs home the same way", woke != nil, "\(String(describing: meadow.roaming(cat)))")

        // Round eyes through a stand-in Claude's fidgets (awake at its prompt).
        let eyes = workbench.newWorkspace(folder: folder("life-eyes"))
        guard await shellReady(eyes), let eyesSpace = workbench.workspace(of: eyes.id)?.0 else { return check("meadow life: a third workspace", false) }
        eyes.type("PROMPT='$ '; PS1='$ '; clear\r")
        eyes.debugPretendsClaude = true
        workbench.select(workspace: eyesSpace)
        await PerfWait.sleep(1500)
        let eyesCat = MeadowItem.cat(blanket: eyesSpace.id.uuidString, agent: MeadowMapping.catID(pane: eyes.id, agent: nil))
        for (fidget, at) in [("wash", 900.0), ("stretch", 800), ("sip", 1100), ("nibble", 1400)] {
            for theme in Self.lifeThemes {
                setLifeTheme(theme)
                await PerfWait.sleep(300)
                meadow.fidget(eyesCat, fidget)
                await PerfWait.sleep(at)
                await lifePicture("eyes-\(fidget)", theme)
            }
        }
        setLifeTheme(Self.lifeThemes[0])
        eyes.debugPretendsClaude = false
        claude.debugPretendsClaude = false
    }

    // MARK: Pieces

    static let lifeThemes = [("whiskr-light", BuiltInThemes.defaultID, ThemeStore.Appearance.light), ("whiskr-dark", BuiltInThemes.defaultID, .dark),
                             ("graphite", "graphite", .dark)]

    private func setLifeTheme(_ theme: (String, String, ThemeStore.Appearance)) {
        ThemeStore.shared.themeID = theme.1
        ThemeStore.shared.appearance = theme.2
    }

    /// The window as it is, in each of the three themes.
    private func lifePictures(_ name: String) async {
        for theme in Self.lifeThemes {
            setLifeTheme(theme)
            await PerfWait.sleep(350)
            await lifePicture(name, theme)
        }
        setLifeTheme(Self.lifeThemes[0])
    }

    private func lifePicture(_ name: String, _ theme: (String, String, ThemeStore.Appearance)) async {
        // The pointer away from the meadow, so no name note stands over the cats.
        await pointerAway()
        let folder = URL(fileURLWithPath: self.folder("meadow-pictures"), isDirectory: true)
        DebugShell.snapshot(window: controller, workbench: workbench, to: folder.appendingPathComponent("\(name)-\(theme.0).png"))
    }

    /// The pointer leaves the meadow: no cat is watched (one under the pointer stays where it is) and no name
    /// note shows.
    private func pointerAway() async {
        let meadow = controller.navigator.meadow
        guard meadow.hovered != nil, let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil) else { return }
        meadow.mouseExited(with: exit)
        await PerfWait.sleep(250)
    }

    /// A turn begun and finished, so its Claude is idle afresh (and its nap a while off), and seen.
    private func idleAgain(_ pane: Pane) async {
        // At the window (a picture's theme change can tell the window it was covered for a moment).
        workbench.isLookingAtWindow = true
        lifeHook(pane, "UserPromptSubmit", [:])
        lifeHook(pane, "Stop", [:])
        _ = await PerfWait.until(4000) { self.workbench.status(of: pane) == .idle }
    }

    /// Outings, a fresh one at a time (each cat chooses its own way: a stop on its blanket, a walk rather than
    /// a bound), until `happens` holds (`tries` at most); when it first held.
    private func outing(_ pane: Pane, _ cat: MeadowItem, tries: Int = 5, _ happens: @escaping @MainActor () -> Bool) async -> Double? {
        for _ in 0..<tries {
            await idleAgain(pane)
            await sendOut(cat)
            if let at = await PerfWait.until(20000, happens) { return at }
            let meadow = controller.navigator.meadow
            print("meadow life: an outing did not do it: \(String(describing: meadow.roaming(cat))), status \(String(describing: workbench.status(of: pane))), "
                  + "animated \(meadow.animatesAmbient), reduced \(meadow.reduceMotion), wander \(meadow.settings.catsWander), resting \(meadow.isResting), "
                  + "drawn \(meadow.timings.map { "\($0.framesPerSecond)" } ?? "-")")
        }
        return nil
    }

    /// The cat sets off at once rather than after its rest.
    private func sendOut(_ cat: MeadowItem) async {
        let meadow = controller.navigator.meadow
        _ = await PerfWait.until(4000) { meadow.roaming(cat)?.out == false }
        meadow.sendCatsOut()
    }

    /// Whether the cat stands off its blanket, out in the grass (its middle outside the cloth's rect on screen).
    private func outInTheGrass(_ cat: MeadowItem, _ space: Workspace) -> Bool {
        let meadow = controller.navigator.meadow
        guard meadow.roaming(cat)?.out == true, let body = meadow.screenRect(of: cat), let cloth = meadow.screenRect(of: .blanket(space.id.uuidString)) else { return false }
        return !cloth.insetBy(dx: body.width * 0.2, dy: body.height * 0.2).contains(NSPoint(x: body.midX, y: body.minY + body.height * 0.2))
    }

    private func lifeHook(_ pane: Pane, _ event: String, _ extra: [String: JSONValue]) {
        var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string("life-\(pane.id.uuidString)"), "cwd": .string(pane.folder)]
        payload.merge(extra) { _, new in new }
        workbench.monitor.simulate(paneID: pane.id, payload: .object(payload))
    }
}
#endif
