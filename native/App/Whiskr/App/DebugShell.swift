#if DEBUG
import AppKit
import MeadowScene
import SwiftUI
import WhiskrKit

/// Debug builds only: command-line steps for the window's own surfaces (workspaces, the Start page, the
/// palette, the answer card), so each can be looked at in a background snapshot. Run from
/// `DebugScenario.run`, after its own flags.
///
///   --new-workspaces <n> [--every <s>]   File › New Workspace (⌘N) n times, a moment apart
///   --palette commands|goto [--palette-query <text>] [--palette-after <s>]   shows the palette or Go to
///   --answer-card-after <s> opens the answer card for the first open request (with --demo)
///   --rename-workspace <name>  names the selected workspace
///   --meadow-keyboard       Go › Move Focus to Meadow
///   --measure-shell-after <s>  times the window's own work for closing, switching and opening tabs and
///                           workspaces, and prints it
///   --shell-snapshot <png> [--after <s>]   as --snapshot, with the palette or answer card drawn over it
@MainActor
enum DebugShell {
    private static func value(_ flag: String) -> String? { DebugScenario.value(flag) }
    private static func has(_ flag: String) -> Bool { DebugScenario.has(flag) }

    static func run(workbench: Workbench, window: MainWindowController) {
        if has("--launch-time") {
            // From the process starting to the window showing the restored workbench, and to the first frame drawn after.
            var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
            sysctl(&name, 4, &info, &size, nil, 0)
            let started = Double(info.kp_proc.p_starttime.tv_sec) + Double(info.kp_proc.p_starttime.tv_usec) / 1e6
            print(String(format: "launch: workbench ready after %.0f ms", (Date().timeIntervalSince1970 - started) * 1000))
            DispatchQueue.main.async {
                window.window?.displayIfNeeded()
                print(String(format: "launch: drawn after %.0f ms", (Date().timeIntervalSince1970 - started) * 1000))
                fflush(stdout)
            }
        }
        if let count = value("--new-workspaces").flatMap(Int.init) {
            let every = value("--every").flatMap(Double.init) ?? 0.4
            for step in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + every * Double(step)) {
                    // The window is in the background (never key), so the menu's action is sent to it directly.
                    window.newWorkspace(nil)
                }
            }
        }
        if let delay = value("--measure-shell-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { ShellTimings.run(workbench: workbench, window: window) }
        }
        if let mode = value("--palette") {
            let delay = value("--palette-after").flatMap(Double.init) ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                window.palette?.show(mode == "goto" ? .goTo : .commands, query: value("--palette-query") ?? "")
            }
        }
        if let delay = value("--answer-card-after").flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let pane = workbench.agentRows.first(where: { $0.status == .blocked && workbench.openRequest(pane: $0.id) != nil })?.id else {
                    return print("answer-card: no open request")
                }
                // Behind other windows the meadow draws no frames: it is settled first, so the card
                // points at the cat where the snapshot shows it.
                window.navigator.meadow.advance(seconds: 3)
                window.navigator.showAnswerCard(pane: pane)
            }
        }
        if let pane = value("--settings-shot"), let out = value("--settings-out") {
            // A settings pane drawn in a window that is never shown.
            let view: NSView = switch pane {
            case "alerts": NSHostingView(rootView: AlertSettings(preferences: .shared))
            case "terminal": NSHostingView(rootView: TerminalSettings(store: .shared))
            case "editor": NSHostingView(rootView: EditorSettings(preferences: .shared, theme: .shared))
            case "meadow": NSHostingView(rootView: WorldSettingsView(store: .shared))
            default: NSHostingView(rootView: GeneralSettings(preferences: .shared))
            }
            let offscreen = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 720, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
            offscreen.contentView = view
            if let appearance = value("--appearance") { offscreen.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                withExtendedLifetime(offscreen) {}
            }
        }
        if has("--hit-test-tab") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                // What a click lands on: the first tab's close button, then its title.
                guard let frame = window.window?.contentView?.superview,
                      let strip = descendant(of: frame, where: { $0 is NSHostingView<TabStrip> }),
                      let mouse = descendant(of: strip, where: { $0 is TabMouseView }) else { return print("hit-test: no tab") }
                let tab = mouse.convert(mouse.bounds, to: frame)
                for (name, x) in [("close button", tab.minX + 5 + 8), ("title", tab.midX)] {
                    let hit = frame.hitTest(NSPoint(x: x, y: tab.midY))
                    print("hit-test \(name): \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
                }
                // A mouse-down on the close button, delivered to what the click lands on, as AppKit would.
                let point = frame.convert(NSPoint(x: tab.minX + 13, y: tab.midY), to: nil)
                let before = workbench.selectedWorkspace?.tabs.count ?? 0
                let start = DispatchTime.now()
                if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.window?.windowNumber ?? 0,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    frame.hitTest(frame.convert(point, from: nil))?.mouseDown(with: event)
                }
                window.window?.displayIfNeeded()
                let after = workbench.selectedWorkspace?.tabs.count ?? 0
                print(String(format: "hit-test close: tabs %d → %d in %.2f ms", before, after,
                             Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6))
            }
        }
        if let name = value("--rename-workspace") { workbench.selectedWorkspace.map { workbench.rename(workspace: $0, to: name) } }
        if has("--meadow-keyboard") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { window.navigator.takeKeyboard() } }
        if let out = value("--shell-snapshot") {
            let after = value("--after").flatMap(Double.init) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                snapshot(window: window, workbench: workbench, to: URL(fileURLWithPath: out))
                NSApp.terminate(nil)
            }
        }
    }

    /// The window as `DebugScenario.snapshot` draws it, with what floats over it drawn on top: the
    /// palette, the answer card (their windows are children of the main one, or popovers).
    static func snapshot(window controller: MainWindowController, workbench: Workbench, to url: URL) {
        DebugScenario.snapshot(window: controller, workbench: workbench, to: url)
        guard let window = controller.window, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let base = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        var overlays = window.childWindows ?? []
        if let card = controller.navigator.answerCardWindow, !overlays.contains(card) { overlays.append(card) }
        print("overlays: \(overlays.map { "\(type(of: $0)) \($0.frame)" })")
        guard !overlays.isEmpty else { return }
        let scale = window.backingScaleFactor
        guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        for overlay in overlays {
            // A popover's glass is drawn by the window server, out of reach of a snapshot: its content only.
            let isPopover = overlay === controller.navigator.answerCardWindow
            guard let view = isPopover ? overlay.contentView : overlay.contentView?.superview ?? overlay.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let frame = isPopover ? overlay.convertToScreen(view.convert(view.bounds, to: nil)) : overlay.frame
            let x = (frame.minX - window.frame.minX) * scale, y = (frame.minY - window.frame.minY) * scale
            // A soft shadow, as the window server gives a floating panel.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 30 * scale, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            if let image = rep.cgImage { context.draw(image, in: CGRect(x: x, y: y, width: frame.width * scale, height: frame.height * scale)) }
            context.restoreGState()
        }
        if let image = context.makeImage() {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    static func descendant(of view: NSView, where test: (NSView) -> Bool) -> NSView? {
        if test(view) { return view }
        for child in view.subviews { if let found = descendant(of: child, where: test) { return found } }
        return nil
    }
}
#endif

#if DEBUG
/// How long the window's own work takes for each common action: the model change, then laying out and
/// drawing the window, all on the main thread, as a click would cost before the next frame.
@MainActor
enum ShellTimings {
    static func run(workbench: Workbench, window controller: MainWindowController) {
        guard let window = controller.window else { return }
        func time(_ name: String, _ action: () -> Void) {
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = DispatchTime.now()
                action()
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            }
            samples.sort()
            print(String(format: "timing %@: median %.2f ms, worst %.2f ms", name, samples[2], samples[4]))
        }
        // Enough to switch between: three workspaces, the last with four tabs.
        while workbench.workspaces.count < 3 { workbench.newWorkspace(folder: FileManager.default.homeDirectoryForCurrentUser.path) }
        while (workbench.selectedWorkspace?.tabs.count ?? 0) < 4 { workbench.newTab() }
        time("switch tab") { workbench.selectTab(offset: 1) }
        time("switch workspace") { workbench.selectWorkspace(offset: 1) }
        time("new tab") { workbench.newTab() }
        time("close tab") { if let tab = workbench.selectedTab { workbench.close(tab: tab) } }
        time("new workspace") { _ = workbench.newWorkspace(folder: FileManager.default.homeDirectoryForCurrentUser.path) }
        // A divider drag over a terminal with a full scrollback: each step resizes it (and reflows its lines).
        workbench.focusedPane?.type("seq 1 12000\r")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var width = 420.0
            time("divider step, 12000 lines, outside a drag") {
                width += 7
                controller.debugSetLayout { $0.dragDivider(to: width, window: Double(window.frame.width)) }
            }
            // As a real drag runs: the split view's tracking loop is a live resize.
            LiveResize.shared.begin()
            time("divider step, 12000 lines, during a drag") {
                width += 7
                controller.debugSetLayout { $0.dragDivider(to: width, window: Double(window.frame.width)) }
            }
            time("window resize step, 12000 lines, during a drag") {
                var frame = window.frame
                frame.size.width -= 9
                window.setFrame(frame, display: false)
            }
            var ended = false
            time("drag ends (the one resize), 12000 lines") {
                if !ended { LiveResize.shared.end(); ended = true } else { LiveResize.shared.begin(); LiveResize.shared.end() }
            }
            fflush(stdout)
        }
        fflush(stdout)
    }
}
#endif
