#if DEBUG
import AppKit
import SwiftTerm
import WhiskrKit

/// The terminal's side of files: find, command marks in zsh and bash, links, the right-click menu; then
/// the command palette. (`DebugInteractions` checks find's first steps, ⌘↑, ⇧⌘↑, ⌃Tab and the menu over
/// text and a path; this adds what it leaves out.)
extension FilesFlow {
    /// The shell's tab shown, its terminal with the keyboard.
    func showShell() async {
        workbench.focus(pane: shell.id)
        _ = await PerfWait.until(2000) { self.suite.focused(self.shell) }
    }

    /// Types a command and waits until a line reading exactly `until` is on screen.
    @discardableResult
    func run(_ command: String, until line: String, timeout: Double = 6000) async -> Bool {
        shell.type(command + "\r")
        let shown = await PerfWait.until(timeout) { self.suite.row(self.shell, showing: line) != nil } != nil
        // The next prompt drawn before anything more is typed (typed ahead, a command shows before its prompt).
        await PerfWait.sleep(400)
        return shown
    }

    /// The find bar's "n of 12": n, when it counts twelve.
    func findIndex(_ surface: TerminalSurface) -> Int? {
        guard let bar = surface.findBar, let label = DebugShell.descendant(of: bar, where: { ($0 as? NSTextField)?.isEditable == false }) as? NSTextField else { return nil }
        let parts = label.stringValue.split(separator: " ")
        return parts.count == 3 && parts[2] == "12" ? Int(parts[0]) : nil
    }

    // MARK: 5. Terminal

    func terminal() async {
        await showShell()
        let surface = shell.surface
        // Find: twelve matches, "n of 12", ⌘G and ⇧⌘G with the bar open, Esc gives the keyboard back.
        guard await run("clear; for i in $(seq 1 12); do printf 'F%sND %s\\n' Q $i; done", until: "FQND 12") else { return check("find: the text printed", false) }
        await PerfWait.sleep(200)
        suite.shortcut("cmd+f")
        _ = await PerfWait.until(1500) { surface.findBar?.hasKeyboard == true }
        suite.typeKeys("FQND")
        let counted = await PerfWait.until(2000) { self.findIndex(surface) != nil }
        check("find: typing shows “n of 12”", counted != nil, "count “\(surface.findBar.map { _ in findIndex(surface).map(String.init) ?? "-" } ?? "no bar")”")
        if let first = findIndex(surface) {
            suite.shortcut("cmd+g")
            let next = await PerfWait.until(1000) { self.findIndex(surface) == first % 12 + 1 }
            suite.shortcut("cmd+shift+g")
            let back = await PerfWait.until(1000) { self.findIndex(surface) == first }
            check("find: ⌘G steps to the next match, ⇧⌘G back, the keyboard in the bar", next != nil && back != nil && surface.findBar?.hasKeyboard == true,
                  "from \(first): next \(next != nil), back \(back != nil), now \(findIndex(surface).map(String.init) ?? "-")")
            // The same ⌘G as the app gets it from the window server (`NSApplication.sendEvent`).
            press("g", .command, code: 5)
            let viaApp = await PerfWait.until(1000) { self.findIndex(surface) == first % 12 + 1 }
            print("files: ⌘G through NSApp.sendEvent with the bar's field focused: stepped \(viaApp != nil), key window \(NSApp.keyWindow === window), keyboard in \(responderName)")
        }
        press(Self.escape.0, code: Self.escape.1)
        let closed = await PerfWait.until(1500) { !surface.isFindShown && self.window.firstResponder === surface }
        check("find: Esc closes the bar, the keyboard back in the terminal", closed != nil, "keyboard in \(responderName)")
        // ⌘E: the selection is what Find looks for; ⌘F then opens with it.
        surface.selectNone()
        if let row = suite.row(shell, showing: "FQND 7") {
            _ = suite.rightClickMenu(surface, at: suite.cellPoint(shell, row: row, column: 1))
            let selected = surface.getSelection()
            suite.shortcut("cmd+e")
            let taken = TerminalSurface.findPasteboardText
            suite.shortcut("cmd+f")
            _ = await PerfWait.until(1500) { surface.isFindShown }
            check("find: ⌘E takes the selection as the text to find; ⌘F opens with it", selected != nil && taken == selected && surface.findBar?.text == selected,
                  "selected “\(selected ?? "-")”, find text “\(taken ?? "-")”, bar “\(surface.findBar?.text ?? "-")”")
            press(Self.escape.0, code: Self.escape.1)
            _ = await PerfWait.until(1000) { !surface.isFindShown }
            surface.selectNone()
        }

        await marksCheck(surface)
        await bashCheck(surface)
        await linksCheck(surface)
    }

    /// ⌘↓ after ⌘↑, and ⇧⌘↓ after ⇧⌘↑ twice.
    private func marksCheck(_ surface: TerminalSurface) async {
        // `clear` alone first: a command after it on the same line would have its prompt wiped away.
        shell.type("clear\r")
        await PerfWait.sleep(400)
        await run("echo first-out", until: "first-out")
        await run("echo second-out", until: "second-out")
        await PerfWait.sleep(300)
        let lines = { (surface.getSelection() ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        suite.shortcut("cmd+shift+up")
        _ = await PerfWait.until(1000) { lines() == ["second-out"] }
        print("files: ⇧⌘↑ once: “\(lines())”, prompt kept \(surface.selectedCommandPrompt.map(String.init) ?? "none"), selection active \(surface.selectionActive)")
        suite.shortcut("cmd+shift+up")
        let earlier = await PerfWait.until(1000) { lines() == ["first-out"] }
        suite.shortcut("cmd+shift+down")
        let later = await PerfWait.until(1000) { lines() == ["second-out"] }
        let kinds = surface.reach?.locked { terminal, _ in
            (0..<min(12, terminal.rows + terminal.buffer.yDisp)).map { row -> String in
                let kind = terminal.semanticRowKind(at: row).map { "\($0)" } ?? "-"
                let text = terminal.bufferLine(atRow: row).map { terminal.getText(for: $0[0]) + terminal.getText(for: $0[1]) + terminal.getText(for: $0[2]) } ?? ""
                return "\(row):\(kind):\(text)"
            }
        } ?? []
        check("marks: ⇧⌘↑ twice selects the earlier output, ⇧⌘↓ the later one again", earlier != nil && later != nil, "now “\(lines())”, earlier \(earlier != nil); rows \(kinds)")
        surface.selectNone()
        await run("seq 1 200", until: "200")
        await run("seq 1 200", until: "200")
        await PerfWait.sleep(300)
        suite.shortcut("cmd+up")
        suite.shortcut("cmd+up")
        await PerfWait.sleep(200)
        let up = suite.topRow(shell)
        suite.shortcut("cmd+down")
        await PerfWait.sleep(200)
        let down = suite.topRow(shell)
        check("marks: ⌘↓ after ⌘↑ goes forward to the next prompt", (up ?? 0) < (down ?? 0), "top row after ⌘↑⌘↑ \(up.map(String.init) ?? "-"), after ⌘↓ \(down.map(String.init) ?? "-")")
        surface.scroll(toPosition: 1)
        await run("clear", until: "")
    }

    /// bash with Whiskr's integration (its prompt command, as a pane whose shell is bash gets it): its prompts
    /// are marked, so ⇧⌘↑ selects what a command printed. And the integration scripts parse.
    private func bashCheck(_ surface: TerminalSurface) async {
        let shellFolder = AppPlaces.supportFolder.appendingPathComponent("shell", isDirectory: true)
        let integration = ShellIntegration(folder: shellFolder)
        let environment = integration.environment(ProcessInfo.processInfo.environment, shell: "/bin/bash", paneID: shell.id.uuidString, hooksFile: nil)
        guard let command = environment["PROMPT_COMMAND"] else { return check("bash: the integration has a prompt command", false) }
        let rc = URL(fileURLWithPath: suite.folder("files-bash")).appendingPathComponent("rc.bash")
        try? Data("PS1='bash$ '\nPROMPT_COMMAND=\(ShellQuote.quote(command))\n".utf8).write(to: rc)
        guard await run("clear; /bin/bash --noprofile --rcfile \(ShellQuote.quote(rc.path)) -i", until: "bash$") else { return check("bash: started", false) }
        await run("echo bash-out", until: "bash-out")
        await PerfWait.sleep(400)
        suite.shortcut("cmd+shift+up")
        let selected = await PerfWait.until(1500) { surface.getSelection()?.trimmingCharacters(in: .whitespacesAndNewlines) == "bash-out" }
        check("bash: prompts are marked (OSC 133), so ⇧⌘↑ selects what a command printed", selected != nil, "selected “\(surface.getSelection() ?? "nothing")”")
        surface.selectNone()
        shell.type("exit\r")
        await PerfWait.sleep(500)
        // The scripts as installed: bash and zsh parse them; fish is checked where it is installed.
        var parsed: [String] = []
        for (shellPath, file) in [("/bin/bash", "bash/whiskr.bash"), ("/bin/zsh", "zsh/.zshenv")] {
            let url = shellFolder.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { parsed.append("\(file) missing"); continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shellPath)
            process.arguments = ["-n", url.path]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            parsed.append("\(file) \(process.terminationStatus == 0 ? "ok" : "status \(process.terminationStatus)")")
        }
        let fish = ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) }
        check("shells: the bash and zsh integration scripts parse (`-n`)", parsed.allSatisfy { $0.hasSuffix(" ok") }, "\(parsed); fish \(fish ?? "not installed: not checked")")
    }

    /// ⌘-click on each form a path is printed in opens the file at its line; ⌘ over a path that does not
    /// exist underlines nothing; the menu over a web link.
    private func linksCheck(_ surface: TerminalSurface) async {
        let forms: [(printed: String, file: String, line: Int, column: Int)] = [
            ("src/util.ts:3:5", "src/util.ts", 3, 5),
            ("src/util.ts(4,3)", "src/util.ts", 4, 3),
            ("  File \"tools/build.py\", line 5, in main", "tools/build.py", 5, 1),
            ("--- a/src/index.ts", "src/index.ts", 1, 1),
            ("+++ b/Sources/App/main.swift", "Sources/App/main.swift", 1, 1),
            ("at \"my file.ts\":3", "my file.ts", 3, 1),
            ("app/[id]/page.tsx:2", "app/[id]/page.tsx", 2, 1),
        ]
        let printed = forms.map(\.printed) + ["missing.ts:3", "see https://example.com/docs now"]
        let quoted = printed.map { "printf '%s\\n' \(ShellQuote.quote($0))" }.joined(separator: "; ")
        guard await run("clear; " + quoted, until: "see https://example.com/docs now") else { return check("links: the lines printed", false) }
        await PerfWait.sleep(300)
        for form in forms {
            await showShell()
            guard let row = suite.row(shell, showing: form.printed.trimmingCharacters(in: .whitespaces)) else { check("links: “\(form.printed)” on screen", false); continue }
            // The middle of the path itself (past any leading words).
            let text = form.printed.trimmingCharacters(in: .whitespaces)
            let offset = (text as NSString).range(of: (form.file as NSString).lastPathComponent).location
            let column = (suite.drawnRows(shell)[row].count - suite.drawnRows(shell)[row].drop { $0 == " " }.count) + max(0, offset) + 1
            let point = suite.cellPoint(shell, row: row, column: column)
            await suite.hover(surface, at: point)
            suite.hold(.command, code: 55)
            let underlined = await PerfWait.until(1000) { surface.linkUnderline?.isHidden == false }
            suite.hold([], code: 55)
            suite.commandClick(surface, at: point)
            // A path without a line shows the file where it was; one with a line goes there.
            let lineGiven = form.printed.contains(":\(form.line)") || form.printed.contains("(\(form.line)") || form.printed.contains("line \(form.line)")
            let opened = await PerfWait.until(3000) { self.shown(form.file).flatMap(self.place).map { !lineGiven || ($0.line == form.line && $0.column == form.column) } ?? false }
            check("links: ⌘ underlines and ⌘-click opens “\(form.printed.trimmingCharacters(in: .whitespaces))” at \(form.line):\(form.column)", underlined != nil && opened != nil,
                  "underlined \(underlined != nil), editor \(shown(form.file).flatMap(place).map { "\($0.line):\($0.column)" } ?? "not on \(form.file)"), page \(workbench.focusedPage?.path.split(separator: "/").suffix(2).joined(separator: "/") ?? "none")")
        }
        await showShell()
        if let row = suite.row(shell, showing: "missing.ts:3") {
            await suite.hover(surface, at: suite.cellPoint(shell, row: row, column: 3))
            suite.hold(.command, code: 55)
            await PerfWait.sleep(400)
            let underlined = surface.linkUnderline?.isHidden == false
            suite.hold([], code: 55)
            check("links: ⌘ over a path that does not exist underlines nothing", !underlined)
        }
        if let row = suite.row(shell, showing: "see https://example.com/docs now") {
            surface.selectNone()
            let menu = suite.rightClickMenu(surface, at: suite.cellPoint(shell, row: row, column: 10))
            let titles = menu.map(suite.titles) ?? []
            check("right-click over a web link starts with Open Link, Copy Link", Array(titles.prefix(3)) == [String(localized: "Open Link", comment: "Terminal menu: opens a web link in the browser"), String(localized: "Copy Link", comment: "Terminal menu"), "—"],
                  titles.joined(separator: " · "))
            if let copy = menu?.items.dropFirst().first, let action = copy.action {
                NSApp.sendAction(action, to: copy.target, from: copy)
                check("right-click: Copy Link copies it", NSPasteboard.general.string(forType: .string) == "https://example.com/docs", "clipboard “\(NSPasteboard.general.string(forType: .string) ?? "-")”")
            }
            surface.selectNone()
        }
    }

    // MARK: 6. The command palette

    func palette() async {
        // From an editor: the editor's commands are offered; from a terminal they are not.
        guard let page = await open("src/util.ts") else { return check("palette: an editor to start from", false) }
        await focusEditor(page)
        suite.shortcut("cmd+shift+p")
        guard await PerfWait.until(2000, { self.paletteModel != nil }) != nil, let model = paletteModel else { return check("palette: ⇧⌘P opens it", false) }
        let titles = { (query: String) -> [String] in
            model.query = query
            return model.rows.map(\.entry.title)
        }
        print("files: palette from an editor: main window is the app's \(NSApp.mainWindow === window), key \(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "none"); Toggle Comment listed \(titles(String(localized: "Toggle Comment")).contains(String(localized: "Toggle Comment")))")
        typeInPalette("\u{1b}")
        _ = await PerfWait.until(1000) { self.paletteModel == nil }
        check("palette: Esc closes it, the keyboard back where it was", paletteModel == nil && window.firstResponder === page.editor?.textView, "keyboard in \(responderName)")
        await showShell()
        suite.shortcut("cmd+shift+p")
        guard await PerfWait.until(2000, { self.paletteModel != nil }) != nil else { return }
        // ⌘. cancels as Esc does.
        if let panel = controller.palette?.panelForSnapshot, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime,
                                                                                          windowNumber: panel.windowNumber, context: nil, characters: ".", charactersIgnoringModifiers: ".", isARepeat: false, keyCode: 47) {
            panel.sendEvent(event)
        }
        let cancelled = await PerfWait.until(1000) { self.paletteModel == nil }
        check("palette: ⌘. cancels it", cancelled != nil, "open \(paletteModel != nil)")
        if paletteModel != nil { controller.palette?.close() }

        // Every command it lists is enabled where it is chosen, and the everyday ones do what they say.
        suite.shortcut("cmd+shift+p")
        guard await PerfWait.until(2000, { self.paletteModel != nil }) != nil, let all = paletteModel else { return }
        var disabled: [String] = []
        for (_, value) in Self.actions(of: all) {
            guard case .command(let item, let target) = value, let target, let action = item.action else { continue }
            let enabled = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? (target as? NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? target.responds(to: action)
            if !enabled { disabled.append(item.title) }
        }
        check("palette: every listed command is enabled where it is chosen", disabled.isEmpty && Self.actions(of: all).count > 20, "\(Self.actions(of: all).count) entries, disabled \(disabled)")
        let panes = workbench.selectedTab?.tree.panes.count ?? 0
        all.query = String(localized: "Split Right")
        all.choose()
        let split = await PerfWait.until(2000) { (self.workbench.selectedTab?.tree.panes.count ?? 0) == panes + 1 }
        check("palette: choosing Split Right splits the pane", split != nil && paletteModel == nil)
        if split != nil { suite.shortcut("cmd+w") }

        // Go to's ranking: a name finds its file first.
        var ranked: [String: String] = [:]
        for (query, expected) in [("util", "util.ts"), ("page", "page.tsx"), ("main.sw", "main.swift"), ("readme", "README.md"), ("日本", "日本語.md")] {
            suite.shortcut("cmd+p")
            guard await PerfWait.until(2000, { self.paletteModel != nil }) != nil, let goTo = paletteModel else { continue }
            goTo.query = query
            _ = await PerfWait.until(3000) { goTo.rows.contains { $0.entry.kind == .file && $0.entry.title == expected } }
            ranked[query] = goTo.rows.first { $0.entry.kind == .file }?.entry.title
            controller.palette?.close()
        }
        check("Go to: a file's name finds it first among the files", ranked == ["util": "util.ts", "page": "page.tsx", "main.sw": "main.swift", "readme": "README.md", "日本": "日本語.md"], "\(ranked)")
    }

    /// The overlay's every entry and what choosing it does (its model's own list).
    static func actions(of model: PaletteModel) -> [String: PaletteModel.Action] {
        for child in Mirror(reflecting: model).children where child.label == "actions" || child.label == "_actions" {
            if let actions = child.value as? [String: PaletteModel.Action] { return actions }
        }
        return [:]
    }
}
#endif
