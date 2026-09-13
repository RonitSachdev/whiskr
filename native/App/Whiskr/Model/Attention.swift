import AppKit
import WhiskrKit

/// How the app tells you that a Claude needs you or has finished, beyond the marks in the meadow and on
/// the tabs, which always show (docs/DESIGN.md): a soft sound while you are in the app and the
/// asking pane is not the one you are typing in; a notification while you are in another app; the Dock
/// icon's count and, if you want it, one bounce. Pause Alerts silences the sounds and notifications.
/// Nothing here ever moves focus, a window, a tab or the meadow's camera (§6.5).
@MainActor
final class AlertCenter: NSObject {
    static let shared = AlertCenter()

    private var queue = AlertQueue()
    private var retry: Timer?
    private var sounds: [AlertSound: NSSound] = [:]
    /// When each session's turn began, so only turns of 30 seconds or more notify when they finish.
    private var turnStarted: [String: Date] = [:]

    /// A Claude's state changed to one that has something to say. `focusedHere`: its pane is the one
    /// you are typing in, in the window you are looking at (then nothing sounds: you can see it).
    func changed(_ session: SessionSnapshot, place: String, focusedHere: Bool, notify: (String, String, Bool) -> Void) {
        switch session.status {
        case .working:
            if turnStarted[session.id] == nil { turnStarted[session.id] = Date() }
            return
        case .blocked, .done:
            break
        default:
            turnStarted[session.id] = nil
            return
        }
        let began = turnStarted.removeValue(forKey: session.id)
        guard !focusedHere, !Preferences.shared.alertsPaused else { return }
        let sound: AlertSound = session.status == .done ? .finished : session.failed ? .error : .request
        if NSApp.isActive {
            let wanted = sound == .finished ? Preferences.shared.soundFinished : Preferences.shared.soundRequests
            guard wanted else { return }
            queue.offer(sound, key: "\(session.id)/\(session.statusSince.timeIntervalSince1970)/\(sound)", now: Date())
            playWhenDue()
        } else {
            switch sound {
            case .finished:
                // Finished is never loud, and only worth a notification after a long turn.
                guard Preferences.shared.notifyFinished, Date().timeIntervalSince(began ?? .distantFuture) >= 30 else { return }
                notify(place, String(localized: "Finished", comment: "Notification body: Claude's turn ended"), false)
            case .error, .request:
                guard Preferences.shared.notifyRequests else { return }
                let body = sound == .error
                    ? String(localized: "Stopped on an error", comment: "Notification body: Claude's turn ended on an error")
                    : session.main.line.isEmpty ? String(localized: "Claude needs you", comment: "Notification body: a request with no detail") : session.main.line
                notify(place, body, sound == .request)
                if Preferences.shared.dockBounce { NSApp.requestUserAttention(.informationalRequest) }
            }
        }
    }

    /// Plays the waiting sound once the queue allows (spaced, after a pause in typing).
    private func playWhenDue() {
        retry?.invalidate()
        retry = nil
        if let sound = queue.take(now: Date(), lastKey: lastKeystroke(), paused: Preferences.shared.alertsPaused) { play(sound) }
        guard queue.isWaiting else { return }
        let timer = Timer(timeInterval: 0.25, repeats: false) { _ in MainActor.assumeIsolated { AlertCenter.shared.playWhenDue() } }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
    }

    /// Settings › Alerts' Play buttons, and the alerts themselves.
    func play(_ sound: AlertSound) {
        // A run against scratch settings (Debug) never makes a sound on your Mac.
        guard !AppPlaces.isIsolated else { return }
        let player = sounds[sound] ?? NSSound(data: sound.wav)
        sounds[sound] = player
        player?.stop()
        player?.volume = Float(Preferences.shared.soundVolume)
        player?.play()
    }

    /// When a key was last typed into a terminal (kept by the window's key monitor).
    var lastKeystroke: () -> Date? = { nil }

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
