import AppKit
import WhiskrKit

/// How the app tells you that a Claude needs you, has finished or stopped on an error, that a helper is
/// done, or that a terminal rang its bell, beyond the marks in the meadow and on the tabs, which always
/// show (docs/DESIGN.md, Attention): each event's sound and notification as Settings › Alerts sets them
/// (`AlertPreferences.decide`: a sound unless you are typing in that very terminal, a notification while
/// Whiskr is in the background), the Dock icon's count and, if you want it, one bounce. Pause Alerts
/// silences the sounds and notifications. Nothing here ever moves focus, a window, a tab or the meadow's
/// camera (§6.5).
@MainActor
final class AlertCenter: NSObject {
    static let shared = AlertCenter()

    private var queue = AlertQueue()
    private var retry: Timer?
    private var players: [AlertSoundChoice: NSSound] = [:]
    /// When each session's turn began, so only long turns notify when they finish. A request in the middle
    /// of a turn does not start it again.
    private var turnStarted: [String: Date] = [:]
    private var lastBell = Date.distantPast
    static let bellSpacing: TimeInterval = 1

    /// Where the sounds you add are kept (Settings › Alerts › Choose…).
    static var soundsFolder: URL { AppPlaces.supportFolder.appendingPathComponent("Sounds", isDirectory: true) }

    /// The sounds you added, by file name.
    static var customSounds: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: soundsFolder.path)) ?? []
        return names.filter { AlertSoundChoice.isPlainName($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A Claude's state changed. `moment`: where you are (`Workbench.alertMoment`); `notify` shows a
    /// notification with a title, a body and the event it is for.
    func changed(_ session: SessionSnapshot, place: String, moment: AlertMoment, notify: @escaping (String, String, AlertEvent) -> Void) {
        let now = Date()
        if session.status == .working {
            if turnStarted[session.id] == nil { turnStarted[session.id] = now }
            return
        }
        guard let event = AlertEvent.of(status: session.status, failed: session.failed, request: session.request) else {
            turnStarted[session.id] = nil
            return
        }
        var moment = moment
        if event == .finished || event == .error {
            moment.turnLength = turnStarted.removeValue(forKey: session.id).map { now.timeIntervalSince($0) }
        }
        let body: String = switch event {
        case .error: String(localized: "Stopped on an error", comment: "Notification body: Claude's turn ended on an error")
        case .finished: String(localized: "Finished", comment: "Notification body: Claude's turn ended")
        default:
            session.agents.first { $0.request != nil }.map(\.line).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "Claude needs you", comment: "Notification body: a request with no detail")
        }
        announce(event, key: "\(session.id)/\(session.statusSince.timeIntervalSince1970)/\(event.rawValue)", moment: moment) { notify(place, body, event) }
    }

    /// A helper finished its task (SubagentStop).
    func helperFinished(_ title: String, key: String, place: String, moment: AlertMoment, notify: @escaping (String, String, AlertEvent) -> Void) {
        let body = title.isEmpty
            ? String(localized: "A helper finished", comment: "Notification body: one of Claude's helpers is done")
            : String(localized: "A helper finished · \(title)", comment: "Notification body: one of Claude's helpers is done, then its task")
        announce(.helperFinished, key: key, moment: moment) { notify(place, body, .helperFinished) }
    }

    /// A plain terminal rang its bell.
    func bell(place: String, moment: AlertMoment, notify: @escaping (String, String, AlertEvent) -> Void) {
        announce(.bell, key: UUID().uuidString, moment: moment) {
            notify(place, String(localized: "Bell", comment: "Notification body: a terminal rang its bell"), .bell)
        }
    }

    private func announce(_ event: AlertEvent, key: String, moment: AlertMoment, notify: () -> Void) {
        let decision = Preferences.shared.alerts.decide(event, moment)
        #if DEBUG
        decisions.append((event, moment, decision))
        #endif
        if decision.sound != nil {
            if event == .bell {
                // The terminal's answer to what you typed: at once, not after a pause in typing; and once a
                // second at most, so a program printing bells (or binary) does not ring on and on.
                let now = Date()
                if now.timeIntervalSince(lastBell) >= Self.bellSpacing {
                    lastBell = now
                    play(event)
                }
            } else {
                queue.offer(event, key: key, now: Date())
                playWhenDue()
            }
        }
        guard decision.notify else { return }
        notify()
        if Preferences.shared.dockBounce, [.request, .question, .error].contains(event) { NSApp.requestUserAttention(.informationalRequest) }
    }

    /// Plays the waiting sound once the queue allows (spaced, after a pause in typing).
    private func playWhenDue() {
        retry?.invalidate()
        retry = nil
        if let event = queue.take(now: Date(), lastKey: lastKeystroke(), paused: Preferences.shared.alertsPaused) { play(event) }
        guard queue.isWaiting else { return }
        let timer = Timer(timeInterval: 0.25, repeats: false) { _ in MainActor.assumeIsolated { AlertCenter.shared.playWhenDue() } }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
    }

    /// The sound an event makes now (its default when a sound you added is gone).
    func sound(for event: AlertEvent) -> AlertSoundChoice {
        Preferences.shared.alerts.sound(for: event, available: Set(Self.customSounds))
    }

    func play(_ event: AlertEvent) {
        play(sound(for: event), for: event)
    }

    /// Settings › Alerts' Play buttons and sound menus, and the alerts themselves.
    func play(_ choice: AlertSoundChoice, for event: AlertEvent? = nil) {
        let volume = Float(Preferences.shared.alerts.volume)
        // A run against scratch settings (Debug) never makes a sound on your Mac: it notes what it would
        // have played, and how loud.
        if AppPlaces.isIsolated {
            #if DEBUG
            played.append((choice, volume, event))
            #endif
            return
        }
        switch choice {
        case .none:
            return
        case .macAlert:
            // At System Settings' alert volume, as every Mac app's alert sound.
            NSSound.beep()
        default:
            guard let player = player(for: choice) ?? event.flatMap({ player(for: AlertPreferences.standard[$0].sound) }) else { return }
            player.stop()
            player.volume = volume
            player.play()
        }
    }

    private func player(for choice: AlertSoundChoice) -> NSSound? {
        if let player = players[choice] { return player }
        let player: NSSound? = switch choice {
        case .whiskr(let sound): NSSound(data: sound.wav)
        case .system(let name): NSSound(contentsOf: Self.systemSoundsFolder.appendingPathComponent(name + ".aiff"), byReference: true)
        case .custom(let file): NSSound(contentsOf: Self.soundsFolder.appendingPathComponent(file), byReference: true)
        case .none, .macAlert: nil
        }
        players[choice] = player
        return player
    }

    /// A sound you added has been removed (or replaced): its player goes with it.
    func forgetPlayer(_ choice: AlertSoundChoice) {
        players[choice]?.stop()
        players[choice] = nil
    }

    /// The Mac's own alert sounds, offered beside the app's.
    static let systemSoundsFolder = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    static let systemSounds: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: systemSoundsFolder.path)) ?? []
        return names.filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()
    }()

    /// The system's beep (a refused action, a terminal's bell in sight). Every beep goes through here, so
    /// a run against scratch settings (Debug) never makes one on your Mac either.
    nonisolated static func beep() {
#if DEBUG
        // From any thread, so read from the arguments that make a run isolated (`AppPlaces.isolate`).
        guard !ProcessInfo.processInfo.arguments.contains("--isolated") else { return }
#endif
        NSSound.beep()
    }

    /// When a key was last typed into a terminal (kept by the window's key monitor).
    var lastKeystroke: () -> Date? = { nil }

    #if DEBUG
    /// Debug builds: every decision taken, and what a test run would have played (and how loud), oldest first.
    var decisions: [(event: AlertEvent, moment: AlertMoment, decision: AlertDecision)] = []
    var played: [(choice: AlertSoundChoice, volume: Float, event: AlertEvent?)] = []
    #endif

    // MARK: Pause Alerts (§6.6)

    @objc func pauseForAnHour(_ sender: Any?) { Preferences.shared.alertsPausedUntil = Date().addingTimeInterval(3600) }
    @objc func pauseUntilTomorrow(_ sender: Any?) { Preferences.shared.alertsPausedUntil = AlertPause.untilTomorrow(from: Date()) }
    @objc func resumeAlerts(_ sender: Any?) { Preferences.shared.alertsPausedUntil = nil }

    /// The Pause Alerts submenu, for the app menu and the Dock menu.
    static func pauseMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Pause Alerts"))
        for (title, action) in [(String(localized: "For 1 Hour"), #selector(pauseForAnHour(_:))),
                                (String(localized: "Until Tomorrow"), #selector(pauseUntilTomorrow(_:))),
                                (String(localized: "Resume Alerts"), #selector(resumeAlerts(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = shared
            menu.addItem(item)
        }
        return menu
    }
}

extension AlertCenter: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let paused = Preferences.shared.alertsPaused
        switch item.action {
        case #selector(resumeAlerts(_:)):
            if paused, let until = Preferences.shared.alertsPausedUntil {
                item.title = String(localized: "Resume Alerts (paused until \(until.formatted(date: .omitted, time: .shortened)))")
            } else {
                item.title = String(localized: "Resume Alerts")
            }
            return paused
        default:
            return true
        }
    }
}
