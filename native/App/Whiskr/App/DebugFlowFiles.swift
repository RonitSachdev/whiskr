#if DEBUG
import AppKit
import ObjectiveC
import WhiskrKit

/// `--perf-flows files` (`make perf`'s checks): files, the editor, diffs and Changes, find, links, ⌃Tab, the
/// palette and Go to, as a person uses them, on a scratch repository of every kind of file (Swift,
/// TypeScript, Python, Markdown with code and a picture, JSON, Japanese and emoji, a binary, an image,
/// compact folders, `app/[id]/page.tsx`, Windows line breaks, a last line without its line break).
/// Events go through the app's own event path, as `DebugInteractions` sends them (its helpers are shared);
/// what AppKit would only put on screen (a context menu, a sheet) is asked for, looked at and answered
/// in place, never shown: a background run orders every window transparent (`DebugScript.keepOutOfSight`).
/// Nothing leaves the app: Finder, the browser and the Trash are stand-ins here (`OutsideStandIn`).
extension PerfSuite {
    func filesCheck() async {
        HeldKeys.install()
        PointerStandIn.install()
        let trash = URL(fileURLWithPath: folder("files-trash"), isDirectory: true)
        OutsideStandIn.install(trash: trash)
        let root = URL(fileURLWithPath: folder("files-repo"), isDirectory: true)
        guard let fixture = FilesFixture(root: root, git: { self.git($0, in: root) }) else {
            return check("files: a scratch repository with every kind of file", false)
        }
        let shell = workbench.newWorkspace(folder: root.path)
        guard await shellReady(shell), let workspace = workbench.selectedWorkspace else { return check("files: the repository's shell drew its prompt", false) }
        let flow = FilesFlow(suite: self, fixture: fixture, workspace: workspace, shell: shell)
        await flow.opening()
        await flow.editing()
        await flow.markdown()
        await flow.editorBasics()
        await flow.filesPanel()
        await flow.changes()
        await flow.terminal()
        await flow.palette()
        HeldKeys.flags = nil
        PointerStandIn.location = nil
        check("files: nothing was handed to another app (Finder, the browser, the Trash) except as a stand-in",
              OutsideStandIn.unexpected.isEmpty, OutsideStandIn.unexpected.joined(separator: "; "))
        check("files: no sheet left open", window.attachedSheet == nil)
        OutsideStandIn.uninstall()
    }
}

extension DebugScript {
    /// `--script` commands of this flow; true when `command` was one of them.
    static func filesCommand(_ command: String, _ argument: String, _ workbench: Workbench, _ controller: MainWindowController) -> Bool { false }
}

/// The scratch repository: committed once, with everything a session opens, so each step has its file.
struct FilesFixture {
    let root: URL
    let git: ([String]) -> String?

    func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
    func path(_ relative: String) -> String { url(relative).path }

    /// 200 numbered lines of TypeScript-ish text: long enough to scroll, each line telling its number.
    static let longLines = (1...200).map { "export const line\($0) = \($0);" }

    init?(root: URL, git: @escaping ([String]) -> String?) {
        self.root = root
        self.git = git
        let files: [String: String] = [
            "Sources/App/main.swift": "import Foundation\n\nstruct Greeter {\n    let name: String\n\n    func greet() -> String {\n        \"Hello, \\(name)\"\n    }\n}\n\nprint(Greeter(name: \"cat\").greet())\n",
            "src/index.ts": Self.longLines.joined(separator: "\n") + "\n",
            "src/util.ts": "export function twice(x: number): number {\n  if (x > 0) {\n    return x * 2;\n  }\n  return 0;\n}\n",
            "tools/build.py": "import sys\n\n\ndef main():\n    for arg in sys.argv[1:]:\n        if arg:\n            print(arg)\n\n\nmain()\n",
            "README.md": """
                # Fixture

                Some *text* with `code`, a [link to util](src/util.ts) and [the web](https://example.com).

                ![logo](docs/logo.png)

                ```swift
                let cat = "black"
                ```

                ```ts
                const x: number = 1;
                ```

                ```python
                def f(): return 1
                ```

                ## Section

                - one
                - [x] done

                """,
            "config.json": "{\n  \"name\": \"fixture\",\n  \"count\": 3,\n  \"on\": true\n}\n",
            "notes/日本語.md": "# こんにちは 🐱\n\n猫がいます。👩‍👩‍👧 絵文字と日本語。\n",
            "deep/a/b/c/leaf.txt": "a leaf in a chain of folders\n",
            "app/[id]/page.tsx": "export default function Page() {\n  return <div>page</div>;\n}\n",
            "my file.ts": "// a name with a space\nexport const a = 1;\nexport const b = 2;\nexport const c = 3;\n",
            "multi.txt": (1...60).map { "line \($0)" }.joined(separator: "\n") + "\n",
            "windows.txt": (1...40).map { "row \($0)" }.joined(separator: "\r\n") + "\r\n",
            "nonl.txt": (1...10).map { "item \($0)" }.joined(separator: "\n"),
            "old-name.txt": (1...12).map { "kept \($0)" }.joined(separator: "\n") + "\n",
            "long/minified.js": "var a=" + String(repeating: "1+", count: 45_000) + "1;\nvar b = 2;\n",
        ]
        do {
            for (relative, text) in files {
                let url = root.appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
            try Self.png(color: .systemTeal).write(to: root.appendingPathComponent("docs/logo.png"))
            try Data([0, 1, 2, 3, 0, 255, 254, 0, 9]).write(to: root.appendingPathComponent("bin/blob.bin").creatingFolder())
        } catch {
            return nil
        }
        // Commits never ask for anything: no signing, no hooks, no daemon (the owner's own git settings stay
        // theirs; the repository's own settings come first).
        let hooks = root.deletingLastPathComponent().appendingPathComponent("files-no-hooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let settings = [("user.name", "Whiskr files check"), ("user.email", "files@example.invalid"), ("commit.gpgsign", "false"),
                        ("tag.gpgsign", "false"), ("core.hooksPath", hooks.path), ("core.fsmonitor", "false"), ("core.autocrlf", "false")]
        guard git(["init", "-q", "-b", "main"]) != nil, settings.allSatisfy({ git(["config", $0.0, $0.1]) != nil }),
              git(["add", "-A"]) != nil, git(["commit", "-q", "-m", "first"]) != nil else { return nil }
    }

    /// A small square picture.
    static func png(color: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

private extension URL {
    func creatingFolder() -> URL {
        try? FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

/// The files flow's steps, sharing the suite's events and checks.
@MainActor
final class FilesFlow {
    let suite: PerfSuite
    let fixture: FilesFixture
    let workspace: Workspace
    let shell: Pane
    var workbench: Workbench { suite.workbench }
    var controller: MainWindowController { suite.controller }
    var window: NSWindow { suite.window }

    init(suite: PerfSuite, fixture: FilesFixture, workspace: Workspace, shell: Pane) {
        self.suite = suite
        self.fixture = fixture
        self.workspace = workspace
        self.shell = shell
    }

    func check(_ name: String, _ passed: Bool, _ detail: String = "") { suite.check("files: " + name, passed, detail) }

    // MARK: Pages

    /// The view of a page by its id.
    func pageView(_ id: UUID?) -> NSView? { id.flatMap { controller.terminals.paneArea.pageView($0) } }

    /// The focused file page, when the focused page is a file.
    var filePage: FilePageView? { pageView(workbench.focusedPageID) as? FilePageView }

    var diffPage: DiffPageView? { pageView(workbench.focusedPageID) as? DiffPageView }

    /// The focused page is `relative`'s file, read and shown (its editor made, for text).
    func shown(_ relative: String) -> FilePageView? {
        guard let page = filePage, page.document.url.standardizedFileURL.path == fixture.url(relative).standardizedFileURL.path,
              page.document.content != .loading else { return nil }
        if page.document.isText, page.mode != .preview, page.editor == nil { return nil }
        return page
    }

    /// Opens a file as a person would from Go to (a tab of its own) and waits for it.
    @discardableResult
    func open(_ relative: String, line: Int? = nil) async -> FilePageView? {
        workbench.open(file: fixture.path(relative), mode: .keep, line: line)
        _ = await PerfWait.until(5000) { self.shown(relative) != nil }
        await PerfWait.sleep(150)
        return shown(relative)
    }

    /// The caret's line and column (1-based) in a page's editor.
    func place(_ page: FilePageView) -> (line: Int, column: Int)? {
        guard let text = page.editor?.textView else { return nil }
        let lines = page.document.lines
        let location = text.selectedRange().location
        let line = lines.line(at: location)
        return (line + 1, location - lines.starts[line] + 1)
    }

    /// The tab showing `relative`'s file (pages keep paths as `standardizedFileURL` writes them: `/tmp`,
    /// not `/private/tmp`).
    func tab(showing relative: String) -> Tab? {
        let page = TabPage.file(path: fixture.url(relative).standardizedFileURL.path)
        return workspace.tabs.first { $0.tree.panes.contains { workbench.pages[$0] == page } }
    }

    func text(_ page: FilePageView) -> String { page.document.storage.string }

    func disk(_ relative: String) -> String? { try? String(contentsOf: fixture.url(relative), encoding: .utf8) }

    func diskData(_ relative: String) -> Data? { try? Data(contentsOf: fixture.url(relative)) }

    func keyboardIn(_ view: NSView?) -> Bool {
        guard let view, let responder = window.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    var responderName: String { window.firstResponder.map { String(describing: type(of: $0)) } ?? "none" }

    /// The keyboard into a page's editor, as a click in it gives it.
    func focusEditor(_ page: FilePageView) async {
        guard let text = page.editor?.textView else { return }
        window.makeFirstResponder(text)
        _ = await PerfWait.until(1000) { self.window.firstResponder === text }
    }

    /// A key with modifiers through the app's whole event path.
    func press(_ characters: String, _ modifiers: NSEvent.ModifierFlags = [], code: UInt16 = 0, ignoring: String? = nil) {
        suite.press(characters, ignoring: ignoring, modifiers: modifiers, code: code)
    }

    static let returnKey = ("\r", UInt16(36)), escape = ("\u{1b}", UInt16(53)), backspace = ("\u{7f}", UInt16(51)), tab = ("\t", UInt16(48))

    /// An accessibility element (a SwiftUI button) of `view` by its label or title, pressed as VoiceOver
    /// presses it.
    @discardableResult
    func pressElement(_ name: String, in view: NSView) -> Bool {
        guard let element = DebugScript.accessibilityElement(in: view, named: name) ?? DebugScript.accessibilityElement(in: view.window?.contentView?.superview ?? view, named: name) else {
            var lines: [String] = []
            func walk(_ element: Any, _ depth: Int) {
                guard depth < 12, let element = element as? NSAccessibilityProtocol else { return }
                lines.append(String(repeating: " ", count: depth) + "\(element.accessibilityRole()?.rawValue ?? "?") “\(element.accessibilityLabel() ?? "")” “\(element.accessibilityTitle() ?? "")”")
                for child in element.accessibilityChildren() ?? [] { walk(child, depth + 1) }
            }
            walk(view, 0)
            print("files: nothing called “\(name)” to press; the page's accessibility: \(lines.prefix(40).joined(separator: " | "))")
            return false
        }
        return element.accessibilityPerformPress()
    }

    /// The sheet over the window, once one is there.
    func sheet() async -> NSWindow? {
        _ = await PerfWait.until(3000) { self.window.attachedSheet != nil }
        return window.attachedSheet
    }

    /// A sheet's buttons, in order.
    func buttons(of sheet: NSWindow) -> [NSButton] {
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let button = view as? NSButton, !button.title.isEmpty, button.bezelStyle != .disclosure { found.append(button) }
            view.subviews.forEach(walk)
        }
        if let content = sheet.contentView { walk(content) }
        return found.sorted { $0.frame.minX > $1.frame.minX || ($0.frame.minX == $1.frame.minX && $0.frame.minY > $1.frame.minY) }
    }

    /// Answers a sheet with the button titled `title`; true when there was one.
    @discardableResult
    func answer(_ sheet: NSWindow?, _ title: String) async -> Bool {
        guard let sheet, let button = buttons(of: sheet).first(where: { $0.title == title }) else { return false }
        button.performClick(nil)
        _ = await PerfWait.until(2000) { self.window.attachedSheet == nil }
        return true
    }

    func snapshot(_ name: String) {
        DebugShell.snapshot(window: controller, workbench: workbench, to: suite.root.appendingPathComponent("files-\(name).png"))
    }
}

/// What would leave the app in a person's session (Finder, the browser, another app, the Trash), caught:
/// the Trash is a folder of the run's own; anything else is noted as unexpected (no step here asks for it).
@MainActor
enum OutsideStandIn {
    nonisolated(unsafe) static var trash: URL?
    nonisolated(unsafe) static var unexpected: [String] = []
    nonisolated(unsafe) static var trashed: [URL] = []
    private static var installed = false
    private static let swaps: [(Selector, Selector)] = [
        (#selector(NSWorkspace.open(_:) as (NSWorkspace) -> (URL) -> Bool), #selector(NSWorkspace.debugOpen(_:))),
        (#selector(NSWorkspace.activateFileViewerSelecting(_:)), #selector(NSWorkspace.debugActivateFileViewerSelecting(_:))),
        (#selector(NSWorkspace.recycle(_:completionHandler:)), #selector(NSWorkspace.debugRecycle(_:completionHandler:))),
    ]

    static func install(trash: URL) {
        self.trash = trash
        guard !installed else { return }
        installed = true
        exchange()
    }

    static func uninstall() {
        guard installed else { return }
        installed = false
        exchange()
    }

    private static func exchange() {
        for (original, replacement) in swaps {
            guard let from = class_getInstanceMethod(NSWorkspace.self, original), let to = class_getInstanceMethod(NSWorkspace.self, replacement) else { continue }
            method_exchangeImplementations(from, to)
        }
    }
}

extension NSWorkspace {
    @objc func debugOpen(_ url: URL) -> Bool {
        OutsideStandIn.unexpected.append("open \(url.absoluteString)")
        return true
    }

    @objc func debugActivateFileViewerSelecting(_ urls: [URL]) {
        OutsideStandIn.unexpected.append("Finder \(urls.map(\.lastPathComponent))")
    }

    /// The run's own Trash: moved into a folder of the run, as the Finder would move it into its own.
    @objc func debugRecycle(_ urls: [URL], completionHandler: (@Sendable ([URL: URL], (any Error)?) -> Void)?) {
        var moved: [URL: URL] = [:]
        var failure: (any Error)?
        for url in urls {
            guard let trash = OutsideStandIn.trash else { break }
            let target = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: target)
                moved[url] = target
                OutsideStandIn.trashed.append(url)
            } catch {
                failure = error
            }
        }
        DispatchQueue.main.async { completionHandler?(moved, failure) }
    }
}
#endif
