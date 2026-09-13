import Foundation

/// Where a host lives on disk, all inside the app's support folder: `host/` (only you can enter it)
/// holds its socket, the lock that keeps a second host from starting beside it, and its log.
public struct HostPlaces: Sendable, Equatable {
    public let folder: URL
    /// Where a socket goes when its path inside `folder` would not fit a socket address.
    public let fallbackFolder: URL

    /// The longest path a Unix socket address holds (`sun_path` is 104 bytes with its ending zero).
    public static let longestSocketPath = 103

    /// `temporaryFolder`: your private temporary folder (`NSTemporaryDirectory()`), whose path is short.
    /// `fallbackPrefix`: how the fallback folder's name starts (the app's earlier name used `wf-host`).
    public init(supportFolder: URL, temporaryFolder: URL, fallbackPrefix: String = "whiskr-host") {
        folder = supportFolder.appendingPathComponent("host", isDirectory: true)
        fallbackFolder = temporaryFolder.appendingPathComponent("\(fallbackPrefix)-\(Self.fingerprint(supportFolder.path))", isDirectory: true)
    }

    /// Where a host of the app's earlier name ("Workers Factory") lives, in its own support folder.
    public static func legacy(applicationSupport: URL, temporaryFolder: URL) -> HostPlaces {
        HostPlaces(supportFolder: applicationSupport.appendingPathComponent(LegacyMigration.oldSupportFolderName, isDirectory: true),
                   temporaryFolder: temporaryFolder, fallbackPrefix: "wf-host")
    }

    /// The socket every app tries first.
    public var primary: HostSocket { socket(named: "host") }

    /// The socket an app uses when the host on the primary one speaks a protocol it cannot: a host of
    /// its own version beside it, so the other's terminals are left alone.
    public func alternate(for version: Int) -> HostSocket { socket(named: "host-v\(version)") }

    private func socket(named name: String) -> HostSocket {
        let inside = folder.appendingPathComponent("\(name).sock").path
        let path = inside.utf8.count <= Self.longestSocketPath ? inside : fallbackFolder.appendingPathComponent("\(name).sock").path
        return HostSocket(path: path, lock: folder.appendingPathComponent("\(name).lock").path, log: folder.appendingPathComponent("\(name).log").path)
    }

    /// A short, stable name for a folder (FNV-1a), so each support folder gets its own fallback.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }
}

public struct HostSocket: Sendable, Equatable {
    public let path: String
    /// The file a host locks for as long as it owns the socket, so two never share one.
    public let lock: String
    public let log: String

    public init(path: String, lock: String, log: String) {
        self.path = path
        self.lock = lock
        self.log = log
    }
}

/// What an app found on a socket when it knocked.
public enum HostProbe: Sendable, Equatable {
    /// Nothing is listening.
    case absent
    case compatible
    /// A host that speaks a protocol this app cannot, holding that many running terminals.
    case stranger(terminals: Int)
}

/// Which host an app uses. It never ends a host it cannot talk to: that host's terminals keep running
/// (a newer or older copy of the app may be using them), and this app starts one of its own beside it.
public enum HostChoice: Sendable, Equatable {
    public enum Place: Sendable, Equatable { case primary, alternate }

    /// Use the host at `place`, starting one there first when `start`.
    case use(Place, start: Bool)
    /// Both sockets are held by hosts this app cannot talk to.
    case none

    public static func choose(primary: HostProbe, alternate: HostProbe) -> HostChoice {
        if primary == .compatible { return .use(.primary, start: false) }
        if alternate == .compatible { return .use(.alternate, start: false) }
        if primary == .absent { return .use(.primary, start: true) }
        if alternate == .absent { return .use(.alternate, start: true) }
        return .none
    }

    /// Running terminals this app cannot show, to tell the user about.
    public static func strangers(primary: HostProbe, alternate: HostProbe) -> Int {
        [primary, alternate].reduce(0) { total, probe in
            if case .stranger(let terminals) = probe { total + terminals } else { total }
        }
    }
}

/// When a host leaves by itself, and when a closed terminal's programs end.
public enum HostLifecycle {
    /// With no terminal running and no client connected, the host waits this long, then exits.
    public static let idleGrace: TimeInterval = 30
    /// After the hang-up that asks a terminal's programs to end, whatever is left is killed.
    public static let killGrace: TimeInterval = 2
    /// On shutdown, how long every terminal gets to end by itself.
    public static let shutdownGrace: TimeInterval = 1.5
    /// How often the host looks at each watched terminal's foreground: a cat appears this soon after
    /// `claude` starts.
    public static let lookInterval: TimeInterval = 0.1

    /// How long until the host should exit if nothing changes: 0 now, nil never. With no terminal
    /// running and no client connected it waits `idleGrace`, counted from whichever went last.
    /// `abandonedAfter` (test runs only): it leaves, ending any terminals, once no client has been
    /// connected that long, so a run that crashed leaves nothing behind.
    public static func exitDelay(runningTerminals: Int, clients: Int, lastClient: Date, lastTerminal: Date, now: Date,
                                 idleGrace: TimeInterval = idleGrace, abandonedAfter: TimeInterval? = nil) -> TimeInterval? {
        guard clients == 0 else { return nil }
        var delays: [TimeInterval] = []
        if let abandonedAfter { delays.append(abandonedAfter - now.timeIntervalSince(lastClient)) }
        if runningTerminals == 0 { delays.append(idleGrace - now.timeIntervalSince(max(lastClient, lastTerminal))) }
        return delays.min().map { max($0, 0) }
    }
}
