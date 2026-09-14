#if DEBUG
import AppKit
import SwiftTerm
import TerminalHost
import WhiskrKit

/// `--perf-flows robust` (`make perf`'s checks): what must hold up under abuse: floods, binary and wide text, long pastes, resize storms, the session host going away.
///
/// Each step ends with a line the shell prints only once the step's command is done (`echo R…$((1))`
/// prints `R…1`, which the command line itself never shows), so nothing here waits a fixed time. Throughout,
/// a ping every 4 ms (`MainPinger`) says how long the main thread was ever held: more than a second is a
/// hang. After each step the terminal must still be sane: its program, its grid and its view agree on the
/// size (`stty size`), and the cursor is inside the grid. Binary output goes to a tab out of sight, where
/// the bells in it only mark the tab (a run must never beep). The session host is killed last.
extension PerfSuite {
    func robustCheck() async {
        let pinger = MainPinger(log: log)
        pinger.start()
        defer { pinger.stop() }
        let base = URL(fileURLWithPath: folder("r1"), isDirectory: true)
        let pane = workbench.newWorkspace(folder: base.path)
        guard await shellReady(pane) else { return check("robust: the first shell drew its prompt", false) }
        await robustStep("a line of 1 MB with no line break", pane, timeout: 60000) {
            pane.type(#"head -c 1000000 /dev/zero | tr '\0' x; echo; echo Rlong$((1))"# + "\r")
            return "Rlong1"
        }
        await robustStep("emoji, ZWJ sequences, flags, Japanese, combining marks", pane, timeout: 10000) {
            pane.type("clear; printf '%s\\n' '\(Self.wideText)'; echo Rwide$((1))\r")
            return "Rwide1"
        }
        let wide = screen(pane).first { $0.replacingOccurrences(of: " ", with: "").contains("日本語テキスト") }
        check("robust: wide text is on screen as printed", wide != nil, wide ?? "not found in \(screen(pane).prefix(4))")
        await terminalInputMethodCheck(pane)
        await pasteCheck(pane, base: base)
        await binaryCheck(besides: pane)
        await editorInputMethodCheck(base: base)
        await closingLetsGoCheck()
        await resizeStormCheck(pane)
        await hostLostCheck()
    }

    /// Wide and composed text: a family (four people joined by ZWJ), a flag, a skin tone, accents as
    /// combining marks, full-width Japanese and half-width katakana.
    static let wideText = "👩‍👩‍👧‍👦 🇯🇵 👍🏽 e\u{301}a\u{308}n\u{303} 日本語テキスト ｶﾀｶﾅ Ａ"

    // MARK: Steps

    /// Runs one step (`start` types it and returns the line that says it is done) and checks the step
    /// ended, held the main thread under a second, and left the terminal sane.
    private func robustStep(_ name: String, _ pane: Pane, timeout: Double, _ start: () -> String) async {
        let begin = perfNow()
        let marker = start()
        let done = await PerfWait.until(timeout) { self.screen(pane).contains(marker) }
        let held = log.pings(from: begin, to: perfNow()).max() ?? 0
        check("robust: \(name): done", done != nil, done.map { String(format: "after %.0f ms", $0 - begin) } ?? "“\(marker)” never printed; screen \(screen(pane).suffix(3))")
        check("robust: \(name): the window never hung", held < 1000, String(format: "main thread held at most %.0f ms", held))
        await terminalSane(pane, name)
    }

    /// The program, the terminal and the view agree on the size, and the cursor is inside the grid.
    func terminalSane(_ pane: Pane, _ name: String) async {
        await PerfWait.sleep(200)
        let (rows, cols) = (pane.surface.terminalDimensions.rows, pane.surface.terminalDimensions.cols)
        let cursor = pane.surface.reach?.locked { terminal, _ in terminal.getCursorLocation() }
        check("robust: \(name): the cursor is inside the grid", cursor.map { $0.x >= 0 && $0.x <= cols && $0.y >= 0 && $0.y < rows } ?? false,
              "cursor \(cursor.map { "\($0.x),\($0.y)" } ?? "?") in \(cols)x\(rows)")
        sizeTick += 1
        let marker = "SZ\(sizeTick)"
        pane.type("echo \(marker) $(stty size)\r")
        let answer = { (row: String) -> String? in
            let parts = row.split(separator: " ")
            return parts.count == 3 && parts[0] == marker ? "\(parts[2])x\(parts[1])" : nil
        }
        _ = await PerfWait.until(8000) { self.screen(pane).contains { answer($0) != nil } }
        let told = screen(pane).compactMap(answer).first ?? "?"
        let grid = pane.surface.terminalDimensions
        let room = pane.surface.size(for: pane.surface.frame.size)
        check("robust: \(name): program, terminal and view agree on the size",
              told == "\(grid.cols)x\(grid.rows)" && grid.cols == room.columns && grid.rows == room.rows,
              "program \(told), terminal \(grid.cols)x\(grid.rows), view room \(room.columns)x\(room.rows)")
    }

    /// Marked text (an input method's composition) in the terminal: shown while composing, never sent;
    /// committed text is sent once; a composition abandoned (`unmarkText`) sends nothing.
    private func terminalInputMethodCheck(_ pane: Pane) async {
        let surface = pane.surface
        let none = NSRange(location: NSNotFound, length: 0)
        pane.type("clear; echo ")
        await PerfWait.sleep(200)
        surface.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: none)
        let composing = surface.hasMarkedText()
        surface.insertText("日本語", replacementRange: none)
        let committed = !surface.hasMarkedText()
        surface.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: none)
        surface.unmarkText()
        pane.type(" Rime$((1))\r")
        let line = await PerfWait.until(5000) { self.screen(pane).contains { $0.hasSuffix("Rime1") && !$0.contains("echo") } }
        let shown = screen(pane).first { $0.hasSuffix("Rime1") && !$0.contains("echo") } ?? "-"
        check("robust: input method in the terminal: composing, committing, abandoning",
              composing && committed && line != nil && shown.replacingOccurrences(of: " ", with: "") == "日本語Rime1",
              "composing \(composing), committed \(committed), printed “\(shown)”")
        await terminalSane(pane, "input method")
    }

    /// 10,000 lines pasted into `cat`, with bracketed paste off, then on: every line arrives, the
    /// window never hangs, and with bracketed paste the paste is wrapped once.
    private func pasteCheck(_ pane: Pane, base: URL) async {
        let text = (1...10_000).map { "pasted line \($0) of ten thousand, with some words to make it long enough" }.joined(separator: "\n") + "\n"
        for (index, bracketed) in [false, true].enumerated() {
            let file = base.appendingPathComponent("paste-\(index).txt").path
            pane.type("clear; \(bracketed ? #"printf '\e[?2004h'; "# : #"printf '\e[?2004l'; "#)cat > \(ShellQuote.quote(file))\r")
            await PerfWait.sleep(400)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            let begin = perfNow()
            pane.surface.paste(self)
            let written = await PerfWait.until(60000) { ((try? FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0) >= text.utf8.count }
            let held = log.pings(from: begin, to: perfNow()).max() ?? 0
            // Everything has been written: ⌃C ends cat (a ⌃D too many would end the shell), then bracketed paste goes off.
            pane.type("\u{03}")
            await PerfWait.sleep(300)
            pane.type(#"printf '\e[?2004l'; echo Rpaste$((\#(index)+1)) $(wc -l < "# + ShellQuote.quote(file) + ")\r")
            let marker = "Rpaste\(index + 1)"
            _ = await PerfWait.until(8000) { self.screen(pane).contains { $0.hasPrefix(marker + " ") } }
            let lines = screen(pane).first { $0.hasPrefix(marker + " ") }?.split(separator: " ").last.map(String.init) ?? "?"
            let content = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            let wrapped = content.components(separatedBy: "\u{1b}[200~").count - 1
            let name = "robust: a paste of 10,000 lines, bracketed paste \(bracketed ? "on" : "off")"
            check("\(name): every line arrives", written != nil && lines == "10000" && wrapped == (bracketed ? 1 : 0),
                  "lines \(lines), bytes \(content.utf8.count) of \(text.utf8.count), wrapped \(wrapped) times")
            check("\(name): the window never hung", held < 1000, String(format: "main thread held at most %.0f ms", held))
        }
        await terminalSane(pane, "paste")
    }

    /// 5 MB of random bytes into a terminal in a tab out of sight (its bells only mark the tab), then the
    /// terminal reset: nothing crashes or hangs, and once shown it is sane.
    private func binaryCheck(besides pane: Pane) async {
        guard let workspace = workbench.selectedWorkspace, let shown = workspace.selectedTab else { return check("robust: binary: setup", false) }
        let other = workbench.newTab()
        guard await shellReady(other) else { return check("robust: binary: the second tab's shell drew its prompt", false) }
        workbench.select(tab: shown)
        _ = await PerfWait.until(2000) { self.focused(pane) }
        let begin = perfNow()
        // Answers the terminal gives to what the bytes ask (device reports) reach the shell afterwards: ⌃C
        // clears them from its line before the next command.
        other.type("head -c 5000000 /dev/urandom; printf '\\033c'; stty sane; echo Rbinary$((1))\r")
        let done = await PerfWait.until(90000) { self.screen(other).contains("Rbinary1") }
        let held = log.pings(from: begin, to: perfNow()).max() ?? 0
        check("robust: 5 MB of random bytes: done", done != nil, done.map { String(format: "after %.0f ms", $0 - begin) } ?? "never ended; screen \(screen(other).suffix(3))")
        check("robust: 5 MB of random bytes: the window never hung", held < 1000, String(format: "main thread held at most %.0f ms", held))
        await PerfWait.sleep(500)
        other.type("\u{03}")
        if let tab = workspace.tabs.first(where: { $0.tree.contains(other.id) }) { workbench.select(tab: tab) }
        _ = await PerfWait.until(2000) { self.focused(other) }
        await terminalSane(other, "random bytes")
        workbench.close(pane: other.id)
        workbench.select(tab: shown)
        _ = await PerfWait.until(2000) { self.focused(pane) }
    }

    /// The editor: wide and composed text typed, a composition committed and one abandoned, then saved:
    /// the file holds exactly what was typed.
    private func editorInputMethodCheck(base: URL) async {
        let file = base.appendingPathComponent("wide.txt")
        try? Data("first line\n".utf8).write(to: file)
        workbench.open(file: file.path)
        _ = await PerfWait.until(5000) { self.codeView() != nil }
        guard let view = codeView() else { return check("robust: editor: the file opened", false) }
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        let none = NSRange(location: NSNotFound, length: 0)
        view.setMarkedText("へんかん", selectedRange: NSRange(location: 4, length: 0), replacementRange: none)
        let composing = view.hasMarkedText()
        view.insertText("変換", replacementRange: none)
        view.setMarkedText("やめる", selectedRange: NSRange(location: 3, length: 0), replacementRange: none)
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: none)
        view.unmarkText()
        view.insertText(" " + Self.wideText + "\n", replacementRange: none)
        let expected = "first line\n変換 " + Self.wideText + "\n"
        check("robust: editor: composing, committing, abandoning, wide text", composing && !view.hasMarkedText() && view.string == expected,
              "composing \(composing), text “\(view.string)”")
        shortcut("cmd+s")
        let saved = await PerfWait.until(5000) { (try? String(contentsOf: file, encoding: .utf8)) == expected }
        check("robust: editor: saved exactly as typed", saved != nil, "file “\((try? String(contentsOf: file, encoding: .utf8)) ?? "-")”")
        if let id = workbench.focusedPageID { workbench.close(page: id) }
    }

    /// A tab with a split and a file, closed: once its ⌘Z has run out, its panes, their terminal views and
    /// the editor are gone from memory (nothing keeps them: no retain cycle, no forgotten observer).
    private func closingLetsGoCheck() async {
        guard let watched = await closedTab() else { return check("robust: closing lets go: setup", false) }
        await PerfWait.sleep(Workbench.undoSeconds * 1000)
        // The terminals' connections close a moment after (`HostConnection.closeGrace`), and take the views' last references with them.
        _ = await PerfWait.until(10000) { !watched.contains { $0.alive() } }
        let left = watched.filter { $0.alive() }.map(\.name)
        check("robust: closing lets go: a closed tab's panes, terminal views and editor are freed once its undo runs out", left.isEmpty,
              left.isEmpty ? "all \(watched.count) freed" : "still alive: \(left.joined(separator: ", "))")
    }

    /// Makes a tab of two panes and a file, closes it, and returns what it held, weakly (no strong
    /// reference may outlive this function, or the check would keep them itself).
    private func closedTab() async -> [(name: String, alive: () -> Bool)]? {
        let base = URL(fileURLWithPath: folder("r2"), isDirectory: true)
        let file = base.appendingPathComponent("gone.txt")
        try? Data("a file to close\n".utf8).write(to: file)
        let first = workbench.newTab()
        _ = await shellReady(first)
        shortcut("cmd+d")
        guard let second = workbench.focusedPane, second !== first else { return nil }
        _ = await shellReady(second)
        workbench.open(file: file.path, mode: .beside)
        _ = await PerfWait.until(5000) { self.codeView() != nil }
        guard let tab = workbench.selectedTab, let editor = codeView() else { return nil }
        weak var weakFirst = first, weakSecond = second, firstView = first.surface, secondView = second.surface, weakEditor = editor
        workbench.close(tab: tab)
        return [("pane", { weakFirst != nil }), ("split pane", { weakSecond != nil }), ("terminal view", { firstView != nil }),
                ("split's terminal view", { secondView != nil }), ("editor", { weakEditor != nil })]
    }

    private func codeView() -> CodeTextView? {
        guard let content = window.contentView else { return nil }
        return DebugShell.descendant(of: content, where: { $0 is CodeTextView && !$0.isHiddenOrHasHiddenAncestor }) as? CodeTextView
    }

    /// The window resized 200 times in a row while the terminal floods, a split opened and closed every
    /// 25: nothing hangs, and once the flood ends every pane is sane.
    private func resizeStormCheck(_ pane: Pane) async {
        let original = window.contentView?.frame.size ?? NSSize(width: 1440, height: 900)
        pane.type("clear; yes 'a storm of lines, each long enough to wrap when the window is narrow enough to make it' | head -n 300000; echo Rstorm$((1))\r")
        await PerfWait.sleep(200)
        let begin = perfNow()
        var split: UUID?
        for step in 0..<200 {
            let width = 1000 + Double((step * 37) % 440), height = 640 + Double((step * 53) % 260)
            window.setContentSize(NSSize(width: width, height: height))
            window.contentView?.layoutSubtreeIfNeeded()
            if step % 25 == 12 {
                if let open = split {
                    workbench.close(pane: open)
                    split = nil
                } else {
                    workbench.focus(pane: pane.id)
                    shortcut("cmd+d")
                    split = workbench.focusedPane.flatMap { $0 !== pane ? $0.id : nil }
                }
            }
            await PerfWait.sleep(4)
        }
        window.setContentSize(original)
        let stormHeld = log.pings(from: begin, to: perfNow()).max() ?? 0
        check("robust: 200 resizes and splits while it floods: the window never hung", stormHeld < 1000, String(format: "main thread held at most %.0f ms", stormHeld))
        let done = await PerfWait.until(120000) { self.screen(pane).contains("Rstorm1") }
        check("robust: 200 resizes and splits while it floods: the flood ended", done != nil, "screen \(screen(pane).suffix(3))")
        await PerfWait.sleep(300)
        for each in workbench.selectedTab?.tree.panes.compactMap({ workbench.panes[$0] }) ?? [] {
            await terminalSane(each, each === pane ? "after the storm" : "after the storm, the split")
        }
        if let open = split { workbench.close(pane: open) }
    }

    /// The session host killed (as a crash would end it): every pane says calmly that its programs have
    /// ended, nothing crashes or hangs, and a new tab starts a new host and works.
    private func hostLostCheck() async {
        guard let host = MachineLoad.hostPID(log: Self.hostLog) else { return check("robust: host lost: the run's own host found", false) }
        let panes = Array(workbench.panes.values)
        let begin = perfNow()
        kill(host, SIGKILL)
        let ended = await PerfWait.until(10000) { panes.allSatisfy(\.exited) }
        let said = panes.allSatisfy { pane in self.screen(pane).contains { $0.contains("session host stopped") } }
        check("robust: host lost: every pane says its programs ended", !panes.isEmpty && ended != nil && said,
              "\(panes.filter(\.exited).count) of \(panes.count) ended, all said so \(said)")
        guard workbench.selectedWorkspace != nil else { return check("robust: host lost: a workspace is still shown", false) }
        let fresh = workbench.newTab()
        let ready = await shellReady(fresh, timeout: 15000)
        let held = log.pings(from: begin, to: perfNow()).max() ?? 0
        check("robust: host lost: a new tab starts a new host and its shell", ready && MachineLoad.hostPID(log: Self.hostLog).map { $0 != host } == true,
              "ready \(ready), host \(host) → \(MachineLoad.hostPID(log: Self.hostLog).map(String.init) ?? "none")")
        check("robust: host lost: the window never hung", held < 1000, String(format: "main thread held at most %.0f ms", held))
        if ready { await terminalSane(fresh, "the new host's terminal") }
    }
}

/// The counter behind `terminalSane`'s markers.
@MainActor private var sizeTick = 0

extension DebugScript {
    /// `--script` commands of this flow; true when `command` was one of them.
    ///   robust-state <file>      the whole model as a launch restored it: workspaces, tabs, trees, panes,
    ///                            pages, panels, the window layout and the theme (upgrade checks)
    ///   robust-soak <minutes>    the long run: 200 tabs opened and closed, 1,000 switches, then Claudes and
    ///                            helpers coming and going (hook events) with floods, for that long; prints
    ///                            the app's and the host's footprint along the way and “soak: done” at the end
    static func robustCommand(_ command: String, _ argument: String, _ workbench: Workbench, _ controller: MainWindowController) -> Bool {
        switch command {
        case "robust-state":
            write(RobustSoak.state(workbench, controller), to: argument)
        case "robust-soak":
            Task { await RobustSoak(workbench: workbench, controller: controller).run(minutes: Double(argument) ?? 30) }
        default:
            return false
        }
        return true
    }

    private static func write(_ lines: [String], to path: String) {
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
        print("  wrote \(lines.count) lines to \(path)")
    }
}

/// The long scripted session behind `robust-soak` (leaks and growth: run `leaks` on the process between
/// its phases, and compare the footprints it prints).
@MainActor
struct RobustSoak {
    let workbench: Workbench
    let controller: MainWindowController

    static func state(_ workbench: Workbench, _ controller: MainWindowController) -> [String] {
        var lines = ["window \(controller.layout)", "theme \(ThemeStore.shared.themeID) of \(ThemeStore.shared.themes.map(\.id).sorted())"]
        for workspace in workbench.workspaces {
            lines.append("workspace \(workspace.id) “\(workspace.name)” folder \(workspace.folder) colour \(workspace.colorIndex) selected-tab \(workspace.selectedTabID?.uuidString ?? "-") panel \(workbench.files.panels[workspace.id].map { "\($0)" } ?? "-")")
            for tab in workspace.tabs {
                lines.append("  tab \(tab.id) “\(tab.name ?? "")” focused \(tab.focusedPane) zoomed \(tab.zoomedPane?.uuidString ?? "-") tree \(tab.tree)")
                for id in tab.tree.panes {
                    if let pane = workbench.panes[id] {
                        lines.append("    pane \(id) folder \(pane.folder) session \(pane.sessionID ?? "-") exited \(pane.exited)")
                    } else {
                        lines.append("    page \(id) \(workbench.pages[id].map { "\($0)" } ?? "missing")")
                    }
                }
            }
        }
        return lines
    }

    private func say(_ text: String) {
        let host = MachineLoad.hostPID(log: PerfSuite.hostLog)
        print(String(format: "soak: %@; footprint app %.0f MB, host %.0f MB; %d panes, %d workspaces", text,
                     PerfSuite.footprint(getpid()) ?? -1, host.flatMap(PerfSuite.footprint) ?? -1, workbench.panes.count, workbench.workspaces.count))
        fflush(stdout)
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    func run(minutes: Double) async {
        let root = AppPlaces.supportFolder.appendingPathComponent("soak", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        say("start")
        // 200 tabs, ten at a time, each closed once its shell has started; the undo of a close runs out.
        let first = workbench.newWorkspace(folder: root.path)
        // Each closed pane and terminal view, held weakly: once the undo has run out, none may be left.
        var closed: [() -> Bool] = []
        for round in 0..<20 {
            var made: [Pane] = []
            for _ in 0..<10 { made.append(workbench.newTab()) }
            await pause(1.5)
            for pane in made {
                workbench.close(pane: pane.id)
                weak var gone = pane, view = pane.surface
                closed.append { gone != nil || view != nil }
            }
            if round % 5 == 4 { say("tabs \((round + 1) * 10) opened and closed") }
        }
        await pause(Workbench.undoSeconds + 3)
        say("200 tabs done, undo run out; \(closed.filter { $0() }.count) of \(closed.count) closed panes still in memory")
        // Three workspaces of three tabs, switched between 1,000 times.
        for index in 0..<3 {
            let folder = root.appendingPathComponent("w\(index)", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = workbench.newWorkspace(folder: folder.path)
            _ = workbench.newTab()
            _ = workbench.newTab()
        }
        for step in 0..<1000 {
            if step % 3 == 0 { workbench.selectWorkspace(offset: 1) } else { workbench.selectTab(offset: 1) }
            await pause(0.01)
        }
        say("1,000 switches done")
        // Claudes and helpers coming and going, with floods, for the rest of the time.
        let end = Date().addingTimeInterval(minutes * 60)
        var round = 0
        let connection = workbench.host.connect(HostConnection.Handlers())
        connection?.send(.hello(HostProtocol.current, client: "debug"))
        while Date() < end {
            round += 1
            let bosses = workbench.workspaces.compactMap { $0.selectedTab.flatMap { workbench.panes[$0.focusedPane] } }
            for (index, boss) in bosses.enumerated() {
                let session = "soak-\(round)-\(index)"
                let folder = boss.currentFolder
                func send(_ event: String, _ extra: [String: JSONValue] = [:], to pane: UUID = boss.id, session: String = session) {
                    var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string(session), "cwd": .string(folder)]
                    payload.merge(extra) { _, new in new }
                    workbench.monitor.simulate(paneID: pane, payload: .object(payload))
                }
                send("SessionStart")
                send("UserPromptSubmit", ["prompt": .string("round \(round)")])
                send("PreToolUse", ["tool_name": "Bash", "tool_use_id": .string("b\(round)"), "tool_input": ["command": "npm test"]])
                send("PostToolUse", ["tool_name": "Bash", "tool_use_id": .string("b\(round)")])
                if round % 3 == 0 { send("PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]) }
                // A helper that ends by itself a few seconds later.
                if index == 0, workbench.host.speaksAgents, let connection {
                    let helper = UUID(), round = round
                    connection.send(.run(RunRequest(terminal: helper, parent: boss.id, command: "sleep 4", task: nil, name: "helper \(round)",
                                                    directory: folder, background: true)))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
                            var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string("helper-\(round)"), "cwd": .string(folder)]
                            if event == "UserPromptSubmit" { payload["prompt"] = "look" }
                            workbench.monitor.simulate(paneID: helper, payload: .object(payload))
                        }
                    }
                }
                if round % 4 == index % 4 { boss.type("seq 1 200000\r") }
                send("Stop")
                if round % 2 == 0 { send("SessionEnd") }
            }
            await pause(2)
            if round % 15 == 0 { say("agents, round \(round)") }
        }
        withExtendedLifetime(connection) {}
        connection?.close()
        if let workspace = workbench.workspaces.first(where: { $0.tabs.contains { $0.tree.contains(first.id) } }) { workbench.close(workspace: workspace) }
        await pause(Workbench.undoSeconds + 3)
        say("done")
    }
}
#endif
