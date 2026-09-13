#if DEBUG
import AppKit
import ObjectiveC
import QuartzCore
@_spi(Diagnostics) import MeadowScene
import SwiftTerm
import WhiskrKit

/// Debug and profile builds (`make perf`): what someone at the window would see, measured in a run nobody
/// sees. The window stays invisible and behind everything (`--background`), but draws as a visible key
/// window does: the meadow at its own pace as if on screen and key, every terminal on a display link that
/// keeps ticking for a covered window, the window's own layout and display cycles as usual. Every input
/// goes through the app's real event path (`NSApplication.sendEvent`: its key monitors, the window, the
/// view under the pointer or with the keyboard), never through the model.
///
///   --perf <file>             runs the measurements, writes the table to <file> and stdout, then quits
///   --perf-flows <a,b,…>      only these: typing, yes, cat, stream, newtab, close, switch, idle, closing
///   --perf-cats               four more workspaces with Claudes at work, so the meadow is busy
///   --perf-keys <n>           keystrokes timed in `typing` (150)
///   --perf-limits             checks the measurements against `PerfSuite`'s limits; exits with 1 when one
///                             is passed or a check fails (`make perf`)
///
/// Measured: each keystroke from the event to its bytes leaving for the host, to its echo taken in by the
/// terminal, to the terminal's next frame drawn (`TerminalView.onFramePresented`); how long the main
/// thread took to answer a ping sent every 4 ms (a stall is time the window cannot take a key or draw);
/// terminal frames drawn and the longest gap between them; the meadow's frames, main-thread and GPU time.
/// Not measured: the compositor's own step from a drawn frame to the glass (one display refresh).
@MainActor
enum DebugPerf {
    static var isOn: Bool { DebugScenario.value("--perf") != nil }

    /// Before any terminal view exists. SwiftTerm draws on the view's own display link, which stops for a
    /// covered window; Core Video's link ticks at the display's rate whatever the window, and runs the same
    /// frame code.
    static func prepareProcess() {
        guard isOn else { return }
        setenv("SWIFTTERM_FORCE_CVDISPLAYLINK", "1", 1)
    }

    static func run(workbench: Workbench, window controller: MainWindowController) {
        guard let out = DebugScenario.value("--perf"), let window = controller.window else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        KeyStandIn.install(window)
        // `--window` larger than this Mac's screen (a 2560×1440 display's window, on a laptop): kept as asked.
        if let size = DebugScenario.value("--window")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            UnconstrainedFrame.install()
            window.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        let meadow = controller.navigator.meadow
        meadow.assumesOnScreen = true
        meadow.keepsFullRateWhenInactive = true
        let flows = DebugScenario.value("--perf-flows").map { Set($0.split(separator: ",").map(String.init)) }
        let suite = PerfSuite(workbench: workbench, controller: controller, window: window, flows: flows)
        Task {
            await suite.run()
            let text = suite.report()
            print(text)
            try? Data(text.utf8).write(to: URL(fileURLWithPath: out))
            guard suite.passed || !DebugScenario.has("--perf-limits") else {
                // As quitting would, with the status saying it failed.
                workbench.shutDown(stoppingSessions: true)
                exit(1)
            }
            NSApp.terminate(nil)
        }
    }
}

/// The milliseconds clock every probe uses (any thread).
nonisolated func perfNow() -> Double { CACurrentMediaTime() * 1000 }

/// Everything the probes saw, with when (any thread).
nonisolated final class PerfLog: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Double] = []
    private var outputs: [Double] = []
    private var pings: [(at: Double, ms: Double)] = []
    private var meadow: [(at: Double, timings: MeadowView.Timings)] = []

    func frame() { let now = perfNow(); lock.withLock { frames.append(now) } }
    func output() { let now = perfNow(); lock.withLock { outputs.append(now) } }
    func ping(sentAt: Double, ms: Double) { lock.withLock { pings.append((sentAt, ms)) } }
    func meadow(_ timings: MeadowView.Timings) { let now = perfNow(); lock.withLock { meadow.append((now, timings)) } }
    private var invalidations: [Double] = []
    func invalidated() { let now = perfNow(); lock.withLock { invalidations.append(now) } }
    func invalidations(from: Double, to: Double) -> Int { lock.withLock { invalidations.filter { $0 >= from && $0 <= to }.count } }

    func frames(from: Double, to: Double = .infinity) -> [Double] { lock.withLock { frames.filter { $0 >= from && $0 <= to } } }
    func outputs(from: Double, to: Double = .infinity) -> [Double] { lock.withLock { outputs.filter { $0 >= from && $0 <= to } } }
    func pings(from: Double, to: Double) -> [Double] { lock.withLock { pings.filter { $0.at >= from && $0.at <= to }.map(\.ms) } }
    func meadow(from: Double, to: Double) -> [MeadowView.Timings] { lock.withLock { meadow.filter { $0.at >= from && $0.at <= to }.map(\.timings) } }
    var lastOutput: Double? { lock.withLock { outputs.last } }
    func firstFrame(after time: Double) -> Double? { lock.withLock { frames.first { $0 > time } } }
}

/// Asks the main thread for a moment every 4 ms, from a thread of its own, and notes how long the answer
/// took: what a key press or a frame waiting behind the main thread's work would have waited.
nonisolated final class MainPinger: @unchecked Sendable {
    private let log: PerfLog
    private let lock = NSLock()
    private var running = false

    init(log: PerfLog) { self.log = log }

    func start() {
        lock.withLock { running = true }
        let thread = Thread { [self] in
            while lock.withLock({ running }) {
                let sent = perfNow()
                let answered = DispatchSemaphore(value: 0)
                let log = log
                DispatchQueue.main.async {
                    log.ping(sentAt: sent, ms: perfNow() - sent)
                    answered.signal()
                }
                answered.wait()
                usleep(4000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() { lock.withLock { running = false } }
}

/// Where in a turn of the main run loop the long ones went: timers, sources (events, queued work), the
/// window's layout and drawing (Core Animation's commit), or between. Each stretch over 16 ms is noted
/// with its kind and when.
@MainActor
final class RunLoopAnatomy {
    private(set) var long: [(at: Double, kind: String, ms: Double)] = []
    private var mark = perfNow()
    private var phase = "waking"
    private var observers: [CFRunLoopObserver] = []

    func start() {
        let points: [(CFRunLoopActivity, Int, String)] = [
            (.afterWaiting, Int.min, "waking"), (.beforeTimers, Int.min, "timers"), (.beforeSources, Int.min, "sources"),
            (.beforeWaiting, 1_999_000, "before drawing"), (.beforeWaiting, 2_001_000, "drawing (commit)"),
        ]
        for (index, (activity, order, next)) in points.enumerated() {
            let observer = CFRunLoopObserverCreateWithHandler(nil, activity.rawValue, true, order) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.reach(next, closing: index == 4) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer!)
        }
    }

    private func reach(_ next: String, closing: Bool) {
        let now = perfNow()
        // The stretch just ended was the phase named last; after the commit the loop sleeps (not counted).
        if now - mark > 16, phase != "asleep" { long.append((mark, phase == "drawing (commit)" ? "drawing (commit)" : phase, now - mark)) }
        mark = now
        phase = closing ? "asleep" : next
    }

    func long(from: Double, to: Double) -> String {
        let found = long.filter { $0.at >= from && $0.at <= to }
        guard !found.isEmpty else { return "none" }
        return Dictionary(grouping: found, by: \.kind).map { "\($0.key) \($0.value.count)×, max \(String(format: "%.0f", $0.value.map(\.ms).max() ?? 0)) ms" }.sorted().joined(separator: "; ")
    }
}

/// The run's window counts as the key window of the active app, as a window you type and click in is,
/// though it never takes the keyboard from anyone: a terminal draws its cursor as focused, the meadow
/// paces itself as in front, and a click is a click, not the first click that only brings a window forward.
@MainActor
enum KeyStandIn {
    nonisolated(unsafe) static weak var window: NSWindow?

    static func install(_ window: NSWindow) {
        self.window = window
        for (type, original, replacement): (AnyClass, Selector, Selector) in [
            (NSWindow.self, #selector(getter: NSWindow.isKeyWindow), #selector(NSWindow.debugPerfIsKeyWindow)),
            (NSApplication.self, #selector(getter: NSApplication.isActive), #selector(NSApplication.debugPerfIsActive)),
        ] {
            guard let from = class_getInstanceMethod(type, original), let to = class_getInstanceMethod(type, replacement) else { continue }
            method_exchangeImplementations(from, to)
        }
        // The key window among this app's own (the app stays inactive: nobody else's keyboard moves). Without
        // it the window takes the first click as the one that brings it forward, and drops it.
        window.makeKey()
    }
}

/// The window may be larger than the screen (it is never on it): AppKit would shrink it to fit.
@MainActor
enum UnconstrainedFrame {
    static func install() {
        guard let from = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:))),
              let to = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.debugPerfConstrainFrameRect(_:to:))) else { return }
        method_exchangeImplementations(from, to)
    }
}

extension NSWindow {
    @objc func debugPerfConstrainFrameRect(_ frame: NSRect, to screen: NSScreen?) -> NSRect {
        self === KeyStandIn.window ? frame : debugPerfConstrainFrameRect(frame, to: screen)
    }

    @objc func debugPerfIsKeyWindow() -> Bool {
        self === KeyStandIn.window || debugPerfIsKeyWindow()     // the original, exchanged
    }
}

extension NSApplication {
    @objc func debugPerfIsActive() -> Bool { KeyStandIn.window != nil || debugPerfIsActive() }
}

/// Waits, without polling, for something on the main thread to hold: checked at the start of every turn
/// of the main run loop and after the window's drawing has been committed (just before the loop sleeps).
@MainActor
enum PerfWait {
    /// The time it first held, or nil after `timeout` milliseconds.
    static func until(_ timeout: Double = 5000, _ condition: @escaping @MainActor () -> Bool) async -> Double? {
        if condition() { return perfNow() }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Double?, Never>) in
            let waiter = Waiter(continuation)
            // After Core Animation's commit (order 2,000,000): what held is on its way to the screen.
            let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.beforeTimers.rawValue,
                                                              true, 2_000_100) { _, _ in
                MainActor.assumeIsolated { if condition() { waiter.finish(perfNow()) } }
            }
            waiter.observer = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout / 1000) { waiter.finish(nil) }
        }
    }

    /// One wait: answered once, by whichever comes first.
    private final class Waiter {
        private var continuation: CheckedContinuation<Double?, Never>?
        var observer: CFRunLoopObserver?

        init(_ continuation: CheckedContinuation<Double?, Never>) { self.continuation = continuation }

        func finish(_ time: Double?) {
            guard let continuation else { return }
            self.continuation = nil
            if let observer { CFRunLoopObserverInvalidate(observer) }
            continuation.resume(returning: time)
        }
    }

    /// Several things at once: when each first held (nil for one that had not within `timeout`), each
    /// timed on its own rather than after the one before.
    static func each(_ timeout: Double = 5000, _ conditions: [@MainActor () -> Bool]) async -> [Double?] {
        var times = [Double?](repeating: nil, count: conditions.count)
        let note: @MainActor () -> Bool = {
            let now = perfNow()
            for (index, condition) in conditions.enumerated() where times[index] == nil && condition() { times[index] = now }
            return times.allSatisfy { $0 != nil }
        }
        _ = await until(timeout, note)
        return times
    }

    static func sleep(_ milliseconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(milliseconds)))
    }
}

/// One row of the report.
struct PerfRow {
    var name: String
    var values: [(String, String)]
}

@MainActor
final class PerfSuite {
    let workbench: Workbench
    let controller: MainWindowController
    let window: NSWindow
    let flows: Set<String>?
    let log = PerfLog()
    private lazy var pinger = MainPinger(log: log)
    private let anatomy = RunLoopAnatomy()
    /// What the window's chrome reads of the model (the meadow's snapshot, every tab's title and mark):
    /// counted each time something it read changes. Typing and printing should change none of it.
    private var chromeWatch: Observing?
    private var rows: [PerfRow] = []
    private var checks: [(String, Bool, String)] = []
    /// Measurements against their limits (`--perf-limits`): loose enough never to fail by chance on an
    /// idle Mac, tight enough to catch what made the window lag.
    private var limits: [(String, Bool, String)] = []
    var passed: Bool { checks.allSatisfy(\.1) && limits.allSatisfy(\.1) }

    private func limit(_ name: String, _ value: Double?, atMost most: Double) {
        let ok = value.map { $0.isFinite && $0 <= most } ?? false
        limits.append((name, ok, "\(value.map { String(format: "%.1f", $0) } ?? "none") (limit \(String(format: "%g", most)))"))
    }
    private var root: URL!
    private var main: Pane!

    init(workbench: Workbench, controller: MainWindowController, window: NSWindow, flows: Set<String>?) {
        self.workbench = workbench
        self.controller = controller
        self.window = window
        self.flows = flows
    }

    /// Without `--perf-flows`, every measurement; the correctness checks (`closing`, `sizes`) only when named.
    private func wants(_ flow: String) -> Bool { flows?.contains(flow) ?? !["closing", "sizes"].contains(flow) }

    // MARK: Running

    func run() async {
        let log = log
        TerminalView.onFramePresented = { log.frame() }
        controller.navigator.meadow.onTimings = { log.meadow($0) }
        let workbench = workbench
        chromeWatch = Observing {
            _ = workbench.scene
            for tab in workbench.workspaces.flatMap(\.tabs) { _ = (workbench.title(of: tab), workbench.status(of: tab)) }
            log.invalidated()
        }
        root = AppPlaces.supportFolder.appendingPathComponent("perf", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if DebugScenario.has("--perf-cats") {
            _ = DebugScenario.Demo(workbench: workbench, root: root.appendingPathComponent("cats", isDirectory: true), count: 4)
        }
        // AppKit drops the first click a window ever gets in a run like this one (the one that would bring an
        // inactive window forward): one on Home's empty page, which does nothing, takes its place.
        if let home = controller.terminals.home { click(home, at: NSPoint(x: home.bounds.midX, y: 8)) }
        if wants("closing") { await closingCheck() }
        if wants("sizes") { await sizesCheck() }
        guard flows.map({ !$0.subtracting(["closing", "sizes"]).isEmpty }) ?? true else { return }
        main = workbench.newWorkspace(folder: folder("w1"))
        guard await shellReady(main) else { return note("setup", "the first shell never drew its prompt") }
        pinger.start()
        anatomy.start()
        defer { pinger.stop() }
        if wants("typing") { await typing() }
        if wants("newtab") || wants("close") { await newAndClose() }
        if wants("switch") { await switching() }
        if wants("yes") { await flood("yes", command: "yes 'y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y' | head -200000") }
        if wants("cat") { await flood("cat", command: "cat \(ShellQuote.quote(bigFile().path))", switchMidway: true) }
        if wants("stream") { await flood("stream", command: "perl \(ShellQuote.quote(streamScript().path)) 6", switchMidway: true, typeMidway: true) }
        if wants("idle") { await idle() }
    }

    private func folder(_ name: String) -> String {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func note(_ name: String, _ text: String) { rows.append(PerfRow(name: name, values: [("", text)])) }

    /// The pane's shell has drawn its first prompt (our integration's OSC 7, else quiet output), and a
    /// frame has been drawn since.
    private func shellReady(_ pane: Pane, timeout: Double = 10000) async -> Bool {
        guard let ready = await PerfWait.until(timeout, { pane.debugReady }) else { return false }
        return await PerfWait.until(1000, { self.log.firstFrame(after: ready) != nil }) != nil
    }

    // MARK: Events, as the window gets them

    private func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags = [], code: UInt16 = 0) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    /// A typed key: to the window, which hands it to its first responder.
    private func typeKeys(_ text: String) {
        for character in text {
            let key = character == "\r" ? ("\r", UInt16(36)) : (String(character), UInt16(0))
            if let event = keyEvent(key.0, code: key.1) { NSApp.sendEvent(event) }
        }
    }

    /// A shortcut, as the app routes one: the window's views, then the menus.
    private func shortcut(_ spec: String) {
        DebugScript.key(spec, window: window, quiet: true)
    }

    private var eventNumber = 1000
    private func nextEventNumber() -> Int { eventNumber += 1; return eventNumber }

    /// A click (down, then up) at a point in `view`, delivered as the window delivers a click: to whatever
    /// its views say is under that point. Returns the view that took it.
    @discardableResult
    private func click(_ view: NSView, at point: NSPoint, count: Int = 1) -> NSView? {
        let location = view.convert(point, to: nil)
        let target = hit(view, at: point)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: count,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            NSApp.sendEvent(event)
        }
        return target
    }

    /// What the window would deliver a click at that point in `view` to.
    private func hit(_ view: NSView, at point: NSPoint) -> NSView? {
        window.contentView?.superview?.hitTest(view.convert(point, to: nil))
    }

    /// The pointer moves to a point in `view` and rests there a moment (hover effects show, as before a
    /// real click).
    private func hover(_ view: NSView, at point: NSPoint) async {
        let location = view.convert(point, to: nil)
        // A real pointer moving shows the cursor that typing hid; until then AppKit takes a click as the
        // one that shows it again, and drops it.
        NSCursor.setHiddenUntilMouseMoves(false)
        for type in [NSEvent.EventType.mouseMoved, .mouseMoved] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                window.sendEvent(event)
            }
        }
        await PerfWait.sleep(60)
    }

    /// The tab row's tabs on screen, leading first.
    private var tabViews: [TabMouseView] {
        guard let frame = window.contentView?.superview else { return [] }
        var found: [TabMouseView] = []
        func walk(_ view: NSView) {
            if let tab = view as? TabMouseView, !tab.isHiddenOrHasHiddenAncestor { found.append(tab) }
            view.subviews.forEach(walk)
        }
        walk(frame)
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func tabView(_ tab: Tab) -> TabMouseView? { tabViews.first { $0.tab == tab.id } }

    /// The point of a tab's close button, in the tab's view.
    private func closePoint(_ view: TabMouseView) -> NSPoint { view.closePoint }

    private func screen(_ pane: Pane) -> [String] {
        let rows = pane.surface.terminalDimensions.rows
        return pane.surface.visibleRowsText(0..<rows).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func focused(_ pane: Pane) -> Bool { window.firstResponder === pane.surface && pane.surface.window === window }

    // MARK: Statistics

    private static func pick(_ values: [Double], _ part: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * part + 0.5))]
    }

    private static func ms(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "-" }
        return String(format: "%.1f", value)
    }

    /// Main-thread stalls and the meadow over a stretch of time.
    private func stalls(from: Double, to: Double) -> [(String, String)] {
        let pings = log.pings(from: from, to: to)
        let meadow = log.meadow(from: from, to: to)
        var values: [(String, String)] = [
            ("chrome updates/s", String(format: "%.1f", Double(log.invalidations(from: from, to: to)) / max((to - from) / 1000, 0.001))),
            ("stall p99", Self.ms(Self.pick(pings, 0.99))), ("stall max", Self.ms(pings.max())),
            (">16ms", "\(pings.filter { $0 > 16 }.count)"), (">50ms", "\(pings.filter { $0 > 50 }.count)"),
            ("long turns", anatomy.long(from: from, to: to)),
        ]
        if !meadow.isEmpty {
            let n = Double(meadow.count)
            // Frames drawn (a covered window's are never presented, so the presented count says nothing here).
            values += [("meadow fps", String(format: "%.0f/%d", meadow.map(\.framesPerSecond).reduce(0, +) / n, meadow.last?.targetFramesPerSecond ?? 0)),
                       ("meadow cpu", Self.ms(meadow.map(\.cpuMilliseconds).reduce(0, +) / n)
                            + " (update \(Self.ms(meadow.map(\.updateMilliseconds).reduce(0, +) / n)) pose \(Self.ms(meadow.map(\.poseMilliseconds).reduce(0, +) / n))"
                            + " encode \(Self.ms(meadow.map(\.encodeMilliseconds).reduce(0, +) / n)) slot wait \(Self.ms(meadow.map(\.slotWaitMilliseconds).reduce(0, +) / n)))"),
                       ("meadow gpu", Self.ms(meadow.map(\.gpuMilliseconds).reduce(0, +) / n))]
        }
        return values
    }

    // MARK: (a) Typing

    /// Keystrokes at a typist's pace into `cat` (the terminal's own line discipline echoes each at once).
    private func typing() async {
        main.type("clear; cat > /dev/null\r")
        await PerfWait.sleep(600)
        let log = log
        main.surface.setOutputHandler { log.output() }
        defer { main.surface.setOutputHandler(nil) }
        let count = DebugScenario.value("--perf-keys").flatMap(Int.init) ?? 150
        var sent: [(down: Double, written: Double)] = []
        let start = perfNow()
        for index in 0..<count {
            let letter = String(UnicodeScalar(UInt8(97 + index % 26)))
            guard let event = keyEvent(letter) else { continue }
            let down = perfNow()
            NSApp.sendEvent(event)
            sent.append((down, perfNow()))
            // A brisk typist: 35 to 65 ms apart.
            await PerfWait.sleep(35 + Double(index * 7 % 31))
        }
        await PerfWait.sleep(300)
        let end = perfNow()
        var written: [Double] = [], echoed: [Double] = [], drawn: [Double] = [], lost = 0
        for (index, key) in sent.enumerated() {
            let next = index + 1 < sent.count ? sent[index + 1].down : end
            guard let echo = log.outputs(from: key.down, to: next).first, let frame = log.firstFrame(after: echo) else { lost += 1; continue }
            written.append(key.written - key.down)
            echoed.append(echo - key.down)
            drawn.append(frame - key.down)
        }
        main.type("\u{3}")
        let pings = log.pings(from: start, to: end)
        limit("typing: keystrokes without an echo", Double(lost), atMost: 0)
        limit("typing: keystroke to glyph drawn, median ms", Self.pick(drawn, 0.5), atMost: 25)
        limit("typing: keystroke to glyph drawn, p99 ms", Self.pick(drawn, 0.99), atMost: 50)
        limit("typing: main-thread stalls over 50 ms", Double(pings.filter { $0 > 50 }.count), atMost: 0)
        rows.append(PerfRow(name: "typing", values: [
            ("keys", "\(count)"), ("no echo", "\(lost)"),
            ("to host p50", Self.ms(Self.pick(written, 0.5))),
            ("echo p50", Self.ms(Self.pick(echoed, 0.5))), ("echo p99", Self.ms(Self.pick(echoed, 0.99))),
            ("glyph p50", Self.ms(Self.pick(drawn, 0.5))), ("glyph p99", Self.ms(Self.pick(drawn, 0.99))), ("glyph max", Self.ms(drawn.max())),
        ] + stalls(from: start, to: end)))
    }

    // MARK: (c, d) New tab, close tab

    /// ⌘T, then keys typed at once (they must reach the new tab's shell, none lost, none elsewhere); then
    /// the tab closed again, by its × or by ⌘W, alternately.
    private func newAndClose() async {
        var opened: [String: [Double]] = [:], closed: [String: [Double]] = [:]
        var misses: [String] = []
        let start = perfNow()
        for round in 0..<8 {
            guard let workspace = workbench.selectedWorkspace, let before = workbench.focusedPane else { break }
            let count = workspace.tabs.count
            let marker = "NT\(round)X"
            let down = perfNow()
            shortcut("cmd+t")
            let action = perfNow()
            // Typed straight after: the next events in the queue.
            for character in "echo \(marker)\r" {
                DispatchQueue.main.async { self.typeKeys(String(character)) }
            }
            guard let pane = workbench.focusedPane, pane !== before else { misses.append("⌘T made no tab"); break }
            let early = await PerfWait.each(3000, [{ self.tabViews.count == count + 1 }, { self.focused(pane) }, { pane.debugStarted }])
            let (shown, focus, started) = (early[0], early[1], early[2])
            // The prompt: the first text on its screen, then a frame drawn.
            let prompt = await PerfWait.until(10000) { self.screen(pane).contains { !$0.isEmpty } }.flatMap { log.firstFrame(after: $0) }
            let accepted = await PerfWait.until(10000) { self.screen(pane).contains(marker) }
            if accepted == nil { misses.append("round \(round): typed keys never ran in the new tab") }
            if screen(before).contains(where: { $0.contains("echo \(marker)") }) { misses.append("round \(round): keys went to the previous tab") }
            for (name, time) in [("action", action), ("tab shown", shown), ("focused", focus), ("started", started), ("prompt drawn", prompt), ("keys ran", accepted)] {
                opened[name, default: []].append((time ?? .nan) - down)
            }
            await PerfWait.sleep(300)
            // Close it again: the × (a click where the window would deliver it), or ⌘W.
            let byClick = round % 2 == 0
            guard let tab = workbench.selectedTab else { break }
            let closeDown = perfNow()
            if byClick {
                guard let view = tabView(tab) else { misses.append("round \(round): no view for the tab"); break }
                let hit = click(view, at: closePoint(view))
                if hit !== view { misses.append("round \(round): the × is covered by \(hit.map { String(describing: type(of: $0)) } ?? "nothing")") }
            } else {
                shortcut("cmd+w")
            }
            let closeAction = perfNow()
            let after = await PerfWait.each(2000, [{ self.tabViews.count == count }, { self.focused(before) }])
            let (gone, back) = (after[0], after[1])
            let key = byClick ? "×" : "⌘W"
            for (name, time) in [("action", closeAction), ("gone from bar", gone), ("next shown with the keyboard", back)] {
                closed["\(key) \(name)", default: []].append((time ?? .nan) - closeDown)
            }
            if back == nil { misses.append("round \(round): the previous tab did not get the keyboard back after \(key)") }
            await PerfWait.sleep(300)
        }
        let end = perfNow()
        var values: [(String, String)] = []
        for name in ["action", "tab shown", "focused", "started", "prompt drawn", "keys ran"] {
            values.append((name, Self.ms(Self.pick(opened[name] ?? [], 0.5)) + "/" + Self.ms((opened[name] ?? []).max())))
        }
        rows.append(PerfRow(name: "new tab ⌘T (median/max)", values: values + stalls(from: start, to: end)))
        limit("new tab: keys typed straight after ⌘T lost or misplaced", Double(misses.count), atMost: 0)
        limit("new tab: shown in the row, median ms", Self.pick(opened["tab shown"] ?? [], 0.5), atMost: 50)
        limit("new tab: has the keyboard, median ms", Self.pick(opened["focused"] ?? [], 0.5), atMost: 50)
        limit("new tab: shell started, median ms", Self.pick(opened["started"] ?? [], 0.5), atMost: 100)
        values = []
        for name in ["× action", "× gone from bar", "× next shown with the keyboard", "⌘W action", "⌘W gone from bar", "⌘W next shown with the keyboard"] {
            values.append((name, Self.ms(Self.pick(closed[name] ?? [], 0.5)) + "/" + Self.ms((closed[name] ?? []).max())))
        }
        rows.append(PerfRow(name: "close tab (median/max)", values: values))
        for key in ["×", "⌘W"] {
            limit("close by \(key): gone from the row, median ms", Self.pick(closed["\(key) gone from bar"] ?? [], 0.5), atMost: 50)
            limit("close by \(key): the next tab shown with the keyboard, median ms", Self.pick(closed["\(key) next shown with the keyboard"] ?? [], 0.5), atMost: 50)
        }
        if !misses.isEmpty { note("new/close problems", misses.joined(separator: "; ")) }
    }

    // MARK: (e) Switching

    private func switching() async {
        guard let workspace = workbench.selectedWorkspace else { return }
        // A second tab with a full screen and scrollback, and a second workspace.
        let first = main!
        let second = workbench.newTab()
        _ = await shellReady(second)
        second.type("seq 1 5000\r")
        let other = workbench.newWorkspace(folder: folder("w2"))
        _ = await shellReady(other)
        other.type("seq 1 5000\r")
        guard let otherSpace = workbench.selectedWorkspace else { return }
        workbench.select(workspace: workspace)
        await PerfWait.sleep(800)
        var tabTimes: [Double] = [], spaceTimes: [Double] = []
        let start = perfNow()
        for round in 0..<10 {
            let target = round % 2 == 0 ? second : first
            let down = perfNow()
            shortcut(round % 2 == 0 ? "cmd+2" : "cmd+1")
            // Shown: in the window with the keyboard, and that frame committed (`PerfWait`). Its terminal draws
            // again only if something changed while it was hidden; its layer still holds its last frame.
            if let shown = await PerfWait.until(2000, { self.focused(target) }) {
                tabTimes.append(shown - down)
            } else { tabTimes.append(.nan) }
            await PerfWait.sleep(250)
        }
        for round in 0..<10 {
            let target = round % 2 == 0 ? otherSpace : workspace
            guard let index = workbench.workspaces.firstIndex(where: { $0 === target }) else { break }
            let down = perfNow()
            shortcut("cmd+opt+\(index + 1)")
            if let shown = await PerfWait.until(2000, { self.workbench.selectedWorkspace === target && self.workbench.focusedPane.map(self.focused) == true }) {
                spaceTimes.append(shown - down)
            } else { spaceTimes.append(.nan) }
            await PerfWait.sleep(250)
        }
        let end = perfNow()
        let tabs = tabTimes.filter(\.isFinite), spaces = spaceTimes.filter(\.isFinite)
        limit("switch: tab, median ms", Self.pick(tabs, 0.5), atMost: 50)
        limit("switch: workspace, median ms", Self.pick(spaces, 0.5), atMost: 50)
        limit("switch: switches that never showed", Double(tabTimes.count - tabs.count + spaceTimes.count - spaces.count), atMost: 0)
        rows.append(PerfRow(name: "switch, to shown", values: [
            ("tab p50", Self.ms(Self.pick(tabs, 0.5))), ("tab max", Self.ms(tabs.max())), ("tab failed", "\(tabTimes.count - tabs.count)"),
            ("workspace p50", Self.ms(Self.pick(spaces, 0.5))), ("workspace max", Self.ms(spaces.max())), ("workspace failed", "\(spaceTimes.count - spaces.count)"),
        ] + stalls(from: start, to: end)))
        workbench.select(workspace: workspace)
        workbench.select(tab: workspace.tabs[0])
        _ = await PerfWait.until(1000) { self.focused(first) }
    }

    // MARK: (b) Heavy output

    /// A command that prints a great deal: how long until its last output is drawn, how evenly frames
    /// came meanwhile, how long the main thread stalled; with `switchMidway` a tab switch there and back
    /// while it prints, with `typeMidway` keystrokes (to the bytes leaving for the host).
    private func flood(_ name: String, command: String, switchMidway: Bool = false, typeMidway: Bool = false) async {
        main.type("clear\r")
        await PerfWait.sleep(500)
        let log = log
        main.surface.setOutputHandler { log.output() }
        defer { main.surface.setOutputHandler(nil) }
        let start = perfNow()
        main.type(command + "\r")
        var midway: [(String, String)] = []
        var aside = (from: Double.infinity, to: -Double.infinity)
        if switchMidway || typeMidway {
            await PerfWait.sleep(150)
            aside.from = perfNow()
            if typeMidway {
                var written: [Double] = []
                for _ in 0..<20 {
                    let down = perfNow()
                    if let event = keyEvent("z") { NSApp.sendEvent(event) }
                    written.append(perfNow() - down)
                    await PerfWait.sleep(40)
                }
                midway.append(("key taken max", Self.ms(written.max())))
            }
            if switchMidway, let workspace = workbench.selectedWorkspace, workspace.tabs.count > 1,
               let other = workspace.tabs.dropFirst().first.flatMap({ workbench.panes[$0.focusedPane] }) {
                let down = perfNow()
                shortcut("cmd+2")
                let away = await PerfWait.until(2000) { self.focused(other) }
                await PerfWait.sleep(200)
                let backDown = perfNow()
                shortcut("cmd+1")
                let back = await PerfWait.until(2000) { self.focused(self.main) }
                midway += [("switch away", Self.ms(away.map { $0 - down })), ("switch back", Self.ms(back.map { $0 - backDown }))]
                limit("\(name): tab switch while it prints, ms", away.map { $0 - down }, atMost: 100)
                limit("\(name): tab switch back while it prints, ms", back.map { $0 - backDown }, atMost: 100)
            }
            aside.to = perfNow()
        }
        // Done once nothing has come for half a second.
        _ = await PerfWait.until(60000) { (log.lastOutput ?? start) > start && perfNow() - (log.lastOutput ?? 0) > 500 }
        let last = log.lastOutput ?? start
        let drawnEnd = log.firstFrame(after: last) ?? last
        let frames = log.frames(from: start, to: drawnEnd)
        // Gaps while another tab was shown midway say nothing about this one.
        let gaps = zip(frames.dropFirst(), frames).filter { $0.1 > aside.to || $0.0 < aside.from }.map { $0 - $1 }
        limit("\(name): main-thread stalls over 100 ms", Double(log.pings(from: start, to: drawnEnd).filter { $0 > 100 }.count), atMost: 0)
        rows.append(PerfRow(name: name, values: [
            ("until drawn", Self.ms(drawnEnd - start)), ("frames/s", String(format: "%.0f", Double(frames.count) / max((drawnEnd - start) / 1000, 0.001))),
            ("frame gap p99", Self.ms(Self.pick(gaps, 0.99))), ("frame gap max", Self.ms(gaps.max())),
        ] + midway + stalls(from: start, to: drawnEnd)))
        await PerfWait.sleep(300)
    }

    private func bigFile() -> URL {
        let url = root.appendingPathComponent("big.txt")
        guard !FileManager.default.fileExists(atPath: url.path) else { return url }
        var text = ""
        text.reserveCapacity(8_400_000)
        var line = 0
        while text.utf8.count < 8_000_000 {
            line += 1
            text += "\(line)\t\u{1b}[32mok\u{1b}[0m src/module\(line % 97)/file\(line % 13).swift: the quick brown fox jumps over the lazy dog \(line * 7919 % 10007)\n"
        }
        try? Data(text.utf8).write(to: url)
        return url
    }

    /// A stand-in for Claude Code at work: text streaming in above a status block that is redrawn 30 times a
    /// second (cursor up, clear, draw again, as Ink does), with a spinner.
    private func streamScript() -> URL {
        let url = root.appendingPathComponent("stream.pl")
        let script = #"""
        use Time::HiRes qw(time sleep); binmode STDOUT, ':utf8'; $| = 1;
        my @spin = ("\x{00B7}", "\x{2722}", "\x{2733}", "\x{2736}", "\x{273B}", "\x{273D}");
        my $start = time; my $i = 0; print "\n" x 4;
        while (time - $start < $ARGV[0]) {
          my $out = "\e[4A\e[J";
          $out .= "  Line $i of the answer: the quick brown fox jumps over the lazy dog, again and again and again.\n" if $i % 2 == 0;
          $out .= sprintf("\e[38;5;174m%s\e[0m Thinking\x{2026} (%ds \x{00B7} esc to interrupt)\n", $spin[$i % 6], time - $start);
          $out .= "\e[2m" . ("\x{2500}" x 70) . "\e[0m\n> \n\e[2m  ? for shortcuts\e[0m\n";
          print $out; $i++; sleep(1 / 30);
        }
        """#
        try? Data(script.utf8).write(to: url)
        return url
    }

    // MARK: Idle

    /// Five seconds with nothing typed and nothing printed, after the meadow has had time to rest: the
    /// process's CPU time (with the pings stopped, which cost a little of their own).
    private func idle() async {
        pinger.stop()
        main.type("clear\r")
        await PerfWait.sleep(7000)
        var before = rusage(), after = rusage()
        getrusage(RUSAGE_SELF, &before)
        let start = perfNow()
        await PerfWait.sleep(5000)
        getrusage(RUSAGE_SELF, &after)
        let elapsed = perfNow() - start
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        let cpu = (seconds(after.ru_utime) + seconds(after.ru_stime) - seconds(before.ru_utime) - seconds(before.ru_stime)) * 1000
        let frames = log.frames(from: start, to: start + elapsed)
        limit("idle: process CPU %", cpu / elapsed * 100, atMost: 15)
        limit("idle: chrome updates a second", Double(log.invalidations(from: start, to: start + elapsed)) / (elapsed / 1000), atMost: 1)
        rows.append(PerfRow(name: "idle", values: [("cpu %", String(format: "%.1f", cpu / elapsed * 100)), ("terminal frames/s", String(format: "%.1f", Double(frames.count) / (elapsed / 1000)))]
                            + stalls(from: start, to: start + elapsed).filter { $0.0.hasPrefix("meadow") || $0.0.hasPrefix("chrome") }))
        pinger.start()
    }

    // MARK: Sizes (correctness)

    /// Whether a pane's program, its terminal and its view agree on the size: `stty size` typed into the
    /// shell (what the program was told), the terminal's grid, and the grid the view has room for; and
    /// whether its prompt starts at the left edge.
    private func checkSize(_ pane: Pane, _ name: String) async {
        if !pane.debugReady { guard await shellReady(pane) else { return check("\(name): shell ready", false) } }
        await PerfWait.sleep(300)
        let marker = "SZ\(Int(perfNow()) % 100000)"
        pane.type("echo \(marker) $(stty size)\r")
        // The answer's own line (the command itself, wrapped, can start with the marker too).
        let answer = { (row: String) -> [Int]? in
            let parts = row.split(separator: " ")
            guard parts.count == 3, parts[0] == marker else { return nil }
            let numbers = parts.dropFirst().compactMap { Int($0) }
            return numbers.count == 2 ? numbers : nil
        }
        let told = await PerfWait.until(8000) { self.screen(pane).contains { answer($0) != nil } }
        let parts = screen(pane).compactMap(answer).first ?? []
        let grid = pane.surface.terminalDimensions
        let room = pane.surface.size(for: pane.surface.frame.size)
        let program = parts.count == 2 ? "\(parts[1])x\(parts[0])" : "?"
        check("\(name): program, terminal and view agree on the size", told != nil && program == "\(grid.cols)x\(grid.rows)"
              && grid.cols == room.columns && grid.rows == room.rows,
              "program \(program), terminal \(grid.cols)x\(grid.rows), view room \(room.columns)x\(room.rows), "
              + "view \(pane.surface.convert(pane.surface.bounds, to: nil).integral) in its card \(pane.surface.superview.map { $0.convert($0.bounds, to: nil).integral } ?? .zero)")
    }

    /// New tabs, splits right and down, a three-way split, a divider dragged, the meadow's divider dragged:
    /// after each, every pane on screen is checked (`checkSize`).
    private func sizesCheck() async {
        let first = workbench.newWorkspace(folder: folder("s1"))
        await checkSize(first, "first terminal")
        shortcut("cmd+t")
        guard let tabbed = workbench.focusedPane else { return }
        await checkSize(tabbed, "new tab")
        shortcut("cmd+d")
        guard let right = workbench.focusedPane, right !== tabbed else { return check("split right", false) }
        await checkSize(right, "split right, new pane")
        await checkSize(tabbed, "split right, old pane")
        shortcut("cmd+shift+d")
        guard let down = workbench.focusedPane, down !== right else { return check("split down", false) }
        await checkSize(down, "three-way, new pane")
        await checkSize(right, "three-way, the pane split down")
        await checkSize(tabbed, "three-way, the first pane")
        // A divider dragged with the mouse: the split view's own tracking loop takes the events queued for it.
        if let split = DebugShell.descendant(of: controller.terminals.paneArea, where: { $0 is RatioSplitView }) as? RatioSplitView,
           split.subviews.count == 2 {
            let x = split.subviews[0].frame.maxX + 0.5, y = split.bounds.midY
            let start = split.convert(NSPoint(x: x, y: y), to: nil)
            for step in 1...12 {
                let point = NSPoint(x: start.x - CGFloat(step * 10), y: start.y)
                if let drag = NSEvent.mouseEvent(with: step == 12 ? .leftMouseUp : .leftMouseDragged, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: 1, pressure: step == 12 ? 0 : 1) {
                    NSApp.postEvent(drag, atStart: false)
                }
            }
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: start, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: nextEventNumber(), clickCount: 1, pressure: 1) {
                NSApp.sendEvent(down)
            }
            await PerfWait.sleep(400)
            await checkSize(tabbed, "divider dragged, left pane")
            await checkSize(right, "divider dragged, right pane")
        } else {
            check("a divider to drag", false)
        }
        // The meadow's divider, as a live resize (`DebugResize`).
        LiveResize.shared.begin()
        controller.debugSetLayout { $0.dragDivider(to: 360, window: Double(self.window.frame.width)) }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        LiveResize.shared.end()
        await PerfWait.sleep(400)
        await checkSize(tabbed, "meadow divider dragged, first pane")
        await checkSize(down, "meadow divider dragged, bottom pane")
        DebugShell.snapshot(window: controller, workbench: workbench, to: root.appendingPathComponent("sizes.png"))
        for (index, pane) in [tabbed, right, down].enumerated() {
            let surface = pane.surface
            let scale = window.backingScaleFactor
            // What the layer holds (what the screen shows), against what the view draws when asked.
            if let layer = surface.layer, let context = CGContext(data: nil, width: Int(surface.bounds.width * scale), height: Int(surface.bounds.height * scale), bitsPerComponent: 8,
                                                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.scaleBy(x: scale, y: scale)
                layer.render(in: context)
                if let image = context.makeImage() {
                    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("layer-\(index).png"))
                }
            }
            if let rep = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) {
                surface.cacheDisplay(in: surface.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("drawn-\(index).png"))
            }
            print("check: pane \(index) layer \(surface.layer.map { "\($0.frame) contentsRect \($0.contentsRect) gravity \($0.contentsGravity.rawValue) contents \($0.contents != nil) sublayers \($0.sublayers?.count ?? 0)" } ?? "-")")
        }
    }

    // MARK: Closing everything (correctness)

    private func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        checks.append((name, passed, detail))
        print("check: \(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Clicks a tab's × where the window would deliver it, the pointer resting on it first; checks
    /// nothing covers it.
    private func clickClose(_ tab: Tab, _ name: String) async -> Bool {
        guard let view = tabView(tab) else { check("\(name): tab on screen", false); return false }
        await hover(view, at: closePoint(view))
        let hit = click(view, at: closePoint(view))
        let covered = hit !== view
        if covered { check("\(name): × not covered", false, "hit \(hit.map { String(describing: type(of: $0)) } ?? "nothing")") }
        return !covered
    }

    private func closingCheck() async {
        let start = workbench.workspaces.count
        // One workspace: a plain shell, a busy shell, a split tab, a file, a file with unsaved changes.
        let first = workbench.newWorkspace(folder: folder("c1"))
        _ = await shellReady(first)
        guard let workspace = workbench.selectedWorkspace else { return check("setup", false) }
        let busy = workbench.newTab()
        _ = await shellReady(busy)
        busy.type("sleep 1000\r")
        let splitTab = workbench.newTab()
        _ = await shellReady(splitTab)
        shortcut("cmd+d")
        _ = await PerfWait.until(2000) { (self.workbench.selectedTab?.tree.panes.count ?? 0) == 2 }
        let file = root.appendingPathComponent("c1/notes.txt"), edited = root.appendingPathComponent("c1/edited.txt")
        try? Data("hello\n".utf8).write(to: file)
        try? Data("hello\n".utf8).write(to: edited)
        workbench.open(file: file.path, in: workspace, mode: .keep)
        await PerfWait.sleep(300)
        workbench.open(file: edited.path, in: workspace, mode: .keep)
        let editedTab = workbench.selectedTab
        // Its editor has the keyboard.
        _ = await PerfWait.until(2000) {
            guard let editor = self.window.firstResponder as? NSTextView, let page = editedTab.flatMap({ self.controller.terminals.paneArea.pageView($0.focusedPane) }) else { return false }
            return editor.isDescendant(of: page)
        }
        print("closing: tabs \(workspace.tabs.map { workbench.title(of: $0) }) on screen \(tabViews.count) first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "-")")
        typeKeys("changed ")
        check("an edited file shows as edited", await PerfWait.until(1000) { editedTab.map(self.workbench.hasEditedFile(in:)) ?? false } != nil)
        await PerfWait.sleep(400)
        check("five tabs on screen", tabViews.count == 5, "\(tabViews.count)")
        let title = tabViews.first.map { ($0, NSPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
        if let (view, point) = title {
            await hover(view, at: point)
            var chain: [String] = []
            var ancestor: NSView? = view
            while let current = ancestor {
                if !current.gestureRecognizers.isEmpty { chain.append("\(type(of: current)): \(current.gestureRecognizers.map { "\(type(of: $0)) delays=\($0.delaysPrimaryMouseButtonEvents) state=\($0.state.rawValue)" })") }
                ancestor = current.superview
            }
            print("closing: recognizers above the tab: \(chain)")
            let target = click(view, at: point)
            print("closing: title click went to \(target.map { String(describing: type(of: $0)) } ?? "-") \(target === view), selected now “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")” view tab \(view.tab == workspace.tabs.first?.id)")
            let selected = await PerfWait.until(1000) { self.workbench.selectedTab === workspace.tabs.first }
            await PerfWait.sleep(300)
            check("a click on a tab's title selects it, and it stays selected", selected != nil && workbench.selectedTab === workspace.tabs.first,
                  "selected at first \(selected != nil), then “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")”, first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "-")")
        }

        let title2 = tabViews.dropFirst().first.map { ($0, NSPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
        if let (view, point) = title2 {
            await hover(view, at: point)
            await PerfWait.sleep(1500)
            await hover(view, at: point)
            let target = click(view, at: point)
            print("closing: title click went to \(target.map { String(describing: type(of: $0)) } ?? "-") \(target === view), selected now “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")” view tab \(view.tab == workspace.tabs.dropFirst().first?.id)")
            let selected2 = await PerfWait.until(1000) { self.workbench.selectedTab === workspace.tabs.dropFirst().first }
            await PerfWait.sleep(300)
            check("after resting on it (its tooltip up), a click on a tab's title selects it", selected2 != nil && workbench.selectedTab === workspace.tabs.dropFirst().first,
                  "selected at first \(selected2 != nil), then “\(workbench.selectedTab.map(workbench.title(of:)) ?? "-")”, first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "-")")
        }

        // Every part of every tab takes its own clicks, the pointer resting there (the × shows): the ×,
        // the state mark, the title, the trailing end.
        for view in tabViews {
            for x in [10, 30, view.bounds.midX, view.bounds.maxX - 30, view.closePoint.x] {
                let point = NSPoint(x: x, y: view.bounds.midY)
                await hover(view, at: point)
                let target = hit(view, at: point)
                if target !== view {
                    check("tab \(tabViews.firstIndex { $0 === view } ?? -1) at x \(Int(x)) takes the click", false,
                          "\(target.map { String(describing: type(of: $0)) } ?? "nothing") has it")
                }
            }
        }
        // × on each, in an order that leaves the first for last.
        for (name, tab) in [("× edited file", editedTab), ("× file", workspace.tabs.first { $0 !== editedTab && workbench.pages[$0.focusedPane] != nil }),
                            ("× split tab", workspace.tabs.first { $0.tree.panes.count == 2 }),
                            ("× busy shell", workspace.tabs.first { $0.tree.contains(busy.id) })] {
            guard let tab = name == "× edited file" ? editedTab : tab else { check("\(name): found", false); continue }
            let count = workspace.tabs.count
            print("closing: \(name) on “\(workbench.title(of: tab))” of \(workspace.tabs.map { workbench.title(of: $0) })")
            guard await clickClose(tab, name) else { continue }
            if name == "× edited file" {
                // Save / Cancel / Don't Save: Don't Save.
                let sheet = await PerfWait.until(2000) { self.window.attachedSheet != nil }
                check("\(name): asks first", sheet != nil)
                if let alert = window.attachedSheet, let discard = DebugShell.descendant(of: alert.contentView!, where: { ($0 as? NSButton)?.title == String(localized: "Don’t Save") }) as? NSButton {
                    discard.performClick(nil)
                }
            }
            let gone = await PerfWait.until(2000) { workspace.tabs.count == count - 1 && self.tabViews.count == count - 1 }
            check("\(name): closed", gone != nil, "tabs \(workspace.tabs.count), on screen \(tabViews.count)")
            let focusedNext = await PerfWait.until(2000) {
                self.workbench.focusedPane.map(self.focused) == true || (self.window.firstResponder is NSTextView)
            }
            check("\(name): next tab has the keyboard", focusedNext != nil, "first responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
        }
        // The only tab left: its × closes the workspace, and Home comes.
        if let last = workspace.tabs.first, await clickClose(last, "× only tab") {
            let home = await PerfWait.until(2000) { self.workbench.isHome && !self.workbench.workspaces.contains { $0 === workspace } }
            check("× only tab: workspace closed, Home shown", home != nil)
        }

        // ⌘W and ⌥⌘W from a terminal, an editor, Home and the meadow.
        let second = workbench.newWorkspace(folder: folder("c2"))
        _ = await shellReady(second)
        let other = workbench.newTab()
        _ = await shellReady(other)
        let fileTab = root.appendingPathComponent("c2/readme.txt")
        try? Data("hi\n".utf8).write(to: fileTab)
        workbench.open(file: fileTab.path, mode: .keep)
        _ = await PerfWait.until(2000) { self.window.firstResponder is NSTextView }
        var count = workbench.selectedWorkspace?.tabs.count ?? 0
        shortcut("cmd+w")
        check("⌘W in an editor closes its tab", await PerfWait.until(2000) { (self.workbench.selectedWorkspace?.tabs.count ?? 0) == count - 1 } != nil)
        _ = await PerfWait.until(2000) { self.workbench.focusedPane.map(self.focused) == true }
        count = workbench.selectedWorkspace?.tabs.count ?? 0
        shortcut("cmd+opt+w")
        check("⌥⌘W in a terminal closes its tab", await PerfWait.until(2000) { (self.workbench.selectedWorkspace?.tabs.count ?? 0) == count - 1 } != nil)
        _ = await PerfWait.until(2000) { self.workbench.focusedPane.map(self.focused) == true }
        shortcut("opt+cmd+0")
        _ = await PerfWait.until(1000) { self.window.firstResponder === self.controller.navigator.meadow }
        check("the meadow has the keyboard", window.firstResponder === controller.navigator.meadow)
        shortcut("cmd+w")
        check("⌘W with the meadow focused closes the last tab, Home shows", await PerfWait.until(2000) { self.workbench.isHome } != nil)
        shortcut("cmd+w")
        shortcut("cmd+opt+w")
        check("⌘W and ⌥⌘W on Home change nothing", workbench.isHome && workbench.workspaces.count == start)

        // Ten tabs closed by × as fast as clicks can come: every one goes, Home at the end.
        _ = await shellReady(workbench.newWorkspace(folder: folder("c3")))
        for _ in 0..<9 { workbench.newTab() }
        _ = await PerfWait.until(3000) { (self.workbench.selectedWorkspace?.tabs.count ?? 0) == 10 }
        await PerfWait.sleep(300)
        // The row shows as many as fit (`TabRowLayout`), always the selected one whole, its × inside the window.
        let selectedWhole = workbench.selectedTab.flatMap(tabView).map { view in
            window.contentView!.bounds.contains(view.convert(view.bounds, to: nil).insetBy(dx: 0.5, dy: 0.5))
        } ?? false
        check("ten tabs: the selected one whole on screen", (workbench.selectedWorkspace?.tabs.count ?? 0) == 10 && selectedWhole,
              "\(tabViews.count) in sight")
        await PerfWait.sleep(500)
        DebugShell.snapshot(window: controller, workbench: workbench, to: root.appendingPathComponent("ten-tabs.png"))
        print("closing: ten tabs at \(tabViews.map { Int($0.convert($0.bounds, to: nil).minX) }), window \(Int(window.frame.width))")
        var clicks = 0
        // The selected tab's ×, which the row keeps in view, again and again where it is now.
        while let tab = workbench.selectedTab, let view = tabView(tab), clicks < 20 {
            clicks += 1
            let target = click(view, at: closePoint(view))
            // The next click comes as soon as the bar has drawn again (a fast double-tapper).
            let gone = await PerfWait.until(500) { self.tabView(tab) == nil }
            if gone == nil { print("closing: rapid click \(clicks) did nothing; it went to \(target.map { String(describing: type(of: $0)) } ?? "-")") }
        }
        check("rapid ×: ten clicks closed ten tabs and Home shows", clicks == 10 && workbench.isHome && workbench.workspaces.count == start,
              "\(clicks) clicks, home \(workbench.isHome)")
        // Ten tabs closed by ⌘W held down (key repeat, 30 a second).
        let held = workbench.newWorkspace(folder: folder("c4"))
        _ = await shellReady(held)
        for _ in 0..<9 { workbench.newTab() }
        _ = await PerfWait.until(3000) { (self.workbench.selectedWorkspace?.tabs.count ?? 0) == 10 }
        for _ in 0..<12 {
            shortcut("cmd+w")
            await PerfWait.sleep(33)
        }
        _ = await PerfWait.until(2000) { self.workbench.isHome }
        check("⌘W repeated: every tab closed, Home shows", workbench.isHome && workbench.workspaces.count == start, "workspaces \(workbench.workspaces.count)")

        // Nothing left behind once the undo has run out.
        await PerfWait.sleep((Workbench.undoSeconds + 1.5) * 1000)
        let cards = DebugShell.descendant(of: controller.terminals.paneArea) { $0 is PaneCard }
        check("nothing left: no panes, no terminal views, no tabs", workbench.panes.isEmpty && cards == nil && tabViews.isEmpty && workbench.pages.isEmpty,
              "panes \(workbench.panes.count), pages \(workbench.pages.count), tabs on screen \(tabViews.count), cards \(cards == nil ? 0 : 1)")
    }

    // MARK: Report

    func report() -> String {
        var lines = ["Whiskr perf: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") "
                     + "\(isOptimised ? "optimised" : "unoptimised") window \(Int(window.frame.width))x\(Int(window.frame.height)) "
                     + "@\(Int(window.backingScaleFactor))x\(DebugScenario.has("--perf-cats") ? " with working cats" : ""), terminals drawn "
                     + (main.map { $0.surface.isUsingRenderLoop ? "by Metal on a render thread" : $0.surface.isUsingMetalRenderer ? "by Metal" : "by Core Graphics" } ?? "-")]
        for row in rows {
            lines.append(row.name + ": " + row.values.map { $0.0.isEmpty ? $0.1 : "\($0.0) \($0.1)" }.joined(separator: " · "))
        }
        let broken = limits.filter { !$0.1 }
        if !limits.isEmpty {
            lines.append("limits: \(limits.count - broken.count)/\(limits.count) kept" + (broken.isEmpty ? "" : "; PASSED: " + broken.map { "\($0.0) \($0.2)" }.joined(separator: "; ")))
        }
        if !checks.isEmpty {
            let failed = checks.filter { !$0.1 }
            lines.append("checks: \(checks.count - failed.count)/\(checks.count) passed" + (failed.isEmpty ? "" : "; FAILED: " + failed.map { "\($0.0) (\($0.2))" }.joined(separator: "; ")))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Built with optimisation (`make perf`'s profile build) or not (a Debug build).
    private var isOptimised: Bool { !_isDebugAssertConfiguration() }
}
#endif
