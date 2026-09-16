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
///   --perf-flows <a,b,…>      only these: typing, yes, cat, stream, newtab, close, switch, memory, idle, motion
///                             (the interface's transitions, frame by frame: `DebugAnimations`); and the
///                             checks, run only when named: closing, sizes, interactions (`DebugInteractions`),
///                             journey, files, layout, robust, alerts (`DebugFlowAlerts`),
///                             meadow (`DebugFlowMeadowFollow`), chrome (`DebugFlowChrome`) and resize
///                             (dividers dragged, the window resized, regions shown and hidden: `DebugFlowResize`),
///                             split (a tab split into panes: its segments, closing, "+", headers, the line between
///                             panes: `DebugFlowSplit`), drag (tabs picked up and dropped: `DebugFlowDrag`), home
///                             (New Workspace and Open Folder… from every place: `DebugFlowHome`) and sky (the real
///                             sun, moon and weather, and Settings › Meadow's switch for each: `DebugFlowSky`) and
///                             editor (editing the meadow: `DebugFlowEditor`) and library (My Meadows and meadow files:
///                             `DebugFlowLibrary`)
///   --perf-cats               four more workspaces with Claudes at work, so the meadow is busy
///   --perf-keys <n>           keystrokes timed in `typing` (150)
///   --perf-limits             checks the measurements against `PerfSuite`'s limits; exits with 1 when one
///                             is passed or a check fails (`make perf`)
///
/// Measured: the first terminal after launch, from before it is made; each keystroke from the moment it is
/// queued for the app, to the app taking it (its bytes leave for the host in that same call), to its echo
/// taken in by the terminal, to the terminal's next frame drawn (`TerminalView.onFramePresented`); how long the main
/// thread took to answer a ping sent every 4 ms (a stall is time the window cannot take a key or draw);
/// terminal frames drawn and the longest gap between them; the meadow's frames, main-thread and GPU time;
/// memory (the app's and its session host's footprint) with 1 and with 20 tabs; at idle, by day and by night,
/// the app's and the host's CPU and wakeups and the meadow's frames and GPU time; and, for every limit, how
/// busy the rest of the Mac was meanwhile (`MachineLoad`).
/// Not measured: the compositor's own step from a drawn frame to the glass (one display refresh).
@MainActor
enum DebugPerf {
    static var isOn: Bool { DebugScenario.value("--perf") != nil }

    /// Before any terminal view exists. SwiftTerm draws on the view's own display link, which stops for a
    /// covered window; Core Video's link ticks at the display's rate whatever the window, and runs the same
    /// frame code.
    static func prepareProcess() {
        if isOn || DebugScenario.value("--measure-files") != nil {
            // A window in front is never put to App Nap; the run's, never seen, would be, and its timers
            // (the main-thread watches among them) coalesced and late by tens of milliseconds: waits that are
            // not work, read as holds. Held for the run's life.
            appNapStandIn = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                                  reason: "Measuring as a window in front")
        }
        guard isOn else { return }
        setenv("SWIFTTERM_FORCE_CVDISPLAYLINK", "1", 1)
    }

    private static var appNapStandIn: NSObjectProtocol?

    static func run(workbench: Workbench, window controller: MainWindowController) {
        guard let out = DebugScenario.value("--perf"), let window = controller.window else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        KeyStandIn.install(window)
        // The run's own pointer for every flow, from the start: without it, what the views ask of the pointer
        // (a tab that slid under it, a link under ⌘) was the real pointer of whoever sits at this Mac.
        PointerStandIn.install()
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
        MachineLoad.shared.start(hostLog: PerfSuite.hostLog)
        Task {
            await suite.run()
            let text = suite.report()
            print(text)
            try? Data(text.utf8).write(to: URL(fileURLWithPath: out))
            if DebugScenario.has("--perf-limits"), let status = exitStatus(passed: suite.passed, comparable: suite.comparable) {
                // As quitting would, with the status saying it failed (1) or could not be judged (3).
                workbench.shutDown(stoppingSessions: true)
                exit(status)
            }
            NSApp.terminate(nil)
        }
    }

    /// A run's exit status under `--perf-limits` (and the editor's `--measure-limits`): nil when everything
    /// held, 1 when a check failed or a limit was passed on a quiet machine, 3 when what passed a limit was
    /// measured while the rest of the Mac was busy, so the run says nothing either way (`make perf`).
    static func exitStatus(passed: Bool, comparable: Bool) -> Int32? {
        !passed ? 1 : !comparable ? 3 : nil
    }

    /// Others' load over the whole run, for a report's last line.
    nonisolated static func machineSummary() -> String {
        let all = MachineLoad.shared.all.sorted()
        guard !all.isEmpty else { return "machine: others' load not measured" }
        return String(format: "machine: %d cores; others' load median %.1f, max %.1f cores (busy above %.1f)",
                      MachineLoad.cores, all[all.count / 2], all.last!, MachineLoad.busyCores)
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

/// How busy the rest of the Mac is while a run measures: every core's time as the kernel counts it, less the
/// run's own (the app, its session host and every process under either), in cores, sampled twice a second
/// from a thread of its own. A timing taken while others keep more than `busyCores` busy is not comparable
/// with one taken on a quiet Mac: `make perf` marks it so rather than passing or failing it.
nonisolated final class MachineLoad: @unchecked Sendable {
    static let shared = MachineLoad()
    /// Others' load (in cores) above which a timing is not comparable: about what one busy program costs.
    static let busyCores = 1.0
    static let cores = ProcessInfo.processInfo.activeProcessorCount

    private let lock = NSLock()
    private var samples: [(at: Double, others: Double)] = []
    private var hostLog: URL?
    private var started = false

    /// Starts sampling (once); `hostLog` is the run's session host's log, which names its process.
    func start(hostLog: URL) {
        let first = lock.withLock {
            self.hostLog = hostLog
            defer { started = true }
            return !started
        }
        guard first else { return }
        let thread = Thread { [self] in
            var last = reading()
            while true {
                usleep(500_000)
                let now = reading()
                let wall = now.at - last.at
                if wall > 0, now.total > last.total {
                    let machine = Double(now.busy - last.busy) / Double(now.total - last.total) * Double(Self.cores)
                    // A process of the run's that started since the last sample used all its time in between.
                    let own = now.own.reduce(0.0) { $0 + max(0, $1.value - (last.own[$1.key] ?? 0)) } / wall
                    lock.withLock { samples.append((now.at, max(0, machine - own))) }
                }
                last = now
            }
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Others' mean load from `from` to `to` (milliseconds on `perfNow`'s clock), in cores; nil before the
    /// first sample.
    func others(from: Double, to: Double) -> Double? {
        lock.withLock {
            let within = samples.filter { $0.at >= from && $0.at <= to + 500 }
            let chosen = within.isEmpty ? samples.last(where: { $0.at <= to + 500 }).map { [$0] } ?? [] : within
            return chosen.isEmpty ? nil : chosen.map(\.others).reduce(0, +) / Double(chosen.count)
        }
    }

    /// Every sample so far.
    var all: [Double] { lock.withLock { samples.map(\.others) } }

    private struct Reading { var at: Double; var busy: UInt64; var total: UInt64; var own: [pid_t: Double] }

    private func reading() -> Reading {
        var busy: UInt64 = 0, total: UInt64 = 0
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info {
            for cpu in 0..<Int(count) {
                func ticks(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[cpu * Int(CPU_STATE_MAX) + Int(state)])) }
                let used = ticks(CPU_STATE_USER) + ticks(CPU_STATE_SYSTEM) + ticks(CPU_STATE_NICE)
                busy += used
                total += used + ticks(CPU_STATE_IDLE)
            }
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var own: [pid_t: Double] = [:]
        for pid in Self.processes(under: [getpid()] + (lock.withLock { hostLog }.flatMap(Self.hostPID).map { [$0] } ?? [])) {
            if let usage = PerfSuite.usage(pid) { own[pid] = PerfSuite.cpuMilliseconds(usage) }
        }
        return Reading(at: perfNow(), busy: busy, total: total, own: own)
    }

    /// The run's own session host: the process its log, in the run's isolated folder, says is listening.
    static func hostPID(log: URL) -> pid_t? {
        guard let text = try? String(contentsOf: log, encoding: .utf8),
              let line = text.split(separator: "\n").last(where: { $0.contains("] listening on") }),
              let open = line.firstIndex(of: "["), let close = line[open...].firstIndex(of: "]"),
              let pid = pid_t(line[line.index(after: open)..<close]), kill(pid, 0) == 0 else { return nil }
        return pid
    }

    /// `roots` and every process under them.
    static func processes(under roots: [pid_t]) -> Set<pid_t> {
        var pids = [pid_t](repeating: 0, count: Int(max(proc_listallpids(nil, 0), 0)) + 64)
        let found = Int(max(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)), 0))
        var parent: [pid_t: pid_t] = [:]
        for pid in pids.prefix(found) where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            if proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size { parent[pid] = pid_t(info.pbsi_ppid) }
        }
        var own = Set(roots), grew = true
        while grew {
            grew = false
            for (pid, up) in parent where !own.contains(pid) && own.contains(up) {
                own.insert(pid)
                grew = true
            }
        }
        return own
    }
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
    /// Off: the window counts as not key and the app as not active (the idle flow's "not key").
    nonisolated(unsafe) static var standsIn = true

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
        // It stays so: the system takes key away from a window nobody sees when you change app or Space, and
        // every click after that was dropped (the meadow flow's click on a terminal, on a Mac in use).
        resigned = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { if standsIn { KeyStandIn.window?.makeKey() } }
        }
    }

    nonisolated(unsafe) private static var resigned: NSObjectProtocol?
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
        self === KeyStandIn.window ? KeyStandIn.standsIn : debugPerfIsKeyWindow()     // the original, exchanged
    }
}

extension NSApplication {
    @objc func debugPerfIsActive() -> Bool { KeyStandIn.window != nil ? KeyStandIn.standsIn : debugPerfIsActive() }
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

/// The run's own events queued for the app (`NSApplication.postEvent`), as the window server queues a
/// person's: a click's release behind its press, a drag's moves, a key. AppKit does not hand out the event
/// it was given: it takes a copy off the queue, and on a busy Mac (a few runs in ten) a mouse event's copy
/// came off it with its x moved by hundreds or thousands of points (a release made at 1,355.5 taken at
/// 3,063.5; once its y too), its time, number and screen point as made. The release then lay outside the
/// control it pressed, and the control rightly did nothing (`BarControlView` and `TabMouseView` act only on
/// a release over them): a check failed now and then, never for a person, whose events come from the
/// window server, not `postEvent`. So wherever a queued event's copy goes (`nextEvent`, to the run loop or
/// a tracking loop; then `sendEvent`, from the run loop, which sends the copy it took), the event the run
/// made goes instead.
@MainActor
enum QueuedEvents {
    /// Queued and not yet sent, in order, with AppKit's copy once it has come off the queue. One a tracking
    /// loop takes and handles itself is never sent, and stays (a drag's moves and release: a few in a run).
    private static var waiting: [(made: NSEvent, copy: NSEvent?)] = []
    private static var installed = false
    /// The kinds of event that have a place in the window.
    private static let pointed: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
                                                          .otherMouseDown, .otherMouseUp, .mouseMoved]

    static func post(_ event: NSEvent) {
        install()
        waiting.append((event, nil))
        NSApp.postEvent(event, atStart: false)
    }

    /// The event the run made for `taken`, if it is AppKit's copy of one queued here: one seen before, or
    /// one of the same kind and time (to the nanosecond the copy keeps) just come off the queue. Once sent,
    /// it is no longer waiting. A copy that came off changed is said so.
    fileprivate static func made(for taken: NSEvent, sending: Bool) -> NSEvent? {
        guard !waiting.isEmpty, let index = waiting.firstIndex(where: { $0.copy === taken })
            ?? waiting.firstIndex(where: { $0.copy == nil && $0.made.type == taken.type && abs($0.made.timestamp - taken.timestamp) < 0.000_001 }) else { return nil }
        let made = waiting[index].made
        if waiting[index].copy == nil, pointed.contains(made.type), made.locationInWindow != taken.locationInWindow {
            print("queued events: a \(made.type) made at \(made.locationInWindow) came off the queue at \(taken.locationInWindow); the one made goes on")
        }
        if sending { waiting.remove(at: index) } else { waiting[index].copy = taken }
        return made
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        for (original, replacement) in [(#selector(NSApplication.sendEvent(_:)), #selector(NSApplication.debugQueuedSendEvent(_:))),
                                        (#selector(NSApplication.nextEvent(matching:until:inMode:dequeue:)),
                                         #selector(NSApplication.debugQueuedNextEvent(matching:until:inMode:dequeue:)))] {
            guard let from = class_getInstanceMethod(NSApplication.self, original), let to = class_getInstanceMethod(NSApplication.self, replacement) else { continue }
            method_exchangeImplementations(from, to)
        }
    }
}

extension NSApplication {
    /// Stands in for `sendEvent(_:)` (`QueuedEvents`).
    @objc func debugQueuedSendEvent(_ event: NSEvent) {
        debugQueuedSendEvent(QueuedEvents.made(for: event, sending: true) ?? event)     // the original, exchanged
    }

    /// Stands in for `nextEvent(matching:until:inMode:dequeue:)` (`QueuedEvents`).
    @objc func debugQueuedNextEvent(matching mask: NSEvent.EventTypeMask, until date: Date?, inMode mode: RunLoop.Mode, dequeue: Bool) -> NSEvent? {
        let event = debugQueuedNextEvent(matching: mask, until: date, inMode: mode, dequeue: dequeue)     // the original, exchanged
        guard dequeue, let event else { return event }
        return QueuedEvents.made(for: event, sending: false) ?? event
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
    var rows: [PerfRow] = []
    private var checks: [(String, Bool, String)] = []
    /// Measurements against their limits (`--perf-limits`): loose enough never to fail by chance on an
    /// idle Mac, tight enough to catch what made the window lag. One passed while the rest of the Mac was
    /// busy (`MachineLoad`) is not comparable: neither a failure nor a pass.
    enum LimitResult: String { case kept, passed = "PASSED", notComparable = "not comparable" }
    private var limits: [(String, LimitResult, String)] = []
    var passed: Bool { checks.allSatisfy(\.1) && !limits.contains { $0.1 == .passed } }
    /// No limit was left undecided by a busy machine.
    var comparable: Bool { !limits.contains { $0.1 == .notComparable } }
    /// When the flow being measured began: a limit's machine load is taken over its flow.
    private var flowStart = perfNow()

    func limit(_ name: String, _ value: Double?, atMost most: Double) {
        let ok = value.map { $0.isFinite && $0 <= most } ?? false
        let others = MachineLoad.shared.others(from: flowStart, to: perfNow())
        let result: LimitResult = ok ? .kept : (others ?? 0) > MachineLoad.busyCores ? .notComparable : .passed
        limits.append((name, result, "\(value.map { String(format: "%.1f", $0) } ?? "none") (limit \(String(format: "%g", most)))"
                       + "; others' load \(others.map { String(format: "%.1f", $0) } ?? "-") cores"))
        // Said as it is measured, as checks are: a run that crashes later writes no table.
        print("limit: \(result.rawValue) \(name): \(limits.last!.2)")
    }
    var root: URL!
    private var main: Pane!

    init(workbench: Workbench, controller: MainWindowController, window: NSWindow, flows: Set<String>?) {
        self.workbench = workbench
        self.controller = controller
        self.window = window
        self.flows = flows
    }

    /// The correctness checks, run only when named.
    private static let checkFlows: Set<String> = ["closing", "sizes", "interactions", "journey", "files", "layout", "robust", "alerts", "meadow", "chrome", "resize",
                                                     "split", "drag", "home", "sky", "editor", "library"]

    /// Without `--perf-flows`, every measurement; the checks only when named.
    private func wants(_ flow: String) -> Bool { flows?.contains(flow) ?? !Self.checkFlows.contains(flow) }

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
        // AppKit drops the first click a window ever gets in a run like this one (the one that would bring an
        // inactive window forward): one on Home's empty page, which does nothing, takes its place.
        if let home = controller.terminals.home { click(home, at: NSPoint(x: home.bounds.midX, y: 8)) }
        if wants("closing") { await closingCheck() }
        if wants("sizes") { await sizesCheck() }
        if wants("interactions") { await interactionsCheck() }
        if wants("journey") { await journeyCheck() }
        if wants("files") { await filesCheck() }
        if wants("layout") { await layoutCheck() }
        if wants("robust") { await robustCheck() }
        if wants("alerts") { await alertsCheck() }
        if wants("meadow") { await meadowFollowCheck() }
        if wants("chrome") { await chromeCheck() }
        if wants("resize") { await resizeCheck() }
        if wants("split") { await splitCheck() }
        if wants("drag") { await dragCheck() }
        if wants("home") { await homeEntryCheck() }
        if wants("sky") { await skyCheck() }
        if wants("editor") { await editorCheck() }
        if wants("library") { await libraryCheck() }
        guard flows.map({ !$0.subtracting(Self.checkFlows).isEmpty }) ?? true else { return }
        // From before the first terminal: making its view (its renderer among it) is main-thread work too.
        pinger.start()
        anatomy.start()
        defer { pinger.stop() }
        flowStart = perfNow()
        guard await firstTerminal() else { return note("setup", "the first shell never drew its prompt") }
        // The cats come after it, so the first terminal is the first one the window ever draws.
        if DebugScenario.has("--perf-cats"), let space = workbench.selectedWorkspace {
            _ = DebugScenario.Demo(workbench: workbench, root: root.appendingPathComponent("cats", isDirectory: true), count: 4)
            catsMadeAt = perfNow()
            workbench.select(workspace: space)
            _ = await PerfWait.until(2000) { self.focused(self.main) }
            await PerfWait.sleep(1000)
        }
        let measured: [(String, () async -> Void)] = [
            ("memory", memory), ("typing", typing), ("newtab", newAndClose), ("switch", switching),
            ("yes", { await self.flood("yes", command: "yes 'y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y y' | head -200000") }),
            ("cat", { await self.flood("cat", command: "cat \(ShellQuote.quote(self.bigFile().path))", switchMidway: true) }),
            ("stream", { await self.flood("stream", command: "perl \(ShellQuote.quote(self.streamScript().path)) 6", switchMidway: true, typeMidway: true) }),
            ("idle", idle),
            // Last: the workspace it opens and closes again changes nothing measured before it.
            ("motion", motion),
        ]
        for (name, flow) in measured where wants(name) || (name == "newtab" && wants("close")) {
            flowStart = perfNow()
            await flow()
        }
    }

    /// When the demo's cats were made (`--perf-cats`): they doze off `AgentWorld.napAfter` seconds later.
    private var catsMadeAt: Double?

    func folder(_ name: String) -> String {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func note(_ name: String, _ text: String) { rows.append(PerfRow(name: name, values: [("", text)])) }

    /// The pane's shell has drawn its first prompt (our integration's OSC 7, else quiet output), and a
    /// frame has been drawn since.
    func shellReady(_ pane: Pane, timeout: Double = 10000) async -> Bool {
        guard let ready = await PerfWait.until(timeout, { pane.debugReady }) else { return false }
        return await PerfWait.until(1000, { self.log.firstFrame(after: ready) != nil }) != nil
    }

    // MARK: Events, as the window gets them (also `DebugInteractions`'s)

    func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags = [], code: UInt16 = 0) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    /// A typed key: to the window, which hands it to its first responder.
    func typeKeys(_ text: String) {
        for character in text {
            let key = character == "\r" ? ("\r", UInt16(36)) : (String(character), UInt16(0))
            if let event = keyEvent(key.0, code: key.1) { NSApp.sendEvent(event) }
        }
    }

    /// A shortcut, as the app routes one: the window's views, then the menus.
    func shortcut(_ spec: String) {
        DebugScript.key(spec, window: window, quiet: true)
    }

    private var eventNumber = 1000
    func nextEventNumber() -> Int { eventNumber += 1; return eventNumber }

    /// A click (down, then up) at a point in `view`, delivered as the window delivers a click: to whatever
    /// its views say is under that point. Returns the view that took it.
    @discardableResult
    func click(_ view: NSView, at point: NSPoint, count: Int = 1) -> NSView? {
        let location = view.convert(point, to: nil)
        PointerStandIn.location = location
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
    func hit(_ view: NSView, at point: NSPoint) -> NSView? {
        window.contentView?.superview?.hitTest(view.convert(point, to: nil))
    }

    /// The pointer moves to a point in `view` and rests there a moment (hover effects show, as before a
    /// real click).
    func hover(_ view: NSView, at point: NSPoint) async {
        let location = view.convert(point, to: nil)
        PointerStandIn.location = location
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
    var tabViews: [TabMouseView] {
        guard let frame = window.contentView?.superview else { return [] }
        var found: [TabMouseView] = []
        func walk(_ view: NSView) {
            if let tab = view as? TabMouseView, !tab.isHiddenOrHasHiddenAncestor { found.append(tab) }
            view.subviews.forEach(walk)
        }
        walk(frame)
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    func tabView(_ tab: Tab) -> TabMouseView? { tabViews.first { $0.tab == tab.id } }

    /// The point of a tab's close button, in the tab's view.
    private func closePoint(_ view: TabMouseView) -> NSPoint { view.closePoint }

    func screen(_ pane: Pane) -> [String] {
        let rows = pane.surface.terminalDimensions.rows
        return pane.surface.visibleRowsText(0..<rows).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func focused(_ pane: Pane) -> Bool { window.firstResponder === pane.surface && pane.surface.window === window }

    // MARK: Statistics

    static func pick(_ values: [Double], _ part: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * part + 0.5))]
    }

    static func ms(_ value: Double?) -> String {
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

    // MARK: The first terminal

    /// The first terminal after launch (cold: no terminal has been drawn in this run), made as Home's New
    /// Terminal makes it: when its tab shows, takes the keyboard, its shell starts and its prompt is drawn,
    /// and what the main thread went through meanwhile.
    private func firstTerminal() async -> Bool {
        let before = workbench.panes.count
        let start = perfNow()
        main = workbench.newWorkspace(folder: folder("w1"))
        let pane = main!
        let action = perfNow()
        let early = await PerfWait.each(5000, [{ self.workbench.selectedTab.flatMap(self.tabView) != nil }, { self.focused(pane) }, { pane.debugStarted }])
        let prompt = await drawn(after: await PerfWait.until(10000) { self.screen(pane).contains { !$0.isEmpty } })
        let ready = await shellReady(pane)
        let end = perfNow()
        rows.append(PerfRow(name: before == 0 ? "first terminal, cold (the first after launch)" : "first terminal (after \(before) made before it)", values: [
            ("action", Self.ms(action - start)), ("tab shown", Self.ms(early[0].map { $0 - start })), ("focused", Self.ms(early[1].map { $0 - start })),
            ("started", Self.ms(early[2].map { $0 - start })), ("prompt drawn", Self.ms(prompt.map { $0 - start })),
        ] + stalls(from: start, to: end)))
        limit("first terminal: shown with the keyboard, ms", early[1].map { $0 - start }, atMost: 150)
        limit("first terminal: longest main-thread stall, ms", log.pings(from: start, to: end).max(), atMost: 150)
        oneTab = (Self.footprint(getpid()), hostPID.flatMap(Self.footprint))
        return ready
    }

    /// The first terminal frame drawn after a moment (waiting up to a second for it).
    private func drawn(after time: Double?) async -> Double? {
        guard let time else { return nil }
        _ = await PerfWait.until(1000) { self.log.firstFrame(after: time) != nil }
        return log.firstFrame(after: time)
    }

    // MARK: Memory

    /// The app's and its session host's footprint with one tab (`firstTerminal`), set aside when it was made.
    private var oneTab: (app: Double?, host: Double?) = (nil, nil)

    /// Memory with 20 tabs open, each shown once: 19 more in a workspace of their own (closed again after).
    private func memory() async {
        guard let space = workbench.selectedWorkspace else { return }
        let first = workbench.newWorkspace(folder: folder("m"))
        _ = await shellReady(first)
        for _ in 0..<18 {
            let pane = workbench.newTab()
            _ = await shellReady(pane)
        }
        await PerfWait.sleep(1500)
        let tabs = workbench.workspaces.reduce(0) { $0 + $1.tabs.count }
        let app = Self.footprint(getpid()), host = hostPID.flatMap(Self.footprint)
        func mb(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "-" }
        rows.append(PerfRow(name: "memory, footprint MB", values: [
            ("app, 1 tab", mb(oneTab.app)), ("app, \(tabs) tabs", mb(app)),
            ("app per tab", mb(app.flatMap { app in oneTab.app.map { (app - $0) / Double(max(tabs - 1, 1)) } })),
            ("host, 1 tab", mb(oneTab.host)), ("host, \(tabs) tabs", mb(host)),
        ]))
        limit("memory: the app's footprint with \(tabs) tabs, MB", app, atMost: 900)
        limit("memory: the app's footprint for each tab past the first, MB", app.flatMap { app in oneTab.app.map { (app - $0) / Double(max(tabs - 1, 1)) } }, atMost: 35)
        // Tabs out of the window give their renderers back after `metalRestDelay`: what is left once they have.
        await PerfWait.sleep(Double(TerminalSurface.metalRestDelay.components.seconds) * 1000 + 2000)
        let rested = Self.footprint(getpid())
        rows[rows.count - 1].values.append(("app, \(tabs) tabs after their renderers rest", mb(rested)))
        limit("memory: the app's footprint with \(tabs) tabs once hidden ones have rested, MB", rested, atMost: 450)
        if let created = workbench.workspaces.first(where: { $0.tabs.contains { $0.tree.contains(first.id) } }) { workbench.close(workspace: created) }
        workbench.select(workspace: space)
        _ = await PerfWait.until(2000) { self.focused(self.main) }
        await PerfWait.sleep(500)
    }

    /// A process's physical footprint in MB, as Activity Monitor's Memory column shows it: this app's from
    /// its own task (`TASK_VM_INFO`), another's (its session host) from `proc_pid_rusage`.
    nonisolated static func footprint(_ pid: pid_t) -> Double? {
        if pid == getpid() {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
        }
        return usage(pid).map { Double($0.ri_phys_footprint) / 1_048_576 }
    }

    /// Another process's resource usage (one of this user's: the run's session host).
    nonisolated static func usage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? info : nil
    }

    /// CPU time a process has used, in milliseconds (`proc_pid_rusage` counts in Mach time units).
    nonisolated static func cpuMilliseconds(_ usage: rusage_info_v4) -> Double {
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(usage.ri_user_time + usage.ri_system_time) * Double(base.numer) / Double(base.denom) / 1e6
    }

    /// The run's own session host: the process its log, in this run's isolated folder, says is listening.
    private var hostPID: pid_t? { MachineLoad.hostPID(log: Self.hostLog) }
    static var hostLog: URL { AppPlaces.supportFolder.appendingPathComponent("host/host.log") }

    // MARK: (a) Typing

    /// Keystrokes at a typist's pace into `cat` (the terminal's own line discipline echoes each at once),
    /// queued for the app from a thread of their own as the window server hands keys over: each waits its
    /// turn behind whatever the main thread is doing, as a real one does.
    private func typing() async {
        main.type("clear; cat > /dev/null\r")
        await PerfWait.sleep(600)
        let log = log
        main.surface.setOutputHandler { log.output() }
        defer { main.surface.setOutputHandler(nil) }
        let count = DebugScenario.value("--perf-keys").flatMap(Int.init) ?? 150
        let events = QueuedKeys((0..<count).compactMap { keyEvent(String(UnicodeScalar(UInt8(97 + $0 % 26)))) }, app: NSApp)
        // When the app takes each one off its queue (its key monitors run first, then the terminal's keyDown).
        var taken: [Double] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            taken.append(perfNow())
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let start = perfNow()
        events.post()
        _ = await PerfWait.until(Double(count) * 100 + 3000) { events.done && taken.count >= events.count }
        await PerfWait.sleep(300)
        let end = perfNow()
        let sent = events.times
        var written: [Double] = [], echoed: [Double] = [], drawn: [Double] = [], lost = 0
        for (index, down) in sent.enumerated() {
            let next = index + 1 < sent.count ? sent[index + 1] : end
            guard let echo = log.outputs(from: down, to: next).first, let frame = log.firstFrame(after: echo) else { lost += 1; continue }
            if index < taken.count { written.append(taken[index] - down) }
            echoed.append(echo - down)
            drawn.append(frame - down)
        }
        main.type("\u{3}")
        let pings = log.pings(from: start, to: end)
        limit("typing: keystrokes without an echo", Double(lost), atMost: 0)
        limit("typing: keystroke to glyph drawn, median ms", Self.pick(drawn, 0.5), atMost: 25)
        limit("typing: keystroke to glyph drawn, p99 ms", Self.pick(drawn, 0.99), atMost: 50)
        limit("typing: main-thread stalls over 50 ms", Double(pings.filter { $0 > 50 }.count), atMost: 0)
        rows.append(PerfRow(name: "typing", values: [
            ("keys", "\(count)"), ("no echo", "\(lost)"),
            ("taken p50", Self.ms(Self.pick(written, 0.5))), ("taken max", Self.ms(written.max())),
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
            let prompt = await drawn(after: await PerfWait.until(10000) { self.screen(pane).contains { !$0.isEmpty } })
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
        let spread = { (times: [Double]) in Self.ms(Self.pick(times, 0.5)) + "/" + Self.ms(Self.pick(times, 0.95)) + "/" + Self.ms(times.max()) }
        for name in ["action", "tab shown", "focused", "started", "prompt drawn", "keys ran"] {
            values.append((name, spread(opened[name] ?? [])))
        }
        rows.append(PerfRow(name: "new tab ⌘T, warm (median/p95/max)", values: values + stalls(from: start, to: end)))
        limit("new tab: keys typed straight after ⌘T lost or misplaced", Double(misses.count), atMost: 0)
        limit("new tab: shown in the row, median ms", Self.pick(opened["tab shown"] ?? [], 0.5), atMost: 50)
        limit("new tab: has the keyboard, median ms", Self.pick(opened["focused"] ?? [], 0.5), atMost: 50)
        limit("new tab: shell started, median ms", Self.pick(opened["started"] ?? [], 0.5), atMost: 100)
        limit("new tab: shown in the row, p95 ms", Self.pick(opened["tab shown"] ?? [], 0.95), atMost: 100)
        limit("new tab: has the keyboard, p95 ms", Self.pick(opened["focused"] ?? [], 0.95), atMost: 100)
        limit("new tab: shell started, p95 ms", Self.pick(opened["started"] ?? [], 0.95), atMost: 200)
        values = []
        for name in ["× action", "× gone from bar", "× next shown with the keyboard", "⌘W action", "⌘W gone from bar", "⌘W next shown with the keyboard"] {
            values.append((name, spread(closed[name] ?? [])))
        }
        rows.append(PerfRow(name: "close tab (median/p95/max)", values: values))
        for key in ["×", "⌘W"] {
            limit("close by \(key): gone from the row, median ms", Self.pick(closed["\(key) gone from bar"] ?? [], 0.5), atMost: 50)
            limit("close by \(key): the next tab shown with the keyboard, median ms", Self.pick(closed["\(key) next shown with the keyboard"] ?? [], 0.5), atMost: 50)
            limit("close by \(key): gone from the row, p95 ms", Self.pick(closed["\(key) gone from bar"] ?? [], 0.95), atMost: 100)
            limit("close by \(key): the next tab shown with the keyboard, p95 ms", Self.pick(closed["\(key) next shown with the keyboard"] ?? [], 0.95), atMost: 100)
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
        var tabTimes: [Double] = [], spaceTimes: [Double] = [], drawnTimes: [Double] = []
        let start = perfNow()
        for round in 0..<10 {
            let target = round % 2 == 0 ? second : first
            let down = perfNow()
            shortcut(round % 2 == 0 ? "cmd+2" : "cmd+1")
            // Shown: in the window with the keyboard, and that frame committed (`PerfWait`); then drawn: the
            // terminal's first frame after the switch (one that changed nothing while hidden may draw none; its
            // layer still holds its last frame).
            if let shown = await PerfWait.until(2000, { self.focused(target) }) {
                tabTimes.append(shown - down)
            } else { tabTimes.append(.nan) }
            let drawn = await PerfWait.until(500) { self.log.firstFrame(after: down) != nil }
            drawnTimes.append(drawn != nil ? (log.firstFrame(after: down) ?? .nan) - down : .nan)
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
        let tabs = tabTimes.filter(\.isFinite), spaces = spaceTimes.filter(\.isFinite), drawn = drawnTimes.filter(\.isFinite)
        limit("switch: tab, median ms", Self.pick(tabs, 0.5), atMost: 50)
        limit("switch: workspace, median ms", Self.pick(spaces, 0.5), atMost: 50)
        limit("switch: tab, p95 ms", Self.pick(tabs, 0.95), atMost: 100)
        limit("switch: workspace, p95 ms", Self.pick(spaces, 0.95), atMost: 100)
        // Any terminal's frame (SwiftTerm does not say whose), and one that changed nothing while hidden may
        // draw none: the median says it, a p95 would catch the next unrelated frame.
        if !drawn.isEmpty { limit("switch: tab to the first terminal frame drawn, median ms", Self.pick(drawn, 0.5), atMost: 50) }
        limit("switch: switches that never showed", Double(tabTimes.count - tabs.count + spaceTimes.count - spaces.count), atMost: 0)
        rows.append(PerfRow(name: "switch, to shown", values: [
            ("tab p50", Self.ms(Self.pick(tabs, 0.5))), ("tab p95", Self.ms(Self.pick(tabs, 0.95))), ("tab max", Self.ms(tabs.max())), ("tab failed", "\(tabTimes.count - tabs.count)"),
            ("drawn p50", Self.ms(Self.pick(drawn, 0.5))), ("drawn p95", Self.ms(Self.pick(drawn, 0.95))), ("no frame", "\(drawnTimes.count - drawn.count)"),
            ("workspace p50", Self.ms(Self.pick(spaces, 0.5))), ("workspace p95", Self.ms(Self.pick(spaces, 0.95))), ("workspace max", Self.ms(spaces.max())), ("workspace failed", "\(spaceTimes.count - spaces.count)"),
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

    /// The app left alone: nothing typed, nothing printed and nothing due to change (the demo's cats doze
    /// off `AgentWorld.napAfter` seconds after they are made; that is waited out). Measured by day and by
    /// night, set here so the wall clock never decides, with the window key; then by night with the window
    /// not key, and hidden. The pings are stopped first (they would wake the main thread 250 times a second).
    private func idle() async {
        pinger.stop()
        defer { pinger.start() }
        main.type("clear\r")
        if let catsMadeAt {
            let due = catsMadeAt + (AgentWorld.napAfter + 2) * 1000
            if perfNow() < due { await PerfWait.sleep(due - perfNow()) }
        }
        let store = WorldStore.shared, meadow = controller.navigator.meadow
        let time = store.settings.timeOfDay
        defer { store.settings.timeOfDay = time }
        for (setting, shown, name) in [(WorldSettings.TimeOfDay.day, MeadowSettings.TimeOfDay.day, "day"), (.night, .night, "night")] {
            store.settings.timeOfDay = setting
            // The setting reaches the meadow through an observer, a turn or two later.
            _ = await PerfWait.until(2000) { meadow.settings.timeOfDay == shown }
            await idleStretch("idle, \(name)", limits: true)
        }
        // Not the key window (another window, or another app, in front).
        KeyStandIn.standsIn = false
        meadow.keepsFullRateWhenInactive = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        await idleStretch("idle, night, window not key", limits: false)
        KeyStandIn.standsIn = true
        meadow.keepsFullRateWhenInactive = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        // Hidden (⌘H, minimised): the window taken off the screen, then put back behind everything as the run
        // began. The terminals here still tick on Core Video's link (`SWIFTTERM_FORCE_CVDISPLAYLINK`), where
        // a hidden window's own link would stop.
        meadow.assumesOnScreen = false
        window.orderOut(nil)
        await idleStretch("idle, night, window hidden", limits: false)
        window.orderBack(nil)
        meadow.assumesOnScreen = true
    }

    /// One idle stretch: once the meadow has come to rest (waiting up to 20 s, which is itself a finding;
    /// not waited for while it is hidden), 5 s of the process's CPU time and wakeups, its session host's, the
    /// meadow's frames and GPU time, terminal frames and chrome updates.
    private func idleStretch(_ name: String, limits: Bool) async {
        let meadow = controller.navigator.meadow
        let begun = perfNow()
        let rested = meadow.assumesOnScreen ? await PerfWait.until(20000) { meadow.isResting } : nil
        await PerfWait.sleep(1000)
        let host = hostPID
        let appBefore = Self.usage(getpid()), hostBefore = host.flatMap(Self.usage)
        let start = perfNow()
        flowStart = start
        await PerfWait.sleep(5000)
        let appAfter = Self.usage(getpid()), hostAfter = host.flatMap(Self.usage)
        let end = perfNow(), seconds = (end - start) / 1000
        func cpu(_ a: rusage_info_v4?, _ b: rusage_info_v4?) -> Double? {
            guard let a, let b else { return nil }
            return (Self.cpuMilliseconds(b) - Self.cpuMilliseconds(a)) / (end - start) * 100
        }
        func wakeups(_ a: rusage_info_v4?, _ b: rusage_info_v4?) -> String {
            guard let a, let b else { return "-" }
            return String(format: "%.0f (from idle %.0f)", Double(b.ri_interrupt_wkups - a.ri_interrupt_wkups) / seconds,
                          Double(b.ri_pkg_idle_wkups - a.ri_pkg_idle_wkups) / seconds)
        }
        let appCPU = cpu(appBefore, appAfter), hostCPU = cpu(hostBefore, hostAfter)
        let frames = log.frames(from: start, to: end)
        let chrome = Double(log.invalidations(from: start, to: end)) / seconds
        let drawn = log.meadow(from: start, to: end)
        let gpu = drawn.isEmpty ? 0 : drawn.map { $0.gpuMilliseconds * $0.framesPerSecond }.reduce(0, +) / Double(drawn.count)
        let fps = drawn.isEmpty ? 0 : drawn.map(\.framesPerSecond).reduce(0, +) / Double(drawn.count)
        let others = MachineLoad.shared.others(from: start, to: end)
        // Standing in for a visible window, the meadow always draws (at rest, 12 times a second): none drawn
        // means nothing of its cost was measured, whatever the numbers say. A failed check, not a limit, so a
        // busy Mac cannot make it "not comparable".
        let unmeasured = meadow.assumesOnScreen && drawn.allSatisfy { $0.framesPerSecond == 0 }
        if meadow.assumesOnScreen {
            check("\(name): the meadow drew frames, as on a visible window", !unmeasured,
                  unmeasured ? "not measurable: the meadow got no frames from the display" : "")
        }
        func f(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
        rows.append(PerfRow(name: name, values: [
            ("cpu %", f(appCPU)), ("wakeups/s", wakeups(appBefore, appAfter)),
            ("host cpu %", f(hostCPU)), ("host wakeups/s", wakeups(hostBefore, hostAfter)),
            ("terminal frames/s", f(Double(frames.count) / seconds)), ("chrome updates/s", f(chrome)),
            ("meadow at rest after", unmeasured ? "not measurable (no frames)"
                : rested.map { f(($0 - begun) / 1000) + " s" } ?? (meadow.assumesOnScreen ? "never (20 s)" : "-")),
            ("meadow frames/s", String(format: "%.0f/%d", fps, drawn.last?.targetFramesPerSecond ?? 0)),
            ("meadow gpu ms/s", f(gpu)), ("others' load cores", f(others)),
        ]))
        guard limits, !unmeasured else { return }
        limit("\(name): process CPU %", appCPU, atMost: 15)
        limit("\(name): the session host's CPU %", hostCPU, atMost: 3)
        limit("\(name): chrome updates a second", chrome, atMost: 1)
        limit("\(name): seconds until the meadow rests", rested.map { ($0 - begun) / 1000 }, atMost: 12)
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
              + "view \(pane.surface.convert(pane.surface.bounds, to: nil).integral) in its card \(pane.surface.superview.map { $0.convert($0.bounds, to: nil).integral } ?? .zero), "
              + "held for a live resize \(LiveResize.shared.isActive), the view in a live resize \(pane.surface.inLiveResize)")
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
                    QueuedEvents.post(drag)
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

    func check(_ name: String, _ passed: Bool, _ detail: String = "") {
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
        // A split tab's × (its focused pane's) closes that pane only; the tab stays, with the other.
        if let split = workspace.tabs.first(where: { $0.tree.panes.count == 2 }) {
            let count = workspace.tabs.count, focused = split.focusedPane
            if await clickClose(split, "× split tab's focused pane") {
                let closed = await PerfWait.until(2000) { split.tree.panes.count == 1 && !split.tree.contains(focused) }
                check("× split tab's focused pane: that pane closed, the tab kept with the other", closed != nil && workspace.tabs.count == count,
                      "panes \(split.tree.panes.count), tabs \(count) → \(workspace.tabs.count)")
            }
        }
        for (name, tab) in [("× edited file", editedTab), ("× file", workspace.tabs.first { $0 !== editedTab && workbench.pages[$0.focusedPane] != nil }),
                            ("× split tab, now of one pane", workspace.tabs.first { $0.tree.panes.count == 1 && workbench.panes[$0.focusedPane] != nil && !$0.tree.contains(busy.id) && $0 !== workspace.tabs.first }),
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
        let broken = limits.filter { $0.1 == .passed }, undecided = limits.filter { $0.1 == .notComparable }
        if !limits.isEmpty {
            func listed(_ found: [(String, LimitResult, String)]) -> String { found.map { "\($0.0) \($0.2)" }.joined(separator: "; ") }
            var line = "limits: \(limits.count - broken.count - undecided.count)/\(limits.count) kept"
            if !broken.isEmpty { line += "; PASSED: " + listed(broken) }
            if !undecided.isEmpty { line += "; NOT COMPARABLE (the machine was busy): " + listed(undecided) }
            lines.append(line)
        }
        lines.append(DebugPerf.machineSummary())
        if !checks.isEmpty {
            let failed = checks.filter { !$0.1 }
            lines.append("checks: \(checks.count - failed.count)/\(checks.count) passed" + (failed.isEmpty ? "" : "; FAILED: " + failed.map { "\($0.0) (\($0.2))" }.joined(separator: "; ")))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Built with optimisation (`make perf`'s profile build) or not (a Debug build).
    private var isOptimised: Bool { !_isDebugAssertConfiguration() }
}
/// Keys queued for the app from a thread of their own, at a brisk typist's pace (35 to 65 ms apart), as
/// the window server hands real ones over: when each was queued.
nonisolated final class QueuedKeys: @unchecked Sendable {
    private let events: [NSEvent]
    private let app: NSApplication
    private let lock = NSLock()
    private var queued: [Double] = []
    var count: Int { events.count }

    init(_ events: [NSEvent], app: NSApplication) {
        self.events = events
        self.app = app
    }

    var times: [Double] { lock.withLock { queued } }
    var done: Bool { lock.withLock { queued.count == events.count } }

    func post() {
        let thread = Thread { [self] in
            // AppKit lets `postEvent` be called from any thread ("can also be called in subthreads"); the SDK's
            // annotation says main actor, so it is called through its Objective-C implementation.
            typealias Post = @convention(c) (AnyObject, Selector, NSEvent, ObjCBool) -> Void
            let selector = NSSelectorFromString("postEvent:atStart:")
            let post = unsafeBitCast(class_getMethodImplementation(NSApplication.self, selector), to: Post.self)
            for (index, event) in events.enumerated() {
                let now = perfNow()
                lock.withLock { queued.append(now) }
                post(app, selector, event, false)
                usleep(UInt32(35 + index * 7 % 31) * 1000)
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
#endif
