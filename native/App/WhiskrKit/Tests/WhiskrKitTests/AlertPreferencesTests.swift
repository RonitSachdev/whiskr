import Foundation
import Testing
@testable import WhiskrKit

@Suite("Alert preferences")
struct AlertPreferencesTests {
    let standard = AlertPreferences.standard

    // MARK: Events and hooks

    @Test("every event but the bell comes from hook events the app asks Claude Code for")
    func hooks() {
        for event in AlertEvent.allCases where event != .bell {
            #expect(!event.hookEvents.isEmpty)
            for name in event.hookEvents {
                let hook = String(name.prefix { $0 != " " })
                #expect(HookSettings.events.contains(hook), "\(event): \(hook)")
            }
        }
        #expect(AlertEvent.bell.hookEvents.isEmpty)
    }

    @Test("a Claude's state names its event: request or question by what it waits for, error, finished")
    func eventOfState() {
        #expect(AlertEvent.of(status: .blocked, failed: false, request: .permission) == .request)
        #expect(AlertEvent.of(status: .blocked, failed: false, request: nil) == .request)
        #expect(AlertEvent.of(status: .blocked, failed: false, request: .question) == .question)
        #expect(AlertEvent.of(status: .blocked, failed: true, request: nil) == .error)
        #expect(AlertEvent.of(status: .done, failed: false, request: nil) == .finished)
        for status in [AgentStatus.working, .idle, .unknown] { #expect(AlertEvent.of(status: status, failed: false, request: nil) == nil) }
    }

    private func world(_ events: [(String, [String: JSONValue])]) -> SessionSnapshot? {
        var world = AgentWorld()
        let now = Date(timeIntervalSince1970: 1_000_000)
        for (event, extra) in events {
            var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": "s1", "cwd": "/code/shop"]
            payload.merge(extra) { _, new in new }
            world.ingest(.object(payload), account: "personal", paneID: "pane-1", now: now)
        }
        return world.snapshots.first
    }

    @Test("what a request waits for, from the hooks Claude Code sends for it")
    func requestKinds() {
        let bash: [String: JSONValue] = ["tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]
        let ask: [String: JSONValue] = ["tool_name": "AskUserQuestion", "tool_use_id": "q1", "tool_input": ["questions": [["question": "Which?"]]]]
        let permission = world([("UserPromptSubmit", [:]), ("PreToolUse", bash), ("PermissionRequest", bash),
                                ("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash"])])
        #expect(permission?.status == .blocked && permission?.request == .permission)
        #expect(world([("UserPromptSubmit", [:]), ("PreToolUse", ask)])?.request == .question)
        // Announced as a permission prompt too, it is still a question.
        let asked = world([("UserPromptSubmit", [:]), ("PreToolUse", ask), ("PermissionRequest", ask),
                           ("Notification", ["notification_type": "permission_prompt", "message": "Claude needs your permission to use AskUserQuestion"])])
        #expect(asked?.status == .blocked && asked?.request == .question)
        #expect(world([("UserPromptSubmit", [:]), ("PermissionRequest", ["tool_name": "ExitPlanMode"])])?.request == .question)
        #expect(world([("UserPromptSubmit", [:]), ("Elicitation", ["message": "Sign in"])])?.request == .question)
        #expect(world([("UserPromptSubmit", [:]), ("Notification", ["notification_type": "elicitation_dialog"])])?.request == .question)
        #expect(world([("UserPromptSubmit", [:]), ("Notification", ["notification_type": "permission_prompt"])])?.request == .permission)
        // Answered, it waits for nothing.
        #expect(world([("UserPromptSubmit", [:]), ("PermissionRequest", bash), ("PostToolUse", bash)])?.request == nil)
        // A later permission after an answered question is a permission again.
        let later = world([("UserPromptSubmit", [:]), ("Elicitation", [:]), ("ElicitationResult", [:]), ("PermissionRequest", bash)])
        #expect(later?.request == .permission)
    }

    // MARK: Defaults and settings

    @Test("calm defaults: requests, questions, errors and long finished turns; helpers silent; the bell as a terminal's")
    func defaults() {
        #expect(standard[.request] == AlertEventSetting(sound: .whiskr(.request), notify: true))
        #expect(standard[.question] == AlertEventSetting(sound: .whiskr(.request), notify: true))
        #expect(standard[.finished] == AlertEventSetting(sound: .whiskr(.finished), notify: true))
        #expect(standard[.error] == AlertEventSetting(sound: .whiskr(.error), notify: true))
        #expect(standard[.helperFinished] == AlertEventSetting(sound: .none, notify: false))
        #expect(standard[.bell] == AlertEventSetting(sound: .macAlert, notify: false))
        #expect(!standard.soundsOnlyInBackground)
        #expect(standard.volume > 0.4 && standard.volume <= 1)
        #expect(AlertPreferences(stored: [:]) == standard)
    }

    @Test("sound choices keep as text and come back; anything else is refused")
    func storedChoices() {
        let choices: [AlertSoundChoice] = [.none, .macAlert, .whiskr(.request), .whiskr(.error), .whiskr(.finished), .system("Glass"), .custom("My Ding.m4a")]
        for choice in choices { #expect(AlertSoundChoice(stored: choice.stored) == choice) }
        for bad in ["", "whiskr:", "whiskr:bark", "system:", "custom:../x.wav", "custom:a/b.wav", "custom:.hidden", "loud", "none:x"] {
            #expect(AlertSoundChoice(stored: bad) == nil, "\(bad)")
        }
    }

    @Test("what is kept comes back as it was")
    func roundTrip() {
        var preferences = standard
        preferences[.finished].sound = .system("Glass")
        preferences[.request].notify = false
        preferences[.bell].sound = .none
        preferences[.helperFinished] = AlertEventSetting(sound: .custom("Ding.aiff"), notify: true)
        preferences.volume = 0.25
        preferences.soundsOnlyInBackground = true
        #expect(AlertPreferences(stored: preferences.stored) == preferences)
        // A value of the wrong kind is ignored: that one setting stays at its default.
        var broken = preferences.stored
        broken[AlertPreferences.Key.sound(.finished)] = 7
        broken[AlertPreferences.Key.volume] = 9.0
        let read = AlertPreferences(stored: broken)
        #expect(read[.finished].sound == standard[.finished].sound)
        #expect(read.volume == 1)
    }

    @Test("the earlier version's switches carry over, and the new keys win once there")
    func migration() {
        let earlier: [String: Any] = ["soundRequests": false, "soundFinished": true, "notifyRequests": true, "notifyFinished": false, "soundVolume": 0.4]
        let migrated = AlertPreferences(stored: earlier)
        #expect(migrated[.request].sound == .none && migrated[.question].sound == .none && migrated[.error].sound == .none)
        #expect(migrated[.finished].sound == .whiskr(.finished))
        #expect(migrated[.request].notify && migrated[.question].notify && migrated[.error].notify)
        #expect(!migrated[.finished].notify)
        #expect(migrated.volume == 0.4)
        #expect(migrated[.helperFinished] == standard[.helperFinished] && migrated[.bell] == standard[.bell])
        let onlyFinishes = AlertPreferences(stored: ["soundFinished": false, "notifyRequests": false])
        #expect(onlyFinishes[.finished].sound == .none && onlyFinishes[.request].sound == .whiskr(.request))
        #expect(!onlyFinishes[.request].notify && onlyFinishes[.finished].notify)
        var both = earlier
        both.merge(standard.stored) { _, new in new }
        #expect(AlertPreferences(stored: both) == standard)
        #expect(Set(AlertPreferences.Key.earlier).isSuperset(of: ["soundRequests", "soundFinished", "notifyRequests", "notifyFinished", "soundVolume"]))
    }

    // MARK: Deciding

    @Test("a sound plays unless you are at that terminal; the bell rings even then")
    func soundGate() {
        let away = AlertMoment(appActive: true, watching: false)
        let watchingIdle = AlertMoment(appActive: true, watching: true, typedAgo: 60)
        let typingThere = AlertMoment(appActive: true, watching: true, typedAgo: 2)
        let typedThereLongAgo = AlertMoment(appActive: true, watching: true, typedAgo: AlertPreferences.typingGrace + 1)
        let otherApp = AlertMoment(appActive: false, watching: false)
        for event in [AlertEvent.request, .question, .error, .finished] {
            #expect(standard.decide(event, away).sound == standard[event].sound)
            #expect(standard.decide(event, watchingIdle).sound == standard[event].sound, "watching a Claude you are not typing to: heard")
            #expect(standard.decide(event, typedThereLongAgo).sound == standard[event].sound)
            #expect(standard.decide(event, typingThere).sound == nil, "typing in that very terminal: you see it")
            #expect(standard.decide(event, otherApp).sound == standard[event].sound, "in another app: heard")
        }
        #expect(standard.decide(.bell, typingThere).sound == .macAlert)
        #expect(standard.decide(.helperFinished, away).sound == nil)
    }

    @Test("a notification only while Whiskr is in the background, a finished turn only after a long one")
    func notifyGate() {
        let inApp = AlertMoment(appActive: true, watching: false)
        let otherApp = AlertMoment(appActive: false, watching: false)
        for event in [AlertEvent.request, .question, .error] {
            #expect(!standard.decide(event, inApp).notify)
            #expect(standard.decide(event, otherApp).notify)
        }
        #expect(!standard.decide(.finished, AlertMoment(appActive: false, watching: false, turnLength: 12)).notify)
        #expect(standard.decide(.finished, AlertMoment(appActive: false, watching: false, turnLength: AlertPreferences.longTurn)).notify)
        #expect(!standard.decide(.finished, AlertMoment(appActive: false, watching: false)).notify)
        #expect(!standard.decide(.bell, otherApp).notify && !standard.decide(.helperFinished, otherApp).notify)
        var preferences = standard
        preferences[.bell].notify = true
        #expect(preferences.decide(.bell, otherApp).notify && !preferences.decide(.bell, inApp).notify)
    }

    @Test("Pause Alerts silences everything; sounds can wait for the background")
    func pauseAndBackground() {
        let paused = AlertMoment(appActive: false, watching: false, paused: true, turnLength: 100)
        for event in AlertEvent.allCases { #expect(standard.decide(event, paused) == .nothing) }
        var preferences = standard
        preferences.soundsOnlyInBackground = true
        #expect(preferences.decide(.request, AlertMoment(appActive: true, watching: false)).sound == nil)
        #expect(preferences.decide(.request, AlertMoment(appActive: false, watching: false)).sound == .whiskr(.request))
        preferences[.request].sound = .none
        #expect(preferences.decide(.request, AlertMoment(appActive: false, watching: false)) == AlertDecision(sound: nil, notify: true))
    }

    // MARK: Custom sounds

    @Test("a chosen file keeps its name, numbered when taken, never hidden or a path")
    func customNames() {
        #expect(CustomSounds.fileName(for: "/Users/x/Ding.m4a", taken: []) == "Ding.m4a")
        #expect(CustomSounds.fileName(for: "Ding.m4a", taken: ["Ding.m4a"]) == "Ding 2.m4a")
        #expect(CustomSounds.fileName(for: "Ding.m4a", taken: ["Ding.m4a", "Ding 2.m4a"]) == "Ding 3.m4a")
        #expect(CustomSounds.fileName(for: ".secret.wav", taken: []) == "secret.wav")
        for odd in ["...wav", "..", ".wav", "."] {
            let name = CustomSounds.fileName(for: odd, taken: [])
            #expect(AlertSoundChoice.isPlainName(name), "\(odd) → \(name)")
        }
        #expect(CustomSounds.fileName(for: "a:b.aiff", taken: []) == "a-b.aiff")
        #expect(AlertSoundChoice(stored: AlertSoundChoice.custom(CustomSounds.fileName(for: "../../x.wav", taken: [])).stored) != nil)
        #expect(CustomSounds.displayName("Ding 2.m4a") == "Ding 2")
    }

    @Test("a custom sound must decode, be heard and be short")
    func customCheck() {
        #expect(CustomSounds.check(peak: 0.5, duration: 1.2) == nil)
        #expect(CustomSounds.check(peak: 0.5, duration: 30) == .tooLong(30))
        #expect(CustomSounds.check(peak: 0, duration: 1) == .silent)
        #expect(CustomSounds.check(peak: 0.5, duration: 0) == .unreadable)
        #expect(CustomSounds.check(peak: .nan, duration: 1) == .unreadable)
        #expect(CustomSounds.peak([0.1, -0.7, 0.3]) == 0.7)
        // The app's own sounds pass the same check.
        for sound in AlertSound.allCases {
            #expect(CustomSounds.check(peak: CustomSounds.peak(sound.samples), duration: Double(sound.samples.count) / Double(AlertSound.sampleRate)) == nil)
        }
    }

    @Test("a custom sound that is gone falls back to the default, and removing one resets who used it")
    func customBookkeeping() {
        var preferences = standard
        preferences[.finished].sound = .custom("Ding.m4a")
        preferences[.request].sound = .custom("Ding.m4a")
        preferences[.bell].sound = .custom("Other.wav")
        #expect(preferences.sound(for: .finished, available: ["Ding.m4a"]) == .custom("Ding.m4a"))
        #expect(preferences.sound(for: .finished, available: []) == .whiskr(.finished))
        #expect(preferences.sound(for: .request, available: ["Other.wav"]) == .whiskr(.request))
        preferences.forget(custom: "Ding.m4a")
        #expect(preferences[.finished].sound == .whiskr(.finished) && preferences[.request].sound == .whiskr(.request))
        #expect(preferences[.bell].sound == .custom("Other.wav"))
    }
}
