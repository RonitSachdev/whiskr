#if DEBUG
import AppKit
import QuartzCore
import SwiftTerm
import WhiskrKit

/// `--perf-flows resize` (`make perf`'s checks): what the window shows while it changes size. Every divider
/// (the meadow's edge, a pane split, the side panel's edge) is dragged by the mouse, through the window's
/// own event path into the divider's own tracking loop, at 60 and at 120 moves a second; the window itself is
/// resized as a live resize; and each region (the meadow, the side panel, the status bar) is hidden and
/// shown. Measured meanwhile: how long each step took the main thread to draw (the frames a 60 or 120 Hz
/// display would have shown or missed) and the longest the main thread was held (`MainPinger`).
///
/// Looked at in the middle of each drag, not only before and after: the window is drawn from its layer
/// tree (`CALayer.render(in:)`), which holds what Core Animation will put on screen, the divider's glow
/// among it. (`--snapshot` draws the views with `cacheDisplay`, which leaves out a layer added beside a
/// view's own drawing, the glow: a check that looked only at snapshots, and only once a drag was over,
/// passed while the real window left the glow behind at the place the drag began.) At each look:
/// - the glow is lit and centred on the divider where it is now;
/// - nothing in the accent colour is drawn anywhere else but the focused pane's border and the selected
///   tab's line;
/// - around each terminal held at its size, the pane shows the terminal's background, nothing unpainted.
/// After the mouse goes up the glow stays only while the pointer is still on the divider, and there.
extension PerfSuite {
    func resizeCheck() async {
        PointerStandIn.install()
        let pinger = MainPinger(log: log)
        pinger.start()
        defer {
            pinger.stop()
            PointerStandIn.location = nil
        }
        let pane = workbench.newWorkspace(folder: folder("resize"))
        guard await shellReady(pane), let workspace = workbench.selectedWorkspace else { return check("resize: the first shell drew its prompt", false) }
        // A long scrollback: what makes a terminal's re-wrap costly.
        pane.type("clear; seq 1 12000; echo Rseq$((1))\r")
        _ = await PerfWait.until(20000) { self.screen(pane).contains("Rseq1") }
        shortcut("cmd+d")
        guard let other = await PerfWait.until(3000, { self.workbench.focusedPane.map { $0 !== pane } ?? false }).flatMap({ _ in self.workbench.focusedPane }),
              await shellReady(other) else { return check("resize: a split to drag", false) }
        workbench.files.setPanel(workspace.id) { $0.shown = true; $0.width = 300 }
        await PerfWait.sleep(800)
        print("resize: set up, lit glows: \(litGlows())")
        await rewrapCost(pane)
        for hertz in [60.0, 120.0] {
            await dragEachDivider(hertz: hertz)
        }
        for hertz in [60.0, 120.0] {
            // Once timed, then looked at as it goes.
            await windowLiveResize(hertz: hertz, look: false)
            await windowLiveResize(hertz: hertz, look: true)
        }
        await regionsShowAndHide()
        workbench.files.setPanel(workspace.id) { $0.shown = false }
        controller.resetLayout(nil)
        window.setContentSize(NSSize(width: 1440, height: 900))
    }

    // MARK: The cost of a terminal's re-wrap

    /// What one change of a terminal's width costs the main thread with a long scrollback (SwiftTerm re-wraps
    /// every line it holds): the reason terminals keep their size during a drag and take the new one once.
    private func rewrapCost(_ pane: Pane) async {
        let surface = pane.surface
        let start = surface.frame.size
        var times: [Double] = []
        for step in 0..<10 {
            let begin = perfNow()
            surface.setFrameSize(NSSize(width: start.width + (step % 2 == 0 ? -7 : 0), height: start.height))
            times.append(perfNow() - begin)
        }
        surface.superview?.needsLayout = true
        surface.superview?.layoutSubtreeIfNeeded()
        // A frame drawn for the size before is never stretched to the new one (`TerminalSurface`).
        let gravity = surface.subviews.compactMap { $0.layer as? CAMetalLayer }.first?.contentsGravity
        check("resize: a terminal's Metal frames are pinned, not stretched, while its size changes", gravity == .topLeft || gravity == .bottomLeft,
              "contents gravity \(gravity?.rawValue ?? "no Metal layer")")
        rows.append(PerfRow(name: "resize: one change of a terminal's width, 12,000 lines printed", values: [
            ("median", Self.ms(Self.pick(times, 0.5))), ("max", Self.ms(times.max())),
        ]))
    }

    // MARK: Dividers

    /// A divider: the view whose own tracking loop drags it and owns its glow, and where its line is now
    /// (in the window).
    private struct Divider {
        let name: String
        let host: NSView
        let line: @MainActor () -> NSRect
        /// How far to drag it, out and back (points, along the window's width).
        let reach: CGFloat
    }

    private func dividers() -> [Divider] {
        var found: [Divider] = []
        let frame = window.contentView?.superview ?? window.contentView!
        if let regions = DebugShell.descendant(of: frame, where: { $0 is RegionsSplitView }) as? RegionsSplitView, regions.arrangedSubviews.count == 2 {
            found.append(Divider(name: "the meadow's edge", host: regions, line: {
                let meadow = regions.arrangedSubviews[0]
                return regions.convert(NSRect(x: meadow.frame.maxX, y: 0, width: regions.dividerThickness, height: regions.bounds.height), to: nil)
            }, reach: -140))
        }
        if let split = DebugShell.descendant(of: controller.terminals.paneArea, where: { $0 is RatioSplitView }) as? RatioSplitView, split.subviews.count == 2 {
            found.append(Divider(name: "a pane split", host: split, line: {
                split.convert(NSRect(x: split.subviews[0].frame.maxX, y: 0, width: split.dividerThickness, height: split.bounds.height), to: nil)
            }, reach: -120))
        }
        if let edge = DebugShell.descendant(of: controller.terminals.view, where: { $0 is PanelEdge }) as? PanelEdge, !edge.isHidden {
            found.append(Divider(name: "the side panel's edge", host: edge, line: {
                edge.convert(NSRect(x: edge.bounds.midX - 0.5, y: 0, width: 1, height: edge.bounds.height), to: nil)
            }, reach: -120))
        }
        return found
    }

    private func dragEachDivider(hertz: Double) async {
        let found = dividers()
        check("resize: every divider found (\(Int(hertz)) Hz)", found.count == 3, found.map(\.name).joined(separator: ", "))
        for divider in found {
            // Once timed, looking at nothing; then again, looked at in the middle (looking costs time).
            let timed = await drag(divider, hertz: hertz, look: false)
            report("resize: \(divider.name) dragged at \(Int(hertz)) Hz", timed, hertz: hertz)
            let looked = await drag(divider, hertz: hertz, look: true)
            let failures = looked.failures
            check("resize: \(divider.name) at \(Int(hertz)) Hz: mid-drag, the glow follows the divider and nothing is left behind",
                  looked.looks >= 6 && failures.isEmpty,
                  failures.isEmpty ? "\(looked.looks) looks" : failures.prefix(3).joined(separator: "; "))
            // The pointer stays where the drag left it: on the divider, so the glow stays, at its new place.
            let after = lookAtWindow(divider, during: false)
            check("resize: \(divider.name) at \(Int(hertz)) Hz: after the mouse went up, the glow is on the divider or gone, and nothing is left behind",
                  after.isEmpty, after.prefix(3).joined(separator: "; "))
            // Then it moves away: the glow goes.
            if let content = window.contentView { PointerStandIn.location = content.convert(NSPoint(x: content.bounds.midX + 37, y: content.bounds.midY + 41), to: nil) }
            await PerfWait.sleep(50)
            let lit = glowLayer(of: divider.host).map { !$0.isHidden && $0.opacity > 0 } ?? false
            check("resize: \(divider.name): the glow goes once the pointer leaves the divider", !lit)
            let away = accentLeftBehind(divider: nil)
            check("resize: \(divider.name): once the pointer has left, no accent is drawn anywhere it should not be", away.isEmpty, away.prefix(3).joined(separator: "; "))
        }
    }

    /// What a drag's steps cost, and what was seen at each look.
    private struct DragResult {
        var steps: [Double] = []
        var looks = 0
        var failures: [String] = []
        /// The main thread's longest turn, the mouse going up (the terminals' one re-wrap) included.
        var longestTurn = 0.0
    }

    /// The divider pressed, moved `reach` points in 24 steps and back in 24, at `hertz` moves a second, and
    /// let go. Each move is posted by a timer that runs inside the divider's own tracking loop (the
    /// event-tracking run loop mode), as the window server delivers a hand's moves; a step lasts from its
    /// move being posted to the window's drawing of it being committed.
    private func drag(_ divider: Divider, hertz: Double, look: Bool) async -> DragResult {
        print("resize: before dragging \(divider.name), lit glows: \(litGlows())")
        let line = divider.line()
        let start = NSPoint(x: line.midX, y: line.minY + line.height * 0.6)
        // The pointer comes onto the divider and rests there, as a hand does before pressing.
        PointerStandIn.location = start
        await PerfWait.sleep(DividerGlow.delay * 1000 + 100)
        let out: [NSPoint] = (1...24).map { NSPoint(x: start.x + divider.reach * CGFloat($0) / 24, y: start.y) }
        let points: [NSPoint] = out + out.reversed().dropFirst() + [start]
        let state = DragState()
        let interval = 1000 / hertz
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_001_000) { _, _ in
            MainActor.assumeIsolated {
                guard let posted = state.posted else { return }
                state.steps.append(perfNow() - posted)
                state.posted = nil
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        // The main thread's turns (pings are not answered inside a tracking loop: the main queue waits for it).
        let turns = TurnWatch()
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + interval / 1000, interval / 1000, 0, 0) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The step before has been taken and drawn: look at it (every fourth).
                if look, state.index > 0, state.index % 4 == 0 {
                    state.looks += 1
                    state.failures += self.lookAtWindow(divider, during: true).map { "step \(state.index): \($0)" }
                    // The window at the drag's furthest point, kept for the eye.
                    if state.index == 24 { self.saveLayers("mid-drag \(divider.name) \(Int(hertz)) Hz") }
                }
                guard state.index < points.count else {
                    if let up = self.mouse(.leftMouseUp, at: points.last!) { NSApp.postEvent(up, atStart: false) }
                    CFRunLoopTimerInvalidate(timer)
                    state.done = true
                    return
                }
                let point = points[state.index]
                state.index += 1
                PointerStandIn.location = point
                if let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: self.window.windowNumber, context: nil, eventNumber: self.nextEventNumber(), clickCount: 1, pressure: 1) {
                    NSApp.postEvent(drag, atStart: false)
                    state.posted = perfNow()
                }
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .commonModes)
        if let down = mouse(.leftMouseDown, at: start) { NSApp.sendEvent(down) }
        _ = await PerfWait.until(10000) { state.done }
        // The hand rests where the drag ended, on the divider: the areas the divider has moved under it hear it.
        PointerStandIn.location = points.last
        // The terminals take their new size once the mouse is up: that turn counts too.
        await PerfWait.sleep(400)
        CFRunLoopObserverInvalidate(observer)
        var result = DragResult(steps: state.steps, looks: state.looks, failures: state.failures)
        result.longestTurn = turns.finish().max() ?? 0
        let moved = abs(divider.line().midX - start.x)
        if moved > 2 { result.failures.append(String(format: "the divider did not come back to where it was pressed (%.0f pt away)", moved)) }
        return result
    }

    @MainActor
    private final class DragState {
        var index = 0
        var posted: Double?
        var steps: [Double] = []
        var looks = 0
        var failures: [String] = []
        var done = false
    }

    /// A step that took longer than a frame missed one. `window`: the window's own edge, where every step
    /// lays out the whole window (about 5 ms on an M-series Mac), so a step now and then misses at 120 Hz.
    private func report(_ name: String, _ result: DragResult, hertz: Double, window: Bool = false) {
        let frame = 1000 / hertz
        let missed = result.steps.filter { $0 > frame }.count
        rows.append(PerfRow(name: name, values: [
            ("steps", "\(result.steps.count)"), ("drawn in time", "\(result.steps.count - missed)"), ("missed", "\(missed)"),
            ("step p50", Self.ms(Self.pick(result.steps, 0.5))), ("step p95", Self.ms(Self.pick(result.steps, 0.95))), ("longest step", Self.ms(result.steps.max())),
            ("longest main-thread turn", Self.ms(result.longestTurn)),
        ]))
        // A frame missed now and then is the Mac's, not the window's; most must be in time, and nothing may
        // hold the main thread for two frames at 60 Hz (the mouse going up, the terminals' one re-wrap, too).
        if window {
            limit("\(name): step p95, ms", Self.pick(result.steps, 0.95), atMost: 12)
        } else {
            limit("\(name): steps that missed their frame, %", Double(missed) * 100 / Double(max(result.steps.count, 1)), atMost: 5)
        }
        limit("\(name): longest main-thread turn, ms", result.longestTurn, atMost: 33)
    }

    // MARK: Looking at the window

    /// The divider's glow: the layer it adds to its view (by name; the glow before it had one was the
    /// view's layer at 1,000 above its siblings, so this check can be run against that code too).
    func glowLayer(of host: NSView) -> CALayer? {
        host.layer?.sublayers?.first { $0.name == DividerGlow.layerName } ?? host.layer?.sublayers?.first { $0.zPosition == 1000 }
    }

    /// What is wrong in the window as it is drawn now, around `divider` (nil: no divider in use).
    private func lookAtWindow(_ divider: Divider, during dragging: Bool) -> [String] {
        var wrong: [String] = []
        let line = divider.line()
        let glow = glowLayer(of: divider.host)
        let lit = glow.map { !$0.isHidden && $0.opacity > 0 } ?? false
        let pointerOn = PointerStandIn.location.map { abs($0.x - line.midX) <= 4 } ?? false
        if dragging || pointerOn {
            if !lit { wrong.append("the glow is not lit\(dragging ? " while dragged" : " with the pointer on the divider")") }
        }
        if lit, let glow {
            let place = divider.host.convert(glow.frame, to: nil)
            if abs(place.midX - line.midX) > 1 {
                wrong.append(String(format: "the glow is at x %.1f, the divider at %.1f", place.midX, line.midX))
            }
        }
        wrong += accentLeftBehind(divider: lit ? line : nil)
        wrong += unpaintedAroundTerminals()
        return wrong
    }

    /// The window's layer tree drawn as Core Animation holds it: (pixels, width, height, scale), rows from
    /// the bottom, as the window's coordinates count them.
    /// `presentation`: as the screen shows it in the middle of an animation (each layer's presentation).
    private func renderLayers(presentation: Bool = false) -> (pixels: [UInt8], width: Int, height: Int, scale: CGFloat)? {
        guard let view = window.contentView, let layer = view.layer else { return nil }
        window.displayIfNeeded()
        // `render(in:)` draws sublayers in their order and leaves out `zPosition`, which the screen honours:
        // a layer lifted above its siblings (the glow) is put last among them, where the screen shows it.
        func lift(_ layer: CALayer) {
            for sub in layer.sublayers ?? [] {
                if sub.zPosition > 0, layer.sublayers?.last !== sub { layer.addSublayer(sub) }
                lift(sub)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lift(layer)
        CATransaction.commit()
        CATransaction.flush()
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // A layer draws with its origin at the top (as a flipped view): turned so rows count from the bottom.
            if layer.isGeometryFlipped == false {
                context.translateBy(x: 0, y: CGFloat(height))
                context.scaleBy(x: scale, y: -scale)
            } else {
                context.scaleBy(x: scale, y: scale)
            }
            (presentation ? layer.presentation() ?? layer : layer).render(in: context)
            return true
        }
        return drawn ? (pixels, width, height, scale) : nil
    }

    /// Saved once for the eye: the window as its layers hold it, in the middle of a drag.
    func saveLayers(_ name: String, presentation: Bool = false) {
        guard let (pixels, width, height, _) = renderLayers(presentation: presentation) else { return }
        var flipped = [UInt8](repeating: 0, count: pixels.count)
        for row in 0..<height {
            let from = row * width * 4, to = (height - 1 - row) * width * 4
            flipped[to..<to + width * 4] = pixels[from..<from + width * 4]
        }
        let data = Data(flipped)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("\(name).png"))
    }

    private func rgb(_ color: NSColor) -> (Int, Int, Int) {
        var resolved = color
        window.contentView?.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) ?? color }
        return (Int(resolved.redComponent * 255), Int(resolved.greenComponent * 255), Int(resolved.blueComponent * 255))
    }

    /// Places drawn in the accent colour that should not be: anywhere but the divider in use (its glow,
    /// `divider`), the focused pane's border and the tab row (the selected tab's line). Each as "x … pt, n
    /// pixels".
    private func accentLeftBehind(divider: NSRect?) -> [String] {
        guard let (pixels, width, height, scale) = renderLayers(), let content = window.contentView else { return ["the window could not be drawn"] }
        let accent = rgb(Colors.accent)
        var allowed: [NSRect] = []
        if let divider { allowed.append(divider.insetBy(dx: -(DividerGlow.width / 2 + 2), dy: -2)) }
        if let tabRow = controller.terminals.tabRow { allowed.append(tabRow.convert(tabRow.bounds, to: nil)) }
        // Above the regions: the bars (the top bar's toggles use the primary colour, never the accent, but
        // they are not what is looked at here).
        let regions = controller.terminals.view.superview.map { $0.convert($0.bounds, to: nil) } ?? content.frame
        for card in cards() where card.focus.state == .focused {
            let box = card.focus.convert(card.focus.bounds, to: nil)
            // The border's band, inside the card's edge.
            let band = Look.focusBorderWidth + 1.5
            allowed += [NSRect(x: box.minX - 1, y: box.minY - 1, width: box.width + 2, height: band + 1),
                        NSRect(x: box.minX - 1, y: box.maxY - band, width: box.width + 2, height: band + 1),
                        NSRect(x: box.minX - 1, y: box.minY - 1, width: band + 1, height: box.height + 2),
                        NSRect(x: box.maxX - band, y: box.minY - 1, width: band + 1, height: box.height + 2)]
        }
        // The side panel's own content (a selected row is the system's accent) is not a divider's.
        let panel = controller.terminals.sidePanel.flatMap { $0.isHidden ? nil : $0.convert($0.bounds, to: nil).insetBy(dx: 0, dy: 0) }
        var columns: [Int: Int] = [:]
        let x0 = max(0, Int(regions.minX * scale)), x1 = min(width, Int(regions.maxX * scale))
        let y0 = max(0, Int(regions.minY * scale)), y1 = min(height, Int(regions.maxY * scale))
        for y in stride(from: y0, to: y1, by: 2) {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                guard pixels[i + 3] > 250, abs(Int(pixels[i]) - accent.0) <= 14, abs(Int(pixels[i + 1]) - accent.1) <= 14, abs(Int(pixels[i + 2]) - accent.2) <= 14 else { continue }
                let point = NSPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                if allowed.contains(where: { $0.contains(point) }) { continue }
                if let panel, panel.insetBy(dx: 5, dy: 0).contains(point) { continue }
                columns[Int(point.x), default: 0] += 1
            }
        }
        // Columns side by side are one thing left behind.
        var found: [String] = []
        var run: (from: Int, to: Int, count: Int)?
        for x in columns.keys.sorted() {
            if let current = run, x <= current.to + 1 { run = (current.from, x, current.count + columns[x]!) } else {
                if let current = run { found.append("accent at x \(current.from)–\(current.to) pt (\(current.count) pixels)") }
                run = (x, x, columns[x]!)
            }
        }
        if let current = run { found.append("accent at x \(current.from)–\(current.to) pt (\(current.count) pixels)") }
        // A few stray pixels (antialiasing of the border's corners) are not a line.
        let lines = found.filter { entry in !entry.hasSuffix("(1 pixels)") && !entry.hasSuffix("(2 pixels)") }
        guard !lines.isEmpty else { return [] }
        return lines + ["lit glows: " + litGlows()]
    }

    /// Every divider glow lit in the window, by its view and where (to say what an accent line is).
    private func litGlows() -> String {
        var found: [String] = []
        func walk(_ view: NSView) {
            if let glow = glowLayer(of: view), !glow.isHidden, glow.opacity > 0 {
                found.append(String(format: "%@ at x %.1f (%@ z %.0f, %@, width %.1f)", String(describing: type(of: view)), view.convert(glow.frame, to: nil).midX,
                                    String(describing: type(of: glow)), glow.zPosition, glow.backgroundColor.map { "\($0.components ?? [])" } ?? "no colour", glow.frame.width))
            }
            view.subviews.forEach(walk)
        }
        if let frame = window.contentView { walk(frame) }
        return found.isEmpty ? "none" : found.joined(separator: ", ")
    }

    /// The terminals' cards on screen, with their focus layer.
    private func cards() -> [(card: PaneCard, focus: PaneFocusView)] {
        var found: [(PaneCard, PaneFocusView)] = []
        func walk(_ view: NSView) {
            if let card = view as? PaneCard, !card.isHiddenOrHasHiddenAncestor,
               let focus = card.subviews.first(where: { $0 is PaneFocusView }) as? PaneFocusView { found.append((card, focus)) }
            view.subviews.forEach(walk)
        }
        walk(controller.terminals.paneArea)
        return found
    }

    /// Around each terminal (held at its size or not), its pane shows the terminal's background: no strip
    /// left unpainted or showing something stale.
    private func unpaintedAroundTerminals() -> [String] {
        guard let (pixels, width, height, scale) = renderLayers() else { return [] }
        let background = rgb(Colors.terminalBackground)
        var wrong: [String] = []
        for (card, _) in cards() {
            let box = card.convert(card.bounds, to: nil).insetBy(dx: Look.focusBorderWidth + 2, dy: Look.focusBorderWidth + 2)
            let surface = workbench.panes.values.first { $0.surface.isDescendant(of: card) }?.surface
            let terminal = surface.map { $0.convert($0.bounds, to: nil) } ?? .zero
            var bad = 0
            var first: NSPoint?
            for y in stride(from: max(0, Int(box.minY * scale)), to: min(height, Int(box.maxY * scale)), by: 3) {
                for x in stride(from: max(0, Int(box.minX * scale)), to: min(width, Int(box.maxX * scale)), by: 3) {
                    let point = NSPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                    if terminal.insetBy(dx: -1, dy: -1).contains(point) { continue }
                    let i = (y * width + x) * 4
                    let ok = pixels[i + 3] > 250 && abs(Int(pixels[i]) - background.0) <= 6 && abs(Int(pixels[i + 1]) - background.1) <= 6 && abs(Int(pixels[i + 2]) - background.2) <= 6
                    if !ok { bad += 1; if first == nil { first = point } }
                }
            }
            if bad > 4, let first {
                wrong.append(String(format: "around a terminal, %d samples not its background (first at %.0f, %.0f)", bad, first.x, first.y))
            }
        }
        return wrong
    }

    /// Every terminal on screen holds the grid its view has room for (none left at a size it was held at).
    private func terminalsSized() -> Bool {
        cards().allSatisfy { card in
            guard let surface = workbench.panes.values.first(where: { $0.surface.isDescendant(of: card.card) })?.surface else { return true }
            let room = surface.size(for: surface.frame.size)
            let grid = surface.terminalDimensions
            return room.columns == grid.cols && room.rows == grid.rows
        }
    }

    // MARK: The window's own edge

    /// The window dragged narrower and back by its edge, as a live resize (`windowWillStartLiveResize`, as
    /// AppKit calls it), 8 pt a step at `hertz` steps a second; looked at every sixth step.
    private func windowLiveResize(hertz: Double, look: Bool) async {
        let original = window.frame
        if let content = window.contentView { PointerStandIn.location = content.convert(NSPoint(x: content.bounds.midX + 37, y: content.bounds.midY + 41), to: nil) }
        await PerfWait.sleep(100)
        let interval = 1000 / hertz
        let narrower: [CGFloat] = (1...30).map { original.width - CGFloat($0) * 8 }
        let widths: [CGFloat] = narrower + narrower.reversed().dropFirst() + [original.width]
        let turns = TurnWatch()
        window.delegate?.windowWillStartLiveResize?(Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
        var steps: [Double] = []
        var failures: [String] = []
        for (index, width) in widths.enumerated() {
            let start = perfNow()
            window.setFrame(NSRect(x: original.minX, y: original.minY, width: width, height: original.height), display: true)
            CATransaction.flush()
            steps.append(perfNow() - start)
            if look, index % 6 == 5 {
                failures += accentLeftBehind(divider: nil).map { "width \(Int(width)): \($0)" }
                failures += unpaintedAroundTerminals().map { "width \(Int(width)): \($0)" }
            }
            await PerfWait.sleep(max(1, interval - (perfNow() - start)))
        }
        window.delegate?.windowDidEndLiveResize?(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        await PerfWait.sleep(400)
        let name = "resize: the window's edge dragged at \(Int(hertz)) Hz"
        if look {
            failures += accentLeftBehind(divider: nil).map { "after: \($0)" }
            failures += unpaintedAroundTerminals().map { "after: \($0)" }
            check("\(name): nothing is left behind", failures.isEmpty, failures.prefix(3).joined(separator: "; "))
            check("\(name): every terminal took its new size at the end", terminalsSized())
        } else {
            report(name, DragResult(steps: steps, longestTurn: turns.finish().max() ?? 0), hertz: hertz, window: true)
        }
        window.setFrame(original, display: true)
        await PerfWait.sleep(300)
    }

    // MARK: Regions

    /// The meadow, the side panel and the status bar, each hidden and shown again: how long the main
    /// thread worked for it, its longest turn and how many turns it took (one per frame if the slide is
    /// laid out by the main thread frame by frame), and that it ends where it should, terminals sized.
    private func regionsShowAndHide() async {
        guard let workspace = workbench.selectedWorkspace else { return }
        if let content = window.contentView { PointerStandIn.location = content.convert(NSPoint(x: content.bounds.midX + 37, y: content.bounds.midY + 41), to: nil) }
        let toggles: [(String, () -> Void, () -> Bool)] = [
            ("the meadow hidden (⌃⌘S)", { self.shortcut("ctrl+cmd+s") }, { !self.meadowShown }),
            ("the meadow shown (⌃⌘S)", { self.shortcut("ctrl+cmd+s") }, { self.meadowShown }),
            ("the side panel hidden (⇧⌘E)", { self.workbench.files.setPanel(workspace.id) { $0.shown = false } }, { self.controller.terminals.sidePanel.isHidden }),
            ("the side panel shown (⇧⌘E)", { self.workbench.files.setPanel(workspace.id) { $0.shown = true } }, { !self.controller.terminals.sidePanel.isHidden }),
            ("the status bar hidden", { self.controller.toggleStatusBar(nil) }, { self.statusHeight == 0 }),
            ("the status bar shown", { self.controller.toggleStatusBar(nil) }, { self.statusHeight == Look.Height.statusBar }),
        ]
        // What the main thread does anyway (the meadow draws on it) over as long, for comparison.
        await PerfWait.sleep(300)
        let idle = TurnWatch()
        await PerfWait.sleep(400)
        let idleTurns = idle.finish().filter { $0 > 0.5 }
        rows.append(PerfRow(name: "resize: nothing changing, 400 ms (for comparison)", values: [
            ("main-thread turns", "\(idleTurns.count)"), ("main-thread ms", Self.ms(idleTurns.reduce(0, +))),
        ]))
        let paneArea = controller.terminals.paneArea!
        // Twice: measured, then looked at in the middle (drawing the window to look costs time).
        for (round, (name, act, done)) in (toggles + toggles).enumerated() {
            let look = round >= toggles.count
            await PerfWait.sleep(300)
            // Each time the panes' frame changes is one layout of the work area: once for a slide Core
            // Animation eases, once a frame for one the main thread lays out frame by frame.
            var layouts = 0
            let frames = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: paneArea, queue: nil) { _ in
                MainActor.assumeIsolated { layouts += 1 }
            }
            let watch = TurnWatch()
            let began = perfNow()
            act()
            if look {
                await PerfWait.sleep(Look.Motion.region * 500)
                saveLayers("mid \(name)", presentation: true)
            }
            let ended = await PerfWait.until(2000) { done() && !LiveResize.shared.isActive }
            await PerfWait.sleep(150)
            let turns = watch.finish()
            NotificationCenter.default.removeObserver(frames)
            let held = log.pings(from: began, to: perfNow()).max() ?? 0
            let busy = turns.filter { $0 > 0.5 }
            check("resize: \(name): it ends where it should, with nothing still sliding", ended != nil)
            if !look {
                rows.append(PerfRow(name: "resize: \(name)", values: [
                    ("done after", ended.map { Self.ms($0 - began) } ?? "never"), ("layouts of the panes", "\(layouts)"),
                    ("main-thread turns", "\(busy.count)"), ("main-thread ms", Self.ms(busy.reduce(0, +))), ("longest turn", Self.ms(turns.max())),
                    ("main thread held at most", Self.ms(held)),
                ]))
                // The meadow slides as the split view slides it, laid out each frame (its scene drawn at each
                // width; coming back, its first frame takes about 20 ms); the others are eased by Core Animation
                // and laid out once (twice with the end's), and no turn of theirs may miss a frame.
                if name.contains("meadow") {
                    limit("resize: \(name): longest main-thread turn, ms", turns.max(), atMost: 33)
                } else {
                    limit("resize: \(name): longest main-thread turn, ms", turns.max(), atMost: 16)
                    limit("resize: \(name): layouts of the panes", Double(layouts), atMost: 2)
                }
                continue
            }
            await PerfWait.sleep(200)
            check("resize: \(name): every terminal has its new size", terminalsSized())
            let left = accentLeftBehind(divider: nil)
            check("resize: \(name): no accent is drawn anywhere it should not be", left.isEmpty, left.prefix(3).joined(separator: "; "))
        }
    }

    /// Each turn of the main run loop while it watches: how long from waking to the window's drawing
    /// committed (milliseconds).
    @MainActor
    private final class TurnWatch {
        private var woke = perfNow()
        private var turns: [Double] = []
        private var observers: [CFRunLoopObserver] = []

        init() {
            let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.woke = perfNow() }
            }
            let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_001_000) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.turns.append(perfNow() - self.woke)
                }
            }
            for observer in [wake, sleep].compactMap({ $0 }) {
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                observers.append(observer)
            }
        }

        func finish() -> [Double] {
            observers.forEach { CFRunLoopObserverInvalidate($0) }
            observers = []
            return turns
        }
    }
}
#endif
