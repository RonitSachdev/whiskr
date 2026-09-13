#if DEBUG
import AppKit
import os
@_spi(Diagnostics) import MeadowScene
import SwiftTerm
import WhiskrKit

/// Debug builds only: ways to run the app from the command line without disturbing anyone's screen or
/// state, for checks where clicking is not possible.
///
///   --isolated <folder>     settings and support files of its own (never the real app's)
///   --keep-settings         with --isolated: keeps the settings of the last run there (relaunch checks)
///   --background            never shows the window in front: it is ordered behind every other window
///   --demo <folder>         five workspaces in `<folder>` with shells, and Claude panes driven by real
///                           hook events through the real model: a request, an error, finished, working
///                           with three helpers (selected), idle
///   --demo-count <n>        with --demo: only the first n of those workspaces
///   --folder <path>         opens a workspace on that folder
///   --type-after <s> <text> types into the focused pane after that many seconds ("\r" is Return)
///   --new-tab-after <s>     opens a tab (⌘T) after that many seconds
///   --select <name>         selects that workspace
///   --helper                shows the story of the first helper of the selected workspace's Claude
///   --list                  the sidebar as a list
///   --terminals-only, --meadow-only   those forms of the window
///   --meadow-width <pt>     the meadow at that width, as if the divider were dragged there
///   --window <w>x<h>        the window's size
///   --time day|night        Settings › Meadow
///   --appearance light|dark the app's appearance for this run
///   --leave-host            with --isolated: quits leaving its terminals running in its session host (as
///                           ⌘Q does), for a later run with the same folder to find; a run without it
///                           ends them and the host
///   --terminals <file> [--terminals-after <s>]  writes what the session host holds and each pane's screen
///   --close-tab-after <s>   closes the selected tab after that many seconds and prints how long it took
///   --undo-close-after <s>  Edit › Undo Close Tab after that many seconds
///   --measure-echo <file> [--measure-echo-after <s>]  times keystroke-to-echo in the focused pane
///   --meadow-on-screen      the meadow draws as if on screen though the window is covered, and prints
///                           its timings once a second (frames drawn, GPU and main-thread time per frame)
///   --snapshot <png> [--after <seconds>] [--hold <seconds>]  draws the window (the meadow from the
///                           scene's own offscreen render) into a PNG, then quits
@MainActor
enum DebugScenario {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static func has(_ flag: String) -> Bool { arguments.contains(flag) }
    static func value(_ flag: String) -> String? {
        arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    /// Before anything reads settings: `--isolated`.
    static func prepareProcess() {
        if let folder = value("--isolated") {
            AppPlaces.isolate(in: URL(fileURLWithPath: folder, isDirectory: true), keepingSettings: has("--keep-settings"))
            exitQuietlyOnCrash()
            // `--debug-crash trap|segv|abort|overflow`: crashes on purpose once the app is up, to check
            // that an isolated run's crash ends quietly (exit 70, no report window, no crash report).
            if let kind = value("--debug-crash") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { crashOnPurpose(kind) }
            }
        }
    }

    /// An isolated run that crashes says so on stderr, with its stack, and exits with 70 rather than dying
    /// of the signal. A process that exits is not a crash to macOS: no "quit unexpectedly" window appears
    /// on the screen of whoever is working at this Mac, and no crash report is written. The handler runs on
    /// a stack of its own, so a stack overflow on the main thread is caught too.
    /// The crash handler's own stack, kept for the life of the process.
    nonisolated(unsafe) private static var crashStack: UnsafeMutableRawPointer?

    private static func exitQuietlyOnCrash() {
        _ = quietCrashFrames     // set aside now: the handler must not allocate
        let size = Int(SIGSTKSZ) * 4
        crashStack = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        var stack = stack_t(ss_sp: crashStack, ss_size: size, ss_flags: 0)
        sigaltstack(&stack, nil)
        var action = sigaction()
        action.__sigaction_u.__sa_handler = quietCrashHandler
        action.sa_flags = SA_ONSTACK
        for crash in [SIGTRAP, SIGILL, SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGSYS] {
            sigaction(crash, &action, nil)
        }
    }

    private static func crashOnPurpose(_ kind: String) {
        switch kind {
        case "segv": UnsafeMutablePointer<Int>(bitPattern: 8)!.pointee = 1
        case "abort": abort()
        case "overflow":
            func deeper(_ n: Int) -> Int { n == Int.min ? 0 : deeper(n &+ 1) &+ 1 }
            print(deeper(0))
        default: fatalError("crash on purpose (--debug-crash)")
        }
    }

    static var keepsInBackground: Bool { has("--background") }
    /// With --isolated: the run quits as ⌘Q does, leaving its terminals running in its own session
    /// host for the next run to find. Without it a test run ends everything it started.
    static var leavesHost: Bool { has("--leave-host") }

    /// After the workbench has launched and the window is up.
    static func run(workbench: Workbench, window: MainWindowController) {
        if let theme = value("--appearance") { ThemeStore.shared.appearance = theme == "dark" ? .dark : .light }
        if let time = value("--time") { WorldStore.shared.settings.timeOfDay = time == "night" ? .night : time == "day" ? .day : .followClock }
        if let size = value("--window")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window.window?.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        if has("--list") { window.debugSetLayout { $0.navigator = .list } }
        if has("--terminals-only") { window.debugSetLayout { $0.mode = .terminalsOnly } }
        if has("--meadow-only") { window.debugSetLayout { $0.mode = .meadowOnly } }
        if let width = value("--meadow-width").flatMap(Double.init) {
            window.debugSetLayout { $0.dragDivider(to: width, window: Double(window.window?.frame.width ?? 1440)) }
        }
        if let folder = value("--folder") { workbench.open(folder: folder) }
        var demo: Demo?
        if let folder = value("--demo") {
            demo = Demo(workbench: workbench, root: URL(fileURLWithPath: folder, isDirectory: true), count: value("--demo-count").flatMap(Int.init) ?? 5)
        }
        if let name = value("--select"), let workspace = workbench.workspaces.first(where: { $0.name == name }) {
            workbench.select(workspace: workspace)
        }
        if has("--helper"), let pane = demo?.helperBoss { workbench.selectPane(pane, agent: "h0") }
        for (position, argument) in arguments.enumerated() where argument == "--type-after" && arguments.count > position + 2 {
            let delay = Double(arguments[position + 1]) ?? 0
            let text = arguments[position + 2].replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1b}")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { workbench.focusedPane?.type(text) }
        }
        if let delay = value("--new-tab-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { workbench.newTab() }
        }
        if let delay = value("--close-tab-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Probe.closeTab(workbench: workbench) }
        }
        if let out = value("--measure-echo") {
            let delay = value("--measure-echo-after").flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Probe.echo(workbench: workbench, to: URL(fileURLWithPath: out)) }
        }
        if let out = value("--terminals") {
            let delay = value("--terminals-after").flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { Probe.terminals(workbench: workbench, to: URL(fileURLWithPath: out)) }
        }
        if let delay = value("--undo-close-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { workbench.undoClose() }
        }
        DebugFiles.run(workbench: workbench, window: window)
        DebugShell.run(workbench: workbench, window: window)
        DebugAgents.run(workbench: workbench, window: window, boss: demo?.helperBoss)
        DebugScript.run(workbench: workbench, window: window)
        DebugResize.run(workbench: workbench, window: window)
        DebugChurn.run(workbench: workbench, window: window)
        if has("--meadow-on-screen") {
            let meadow = window.navigator.meadow
            meadow.assumesOnScreen = true
            meadow.onTimings = { t in
                print(String(format: "meadow fps=%.1f target=%d gpu=%.2fms cpu=%.2fms", t.framesPerSecond, t.targetFramesPerSecond, t.gpuMilliseconds, t.cpuMilliseconds))
                fflush(stdout)
            }
        }
        if let out = value("--snapshot") {
            let after = value("--after").flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                snapshot(window: window, workbench: workbench, to: URL(fileURLWithPath: out))
                let hold = value("--hold").flatMap(Double.init) ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Snapshot

    /// The window as drawn by AppKit, with the meadow drawn by the scene's own offscreen renderer in its
    /// place (a Metal layer is not part of AppKit's drawing). Works while the window is behind others.
    static func snapshot(window controller: MainWindowController, workbench: Workbench, to url: URL) {
        guard let window = controller.window, let frameView = window.contentView?.superview else { return }
        let scale = window.backingScaleFactor
        let bounds = frameView.bounds
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let base = rep.cgImage,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // AppKit's drawing leaves out layer backgrounds (the terminals'): the theme's terminal colour underneath.
        frameView.effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(Colors.terminalBackground.cgColor)
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let meadow = controller.navigator.meadow
        if meadow.window === window, !meadow.isHiddenOrHasHiddenAncestor {
            if !window.occlusionState.contains(.visible) { meadow.advance(seconds: 3) }
            let rect = meadow.convert(meadow.bounds, to: frameView)
            if let image = meadow.renderImage(width: Int(rect.width * scale), height: Int(rect.height * scale)) {
                context.draw(image, in: CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
            }
            // What AppKit draws over the meadow (the first-run hint) goes back on top of it.
            for over in meadow.superview?.subviews ?? [] where over !== meadow && !over.isHidden && over.frame.intersects(meadow.frame) {
                guard let overRep = over.bitmapImageRepForCachingDisplay(in: over.bounds) else { continue }
                over.cacheDisplay(in: over.bounds, to: overRep)
                let box = over.convert(over.bounds, to: frameView)
                if let picture = overRep.cgImage {
                    context.draw(picture, in: CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale))
                }
            }
        }
        guard let image = context.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot \(url.lastPathComponent) title=\(window.title) size=\(window.frame.size) sidebar=\(controller.layout)")
        for workspace in workbench.workspaces {
            let panes = workspace.tabs.flatMap(\.tree.panes).compactMap { workbench.panes[$0] }
            print("  workspace \(workspace.name): tabs \(workspace.tabs.map { workbench.title(of: $0) }) panes \(panes.map { "\(workbench.name(of: $0))[\(workbench.status(of: $0).map { "\($0)" } ?? "shell")]" })")
        }
        fflush(stdout)
    }

    // MARK: Measurements

    /// Timings and facts that need the real app: how long closing a tab holds the main thread, how
    /// long a keystroke takes to come back as the terminal's echo, and what the session host holds.
    enum Probe {
        /// Closes the selected tab; prints how long the call took and the longest the main thread was
        /// held in the second after it.
        static func closeTab(workbench: Workbench) {
            guard let tab = workbench.selectedTab else { return }
            let start = DispatchTime.now()
            workbench.close(tab: tab)
            let call = milliseconds(since: start)
            Task { @MainActor in
                var last = DispatchTime.now(), worst = 0.0
                while milliseconds(since: start) < 1000 {
                    try? await Task.sleep(for: .milliseconds(2))
                    let now = DispatchTime.now()
                    worst = max(worst, Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1e6)
                    last = now
                }
                print(String(format: "close-tab call=%.2fms longest-main-thread-hold=%.2fms", call, worst))
                fflush(stdout)
            }
        }

        /// Types one character at a time into the focused pane (run `cat` in it first: the terminal
        /// itself echoes) and times each, from the main thread taking the key until its echo has been
        /// drawn into the terminal: main thread, host, pseudo-terminal and back. Writes the spread to `url`.
        static func echo(workbench: Workbench, to url: URL, samples: Int = 300) {
            guard let pane = workbench.focusedPane else { return }
            let arrived = DispatchSemaphore(value: 0)
            let typedAt = OSAllocatedUnfairLock(initialState: DispatchTime.now())
            pane.surface.setOutputHandler { arrived.signal() }
            DispatchQueue.global(qos: .userInitiated).async {
                var times: [Double] = []
                for _ in 0..<samples {
                    while arrived.wait(timeout: .now()) == .success {}
                    DispatchQueue.main.async {
                        typedAt.withLock { $0 = DispatchTime.now() }
                        pane.type("x")
                    }
                    guard arrived.wait(timeout: .now() + 2) == .success else { continue }
                    times.append(milliseconds(since: typedAt.withLock { $0 }))
                    usleep(5_000)
                }
                times.sort()
                let pick = { (part: Double) in times.isEmpty ? 0 : times[min(times.count - 1, Int(Double(times.count) * part))] }
                let line = String(format: "echo samples=%d median=%.3fms p95=%.3fms max=%.3fms\n", times.count, pick(0.5), pick(0.95), times.last ?? 0)
                try? Data(line.utf8).write(to: url)
            }
        }

        /// Writes what the session host holds (each terminal's process and foreground program) and what
        /// each pane shows (its screen's text), to check that a relaunch found everything as it was.
        static func terminals(workbench: Workbench, to url: URL) {
            Task {
                var lines: [String] = []
                for terminal in await workbench.host.terminals() {
                    lines.append("terminal \(terminal.id) pid \(terminal.pid) size \(terminal.size.columns)x\(terminal.size.rows) foreground \(terminal.status.foreground?.name ?? "-") foreground-pid \(terminal.status.foreground?.pid ?? 0) exited \(terminal.exited) closing \(terminal.closing)")
                }
                for pane in workbench.panes.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                    let rows = pane.surface.terminalDimensions.rows
                    lines.append("pane \(pane.id) claude \(pane.agentRunning) program \(pane.programName ?? "-") exited \(pane.exited) size \(pane.surface.terminalDimensions.cols)x\(rows) scroll \(pane.surface.scrollPosition) can-scroll \(pane.surface.canScroll)")
                    for (index, row) in pane.surface.visibleRowsText(0..<rows).enumerated() where !row.trimmingCharacters(in: .whitespaces).isEmpty {
                        lines.append(String(format: "  %2d| ", index) + row)
                    }
                }
                try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
            }
        }

        nonisolated private static func milliseconds(since start: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
        }
    }

    // MARK: Demo workbench

    /// Five workspaces with every state, driven by hook events through the same model as real Claude
    /// sessions; the panes are real shells pretending Claude is in front of them.
    final class Demo {
        let workbench: Workbench
        private(set) var helperBoss: UUID?
        private var sessionOf: [UUID: String] = [:]

        init(workbench: Workbench, root: URL, count: Int) {
            self.workbench = workbench
            // A request, with a dev server split beside it.
            let shop = claude(root, "shop-web")
            hook(shop, "UserPromptSubmit", [:])
            hook(shop, "PreToolUse", ["tool_name": "Bash", "tool_use_id": "b1", "tool_input": ["command": "npm test"]])
            hook(shop, "PermissionRequest", ["tool_name": "Bash", "tool_input": ["command": "npm test"]])
            workbench.split(.horizontal)
            workbench.focusedPane?.type("sleep 99999\r")
            workbench.focus(pane: shop)
            // An error.
            let api = claude(root, "api")
            hook(api, "UserPromptSubmit", [:])
            hook(api, "StopFailure", ["error": "rate_limit", "error_message": "Rate limited"])
            // Finished, not yet seen.
            let docs = claude(root, "docs")
            hook(docs, "UserPromptSubmit", [:])
            hook(docs, "Stop", [:])
            // Working, with three helpers.
            let auth = claude(root, "auth")
            hook(auth, "UserPromptSubmit", [:])
            for (index, kind) in ["Explore", "Explore", "general-purpose"].enumerated() {
                hook(auth, "PreToolUse", ["tool_name": "Agent", "tool_use_id": .string("t\(index)"), "tool_input": ["subagent_type": .string(kind), "description": "Map the old auth code"]])
                hook(auth, "SubagentStart", ["agent_id": .string("h\(index)"), "agent_type": .string(kind)])
                hook(auth, "PreToolUse", ["tool_name": "Grep", "tool_use_id": .string("g\(index)"), "agent_id": .string("h\(index)"), "tool_input": ["pattern": "getSession"]])
            }
            helperBoss = auth
            // Idle: finished and seen.
            if count > 4 {
                let dots = claude(root, "dotfiles")
                hook(dots, "UserPromptSubmit", [:])
                hook(dots, "Stop", [:])
                if let session = sessionOf[dots] { workbench.monitor.markSeen(sessionID: session) }
            }
            workbench.focus(pane: auth)
        }

        private func claude(_ root: URL, _ name: String) -> UUID {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let pane = workbench.newWorkspace(folder: folder.path)
            pane.debugPretendsClaude = true
            sessionOf[pane.id] = "demo-\(name)"
            return pane.id
        }

        private func hook(_ pane: UUID, _ event: String, _ extra: [String: JSONValue]) {
            var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string(sessionOf[pane] ?? "demo"),
                                                "cwd": .string(workbench.panes[pane]?.folder ?? "/")]
            payload.merge(extra) { _, new in new }
            workbench.monitor.simulate(paneID: pane, payload: .object(payload))
        }
    }
}

/// An isolated run's crash: says so and where, then exits with 70 (see `exitQuietlyOnCrash`). Nonisolated
/// on purpose: code isolated to the main actor gets a runtime check of the current executor, which must
/// never run inside a signal handler (a crash in that very check would recur here and hang). Only
/// async-signal-safe calls: no allocation, no Swift strings.
nonisolated private func quietCrashHandler(_ signal: Int32) {
    let note: StaticString = "isolated run crashed; its stack:\n"
    write(STDERR_FILENO, note.utf8Start, note.utf8CodeUnitCount)
    let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>(OpaquePointer(quietCrashFrames))
    backtrace_symbols_fd(frames, backtrace(frames, 64), STDERR_FILENO)
    _exit(70)
}

/// Room for the handler's backtrace, set aside before any crash (allocating in the handler is unsafe).
nonisolated(unsafe) private let quietCrashFrames = UnsafeMutableRawPointer.allocate(byteCount: 64 * MemoryLayout<UnsafeMutableRawPointer?>.stride,
                                                                                     alignment: MemoryLayout<UnsafeMutableRawPointer?>.alignment)
#endif
