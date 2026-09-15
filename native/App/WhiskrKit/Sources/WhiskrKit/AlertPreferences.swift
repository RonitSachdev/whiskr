import Foundation

/// What can sound or show a notification (Settings › Alerts), named for what you see, each from the
/// Claude Code hook events the app already receives (`HookSettings.events`) or, for the bell, from the
/// terminal itself.
public enum AlertEvent: String, CaseIterable, Codable, Sendable {
    /// A permission request: PermissionRequest, or a Notification of type permission_prompt.
    case request
    /// A question, a plan to approve or a form: AskUserQuestion or ExitPlanMode (PreToolUse, or their
    /// PermissionRequest), Elicitation, or a Notification of type elicitation_dialog.
    case question
    /// A turn that ended: Stop.
    case finished
    /// A turn that stopped on an error: StopFailure.
    case error
    /// A helper that has finished its task: SubagentStop.
    case helperFinished
    /// A plain terminal rang its bell (BEL). Claude's own terminals have the events above instead.
    case bell

    /// The Claude Code hook events behind it, as Settings and Help name them.
    public var hookEvents: [String] {
        switch self {
        case .request: ["PermissionRequest", "Notification (permission_prompt)"]
        case .question: ["PreToolUse (AskUserQuestion, ExitPlanMode)", "Elicitation", "Notification (elicitation_dialog)"]
        case .finished: ["Stop"]
        case .error: ["StopFailure"]
        case .helperFinished: ["SubagentStop"]
        case .bell: []
        }
    }

    /// When two would sound at once, the more important one plays.
    var importance: Int {
        switch self {
        case .request, .question: 4
        case .error: 3
        case .finished: 2
        case .helperFinished: 1
        case .bell: 0
        }
    }

    /// The event a Claude's state stands for, if any: a request (of the kind it is), an error stop, or a
    /// finished turn.
    public static func of(status: AgentStatus, failed: Bool, request: RequestKind?) -> AlertEvent? {
        switch status {
        case .blocked: failed ? .error : request == .question ? .question : .request
        case .done: .finished
        default: nil
        }
    }
}

/// A sound an event can make.
public enum AlertSoundChoice: Hashable, Sendable {
    /// Silent.
    case none
    /// One of the app's own sounds (`AlertSound`).
    case whiskr(AlertSound)
    /// The Mac's alert sound, as chosen in System Settings › Sound (the terminal's bell, as Terminal rings it).
    case macAlert
    /// A sound in /System/Library/Sounds, by name ("Glass").
    case system(String)
    /// A file you chose, copied into the app's Sounds folder, by its file name there.
    case custom(String)

    /// How it is kept in the settings.
    public var stored: String {
        switch self {
        case .none: "none"
        case .whiskr(let sound): "whiskr:\(sound.rawValue)"
        case .macAlert: "mac-alert"
        case .system(let name): "system:\(name)"
        case .custom(let file): "custom:\(file)"
        }
    }

    public init?(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count) {
        case ("none", 1): self = .none
        case ("mac-alert", 1): self = .macAlert
        case ("whiskr", 2): guard let sound = AlertSound(rawValue: parts[1]) else { return nil }; self = .whiskr(sound)
        case ("system", 2) where Self.isPlainName(parts[1]): self = .system(parts[1])
        case ("custom", 2) where Self.isPlainName(parts[1]): self = .custom(parts[1])
        default: return nil
        }
    }

    /// A name that stays inside its folder: settings are only data, so a stored "../x" is refused.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".." && !name.hasPrefix(".")
    }

    public var isSilent: Bool { self == .none }
}

/// One event's sound and whether it shows a notification.
public struct AlertEventSetting: Equatable, Sendable {
    public var sound: AlertSoundChoice
    public var notify: Bool

    public init(sound: AlertSoundChoice, notify: Bool) {
        self.sound = sound
        self.notify = notify
    }
}

/// When an alert happens, what the app knows of where you are.
public struct AlertMoment: Equatable, Sendable {
    /// Whiskr is the app in front.
    public var appActive: Bool
    /// The alert's terminal is on screen in the window you are using.
    public var watching: Bool
    /// How long ago you last typed into that terminal; nil if not since it was last looked at this way.
    public var typedAgo: TimeInterval?
    /// Pause Alerts is on.
    public var paused: Bool
    /// A finished turn: how long it took.
    public var turnLength: TimeInterval?

    public init(appActive: Bool, watching: Bool, typedAgo: TimeInterval? = nil, paused: Bool = false, turnLength: TimeInterval? = nil) {
        self.appActive = appActive
        self.watching = watching
        self.typedAgo = typedAgo
        self.paused = paused
        self.turnLength = turnLength
    }
}

/// What to do about one alert.
public struct AlertDecision: Equatable, Sendable {
    public var sound: AlertSoundChoice?
    public var notify: Bool

    public static let nothing = AlertDecision(sound: nil, notify: false)

    public init(sound: AlertSoundChoice?, notify: Bool) {
        self.sound = sound
        self.notify = notify
    }
}

/// Settings › Alerts: each event's sound and notification, how loud, and whether sounds wait until
/// Whiskr is in the background (docs/DESIGN.md, Attention).
public struct AlertPreferences: Equatable, Sendable {
    public var events: [AlertEvent: AlertEventSetting]
    /// 0…1, for every sound but the Mac's alert sound (which follows System Settings' alert volume).
    public var volume: Double
    /// Sounds only while you are in another app; in Whiskr the meadow and the tabs show it.
    public var soundsOnlyInBackground: Bool

    /// You are at that very terminal: it is on screen in the window you use and you typed into it this
    /// recently. Then you see what happens there, and nothing sounds.
    public static let typingGrace: TimeInterval = 8
    /// A finished turn shows a notification only after a turn this long; a shorter one you were waiting for.
    public static let longTurn: TimeInterval = 30

    /// Calm by default: a request or a question sounds and notifies, a finished turn sounds and notifies
    /// after a long turn, an error sounds and notifies, a helper says nothing, and the bell rings as a
    /// terminal's does.
    public static let standard = AlertPreferences(events: [
        .request: AlertEventSetting(sound: .whiskr(.request), notify: true),
        .question: AlertEventSetting(sound: .whiskr(.request), notify: true),
        .finished: AlertEventSetting(sound: .whiskr(.finished), notify: true),
        .error: AlertEventSetting(sound: .whiskr(.error), notify: true),
        .helperFinished: AlertEventSetting(sound: .none, notify: false),
        .bell: AlertEventSetting(sound: .macAlert, notify: false),
    ], volume: 0.6, soundsOnlyInBackground: false)

    public init(events: [AlertEvent: AlertEventSetting], volume: Double, soundsOnlyInBackground: Bool) {
        self.events = events
        self.volume = volume
        self.soundsOnlyInBackground = soundsOnlyInBackground
    }

    public subscript(event: AlertEvent) -> AlertEventSetting {
        get { events[event] ?? Self.standard.events[event]! }
        set { events[event] = newValue }
    }

    /// Whether the event sounds and whether it notifies, now.
    ///   - Pause Alerts silences both.
    ///   - A sound plays unless you are at that terminal (`typingGrace`), and, if you chose so, only while
    ///     Whiskr is in the background. The bell is the terminal's own answer to what you typed, so it
    ///     rings even then.
    ///   - A notification shows only while Whiskr is in the background (in Whiskr, the meadow, the tabs and
    ///     the sound say it), and for a finished turn only after a long one.
    public func decide(_ event: AlertEvent, _ moment: AlertMoment) -> AlertDecision {
        guard !moment.paused else { return .nothing }
        let setting = self[event]
        let atIt = moment.watching && (moment.typedAgo.map { $0 < Self.typingGrace } ?? false)
        var sound: AlertSoundChoice? = setting.sound
        if setting.sound.isSilent || (atIt && event != .bell) || (soundsOnlyInBackground && moment.appActive) { sound = nil }
        var notify = setting.notify && !moment.appActive
        if event == .finished, (moment.turnLength ?? 0) < Self.longTurn { notify = false }
        return AlertDecision(sound: sound, notify: notify)
    }

    /// The sound an event plays: its own, or its default when a custom file it names is gone (`available`:
    /// the custom files there are).
    public func sound(for event: AlertEvent, available: Set<String>) -> AlertSoundChoice {
        let sound = self[event].sound
        if case .custom(let file) = sound, !available.contains(file) { return Self.standard[event].sound }
        return sound
    }

    /// A custom sound has been removed: the events that played it go back to their default sound.
    public mutating func forget(custom file: String) {
        for event in AlertEvent.allCases where self[event].sound == .custom(file) {
            self[event].sound = Self.standard[event].sound
        }
    }

    // MARK: Kept in the settings

    /// The settings' keys: one per event's sound and notification, then the volume and the background switch.
    public enum Key {
        public static func sound(_ event: AlertEvent) -> String { "alerts.\(event.rawValue).sound" }
        public static func notify(_ event: AlertEvent) -> String { "alerts.\(event.rawValue).notify" }
        public static let volume = "alerts.volume"
        public static let soundsOnlyInBackground = "alerts.soundsOnlyInBackground"
        /// The settings of the version before per-event alerts, read once and then removed.
        public static let earlier = ["soundRequests", "soundFinished", "notifyRequests", "notifyFinished", "soundVolume", "notificationsRequested"]
    }

    /// The preferences kept in `stored` (the settings, as a dictionary), with what an earlier version kept
    /// carried over where this one has nothing yet: "Sound when Claude needs you" off silences requests,
    /// questions and errors; "Sound when Claude finishes" off, finished turns; the two notification switches
    /// likewise; the volume as it was.
    public init(stored: [String: Any]) {
        var preferences = Self.standard
        func flag(_ key: String) -> Bool? { stored[key] as? Bool }
        /// The earlier version's switch for an event: one for requests (errors went with them), one for finishes.
        func earlier(_ event: AlertEvent, _ requests: String, _ finishes: String) -> Bool? {
            switch event {
            case .request, .question, .error: flag(requests)
            case .finished: flag(finishes)
            case .helperFinished, .bell: nil
            }
        }
        for event in AlertEvent.allCases {
            if let text = stored[Key.sound(event)] as? String, let sound = AlertSoundChoice(stored: text) {
                preferences[event].sound = sound
            } else if earlier(event, "soundRequests", "soundFinished") == false {
                preferences[event].sound = .none
            }
            if let notify = flag(Key.notify(event)) ?? earlier(event, "notifyRequests", "notifyFinished") {
                preferences[event].notify = notify
            }
        }
        if let volume = (stored[Key.volume] ?? stored["soundVolume"]) as? Double, volume.isFinite { preferences.volume = min(max(volume, 0), 1) }
        if let background = flag(Key.soundsOnlyInBackground) { preferences.soundsOnlyInBackground = background }
        self = preferences
    }

    /// What to keep in the settings: every value, so a later change of a default never changes yours.
    public var stored: [String: Any] {
        var values: [String: Any] = [Key.volume: volume, Key.soundsOnlyInBackground: soundsOnlyInBackground]
        for event in AlertEvent.allCases {
            values[Key.sound(event)] = self[event].sound.stored
            values[Key.notify(event)] = self[event].notify
        }
        return values
    }
}

/// Sounds you add (Settings › Alerts › Choose…): copied into the app's Sounds folder, so a file moved
/// or deleted later does not silence an alert; checked before they are taken.
public enum CustomSounds {
    /// An alert is a moment, not a song.
    public static let longest: TimeInterval = 10
    /// Quieter than this at its loudest (about -46 dBFS) and it would seem not to play.
    public static let quietest: Float = 0.005

    public enum Problem: Error, Equatable, Sendable {
        case unreadable
        case tooLong(TimeInterval)
        case silent
    }

    /// Whether decoded audio is fit to be an alert: `peak` is its loudest sample (0…1).
    public static func check(peak: Float, duration: TimeInterval) -> Problem? {
        guard duration.isFinite, duration > 0, peak.isFinite else { return .unreadable }
        if duration > longest { return .tooLong(duration) }
        if peak < quietest { return .silent }
        return nil
    }

    /// The loudest sample of some audio, 0…1.
    public static func peak(_ samples: some Sequence<Float>) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    /// The name a chosen file is kept under: its own, or "Name 2.ext" and on when that is taken. Never
    /// hidden, never a path.
    public static func fileName(for original: String, taken: Set<String>) -> String {
        let base = (original as NSString).lastPathComponent
        var stem = (base as NSString).deletingPathExtension.replacingOccurrences(of: ":", with: "-")
        while stem.hasPrefix(".") { stem.removeFirst() }
        if stem.isEmpty { stem = "Sound" }
        let ext = (base as NSString).pathExtension
        func named(_ number: Int) -> String {
            let name = number == 1 ? stem : "\(stem) \(number)"
            return ext.isEmpty ? name : "\(name).\(ext)"
        }
        var number = 1
        while taken.contains(named(number)) { number += 1 }
        return named(number)
    }

    /// The name shown for a kept file: without its extension.
    public static func displayName(_ file: String) -> String {
        (file as NSString).deletingPathExtension
    }
}
