import AppKit
import Foundation
import TerminalHost
import WhiskrKit

/// The app's tie to the session host: the small process, inside the app and started on demand, that
/// owns every terminal so quitting, crashing or updating the app leaves programs running. The app is
/// its client: each pane has a connection of its own (`Pane`), and this holds one for the app itself.
///
/// Quitting never ends the host; only "Quit and Stop All Terminals" does. A host from a version this app
/// cannot talk to is left alone with its terminals, and the app starts its own beside it (`HostChoice`).
final class HostLink {
    /// Where the host listens, once found.
    private(set) var socket: HostSocket?
    /// Running terminals held by a host of another version, which this app cannot show.
    private(set) var strangers = 0
    /// The protocol the host speaks with this app: from 2 on, terminals have addresses and programs can
    /// start and steer terminals (`paw`), and the host answers programs' status probes itself.
    private(set) var version = 1
    /// A program started a terminal (`paw run`); told on the main thread.
    var onStarted: ((TerminalInfo) -> Void)?
    /// Text passed from one terminal into another (a report, a note, a task handed over).
    var onPassed: ((PassedMessage) -> Void)?
    private var control: HostConnection?
    private let launcher: HostLauncher

    /// The host's file name inside the app (beside the app's own executable).
    static let executableName = "whiskr-host"
    /// The command-line tool every terminal has on its PATH (beside the `claude` shim).
    static let toolName = "paw"

    var speaksAgents: Bool { version >= HostProtocol.agents }

    init() {
        let temporary = FileManager.default.temporaryDirectory
        let places = HostPlaces(supportFolder: AppPlaces.supportFolder, temporaryFolder: temporary)
        let executable = Bundle.main.url(forAuxiliaryExecutable: Self.executableName) ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(Self.executableName)")
        // A test run's host must never outlive the run by long, whatever happens to the run.
        let extra = AppPlaces.isIsolated ? ["--abandoned-after", "120"] : []
        // Terminals a "Workers Factory" (the app's earlier name) still runs are counted and left alone, as
        // another version's are. A test run never looks there.
        let legacy = AppPlaces.isIsolated ? nil : HostPlaces.legacy(applicationSupport: AppPlaces.applicationSupport, temporaryFolder: temporary)
        launcher = HostLauncher(places: places, executable: executable,
                                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0", extraArguments: extra,
                                legacyPlaces: legacy)
    }

    /// Finds the host, starting it if none is running, and returns the terminals it holds.
    func start() async -> [TerminalInfo] {
        let launcher = launcher
        let result: Result<HostLauncher.Found, HostLauncher.Failure> = await Task.detached {
            do throws(HostLauncher.Failure) {
                return .success(try launcher.find())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .failure(let failure):
            NSLog("Whiskr: no session host: \(failure)")
            if case .onlyStrangers(let terminals) = failure { strangers = terminals }
            return []
        case .success(let found):
            socket = found.socket
            strangers = found.strangers
            openControl(found)
            return await terminals()
        }
    }

    /// The app's own connection: it hears of terminals programs start and of messages passed, when the
    /// host speaks of them.
    private func openControl(_ found: HostLauncher.Found) {
        version = HostProtocol.spoken(client: HostProtocol.current, host: found.info.speaks)
        let handlers = HostConnection.Handlers(event: { [weak self] event in
            Task { @MainActor in self?.heard(event) }
        })
        guard let control = try? HostConnection(socketPath: found.socket.path, handlers: handlers) else { return }
        self.control = control
        control.send(.hello(HostProtocol.current, client: "app"))
        if speaksAgents { control.send(.subscribe) }
    }

    private func heard(_ event: HostEvent) {
        switch event {
        case .added(let info): onStarted?(info)
        case .passed(let message): onPassed?(message)
        default: break
        }
    }

    /// The terminals the host holds now.
    func terminals() async -> [TerminalInfo] {
        guard let control, case .list(let terminals) = await control.request(.list) else { return [] }
        return terminals
    }

    /// A connection of a pane's own. When the host has gone since the app found it (it crashed, or
    /// was stopped), one is started again first.
    func connect(_ handlers: HostConnection.Handlers) -> HostConnection? {
        for attempt in 0..<2 {
            if let path = socket?.path, let connection = try? HostConnection(socketPath: path, handlers: handlers) {
                connection.send(.hello(HostProtocol.current, client: "pane"))
                return connection
            }
            guard attempt == 0, let found = try? launcher.find() else { break }
            socket = found.socket
            control?.close()
            openControl(found)
        }
        return nil
    }

    /// Ends every terminal and the host itself, and waits for it (a moment: each program is asked
    /// first, then killed). For "Quit and Stop All Terminals" and the end of a test run.
    func stopAll() {
        guard let control else { return }
        _ = control.requestAndWait(.shutdown, timeout: HostLifecycle.shutdownGrace + 3)
        control.close()
        self.control = nil
    }

    /// Lets go of the host, which keeps everything running.
    func disconnect() {
        control?.close()
        control = nil
    }
}
