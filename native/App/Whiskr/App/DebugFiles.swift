#if DEBUG
import AppKit
import WhiskrKit

/// Debug builds only: command-line steps for the files side (the panel, files, previews, diffs), so each
/// can be looked at in a background snapshot, and timings of what must never hitch. Run from
/// `DebugScenario.run` after the workspace flags.
///
///   --panel files|changes [--panel-width <pt>]   shows the side panel
///   --markdown source|preview|side    how Markdown opens       --diff-layout side|inline
///   --open-file <path[:line]>         opens a file in a tab of its own (may be given more than once)
///   --preview-file <path>             opens a file in the preview tab
///   --beside-file <path>              opens a file beside what has the keyboard
///   --diff <path> [--diff-staged]     opens a file's changes
///   --reveal <path>                   Reveal in Files
///   --commit-message <text>           writes the commit message
///   --type-in-editor <text> [--type-in-editor-after <s>]   types into the focused editor
///   --wrap on|off                     Editor › Wrap Lines
///   --go-to-line <n>[,<n>…] [--go-to-line-after <s>]   Go to Line in the focused editor, a second apart
///   --expand <relative folder>        opens a folder in the tree
///   --measure-files <report> --measure-file <big file> [--measure-folder <huge folder>]
///                                     times opening, tab switching, scrolling, typing and expanding
@MainActor
enum DebugFiles {
    private static func value(_ flag: String) -> String? { DebugScenario.value(flag) }
    private static func has(_ flag: String) -> Bool { DebugScenario.has(flag) }
    private static func values(_ flag: String) -> [String] {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.indices.filter { arguments[$0] == flag && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
    }

    static func run(workbench: Workbench, window: MainWindowController) {
        if let mode = value("--markdown") {
            EditorPreferences.shared.markdownMode = mode == "source" ? .source : mode == "side" ? .sideBySide : .preview
        }
        if let wrap = value("--wrap") { EditorPreferences.shared.wrapLines = wrap == "on" }
        if let lines = value("--go-to-line") {
            let delay = value("--go-to-line-after").flatMap(Double.init) ?? 2
            for (step, line) in lines.split(separator: ",").compactMap({ Int($0) }).enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double(step)) {
                    guard let page = workbench.focusedPageID, let view = window.terminals.paneArea.pageView(page) as? FilePageView else { return print("go-to-line: no editor") }
                    let start = DispatchTime.now()
                    view.editor?.textView.show(line: line)
                    window.window?.displayIfNeeded()
                    let took = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
                    print(String(format: "go-to-line %d: top line %d in %.1f ms", line, view.editor.map { $0.topLine + 1 } ?? 0, took))
                }
            }
        }
        if let layout = value("--diff-layout") { EditorPreferences.shared.diffLayout = layout == "inline" ? .inline : .sideBySide }
        if let mode = value("--panel"), let workspace = workbench.selectedWorkspace {
            workbench.files.setPanel(workspace.id) { panel in
                panel.shown = true
                panel.mode = mode == "changes" ? .changes : .files
                if let width = value("--panel-width").flatMap(Double.init) { panel.width = width }
            }
        }
        if let message = value("--commit-message") {
            // Once git has been found for the workspace.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { workbench.selectedRepository?.commitMessage = message }
        }
        for path in values("--open-file") {
            let location = FileLocation(path, folder: FileManager.default.currentDirectoryPath)
            workbench.open(file: location?.path ?? path, mode: .keep, line: location?.line)
        }
        for path in values("--preview-file") { workbench.open(file: path, mode: .preview) }
        for path in values("--beside-file") { workbench.open(file: path, mode: .beside) }
        if let path = value("--diff") { workbench.openChanges(path: path, staged: has("--diff-staged"), mode: .keep) }
        if let path = value("--reveal") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { workbench.revealInFiles(path: path) }
        }
        if let folder = value("--expand") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let repository = workbench.selectedRepository else { return }
                workbench.revealInFiles(path: repository.root.appendingPathComponent(folder).appendingPathComponent(".").path)
            }
        }
        if let text = value("--type-in-editor") {
            let delay = value("--type-in-editor-after").flatMap(Double.init) ?? 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let page = workbench.focusedPageID, let view = window.terminals.paneArea.pageView(page) as? FilePageView else { return }
                view.editor?.textView.insertText(text.replacingOccurrences(of: "\\n", with: "\n"), replacementRange: view.editor?.textView.selectedRange() ?? NSRange())
            }
        }
        if let report = value("--measure-files"), let file = value("--measure-file") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                Task { await Timings(workbench: workbench, window: window, report: URL(fileURLWithPath: report)).run(file: file, folder: value("--measure-folder")) }
            }
        }
    }

    /// Timings of the files side, each measured as the main thread sees it: the call, then the layout
    /// and drawing it causes, and the longest the main thread was held in the moments after.
    private struct Timings {
        let workbench: Workbench
        let window: MainWindowController
        let report: URL

        func run(file: String, folder: String?) async {
            var lines: [String] = []
            func note(_ line: String) {
                lines.append(line)
                print("files-timing " + line)
                fflush(stdout)
            }
            // Opening a large file: from the click to the text laid out and drawn.
            let started = DispatchTime.now()
            workbench.open(file: file, mode: .keep)
            guard let page = workbench.focusedPageID else { return note("no page") }
            var document: FileDocument?
            while milliseconds(since: started) < 10_000 {
                document = workbench.files.openDocument(file)
                if document?.content == .text, (window.terminals.paneArea.pageView(page) as? FilePageView)?.editor != nil { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            drawNow()
            note(String(format: "open %@ lines=%d total=%.1fms", (file as NSString).lastPathComponent, document?.lines.lineCount ?? 0, milliseconds(since: started)))
            try? await Task.sleep(for: .milliseconds(600))

            guard let view = window.terminals.paneArea.pageView(page) as? FilePageView, let editor = view.editor else { return note("no editor") }
            // Scrolling: a screenful at a time from top to bottom (and a jump to the end and back).
            let clip = editor.scrollView.contentView
            var steps: [Double] = []
            let screen = clip.bounds.height
            for step in 0..<240 {
                let begin = DispatchTime.now()
                clip.scroll(to: NSPoint(x: 0, y: CGFloat(step) * screen * 0.9))
                editor.scrollView.reflectScrolledClipView(clip)
                drawNow()
                steps.append(milliseconds(since: begin))
                await Task.yield()
            }
            note(summary("scroll-screenful", steps))
            var jumps: [Double] = []
            for target in [CGFloat.greatestFiniteMagnitude, 0, CGFloat.greatestFiniteMagnitude / 2, 0] {
                let begin = DispatchTime.now()
                let height = editor.textView.frame.height
                clip.scroll(to: NSPoint(x: 0, y: min(target, max(0, height - screen))))
                editor.scrollView.reflectScrolledClipView(clip)
                drawNow()
                jumps.append(milliseconds(since: begin))
                try? await Task.sleep(for: .milliseconds(100))
            }
            note(summary("scroll-jump", jumps))
            // Typing in the middle of the file: one character, laid out, coloured and drawn.
            editor.textView.show(line: (document?.lines.lineCount ?? 2) / 2)
            drawNow()
            var typing: [Double] = []
            for _ in 0..<60 {
                let begin = DispatchTime.now()
                editor.textView.insertText("x", replacementRange: editor.textView.selectedRange())
                drawNow()
                typing.append(milliseconds(since: begin))
                await Task.yield()
            }
            note(summary("type", typing))
            document?.undoManager.removeAllActions()
            document?.revert()
            try? await Task.sleep(for: .milliseconds(500))

            // Switching tabs between the big file and the terminal beside it, back and forth.
            if let workspace = workbench.selectedWorkspace, workspace.tabs.count > 1 {
                var switches: [Double] = []
                for index in 0..<20 {
                    let begin = DispatchTime.now()
                    workbench.select(tab: workspace.tabs[index % workspace.tabs.count])
                    window.window?.contentView?.layoutSubtreeIfNeeded()
                    drawNow()
                    switches.append(milliseconds(since: begin))
                    try? await Task.sleep(for: .milliseconds(30))
                }
                note(summary("switch-tab", switches))
            }

            // Expanding a folder of thousands of files in the tree: the main thread's longest hold.
            if let folder, let repository = workbench.selectedRepository, let workspace = workbench.selectedWorkspace {
                workbench.files.setPanel(workspace.id) { $0.shown = true; $0.mode = .files }
                try? await Task.sleep(for: .milliseconds(400))
                let begin = DispatchTime.now()
                let watch = HoldWatch()
                workbench.revealInFiles(path: repository.root.appendingPathComponent(folder).appendingPathComponent("zz-not-there").path)
                if let node = repository.node(for: folder) { window.terminals.sidePanel.fileTree?.outline.expandItem(node) }
                var loaded = false
                while milliseconds(since: begin) < 5_000 {
                    if let node = repository.node(for: folder), let children = node.children, !children.isEmpty, window.terminals.sidePanel.fileTree?.outline.isItemExpanded(node) == true {
                        loaded = true
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                drawNow()
                let shown = milliseconds(since: begin)
                let hold = await watch.finish(after: 300)
                let count = repository.node(for: folder)?.children?.count ?? 0
                note(String(format: "expand %@ files=%d shown=%.1fms loaded=%@ longest-main-thread-hold=%.1fms", folder, count, shown, loaded ? "yes" : "no", hold))
            }
            try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: report)
        }

        private func drawNow() {
            window.window?.contentView?.layoutSubtreeIfNeeded()
            window.window?.displayIfNeeded()
        }

        private func summary(_ name: String, _ samples: [Double]) -> String {
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { return "\(name) none" }
            let pick = { (part: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * part))] }
            return String(format: "%@ n=%d median=%.2fms p95=%.2fms max=%.2fms", name, sorted.count, pick(0.5), pick(0.95), sorted.last!)
        }
    }

    /// The longest gap between turns of the main run loop while it runs.
    @MainActor
    private final class HoldWatch {
        private var last = DispatchTime.now()
        private var worst = 0.0
        private var timer: Timer?

        init() {
            let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
                MainActor.assumeIsolated { [weak self] in self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func tick() {
            let now = DispatchTime.now()
            worst = max(worst, Double(now.uptimeNanoseconds - last.uptimeNanoseconds) / 1e6)
            last = now
        }

        func finish(after delay: Int) async -> Double {
            try? await Task.sleep(for: .milliseconds(delay))
            timer?.invalidate()
            return worst
        }
    }

    nonisolated private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }
}

private func milliseconds(since start: DispatchTime) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
}
#endif
