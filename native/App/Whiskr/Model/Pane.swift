import AppKit
import Foundation
import Observation
import SwiftTerm
import TerminalHost
import WhiskrKit

/// One terminal in a tab: what is known to be running in front of it, and its view. The terminal itself
/// (the pseudo-terminal and its shell) lives in the session host (`HostLink`), under this pane's id, so
/// it keeps running when the app quits; the pane is the window onto it. Every pane starts as the user's
/// shell; whether Claude is in it is seen, never assumed: from the terminal's foreground program and
/// from the hook events its session sends (`AgentPresence`).
@Observable
final class Pane: Identifiable {
    let id: UUID
    /// The folder it was started in.
    private(set) var folder: String
    let surface: TerminalSurface
    /// The title the program in front set for its terminal (OSC 0/2), without spinner glyphs.
    private(set) var terminalTitle = ""
    /// The shell ended (you typed `exit`, or it failed to start): the code it ended with.
    private(set) var exitCode: Int32?
    private(set) var exited = false
    /// The program in front of the shell; nil while the shell waits at its prompt.
    private(set) var foreground: ForegroundProcess?
    /// What that program says of itself (OSC 7501, read by the host): working, waiting for an answer, idle.
    private(set) var programReport: ProgramReport?
    /// Where the shell is now (it may have `cd`'d), else where it started.
    private(set) var currentFolder: String
    private(set) var presence = AgentPresence()
    /// The latest Claude session that reported from this pane, kept so the pane can resume it after a
    /// restart of the Mac, and the account it ran under (its config folder).
    var sessionID: String?
    var sessionTitle: String?
    var sessionConfigDir: String?
    /// Its terminal's address and name as the host gives them ("t4", "review": what `paw` reaches it
    /// by), and where it came from when a program started it (`paw run`); nil from an older host.
    private(set) var address: String?
    private(set) var terminalName: String?
    private(set) var origin: TerminalOrigin?
    /// The host answers programs' status probes itself (protocol 2): this terminal's own answer is not
    /// sent, so a program hears exactly one.
    @ObservationIgnored var hostAnswersProbes = false

    /// This pane's own connection to the host: its output is read and drawn on a thread of its own.
    @ObservationIgnored private var connection: HostConnection?
    /// What the host last said is in the terminal's foreground.
    @ObservationIgnored private var hostStatus = TerminalStatus()
    /// The size the host's terminal was last given, and how many times the view's has changed.
    @ObservationIgnored private var toldSize: TerminalSize?
    @ObservationIgnored private var resizes = 0
    /// How long the view's size must hold still before the program hears of it.
    static let resizeSettle: TimeInterval = 0.08
    /// What to start, until the view's size is known (`start`), and what was typed meanwhile.
    @ObservationIgnored private var waitingToStart: ProcessSpec?
    @ObservationIgnored private var typedEarly = Data()
    /// How long a new terminal waits for its view to be laid out before starting at the best size it has.
    static let startLatest: TimeInterval = 0.25
    /// The last size any terminal settled at (held still long enough to be told to its program): what a
    /// terminal that starts before it has a size of its own most likely gets once shown.
    private static var lastSettledSize: TerminalSize?
    /// When nothing better is known.
    static let standInSize = TerminalSize(columns: 100, rows: 30)

    /// A size a shell's prompt and a program can be drawn in: not a sliver of a region on its way in.
    static func isPlausible(_ size: TerminalSize) -> Bool {
        size.columns >= 20 && size.rows >= 5
    }
    @ObservationIgnored private var startedAt = Date()
    /// Typed once the shell is ready for it (its first prompt, or quiet after starting).
    @ObservationIgnored private var pendingInput: String?
    @ObservationIgnored private var ready = false
    @ObservationIgnored var onExit: ((Pane) -> Void)?
    @ObservationIgnored var onProgramIdle: ((Pane) -> Void)?
    /// The host said the foreground changed: the workbench looks at once, so a cat appears as Claude starts.
    @ObservationIgnored var onForegroundChange: ((Pane) -> Void)?

    /// Claude is in this pane now: a cat sits on its blanket.
    var agentRunning: Bool { presence.present }

    /// The host says Claude Code is in front of this terminal's shell (before the first look).
    var claudeInFront: Bool { hostStatus.foreground?.isClaude ?? false }

    init(id: UUID = UUID(), folder: String) {
        self.id = id
        self.folder = folder
        self.currentFolder = folder
        self.surface = TerminalSurface()
        surface.surfaceDelegate = self
    }

    /// When the shell last wrote anything, until it is ready (written off the main thread).
    @ObservationIgnored private let outputClock = OutputClock()
    /// How much of the kept output is still to come after attaching.
    @ObservationIgnored private let replay = ReplayCount()

    // MARK: The terminal in the host

    /// Starts a new terminal for this pane in the host: as soon as the pane's view has been laid out
    /// and its size has settled, so the shell starts at its real size and never draws its first prompt
    /// for a size the window was only passing through; a moment later at the latest (a pane in a tab
    /// that is not showing has no layout to wait for).
    func start(_ spec: ProcessSpec, on host: HostLink) {
        startedAt = Date()
        guard connect(to: host) != nil else { return }
        let clock = outputClock
        surface.setOutputHandler { clock.tick() }
        waitingToStart = spec
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.startLatest) { [weak self] in self?.startAtLatest() }
    }

    /// The moment a terminal starts even without a laid-out view: later while the window is still
    /// resizing (a region sliding in), for at most a second and a half more.
    private func startAtLatest(tries: Int = 0) {
        guard waitingToStart != nil else { return }
        if LiveResize.shared.isActive, tries < 15 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.startAtLatest(tries: tries + 1) }
            return
        }
        startNow()
    }

    private func startNow() {
        guard let spec = waitingToStart, let connection else { return }
        waitingToStart = nil
        // Never at a size the window was only passing through (a region sliding in, a split opening),
        // nor at the stand-in size of a tab never shown: a shell draws its first prompt for the size it
        // starts at, and a prompt drawn four columns wide stays broken in the scrollback. Then the size of
        // the terminals on screen is the best guess; the real one follows when the view is laid out.
        var size = surface.size
        if surface.window == nil || !Self.isPlausible(size) {
            size = Self.lastSettledSize ?? Self.standInSize
            surface.adopt(size)
        }
        toldSize = size
        connection.request(.create(TerminalSpec(terminal: id, process: spec, size: size))) { [weak self] reply in
            Task { @MainActor in self?.started(reply) }
        }
        // Keys pressed in the moment before the terminal existed.
        if !typedEarly.isEmpty { connection.type(typedEarly, into: id) }
        typedEarly = Data()
    }

    /// Shows a terminal the host already holds (the app was relaunched, or a program started it): its
    /// kept output is drawn again, then everything it prints from now on.
    func attach(to info: TerminalInfo, on host: HostLink) {
        ready = true
        learn(info)
        hear(info.status)
        // Laid out as it was printed; the view's own size follows once it has been drawn. The size comes
        // first: its card holds the view at the grid's size from the moment it is replaying.
        surface.adopt(info.size)
        surface.replaying = true
        toldSize = info.size
        guard let connection = connect(to: host) else { return }
        let replay = replay
        connection.request(.attach(terminal: id)) { [weak self] reply in
            // On the connection's thread, before the first of the kept output arrives.
            guard case .attached(_, let bytes, let truncated) = reply else {
                Task { @MainActor in self?.lostTerminal() }
                return
            }
            replay.expect(bytes) {
                Task { @MainActor in self?.replayed(truncated: truncated) }
            }
        }
    }

    private func connect(to host: HostLink) -> HostConnection? {
        let surface = surface
        let replay = replay
        let id = id
        let handlers = HostConnection.Handlers(
            output: { _, bytes in
                if replay.isExpecting {
                    // Kept output is laid out at the size each stretch of it was printed for: the size
                    // is taken on the main thread (where the terminal is resized) before the stretch is fed.
                    for piece in ReplaySize.split(bytes) {
                        if let size = piece.size { DispatchQueue.main.sync { MainActor.assumeIsolated { surface.adopt(size) } } }
                        if !piece.bytes.isEmpty { surface.show(piece.bytes) }
                    }
                } else {
                    surface.show(bytes)
                }
                replay.took(bytes.count)
            },
            event: { [weak self] event in
                Task { @MainActor in self?.hear(event, for: id) }
            },
            closed: { [weak self] in
                Task { @MainActor in self?.lostTerminal() }
            })
        guard let connection = host.connect(handlers) else {
            fail(String(localized: "The terminal could not be started: the session host is not running.",
                        comment: "Shown in a pane when the background process that owns terminals could not be reached"))
            return nil
        }
        self.connection = connection
        return connection
    }

    private func started(_ reply: HostReply) {
        switch reply {
        case .created(let info):
            learn(info)
            hear(info.status)
        case .failed(let failure):
            fail(String(localized: "The terminal could not be started: \(failure.message)", comment: "Shown in a pane whose shell failed to launch"))
        default:
            break
        }
    }

    /// The kept output has been drawn: the terminal answers the program again, and takes the size the
    /// view has room for (which the host passes on to the program, as any resize).
    private func replayed(truncated: Bool) {
        surface.replaying = false
        // Its pane lets it follow its edges again; laid out first, so the size taken is the pane's and not
        // the placeholder frame of a view that has not been laid out yet (which would squeeze what was
        // just drawn into 80 columns and push its first line out).
        if surface.window != nil {
            surface.superview?.layoutSubtreeIfNeeded()
            if Self.isPlausible(surface.size(for: surface.frame.size)) { surface.followFrame() }
            tellSize()
        }
        // The kept output began mid-history: a full-screen program is asked to draw itself afresh.
        if truncated { connection?.send(.redraw(terminal: id)) }
    }

    /// Who its terminal is, as the host says.
    private func learn(_ info: TerminalInfo) {
        if address != info.address { address = info.address }
        if terminalName != info.name { terminalName = info.name }
        if origin != info.origin { origin = info.origin }
    }

    private func hear(_ event: HostEvent, for id: UUID) {
        switch event {
        case .status(terminal: id, let status):
            hear(status)
        case .exited(terminal: id, exitCode: let code):
            ended(exitCode: code)
        default:
            break
        }
    }

    private func hear(_ status: TerminalStatus) {
        let changed = status.foreground != hostStatus.foreground
        hostStatus = status
        if programReport != status.program { programReport = status.program }
        if let folder = status.folder, folder != currentFolder { currentFolder = folder }
        if changed { onForegroundChange?(self) }
    }

    private func ended(exitCode code: Int32?) {
        guard !exited else { return }
        exited = true
        exitCode = code
        foreground = nil
        hostStatus.foreground = nil
        presence.observe(foreground: nil, liveSession: false)
        onExit?(self)
    }

    /// The connection ended without the program ending: the host has gone, and its terminals with it.
    private func lostTerminal() {
        guard connection != nil, !exited else { return }
        fail(String(localized: "This terminal's programs have ended: the session host stopped.",
                    comment: "Shown in a pane when the background process that owns terminals went away"))
    }

    private func fail(_ message: String) {
        surface.replaying = false
        surface.feed(text: "\r\n\(message)\r\n")
        ended(exitCode: nil)
    }

    /// Ends everything in the terminal `delay` seconds from now (a hang-up, then a kill, done by the
    /// host), unless `keepRunning` comes first. Never waits.
    func end(after delay: TimeInterval = 0) {
        connection?.send(.close(terminal: id, after: delay))
    }

    /// Takes back an `end` whose moment has not come (undo of a close).
    func keepRunning() {
        connection?.send(.keep(terminal: id))
    }

    /// Lets go of the terminal; the host keeps or ends it as it was told.
    func disconnect() {
        let connection = connection
        self.connection = nil
        surface.surfaceDelegate = nil
        connection?.close()
    }

    #if DEBUG
    /// Debug builds (the demo workbench): the pane behaves as if Claude were in front of its shell.
    var debugPretendsClaude = false
    #endif

    // MARK: What runs in it

    /// Types `text` as soon as the shell is ready for it (at once if it already is), as if you had
    /// typed it at its prompt.
    func typeWhenReady(_ text: String) {
        if ready { type(text) } else { pendingInput = (pendingInput ?? "") + text }
    }

    /// Takes in what the host last said is in the terminal's foreground (it says so within a tenth of a
    /// second of a change). `liveSession`: a session that reported from this pane has not ended. Returns
    /// whether Claude came or went.
    @discardableResult
    func refresh(liveSession: Bool, now: Date = Date()) -> Bool {
        guard !exited else { return false }
        let front = hostStatus.foreground
        #if DEBUG
        if debugPretendsClaude, front == nil {
            let pretend = ForegroundProcess(pid: -1, name: "claude")
            if foreground != pretend { foreground = pretend }
            return presence.observe(foreground: pretend, liveSession: liveSession)
        }
        #endif
        if foreground != front { foreground = front }
        if !ready, shellLooksReady(now: now) { becomeReady() }
        return presence.observe(foreground: front, liveSession: liveSession)
    }

    /// A hook event came from this pane's session.
    @discardableResult
    func heardFromAgent() -> Bool {
        presence.heard()
    }

    /// The shell has drawn its prompt: our zsh integration says so (OSC 7 from its first prompt);
    /// otherwise its output has gone quiet after starting, or it has had long enough.
    private func shellLooksReady(now: Date) -> Bool {
        if foreground != nil { return false }
        if let lastOutput = outputClock.last, now.timeIntervalSince(lastOutput) > 0.4 { return true }
        return now.timeIntervalSince(startedAt) > 4
    }

    private func becomeReady() {
        ready = true
        surface.setOutputHandler(nil)
        if let text = pendingInput {
            pendingInput = nil
            type(text)
        }
    }

    /// Empties the scrollback, keeping what is on screen.
    func clearScrollback() {
        surface.clearScrollback()
    }

    /// Sends text to the program as if typed.
    func type(_ text: String) {
        surface.send(txt: text)
    }

    /// Esc to the program in front: how a Claude turn is interrupted.
    func interrupt() {
        surface.send(txt: "\u{1b}")
    }

    /// What runs in front, by the name people know it by: "Claude Code", "vim", "npm"; nil at the prompt.
    var programName: String? {
        guard let foreground else { return nil }
        if foreground.isClaude { return "Claude Code" }
        return foreground.name.isEmpty ? URL(fileURLWithPath: foreground.executable).lastPathComponent : foreground.name
    }
}

extension Pane: TerminalSurfaceDelegate {
    func surface(_ surface: TerminalSurface, typed bytes: ArraySlice<UInt8>) {
        guard !exited else { return }
        // The host has answered the program's status probe already.
        if hostAnswersProbes, Self.isProbeAnswer(bytes) { return }
        guard waitingToStart == nil else { return typedEarly.append(contentsOf: bytes) }
        connection?.type(Data(bytes), into: id)
    }

    /// The view changed size. The program is told once the size has held still for a moment: a window
    /// being laid out or a divider being dragged passes through many sizes, and each one told would
    /// make the program draw itself again (Claude Code clears its screen to do so).
    func surface(_ surface: TerminalSurface, resizedTo size: TerminalSize) {
        resizes += 1
        let turn = resizes
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeSettle) { [weak self] in
            guard let self, self.resizes == turn else { return }
            self.tellSize()
        }
    }

    private func tellSize() {
        if waitingToStart != nil {
            // Started once laid out at a size a shell can draw in; until then the deadline in `start` holds.
            if surface.window != nil, Self.isPlausible(surface.size), !LiveResize.shared.isActive {
                Self.lastSettledSize = surface.size
                startNow()
            }
            return
        }
        let size = surface.size
        guard !exited, !surface.replaying, waitingToStart == nil, size != toldSize else { return }
        toldSize = size
        if Self.isPlausible(size) { Self.lastSettledSize = size }
        connection?.send(.resize(terminal: id, size))
    }

    func surface(_ surface: TerminalSurface, titled title: String) {
        let plain = Self.plainTitle(title)
        if terminalTitle != plain { terminalTitle = plain }
    }

    /// OSC 7, sent by our zsh integration before each prompt: where the shell is, and that it is ready.
    func surface(_ surface: TerminalSurface, movedTo directory: String?) {
        if let directory, let path = URL(string: directory)?.path ?? Optional(directory), path.hasPrefix("/"), path != currentFolder {
            currentFolder = path
        }
        if !ready, foreground == nil { becomeReady() }
    }

    func surface(_ surface: TerminalSurface, programStatus records: [TerminalProgramStatus]) {
        guard let root = records.first(where: { $0.id.isEmpty }) else { return }
        if root.state == .idle || root.state == .done { onProgramIdle?(self) }
    }

    /// What a terminal says back to a program asking whether it listens for status reports.
    static func isProbeAnswer(_ bytes: ArraySlice<UInt8>) -> Bool {
        let probe = Array("\u{1B}]7501;?".utf8)
        guard bytes.count <= probe.count + 2, bytes.starts(with: probe) else { return false }
        let ending = Array(bytes.dropFirst(probe.count))
        return ending == [0x07] || ending == [0x1B, UInt8(ascii: "\\")]
    }

    /// A terminal title without the spinner or status glyphs programs put in front of it.
    static func plainTitle(_ title: String) -> String {
        String(title.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }
}

/// The time of the latest output, set from the pane's connection thread and read on the main thread.
nonisolated final class OutputClock: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Date?

    func tick() { lock.withLock { latest = Date() } }
    var last: Date? { lock.withLock { latest } }
}

/// How much of a terminal's kept output is still to arrive after attaching; says when all of it has.
/// Set and counted down on the pane's connection thread.
nonisolated final class ReplayCount: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining = 0
    private var finished: (@Sendable () -> Void)?

    func expect(_ bytes: Int, finished: @escaping @Sendable () -> Void) {
        guard bytes > 0 else { return finished() }
        lock.withLock {
            remaining = bytes
            self.finished = finished
        }
    }

    /// Kept output is still on its way.
    var isExpecting: Bool { lock.withLock { finished != nil } }

    func took(_ bytes: Int) {
        let done: (@Sendable () -> Void)? = lock.withLock {
            guard finished != nil else { return nil }
            remaining -= bytes
            guard remaining <= 0 else { return nil }
            defer { finished = nil }
            return finished
        }
        done?()
    }
}
