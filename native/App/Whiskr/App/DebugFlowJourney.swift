#if DEBUG
import AppKit
import MeadowScene
import WhiskrKit

/// `--perf-flows journey` (`make perf`'s checks): the first five minutes as a person spends them, in one
/// run, through the window's own event path (`NSApplication.sendEvent`, `NSWindow.sendEvent`): Home
/// taking Return, a folder, a terminal and its titles; a Claude through every state, every surface that
/// shows it agreeing at each step (`DebugFlowJourneyClaude.swift`); tabs, splits and workspaces by every
/// route (`DebugFlowJourneyTabs.swift`). Main-thread stalls over 50 ms are listed with the step they
/// happened in.
///
/// A relaunch needs a second process, so the journey runs three times on one isolated folder
/// (`Scripts/perf.sh`), each told its part by `--journey-phase`:
///   (none)      the journey; it leaves three workspaces and a Claude for the next run (with `--leave-host`)
///   relaunch    everything back as it was, same processes, nothing typed; then ⌥⌘Q (`DebugFlowJourneyRelaunch.swift`)
///   stopped     after Quit and Stop All Terminals: nothing of the last run still running
///
/// A Claude here is never the real one: a stand-in `claude` (a script the run writes) records how it was
/// started and posts hook events through the settings it was given, and a copy of `sleep` named `claude`
/// stays in front of its shell, so the terminal itself says Claude is there (`JourneyFakeClaude`).
extension PerfSuite {
    func journeyCheck() async {
        let journey = Journey(suite: self)
        switch DebugScenario.value("--journey-phase") {
        case "relaunch": await journey.relaunched()
        case "stopped": await journey.afterStopping()
        default: await journey.run()
        }
    }
}

extension DebugScript {
    /// `--script` commands of this flow; true when `command` was one of them.
    ///   journey-state           what every surface says of every Claude, on one line each (`Journey.surfaces`)
    static func journeyCommand(_ command: String, _ argument: String, _ workbench: Workbench, _ controller: MainWindowController) -> Bool {
        switch command {
        case "journey-state":
            for pane in workbench.panes.values where pane.agentRunning {
                print("  \(Journey.Surfaces(workbench: workbench, controller: controller, pane: pane).line)")
            }
            return true
        default:
            return false
        }
    }
}

/// One scripted journey: its steps, what the main thread did in each, and the helpers its steps share.
@MainActor
final class Journey {
    let suite: PerfSuite
    var workbench: Workbench { suite.workbench }
    var controller: MainWindowController { suite.controller }
    var window: NSWindow { suite.window }
    /// Main-thread stalls, timed by a ping every 4 ms from a thread of its own (`MainPinger`).
    private let pings = PerfLog()
    private lazy var pinger = MainPinger(log: pings)
    private let anatomy = RunLoopAnatomy()
    /// Each step's name and when it ran, for the stalls report.
    private var marks: [(name: String, at: Double)] = []
    /// Where this run keeps its scratch repository, the stand-in `claude` and what the next run checks.
    let place: URL
    /// What the run after a relaunch is to find (`Expectation`), written into the isolated folder.
    static var expectationFile: URL { AppPlaces.supportFolder.appendingPathComponent("journey-expect.json") }

    init(suite: PerfSuite) {
        self.suite = suite
        place = URL(fileURLWithPath: suite.folder("journey"), isDirectory: true)
    }

    func check(_ name: String, _ passed: Bool, _ detail: String = "") { suite.check("journey: \(name)", passed, detail) }

    /// A new step begins: what follows is reported under its name.
    func step(_ name: String) {
        // Someone is at the window throughout: what is on screen counts as seen. (The window of a run nobody
        // sees is never in front, and a change of key window or of what covers it says so again.)
        workbench.isLookingAtWindow = true
        marks.append((name, perfNow()))
        print("journey: step \(name)")
    }

    // MARK: The whole run

    /// The pointer and the keys held become the run's own, and the main thread is watched from now on.
    func beginWatching() {
        HeldKeys.install()
        PointerStandIn.install()
        pinger.start()
        anatomy.start()
    }

    func run() async {
        beginWatching()
        // Never `claude --resume` typed by a later run of this folder (that would be the real Claude):
        // Settings › Resume Claude in restored panes, off for this run's own settings from the start.
        Preferences.shared.resumeClaude = false
        let looking = workbench.isLookingAtWindow
        // As if someone sat at the window: what is on screen counts as seen.
        workbench.isLookingAtWindow = true
        await firstMinute()
        await claudeStates()
        await shimMerge()
        await tabs()
        await splits()
        await workspaces()
        await leaveForRelaunch()
        workbench.isLookingAtWindow = looking
        finishStalls()
        HeldKeys.flags = nil
        PointerStandIn.location = nil
    }

    /// Every ping over 50 ms, by the step it came in, with the long run-loop turns of that step.
    func finishStalls() {
        pinger.stop()
        marks.append(("end", perfNow()))
        var lines: [String] = []
        for (index, mark) in marks.dropLast().enumerated() {
            let end = marks[index + 1].at
            let long = pings.pings(from: mark.at, to: end).filter { $0 > 50 }
            guard !long.isEmpty else { continue }
            lines.append("\(mark.name): \(long.count)× over 50 ms, longest \(PerfSuite.ms(long.max())) ms; long turns \(anatomy.long(from: mark.at, to: end))")
        }
        print("journey: main-thread stalls over 50 ms: \(lines.isEmpty ? "none" : "")")
        for line in lines { print("journey: stall \(line)") }
        suite.note("journey stalls over 50 ms", lines.isEmpty ? "none" : lines.joined(separator: " | "))
    }

    // MARK: Step 1: Home, a folder, a terminal

    /// Launch lands on Home with the keyboard; Return there opens a terminal; the folder opened (as Open
    /// Folder… does once a folder is chosen) becomes a workspace named after its repository; commands typed
    /// title the tab after the program (once it has stayed 0.4 s) or the folder.
    private func firstMinute() async {
        step("launch lands on Home")
        check("launch: Home, no workspace selected", workbench.isHome, "selected \(workbench.selectedWorkspace?.name ?? "none")")
        check("launch: the window is titled “Whiskr”", window.title == "Whiskr", "“\(window.title)”")
        let keyed = await PerfWait.until(2000) { self.homeHasKeyboard }
        check("launch: Home has the keyboard", keyed != nil, "first responder \(describe(window.firstResponder))")

        step("Return on Home")
        let before = workbench.workspaces.count
        typeKeys("\r")
        let opened = await PerfWait.until(3000) { self.workbench.workspaces.count == before + 1 && !self.workbench.isHome }
        check("Home: Return opens New Terminal (a workspace in the home folder)", opened != nil,
              "workspaces \(before) → \(workbench.workspaces.count), home \(workbench.isHome)")
        if let pane = workbench.focusedPane {
            let ready = await suite.shellReady(pane)
            check("Home's terminal: its shell ready and the keyboard in it", ready && suite.focused(pane), "first responder \(describe(window.firstResponder))")
            check("Home's terminal: the window is titled with the workspace's name", window.title == workbench.selectedWorkspace?.name, "“\(window.title)”")
        }

        step("Home again, New Terminal (the script's)")
        shortcut("cmd+shift+h")
        _ = await PerfWait.until(2000) { self.workbench.isHome && self.homeHasKeyboard }
        check("⇧⌘H: Home with the keyboard", workbench.isHome && homeHasKeyboard, "first responder \(describe(window.firstResponder))")
        // As `--script new-terminal` does: Home's row, by the model (SwiftUI's rows are out of reach of a click here).
        let second = workbench.newWorkspace()
        _ = await suite.shellReady(second)

        step("(the run makes its scratch repository with git, on the main thread)")
        guard let repository = makeRepository() else { return check("a scratch git repository", false) }
        step("open the scratch repository")
        let pane = openFolder(repository)
        guard await suite.shellReady(pane) else { return check("the repository's shell drew its prompt", false) }
        let named = await PerfWait.until(5000) { self.workbench.selectedWorkspace?.name == "shop" && self.workbench.selectedWorkspace?.branch == "main" }
        check("Open Folder: the workspace is named after its repository, with its branch", named != nil,
              "name “\(workbench.selectedWorkspace?.name ?? "-")” branch \(workbench.selectedWorkspace?.branch ?? "-")")
        check("Open Folder: the keyboard is in its terminal", suite.focused(pane))
        await titles(pane)
    }

    /// `ls` never titles the tab; `cd sub` titles it "sub" and the workspace keeps the repository's name;
    /// `false` leaves its failed mark; `sleep 1` titles it "sleep" while it runs.
    private func titles(_ pane: Pane) async {
        guard let tab = workbench.selectedTab, let workspace = workbench.selectedWorkspace else { return }
        step("typing: ls")
        typeKeys("ls\r")
        let seen = await sampleTitles(tab, for: 1200)
        check("`ls` never retitles its tab", Set(seen) == ["shop"], "titles seen \(Array(Set(seen)).sorted())")
        step("typing: cd sub")
        typeKeys("cd sub\r")
        let moved = await PerfWait.until(3000) { self.workbench.title(of: tab) == "sub" }
        check("`cd sub` titles the tab “sub”", moved != nil, "“\(workbench.title(of: tab))”")
        check("after `cd sub` the workspace keeps its repository's name", workspace.name == "shop", "“\(workspace.name)”")
        step("typing: false")
        typeKeys("false\r")
        let failed = await PerfWait.until(3000) { pane.failedCommand == 1 }
        // On screen and looked at: seen within a second or so, then gone.
        let cleared = await PerfWait.until(3000) { pane.failedCommand == nil }
        check("`false` marks the command failed, and on screen it is seen", failed != nil && cleared != nil,
              "failed \(failed != nil), cleared \(cleared != nil)")
        step("typing: echo and sleep")
        typeKeys("echo journey-$((6*7))\r")
        let echoed = await PerfWait.until(3000) { self.suite.screen(pane).contains("journey-42") }
        check("`echo` prints in the terminal with the keyboard", echoed != nil)
        typeKeys("sleep 1.5\r")
        let sleeping = await sampleTitles(tab, for: 2600)
        let others = Set(sleeping).subtracting(["sub", "sleep"])
        check("`sleep 1.5` titles the tab “sleep” for a while, then the folder again", sleeping.contains("sleep") && others.isEmpty && sleeping.last == "sub",
              "titles seen in order \(sleeping.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } })")
        typeKeys("cd ..\r")
        _ = await PerfWait.until(3000) { self.workbench.title(of: tab) == "shop" }
    }

    func sampleTitles(_ tab: Tab, for milliseconds: Double) async -> [String] {
        let start = perfNow()
        var seen: [String] = []
        while perfNow() - start < milliseconds {
            seen.append(workbench.title(of: tab))
            await PerfWait.sleep(20)
        }
        return seen
    }

    /// File › Open Folder… once a folder has been chosen (the folder picker itself is a window of the
    /// system's, never shown in a run nobody sees).
    func openFolder(_ folder: URL) -> Pane {
        workbench.open(folder: folder.path)
        return workbench.focusedPane!
    }

    // MARK: The scratch repository

    /// `shop`: a few commits, a folder `sub`, a file changed and not committed.
    func makeRepository() -> URL? {
        let repository = place.appendingPathComponent("shop", isDirectory: true)
        try? FileManager.default.removeItem(at: repository)
        try? FileManager.default.createDirectory(at: repository.appendingPathComponent("sub"), withIntermediateDirectories: true)
        guard git(["init", "-q", "-b", "main"], in: repository) != nil else { return nil }
        for (index, name) in ["README.md", "cart.ts", "sub/notes.txt"].enumerated() {
            try? Data("\(name) \(index)\n".utf8).write(to: repository.appendingPathComponent(name))
            guard git(["add", name], in: repository) != nil,
                  git(["-c", "user.name=Whiskr journey", "-c", "user.email=journey@example.invalid", "-c", "commit.gpgsign=false",
                       "commit", "-q", "-m", "add \(name)"], in: repository) != nil else { return nil }
        }
        try? Data("changed, not committed\n".utf8).write(to: repository.appendingPathComponent("cart.ts"))
        return repository
    }

    /// git in the scratch repository only, with none of this Mac's settings: its output, nil if it failed.
    func git(_ arguments: [String], in folder: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    // MARK: Events

    /// Typed keys, each through the app's event path to the window's first responder.
    func typeKeys(_ text: String) { suite.typeKeys(text) }

    /// A shortcut, as the app routes one: the window's views, then the menus.
    func shortcut(_ spec: String) {
        suite.shortcut(spec)
        endOfEvent()
    }

    /// What AppKit does as each event it took from the window server ends: the run loop's undo group is
    /// closed. A run nobody sees takes no events of its own, so its group would stay open and gather every
    /// later undo into one.
    func endOfEvent() {
        guard let undo = window.undoManager, undo.groupsByEvent, undo.groupingLevel > 0 else { return }
        undo.endUndoGrouping()
    }

    /// A key with its code (arrows, Return, Esc) through the app's event path, to `target` (the main window
    /// unless another window, the palette or a card, has the keyboard).
    func press(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) {
        let target = target ?? window
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: target.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
            target.sendEvent(event)
        }
    }

    func mouse(_ type: NSEvent.EventType, at location: NSPoint, count: Int = 1) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: suite.nextEventNumber(), clickCount: count,
                           pressure: [.leftMouseDown, .otherMouseDown].contains(type) ? 1 : 0)
    }

    /// A double-click: a click, then one that counts 2, each release queued before its press.
    @discardableResult
    func doubleClick(_ view: NSView, at point: NSPoint) -> NSView? {
        let location = view.convert(point, to: nil)
        PointerStandIn.location = location
        let target = suite.hit(view, at: point)
        for count in 1...2 {
            guard let down = mouse(.leftMouseDown, at: location, count: count), let up = mouse(.leftMouseUp, at: location, count: count) else { continue }
            NSApp.postEvent(up, atStart: false)
            NSApp.sendEvent(down)
        }
        return target
    }

    /// The Home page has the keyboard (SwiftUI keeps it in a view of its own inside the page).
    var homeHasKeyboard: Bool {
        guard let home = controller.terminals.home, !home.isHidden else { return false }
        return (window.firstResponder as? NSView)?.isDescendant(of: home) == true
    }

    func describe(_ responder: NSResponder?) -> String {
        guard let responder else { return "none" }
        if let surface = responder as? TerminalSurface, let pane = workbench.panes.values.first(where: { $0.surface === surface }) {
            return "the terminal of “\(workbench.name(of: pane))”"
        }
        return String(describing: type(of: responder))
    }

    /// A note of the work area's own (`ZoomNote`, `UndoNote`: SwiftUI views in hosting views of their
    /// own) while it shows something: its view, else nil. (SwiftUI builds its accessibility only for an
    /// assistive app asking, so a note is found by its view, not by what it says.)
    /// Every view under `root` that passes `test`.
    func allViews(in root: NSView, where test: (NSView) -> Bool) -> [NSView] {
        (test(root) ? [root] : []) + root.subviews.flatMap { allViews(in: $0, where: test) }
    }

    func shownNote(_ name: String) -> NSView? {
        DebugShell.descendant(of: controller.terminals.view) { view in
            String(describing: type(of: view)).contains("<\(name)>") && !view.isHiddenOrHasHiddenAncestor && view.fittingSize.height > 4
        }
    }
}
#endif
