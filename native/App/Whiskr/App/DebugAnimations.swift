#if DEBUG
import AppKit
import QuartzCore
import SwiftUI
import WhiskrKit

/// `motion` (one of `make perf`'s measurements, `--perf-flows motion`): how the interface's own transitions
/// reach the screen (docs/DESIGN.md, "Motion of the interface"). Each is set off as a person would (a key,
/// a click where the window delivers it), and the part of the window it moves is watched at every refresh
/// of the display (`FramePacing`): what it showed at that refresh, read from Core Animation's presentation
/// layers, the state a frame is drawn from. Reported for each: how long after the action the picture
/// first changed, how long it moved, how many refreshes showed a new picture, how many it skipped
/// between its first and its last (a dropped frame), its longest frame, and the main thread's longest
/// hold meanwhile (the `MainPinger` the measurements share). A transition carried by Core Animation
/// itself (an animation on a layer) moves in the render server: every refresh it spans counts as drawn,
/// whatever the main thread is doing. One carried by the main thread (SwiftUI's own frames, a layout per
/// frame) shows only the refreshes the main thread answered.
///
/// It also checks what the motion must never cost: the action itself happens at once (a closed tab is out
/// of the row's reach in the same turn, the next click at the same point reaches the tab now there; Go
/// to's field takes a key typed straight after ⌘P; Esc closes Go to while it is still coming in; the find
/// bar has the keyboard at once).
///
///   --motion-trace               prints every refresh each transition was watched over (* a new picture,
///                                a animating)
///   --motion-snapshots <folder>  writes the window a third, two thirds and all the way through each first
///                                transition, from the presentation layers (the run's own timings suffer)
///
/// Before this check the window had no motion to speak of: a tab, Go to, the ⌃Tab list, a note, the find
/// bar and Home each changed in one frame (a jump, which `make perf` timed as fast and so passed). The
/// limits here fail a jump where the design says something moves (with Reduce Motion on, fades and
/// stillness are what is asked, and the limits on moving are not applied).
extension PerfSuite {
    func motion() async {
        HeldKeys.install()
        PointerStandIn.install()
        defer {
            HeldKeys.flags = nil
            PointerStandIn.location = nil
        }
        let pacing = FramePacing(log: log)
        guard await pacing.ticks() else { return note("motion", "the display's refresh never ticked: nothing measured") }
        let moves = Look.Motion.moves
        print("motion: display refresh \(String(format: "%.1f", 1000 / pacing.period)) Hz; Reduce Motion \(moves ? "off" : "on")")
        let first = workbench.newWorkspace(folder: folder("motion"))
        guard await shellReady(first) else { return check("motion: a shell to start from", false) }
        _ = workbench.newTab()
        await PerfWait.sleep(600)
        guard let workspace = workbench.selectedWorkspace, let row = controller.terminals.tabRow else { return }
        let tabRow = { [row] in [row.layer].compactMap { $0 } }
        var results: [FramePacing.Result] = []

        // Tabs: open (⌘T), choose (a click on a title), close (a click on ×), reorder (a drop), run out of room.
        for round in 0..<3 {
            results.append(await pacing.measure("tab open", round: round, watch: tabRow) { self.shortcut("cmd+t") })
        }
        var hoveredTabs: [Int] = []
        for round in 0..<3 {
            guard let view = tabViews.first(where: { $0.tab != workspace.selectedTab?.id }) else {
                print("motion: tab select: no tab to choose (\(workspace.tabs.count) tabs, \(tabViews.count) in sight)")
                break
            }
            await hover(view, at: NSPoint(x: view.bounds.width * 0.4, y: view.bounds.midY))
            hoveredTabs.append(tabViews.filter(\.debugIsHovered).count)
            results.append(await pacing.measure("tab select", round: round, watch: tabRow) { self.click(view, at: NSPoint(x: view.bounds.width * 0.4, y: view.bounds.midY)) })
        }
        check("motion: the pointer on a tab hovers that tab alone", hoveredTabs.allSatisfy { $0 == 1 }, "tabs hovered each time \(hoveredTabs)")
        let ghosts = Notes(), unhovered = Notes()
        for round in 0..<3 {
            guard workspace.tabs.count > 2, let target = workspace.tabs.dropFirst().first, let view = tabView(target) else { break }
            let point = view.closePoint
            let location = view.convert(point, to: nil)
            await hover(view, at: point)
            results.append(await pacing.measure("tab close", round: round, watch: tabRow) {
                self.click(view, at: point)
                // The next click at the same place, a frame later: it must reach a tab still open, never the
                // one just closed (which would take it and do nothing).
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(12))
                    guard let frame = self.window.contentView?.superview else { return }
                    let under = frame.hitTest(frame.convert(location, from: nil))
                    let tab = (under as? TabMouseView)?.tab
                    if workspace.tabs.contains(where: { $0.id == tab }) == false {
                        ghosts.lines.append("round \(round): \(tab == target.id ? "the closed tab" : under.map { String(describing: type(of: $0)) } ?? "nothing")")
                    } else if let view = under as? TabMouseView, !view.debugIsHovered {
                        unhovered.lines.append("round \(round)")
                    }
                }
            })
            _ = workbench.newTab()
            await PerfWait.sleep(400)
        }
        for round in 0..<3 {
            guard workspace.tabs.count > 2 else { break }
            results.append(await pacing.measure("tab reorder", round: round, watch: tabRow) {
                self.workbench.move(tab: workspace.tabs[0], toIndex: workspace.tabs.count)
            })
        }
        // More tabs than fit: the one that makes the list's chevron appear, then a tab out of sight chosen.
        var overflowed = false
        for _ in 0..<24 {
            let result = await pacing.measure("tab overflow", round: 0, watch: tabRow, quiet: true) { self.shortcut("cmd+t") }
            if tabViews.count < workspace.tabs.count {
                results.append(result)
                overflowed = true
                break
            }
        }
        if overflowed, let hidden = workspace.tabs.first(where: { tab in !tabViews.contains { $0.tab == tab.id } }) {
            results.append(await pacing.measure("tab run shifts", round: 0, watch: tabRow) { self.workbench.select(tab: hidden) })
        }
        while workspace.tabs.count > 3, let last = workspace.tabs.last { workbench.close(tab: last) }
        await PerfWait.sleep(500)

        // Go to (⌘P) and the command palette: in, the list changing (">"), and out (Esc).
        var lastPanel: NSWindow?
        let palette = { [weak self] () -> [CALayer] in
            let panel = self?.controller.palette?.panelForSnapshot ?? lastPanel
            if let shown = self?.controller.palette?.panelForSnapshot { lastPanel = shown }
            // Taken off the window (its old way out, at once): nothing to watch, which is itself a change.
            guard let panel, panel.parent != nil else { return [] }
            return [panel.contentView?.superview?.layer ?? panel.contentView?.layer].compactMap { $0 }
        }
        var typedAtOnce: [Bool] = []
        var escapedEarly: [Bool] = []
        for round in 0..<3 {
            lastPanel = nil
            results.append(await pacing.measure("Go to in", round: round, watch: palette, depth: 4) {
                self.shortcut("cmd+p")
                // Typed in the same turn as ⌘P: the field must already have the keyboard.
                self.typeInOverlay("q")
            })
            typedAtOnce.append(paletteModel?.query == "q")
            // The letter taken back: the list of recent places in place of "Nothing matches.", growing.
            results.append(await pacing.measure("Go to list changes", round: round, watch: palette) { self.typeInOverlay("\u{7f}") })
            results.append(await pacing.measure("Go to out", round: round, watch: palette, depth: 4) { self.typeInOverlay("\u{1b}") })
            if paletteModel != nil { controller.palette?.close() }
            await PerfWait.sleep(200)
            // Esc while it is still coming in.
            shortcut("cmd+p")
            await PerfWait.sleep(40)
            typeInOverlay("\u{1b}")
            escapedEarly.append(paletteModel == nil)
            if paletteModel != nil { controller.palette?.close() }
            await PerfWait.sleep(300)
        }
        check("motion: a key typed straight after ⌘P reaches Go to's field", typedAtOnce.allSatisfy { $0 }, "\(typedAtOnce)")
        check("motion: Esc closes Go to while it is still coming in", escapedEarly.allSatisfy { $0 }, "\(escapedEarly)")

        // ⌃Tab held: the list of recent tabs, in and out.
        if let switcher = controller.tabSwitcher {
            let list = { [weak self] () -> [CALayer] in
                guard let content = self?.window.contentView else { return [] }
                return content.subviews.filter { $0 is NSHostingView<TabSwitcherList> }.compactMap(\.layer)
            }
            for round in 0..<2 {
                hold(.control, code: 59)
                await controlTabDown()
                results.append(await pacing.measure("⌃Tab list in", round: round, watch: list, settle: 450) {})
                results.append(await pacing.measure("⌃Tab list out", round: round, watch: list) { self.hold([], code: 59) })
                if switcher.isActive { hold([], code: 59) }
                await PerfWait.sleep(250)
            }
        }

        // Find in a terminal (⌘F, Esc).
        if let pane = workbench.focusedPane {
            let bar = { [weak pane] () -> [CALayer] in [pane?.surface.findBar?.layer].compactMap { $0 } }
            var keyboard: [Bool] = []
            for round in 0..<3 {
                results.append(await pacing.measure("find bar in", round: round, watch: bar, depth: 0) {
                    self.shortcut("cmd+f")
                    keyboard.append(pane.surface.findBar?.hasKeyboard == true)
                })
                results.append(await pacing.measure("find bar out", round: round, watch: bar, depth: 0) { self.shortcut("esc") })
                if pane.surface.isFindShown { pane.surface.hideFind() }
            }
            check("motion: the find bar has the keyboard in the turn ⌘F was pressed", keyboard.allSatisfy { $0 }, "\(keyboard)")
        }

        // Home and back; Home's note coming and going.
        let region = { [weak self] () -> [CALayer] in [self?.controller.terminals.view.layer].compactMap { $0 } }
        let home = { [weak self] () -> [CALayer] in [self?.controller.terminals.home.layer].compactMap { $0 } }
        for round in 0..<2 {
            results.append(await pacing.measure("Home in", round: round, watch: region, depth: 1) { self.shortcut("cmd+shift+h") })
            results.append(await pacing.measure("Home note in", round: round, watch: home) { self.workbench.launchNotice = HostNotice(terminals: 3, withheld: 0) })
            results.append(await pacing.measure("Home note out", round: round, watch: home) { self.workbench.launchNotice = nil })
            results.append(await pacing.measure("Home out", round: round, watch: region, depth: 1) { self.workbench.select(workspace: workspace) })
        }

        pacing.stop()
        reportMotion(results, pacing: pacing, moves: moves)
        limit("motion: a closed tab caught the next click at its place (ghosts)", Double(ghosts.lines.count), atMost: 0)
        if !ghosts.lines.isEmpty { note("motion: ghosts", ghosts.lines.joined(separator: "; ")) }
        check("motion: after ×, the tab now under the pointer shows its close button at once", unhovered.lines.isEmpty, unhovered.lines.joined(separator: "; "))
        workbench.close(workspace: workspace)
        await PerfWait.sleep(500)
    }

    /// One row per kind of transition, and its limits: how it moves (frames, dropped, longest) by the worst
    /// of its rounds; when it starts and what the main thread did meanwhile by the median, the worst after
    /// it (the first Go to and the first find bar are made then, once).
    private func reportMotion(_ results: [FramePacing.Result], pacing: FramePacing, moves: Bool) {
        let kinds = results.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        func median(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.sorted()[values.count / 2] }
        for kind in kinds {
            let rounds = results.filter { $0.name == kind }
            let frames = rounds.map(\.frames).min() ?? 0
            let span = median(rounds.map(\.span)) ?? 0
            let delays = rounds.compactMap(\.delay), holds = rounds.compactMap(\.hold)
            let dropped = rounds.map(\.dropped).max() ?? 0
            let longest = rounds.map(\.longest).max() ?? 0
            let carrier = Set(rounds.map(\.carrier)).sorted().joined(separator: "+")
            rows.append(PerfRow(name: "motion: \(kind)", values: [
                ("frames", "\(frames)"), ("over", "\(Self.ms(span)) ms"), ("first change after", "\(Self.ms(median(delays)))/\(Self.ms(delays.max())) ms"),
                ("dropped", "\(dropped)"), ("longest frame", "\(Self.ms(longest)) ms"),
                ("main thread's longest hold", "\(Self.ms(median(holds)))/\(Self.ms(holds.max())) ms"), ("by", carrier),
            ]))
            // The action is never held back for the picture: the first change comes with the action's own,
            // within what `make perf` asks of the action itself (50 ms for a tab; going Home or back builds a
            // page or a workspace's panes first, measured at 47 to 56 ms before any motion; the ⌃Tab list
            // waits 0.2 s for ⌃ to be held, by design); and the main thread stays free to draw.
            if kind != "⌃Tab list in" {
                limit("motion: \(kind): first change after the action, median ms", median(delays), atMost: kind.hasPrefix("tab") ? 50 : 80)
            }
            limit("motion: \(kind): main thread's longest hold, median ms", median(holds), atMost: 50)
            guard moves, FramePacing.moving.contains(kind) else { continue }
            // It moves (a jump is one frame), and smoothly: no refresh skipped twice in a row.
            let least = FramePacing.leastFrames(pacing.period)
            limit("motion: \(kind): frames short of \(least), the least a move shows (a jump shows 1)", Double(max(0, least - frames)), atMost: 0)
            limit("motion: \(kind): longest frame, ms", longest, atMost: 2 * pacing.period + 1)
            limit("motion: \(kind): dropped frames", Double(dropped), atMost: 2)
        }
    }

    /// The overlay's model while it is open (Go to or the palette).
    private var paletteModel: PaletteModel? {
        (controller.palette?.panelForSnapshot?.contentViewController as? NSHostingController<PaletteView>)?.rootView.model
    }

    /// Keys typed into the overlay (its own panel takes them, as the key window would).
    private func typeInOverlay(_ text: String) {
        guard let panel = controller.palette?.panelForSnapshot else { return }
        for character in text {
            let characters = String(character)
            let code: UInt16 = characters == "\u{1b}" ? 53 : characters == "\u{7f}" ? 51 : 0
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                            isARepeat: false, keyCode: code) {
                panel.sendEvent(event)
            }
        }
    }

    /// ⌃Tab pressed with ⌃ held, as `DebugInteractions` presses it: queued, so the switcher reads ⌃ off the
    /// event, and offered to the menus from within its dispatch (a background app's menus are not).
    private func controlTabDown() async {
        var taken = false
        let menus = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 48, event.modifierFlags.contains(.control), let self else { return event }
            taken = true
            self.shortcut("ctrl+tab")
            return nil
        }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48) {
            QueuedEvents.post(event)
        }
        _ = await PerfWait.until(1000) { taken }
        if let menus { NSEvent.removeMonitor(menus) }
    }
}

/// Lines noted from work that runs later than the step that started it.
@MainActor
final class Notes {
    var lines: [String] = []
}

/// What part of the window shows at each refresh of the display, from Core Animation's presentation layers
/// (the state a frame is drawn from): their places, sizes, opacities and transforms, and whether Core
/// Animation itself is animating any of them. Ticked by the screen's own display link (it keeps the
/// display's rate, 120 Hz on ProMotion, whether or not the run's window is seen).
@MainActor
final class FramePacing: NSObject {
    struct Result {
        let name: String
        /// From the action to the first refresh that showed a change; nil when nothing changed.
        let delay: Double?
        /// From the first refresh with a change to the last.
        let span: Double
        /// Refreshes that showed a new picture.
        let frames: Int
        /// Refreshes between the first and the last change that showed nothing new (or never came).
        let dropped: Int
        /// The longest a picture stayed between two changes.
        let longest: Double
        /// The main thread's longest hold over the transition.
        let hold: Double?
        /// What carried it: Core Animation (the render server), the main thread, or nothing ("jump").
        let carrier: String
    }

    /// The transitions the design moves (or fades); the rest may simply change.
    static let moving: Set<String> = ["tab open", "tab close", "tab select", "tab reorder", "tab overflow", "tab run shifts",
                                      "Go to in", "Go to out", "Go to list changes", "⌃Tab list in", "⌃Tab list out",
                                      "find bar in", "find bar out", "Home in", "Home out", "Home note in", "Home note out"]

    /// Frames a transition of the quickest duration shows at least, at this refresh period (ms), with room
    /// for its ease-out's last steps being too small to see.
    static func leastFrames(_ period: Double) -> Int { Int((Look.Motion.quick * 1000 / period * 0.5).rounded(.down)) }

    private let log: PerfLog
    private var link: CADisplayLink?
    private var watched: () -> [CALayer] = { [] }
    /// How deep under the watched layers to look: what moves is the layer itself or close under it, and
    /// deeper down live other motions of their own (a field's focus ring, a terminal's cursor).
    private var depth = Int.max
    private var samples: [(tick: Double, picture: Int, animating: Bool)] = []
    private var ticked = 0
    /// The display's refresh period, ms.
    private(set) var period: Double = 1000.0 / 60

    init(log: PerfLog) {
        self.log = log
    }

    /// Starts the display link; false if it never ticked.
    func ticks() async -> Bool {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        guard await PerfWait.until(1000, { self.ticked > 3 }) != nil else { return false }
        period = max(1000.0 / 240, (link.targetTimestamp - link.timestamp) * 1000)
        return true
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// The watched part's window as its presentation layers stand now, written as a PNG (the root layer of
    /// the window the first watched layer is in, so the part is seen in its place).
    private func picture(_ layers: [CALayer], to url: URL) {
        guard var root = layers.first else { return }
        while let up = root.superlayer { root = up }
        let scale: CGFloat = 2
        let size = root.bounds.size
        guard size.width > 0, let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        if root.isGeometryFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        (root.presentation() ?? root).render(in: context)
        guard let image = context.makeImage() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    @objc private func tick(_ link: CADisplayLink) {
        ticked += 1
        let layers = watched()
        guard !layers.isEmpty || !samples.isEmpty else { return }
        var hasher = Hasher()
        var animating = false
        let most = depth
        func walk(_ layer: CALayer, depth: Int) {
            // An animation still running (one held at its end, as a fade-out's is, has finished moving).
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key) else { continue }
                if animation.beginTime == 0 || now < animation.beginTime + animation.duration { animating = true }
            }
            let shown = layer.presentation() ?? layer
            hasher.combine(depth)
            // Out of sight, nothing under it shows: a fade's last frame and the hide after it look the same.
            guard !shown.isHidden, shown.opacity >= 0.01 else { return hasher.combine(-1) }
            hasher.combine(shown.isHidden)
            for value in [shown.position.x, shown.position.y, shown.bounds.width, shown.bounds.height, CGFloat(shown.opacity),
                          shown.transform.m11, shown.transform.m22, shown.transform.m41, shown.transform.m42, shown.sublayerTransform.m11] {
                hasher.combine(Int((value * 100).rounded()))
            }
            guard depth < most else { return }
            for sublayer in layer.sublayers ?? [] { walk(sublayer, depth: depth + 1) }
        }
        // Nothing of it in sight (gone, hidden, or faded to nothing) is one picture, however it got there.
        let seen = layers.filter { layer in
            let shown = layer.presentation() ?? layer
            return !shown.isHidden && shown.opacity >= 0.01
        }
        for layer in seen { walk(layer, depth: 0) }
        hasher.combine(seen.count)
        // When this refresh reaches the glass: what the presentation layers hold now is drawn for it. (A tick
        // answered late, the main thread busy, says so: nothing it saw can be shown before now.)
        samples.append((max(link.targetTimestamp, CACurrentMediaTime()) * 1000, hasher.finalize(), animating))
    }

    /// Watches `layers` while `action` runs and for `settle` ms after it.
    func measure(_ name: String, round: Int, watch layers: @escaping () -> [CALayer], depth: Int = .max, settle: Double = 400, quiet: Bool = false,
                 _ action: @escaping () -> Void) async -> Result {
        watched = layers
        self.depth = depth
        samples = []
        await PerfWait.sleep(80)
        let baseline = samples.count
        let start = perfNow()
        action()
        if round == 0, let folder = DebugScenario.value("--motion-snapshots") {
            // What the window shows a third and two thirds of the way through, and once settled, drawn from the
            // presentation layers (Core Animation's in-flight values), for a person to look at.
            for (part, after) in [("a", 50.0), ("b", 100.0), ("c", settle - 20)] {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int(after)))
                    self?.picture(layers(), to: URL(fileURLWithPath: folder).appendingPathComponent("\(name.replacingOccurrences(of: " ", with: "-"))-\(part).png"))
                }
            }
        }
        await PerfWait.sleep(settle)
        let end = perfNow()
        let taken = samples
        watched = { [] }
        samples = []
        let before = taken.prefix(baseline).last
        let after = Array(taken.dropFirst(baseline)).filter { $0.tick >= start - period }
        if DebugScenario.has("--motion-trace") {
            var last = before?.picture
            print("trace \(name) \(round + 1) (* new picture, a animating): " + after.map { sample in
                defer { last = sample.picture }
                return String(format: "%.1f", sample.tick - start) + (sample.picture != last ? "*" : "") + (sample.animating ? "a" : "")
            }.joined(separator: " "))
        }
        var changes: [(tick: Double, animating: Bool)] = []
        var previous = before?.picture
        for sample in after {
            if sample.picture != previous || sample.animating { changes.append((sample.tick, sample.animating)) }
            previous = sample.picture
        }
        let hold = log.pings(from: start, to: end).max()
        guard let first = changes.first, let last = changes.last else {
            if !quiet { print("motion: \(name) \(round + 1): nothing changed") }
            return Result(name: name, delay: nil, span: 0, frames: 0, dropped: 0, longest: 0, hold: hold, carrier: "nothing")
        }
        // Refreshes from the first change to the last that showed nothing new, or were never answered.
        let refreshes = Int(((last.tick - first.tick) / period).rounded()) + 1
        var longest = 0.0
        for (a, b) in zip(changes, changes.dropFirst()) where !(a.animating && b.animating) { longest = max(longest, b.tick - a.tick) }
        if changes.count == 1 { longest = 0 }
        let byCore = changes.contains { $0.animating }, byMain = changes.contains { !$0.animating }
        let carrier = changes.count == 1 ? "jump" : byCore && byMain ? "Core Animation and main thread" : byCore ? "Core Animation" : "main thread"
        // Core Animation's own refreshes are drawn whether or not the main thread looked at them.
        let frames = byCore && !byMain ? refreshes : changes.count
        let result = Result(name: name, delay: max(0, first.tick - start), span: last.tick - first.tick, frames: frames,
                            dropped: max(0, refreshes - frames), longest: longest, hold: hold, carrier: carrier)
        if !quiet { print("motion: \(name) \(round + 1): \(result.frames) frames over \(PerfSuite.ms(result.span)) ms, first after \(PerfSuite.ms(result.delay)) ms, "
              + "dropped \(result.dropped), longest \(PerfSuite.ms(result.longest)) ms, hold \(PerfSuite.ms(hold)) ms, by \(carrier)") }
        return result
    }
}
#endif
