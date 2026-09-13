import Foundation

/// How the app talks to the session host: the small background process that owns every terminal, so
/// quitting, crashing or updating the app leaves programs running (`TerminalHost`).
///
/// A connection is any ordered byte stream: today a Unix socket in the app's support folder; later the
/// same frames can run over a phone's link, or `ssh host connect` on standard input and output. It
/// carries frames (`HostFrame`): JSON messages for everything said and answered, raw bytes for what a
/// terminal prints and what is typed into it. The app and the `paw` command-line tool are both clients.
///
/// A client says `hello` first. Each side states the newest protocol it speaks and the oldest it still
/// understands; they talk when the two ranges meet (`compatibility`). The framing and `hello` never
/// change, so any app can ask any host what it speaks and how many terminals it holds. Within a
/// conversation each side uses only what both speak: a field a peer does not know is passed over, and
/// a request it does not know is answered with `unknownRequest`.
public enum HostProtocol {
    /// Raised by any change to the messages.
    ///   1  terminals: create, attach, resize, close, list.
    ///   2  agents starting and steering agents: every terminal has an address; `run`, `send`, `keys`,
    ///      `interrupt`, `wait`, `read`, `subscribe`; programs' own status reports (OSC 7501), answered
    ///      by the host. A v2 client on a v1 host uses none of it; a v1 client on a v2 host sees only
    ///      what it knows.
    public static let version = 2
    /// The oldest version this build still speaks.
    public static let oldest = 1
    /// The first version with agents starting and steering agents.
    public static let agents = 2

    public static var current: HostVersion { HostVersion(version: version, oldest: oldest) }

    /// Whether a client and a host can talk: each must be at least as new as the other's oldest.
    public static func compatibility(client: HostVersion, host: HostVersion) -> HostCompatibility {
        if host.version < client.oldest { return .hostTooOld }
        if client.version < host.oldest { return .hostTooNew }
        return .compatible
    }

    /// The version a client and a host speak together: the older of their newest.
    public static func spoken(client: HostVersion, host: HostVersion) -> Int {
        min(client.version, host.version)
    }
}

public struct HostVersion: Sendable, Equatable, Codable {
    public var version: Int
    public var oldest: Int

    public init(version: Int, oldest: Int) {
        self.version = version
        self.oldest = oldest
    }
}

public enum HostCompatibility: Sendable, Equatable {
    case compatible
    /// The host is from an app too old for this one to talk to.
    case hostTooOld
    /// The host is from an app too new for this one to talk to.
    case hostTooNew
}

/// A terminal's size in cells, and in pixels when known (programs that draw images ask).
public struct TerminalSize: Sendable, Equatable, Codable {
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// What to start in a new terminal. The client chooses the terminal's id (the app uses the pane's),
/// which is how it finds the terminal again after a relaunch.
public struct TerminalSpec: Sendable, Equatable, Codable {
    public var terminal: UUID
    public var executable: String
    public var arguments: [String]
    /// argv[0]; a leading "-" makes a shell a login shell.
    public var argv0: String
    public var environment: [String: String]
    public var directory: String
    public var size: TerminalSize

    public init(terminal: UUID, process: ProcessSpec, size: TerminalSize) {
        self.terminal = terminal
        executable = process.executable
        arguments = process.arguments
        argv0 = process.argv0
        environment = process.environment
        directory = process.directory
        self.size = size
    }
}

/// What a terminal is doing, as the host sees it: the program in its foreground (nil while its shell
/// waits at the prompt), the folder its shell is in, and (v2) what the program reports of itself.
public struct TerminalStatus: Sendable, Equatable, Codable {
    public var foreground: ForegroundProcess?
    public var folder: String?
    /// The foreground program's own report (OSC 7501); nil when it makes none.
    public var program: ProgramReport?

    public init(foreground: ForegroundProcess? = nil, folder: String? = nil, program: ProgramReport? = nil) {
        self.foreground = foreground
        self.folder = folder
        self.program = program
    }
}

/// Where a terminal came from when a program started it (`paw run`), rather than a client for a pane.
public struct TerminalOrigin: Sendable, Equatable, Codable {
    /// The terminal it was started from; nil when started from outside any terminal.
    public var parent: UUID?
    /// Started without a pane (`--bg`): the app shows it as a helper until it is looked at.
    public var background: Bool
    /// It keeps running when its parent ends (`--outlive-parent`).
    public var outlivesParent: Bool
    /// Its parent hears when it is blocked, stops on an error or ends (not with `--no-notify`).
    public var notifiesParent: Bool

    public init(parent: UUID?, background: Bool, outlivesParent: Bool = false, notifiesParent: Bool = true) {
        self.parent = parent
        self.background = background
        self.outlivesParent = outlivesParent
        self.notifiesParent = notifiesParent
    }
}

public struct TerminalInfo: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    /// The process started in it (the shell), which leads the terminal's session.
    public var pid: Int32
    public var size: TerminalSize
    public var status: TerminalStatus
    public var exited: Bool
    /// 0–255; nil while running, and when a signal ended it.
    public var exitCode: Int32?
    /// Asked to close: it ends when its moment for undo has passed.
    public var closing: Bool
    /// (v2) Its short address, given by the host ("t4"): what `paw` and people type. nil from a v1 host.
    public var address: String?
    /// (v2) The name it was given (`paw run --name review`), unique among running terminals.
    public var name: String?
    /// (v2) Set when a program started it.
    public var origin: TerminalOrigin?
    /// (v2) Its folder when it was started (the shell's own may differ since).
    public var directory: String?

    public init(id: UUID, pid: Int32, size: TerminalSize, status: TerminalStatus = TerminalStatus(), exited: Bool = false, exitCode: Int32? = nil, closing: Bool = false,
                address: String? = nil, name: String? = nil, origin: TerminalOrigin? = nil, directory: String? = nil) {
        self.id = id
        self.pid = pid
        self.size = size
        self.status = status
        self.exited = exited
        self.exitCode = exitCode
        self.closing = closing
        self.address = address
        self.name = name
        self.origin = origin
        self.directory = directory
    }

    /// What it is doing, in herdr's words: what its program reports, else whether a program runs in
    /// front of its shell.
    public var activity: TerminalActivity {
        if exited { return .exited }
        if let program = status.program {
            switch program.state {
            case .working: return .working
            case .blocked: return .blocked
            case .error: return .error
            case .done: return .done
            case .idle: return .idle
            }
        }
        return status.foreground == nil ? .idle : .working
    }

    /// Its program reports its own status: an agent such as Claude Code, which reads messages typed
    /// into it as messages, not commands.
    public var isAgent: Bool { !exited && status.program != nil }

    /// Its address and name for people: "t4 review", or "t4".
    public var label: String {
        [address, name].compactMap { $0 }.joined(separator: " ")
    }
}

/// What a terminal is doing, as `paw ls` and `paw wait` say it.
public enum TerminalActivity: String, Sendable, Equatable, Codable {
    case working, blocked, error, done, idle, exited

    /// Not working: done with its turn, waiting for an answer, stopped, or gone.
    public var isSettled: Bool { self != .working }
}

/// What the host says of itself in answer to `hello`.
public struct HostInfo: Sendable, Equatable, Codable {
    public var version: Int
    public var oldest: Int
    /// The app version the host was built with, for people.
    public var build: String
    public var pid: Int32
    /// How many terminals it holds that have not ended.
    public var terminals: Int

    public init(version: Int, oldest: Int, build: String, pid: Int32, terminals: Int) {
        self.version = version
        self.oldest = oldest
        self.build = build
        self.pid = pid
        self.terminals = terminals
    }

    public var speaks: HostVersion { HostVersion(version: version, oldest: oldest) }
}

// MARK: Agents (v2)

/// A terminal a program starts (`paw run`): the host starts the shell of the terminal it is started from
/// (that terminal's environment, so `claude` in it reports as everywhere), types `command` at its prompt
/// once the prompt is up, and hands over `task` once the program is ready for it.
public struct RunRequest: Sendable, Equatable, Codable {
    /// Chosen by the caller.
    public var terminal: UUID
    /// The terminal it is started from; nil from outside any terminal.
    public var parent: UUID?
    /// Typed at the prompt, as you would type it ("claude", "npm test"); nil for just a shell.
    public var command: String?
    /// The first message, sent when the program is ready for it.
    public var task: String?
    public var name: String?
    public var directory: String
    public var background: Bool
    public var outlivesParent: Bool
    public var notifiesParent: Bool
    /// The environment to start with when there is no parent to take it from.
    public var environment: [String: String]
    public var size: TerminalSize?

    public init(terminal: UUID, parent: UUID?, command: String?, task: String?, name: String?, directory: String, background: Bool,
                outlivesParent: Bool = false, notifiesParent: Bool = true, environment: [String: String] = [:], size: TerminalSize? = nil) {
        self.terminal = terminal
        self.parent = parent
        self.command = command
        self.task = task
        self.name = name
        self.directory = directory
        self.background = background
        self.outlivesParent = outlivesParent
        self.notifiesParent = notifiesParent
        self.environment = environment
        self.size = size
    }
}

/// Text pasted into a terminal's input and, unless `submit` is off, Return pressed after it.
public struct SendRequest: Sendable, Equatable, Codable {
    public var terminal: UUID
    /// Who it is from, for the tag an agent reads it with; nil from outside any terminal.
    public var sender: UUID?
    public var text: String
    /// Typed as it is, with no tag (to a shell nothing is ever tagged).
    public var raw: Bool
    /// Even into a program waiting for an answer, which the text may answer.
    public var force: Bool
    public var submit: Bool

    public init(terminal: UUID, sender: UUID?, text: String, raw: Bool = false, force: Bool = false, submit: Bool = true) {
        self.terminal = terminal
        self.sender = sender
        self.text = text
        self.raw = raw
        self.force = force
        self.submit = submit
    }
}

/// What a wait waits for.
public enum WaitCondition: Sendable, Equatable, Codable {
    /// Until it is not working: its turn done, waiting for an answer, stopped on an error, or ended.
    case settled
    /// Until it has ended.
    case exited
    /// Until its output holds this text (already printed counts).
    case output(String)
    /// Until all (or any) of the terminals it started are no longer working.
    case children(all: Bool)
    /// Until it shows it took something in: it starts working or asks, or a turn ends (after `send`).
    case activity
    /// Until the task given to `run` has been handed over (or the program asks something first).
    case started
}

public struct WaitRequest: Sendable, Equatable, Codable {
    public var terminal: UUID
    public var until: WaitCondition
    /// Seconds; the answer then says it timed out.
    public var timeout: Double

    public init(terminal: UUID, until: WaitCondition, timeout: Double) {
        self.terminal = terminal
        self.until = until
        self.timeout = timeout
    }
}

public struct WaitResult: Sendable, Equatable, Codable {
    public enum Outcome: String, Sendable, Codable {
        /// What was waited for happened.
        case met
        case timedOut
        /// It is waiting for an answer instead.
        case blocked
        /// It ended instead.
        case exited
    }

    public var outcome: Outcome
    public var terminal: TerminalInfo
    /// For a wait on children: each of them as it was at the end.
    public var children: [TerminalInfo]

    public init(outcome: Outcome, terminal: TerminalInfo, children: [TerminalInfo] = []) {
        self.outcome = outcome
        self.terminal = terminal
        self.children = children
    }
}

/// Text passed from one terminal into another, for the app to show: a report, a note from the host, or
/// a task handed over by `run`.
public struct PassedMessage: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable { case message, note, task }
    public var from: UUID?
    public var to: UUID
    public var kind: Kind

    public init(from: UUID?, to: UUID, kind: Kind) {
        self.from = from
        self.to = to
        self.kind = kind
    }
}

// MARK: Client to host

public enum HostRequest: Sendable, Equatable {
    /// First on every connection. `client` names who is calling ("app", "paw"), for the host's log.
    case hello(HostVersion, client: String)
    /// Starts a terminal and attaches this connection to it.
    case create(TerminalSpec)
    /// Sends the terminal's kept output (answered with `attached`, then the bytes), then everything it
    /// prints from now on, and its status and exit as they change.
    case attach(terminal: UUID)
    case detach(terminal: UUID)
    case resize(terminal: UUID, TerminalSize)
    /// Makes the program in front draw itself again, as after a window resize.
    case redraw(terminal: UUID)
    /// A signal for the terminal's foreground job (the shell's own when nothing runs in front).
    case signal(terminal: UUID, Int32)
    /// Ends everything in the terminal `after` seconds from now: a hang-up, then a kill for whatever
    /// ignored it. Until then `keep` takes it back (the app's undo of a closed tab).
    case close(terminal: UUID, after: Double)
    case keep(terminal: UUID)
    case list
    /// Ends every terminal and the host itself.
    case shutdown
    /// (v2) Starts a terminal from another (`paw run`); answered with `created` once it has started.
    case run(RunRequest)
    /// (v2) Pastes text into a terminal and presses Return; answered once it has been typed.
    case send(SendRequest)
    /// (v2) Presses keys by name ("enter", "esc", "ctrl+c", "up").
    case keys(terminal: UUID, [String])
    /// (v2) Stops what the terminal's program is doing without ending it: Esc for an agent, ⌃C else.
    case interrupt(terminal: UUID)
    /// (v2) Answered with `waited` when the condition holds or the time is up.
    case wait(WaitRequest)
    /// (v2) Answered with `snapshot`, then the terminal's kept output as an output frame.
    case read(terminal: UUID)
    /// (v2) This connection hears of every terminal started by a program, and of messages passed.
    case subscribe
    /// Something a newer client asked that this build does not know; answered with a failure.
    case unknown(String)
}

/// A request with the number its answer will carry.
public struct HostCall: Sendable, Equatable, Codable {
    public var id: Int
    public var request: HostRequest

    public init(id: Int, request: HostRequest) {
        self.id = id
        self.request = request
    }

    private enum Key: String, CodingKey {
        case id, op, version, oldest, client, spec, terminal, size, signal, after, run, send, keys, wait
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        id = try values.decode(Int.self, forKey: .id)
        let op = try values.decode(String.self, forKey: .op)
        func terminal() throws -> UUID { try values.decode(UUID.self, forKey: .terminal) }
        switch op {
        case "hello":
            request = .hello(HostVersion(version: try values.decode(Int.self, forKey: .version), oldest: try values.decode(Int.self, forKey: .oldest)),
                             client: try values.decodeIfPresent(String.self, forKey: .client) ?? "")
        case "create": request = .create(try values.decode(TerminalSpec.self, forKey: .spec))
        case "attach": request = .attach(terminal: try terminal())
        case "detach": request = .detach(terminal: try terminal())
        case "resize": request = .resize(terminal: try terminal(), try values.decode(TerminalSize.self, forKey: .size))
        case "redraw": request = .redraw(terminal: try terminal())
        case "signal": request = .signal(terminal: try terminal(), try values.decode(Int32.self, forKey: .signal))
        case "close": request = .close(terminal: try terminal(), after: try values.decodeIfPresent(Double.self, forKey: .after) ?? 0)
        case "keep": request = .keep(terminal: try terminal())
        case "list": request = .list
        case "shutdown": request = .shutdown
        case "run": request = .run(try values.decode(RunRequest.self, forKey: .run))
        case "send": request = .send(try values.decode(SendRequest.self, forKey: .send))
        case "keys": request = .keys(terminal: try terminal(), try values.decode([String].self, forKey: .keys))
        case "interrupt": request = .interrupt(terminal: try terminal())
        case "wait": request = .wait(try values.decode(WaitRequest.self, forKey: .wait))
        case "read": request = .read(terminal: try terminal())
        case "subscribe": request = .subscribe
        default: request = .unknown(op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        try values.encode(id, forKey: .id)
        func put(_ op: String, terminal: UUID? = nil) throws {
            try values.encode(op, forKey: .op)
            try values.encodeIfPresent(terminal, forKey: .terminal)
        }
        switch request {
        case .hello(let speaks, let client):
            try put("hello")
            try values.encode(speaks.version, forKey: .version)
            try values.encode(speaks.oldest, forKey: .oldest)
            try values.encode(client, forKey: .client)
        case .create(let spec):
            try put("create")
            try values.encode(spec, forKey: .spec)
        case .attach(let terminal): try put("attach", terminal: terminal)
        case .detach(let terminal): try put("detach", terminal: terminal)
        case .resize(let terminal, let size):
            try put("resize", terminal: terminal)
            try values.encode(size, forKey: .size)
        case .redraw(let terminal): try put("redraw", terminal: terminal)
        case .signal(let terminal, let signal):
            try put("signal", terminal: terminal)
            try values.encode(signal, forKey: .signal)
        case .close(let terminal, let after):
            try put("close", terminal: terminal)
            try values.encode(after, forKey: .after)
        case .keep(let terminal): try put("keep", terminal: terminal)
        case .list: try put("list")
        case .shutdown: try put("shutdown")
        case .run(let run):
            try put("run")
            try values.encode(run, forKey: .run)
        case .send(let send):
            try put("send")
            try values.encode(send, forKey: .send)
        case .keys(let terminal, let keys):
            try put("keys", terminal: terminal)
            try values.encode(keys, forKey: .keys)
        case .interrupt(let terminal): try put("interrupt", terminal: terminal)
        case .wait(let wait):
            try put("wait")
            try values.encode(wait, forKey: .wait)
        case .read(let terminal): try put("read", terminal: terminal)
        case .subscribe: try put("subscribe")
        case .unknown(let op): try put(op)
        }
    }

    /// The protocol version a request first appeared in: a host answers anything newer than what it
    /// speaks with this client as unknown.
    public var introducedIn: Int {
        switch request {
        case .run, .send, .keys, .interrupt, .wait, .read, .subscribe: HostProtocol.agents
        default: 1
        }
    }
}

// MARK: Host to client

public enum HostReply: Sendable, Equatable {
    case hello(HostInfo)
    /// A terminal was started.
    case created(TerminalInfo)
    /// The terminal as it is, and how many bytes of kept output follow before anything new.
    /// `truncated`: older output than that has been dropped, so the bytes begin mid-history.
    case attached(TerminalInfo, replay: Int, truncated: Bool)
    case list([TerminalInfo])
    case done
    case failed(HostFailure)
    /// (v2) A wait has ended.
    case waited(WaitResult)
    /// (v2) The terminal as it is, then this many bytes of its kept output in one output frame.
    case snapshot(TerminalInfo, bytes: Int, truncated: Bool)
}

public struct HostFailure: Sendable, Equatable, Codable, Error {
    public enum Code: String, Sendable, Codable {
        /// `hello` was not said first, or the versions do not meet.
        case incompatible
        case unknownRequest
        case noSuchTerminal
        case terminalExists
        /// The program could not be started.
        case launchFailed
        /// The connection to the host ended before it answered.
        case connectionLost
        /// (v2) The terminal waits for an answer (a permission, a question), which typing would give.
        case blocked
        /// (v2) The terminal has ended.
        case exited
        /// (v2) Something asked does not make sense: an unknown key, a name already taken.
        case invalid
        /// A code from a newer peer.
        case other

        public init(from decoder: Decoder) throws {
            self = Code(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
        }
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String = "") {
        self.code = code
        self.message = message
    }
}

public enum HostEvent: Sendable, Equatable {
    case status(terminal: UUID, TerminalStatus)
    /// The program started in the terminal has ended, after everything it printed.
    case exited(terminal: UUID, exitCode: Int32?)
    /// (v2, to subscribers) A program started a terminal.
    case added(TerminalInfo)
    /// (v2, to subscribers) Text was passed from one terminal into another.
    case passed(PassedMessage)
    /// Something a newer host says that this build does not know; ignored.
    case unknown(String)
}

public enum HostMessage: Sendable, Equatable, Codable {
    case reply(id: Int, HostReply)
    case event(HostEvent)

    private enum Key: String, CodingKey {
        case re, kind, event, host, info, terminals, replay, truncated, failure, terminal, status, exitCode, result, bytes, message
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        if let event = try values.decodeIfPresent(String.self, forKey: .event) {
            switch event {
            case "status":
                self = .event(.status(terminal: try values.decode(UUID.self, forKey: .terminal), try values.decode(TerminalStatus.self, forKey: .status)))
            case "exited":
                self = .event(.exited(terminal: try values.decode(UUID.self, forKey: .terminal), exitCode: try values.decodeIfPresent(Int32.self, forKey: .exitCode)))
            case "added":
                self = .event(.added(try values.decode(TerminalInfo.self, forKey: .info)))
            case "passed":
                self = .event(.passed(try values.decode(PassedMessage.self, forKey: .message)))
            default:
                self = .event(.unknown(event))
            }
            return
        }
        let id = try values.decode(Int.self, forKey: .re)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "hello": self = .reply(id: id, .hello(try values.decode(HostInfo.self, forKey: .host)))
        case "created": self = .reply(id: id, .created(try values.decode(TerminalInfo.self, forKey: .info)))
        case "attached":
            self = .reply(id: id, .attached(try values.decode(TerminalInfo.self, forKey: .info), replay: try values.decode(Int.self, forKey: .replay),
                                            truncated: try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false))
        case "list": self = .reply(id: id, .list(try values.decode([TerminalInfo].self, forKey: .terminals)))
        case "done": self = .reply(id: id, .done)
        case "failed": self = .reply(id: id, .failed(try values.decode(HostFailure.self, forKey: .failure)))
        case "waited": self = .reply(id: id, .waited(try values.decode(WaitResult.self, forKey: .result)))
        case "snapshot":
            self = .reply(id: id, .snapshot(try values.decode(TerminalInfo.self, forKey: .info), bytes: try values.decode(Int.self, forKey: .bytes),
                                            truncated: try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false))
        default: self = .reply(id: id, .failed(HostFailure(.unknownRequest, "unknown answer \(kind)")))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        switch self {
        case .event(.status(let terminal, let status)):
            try values.encode("status", forKey: .event)
            try values.encode(terminal, forKey: .terminal)
            try values.encode(status, forKey: .status)
        case .event(.exited(let terminal, let exitCode)):
            try values.encode("exited", forKey: .event)
            try values.encode(terminal, forKey: .terminal)
            try values.encodeIfPresent(exitCode, forKey: .exitCode)
        case .event(.added(let info)):
            try values.encode("added", forKey: .event)
            try values.encode(info, forKey: .info)
        case .event(.passed(let message)):
            try values.encode("passed", forKey: .event)
            try values.encode(message, forKey: .message)
        case .event(.unknown(let event)):
            try values.encode(event, forKey: .event)
        case .reply(let id, let reply):
            try values.encode(id, forKey: .re)
            switch reply {
            case .hello(let host):
                try values.encode("hello", forKey: .kind)
                try values.encode(host, forKey: .host)
            case .created(let info):
                try values.encode("created", forKey: .kind)
                try values.encode(info, forKey: .info)
            case .attached(let info, let replay, let truncated):
                try values.encode("attached", forKey: .kind)
                try values.encode(info, forKey: .info)
                try values.encode(replay, forKey: .replay)
                try values.encode(truncated, forKey: .truncated)
            case .list(let terminals):
                try values.encode("list", forKey: .kind)
                try values.encode(terminals, forKey: .terminals)
            case .done:
                try values.encode("done", forKey: .kind)
            case .failed(let failure):
                try values.encode("failed", forKey: .kind)
                try values.encode(failure, forKey: .failure)
            case .waited(let result):
                try values.encode("waited", forKey: .kind)
                try values.encode(result, forKey: .result)
            case .snapshot(let info, let bytes, let truncated):
                try values.encode("snapshot", forKey: .kind)
                try values.encode(info, forKey: .info)
                try values.encode(bytes, forKey: .bytes)
                try values.encode(truncated, forKey: .truncated)
            }
        }
    }
}
