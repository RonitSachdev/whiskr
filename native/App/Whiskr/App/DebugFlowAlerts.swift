#if DEBUG
import AppKit
import AVFoundation
import UserNotifications
import WhiskrKit

/// `--perf-flows alerts` (`make perf`'s checks): what a person hears and sees when a Claude needs them,
/// end to end. A Claude is started as the owner of a Mac starts one, through a shell function of their own
/// that passes `--settings` (`claude() { command claude --settings <file> "$@"; }`), so through our shim and
/// `paw merge-settings`; the stand-in Claude (`AlertsFakeClaude`, never the real one) then runs every hook
/// command of each event from the settings it was given, as Claude Code runs a command hook: through a
/// shell, the event's JSON on its standard input. The events reach the listener over HTTP, change the
/// state, and the check looks at what the app then decided to play and to show, as a person would be in
/// each case: watching that Claude's terminal after typing to it, typing to it right now, in another app,
/// with alerts paused. A test run plays nothing and posts nothing (`AppPlaces.isIsolated`): `AlertCenter`
/// and `Notifier` note what they would have played (which sound, how loud) and shown (the request
/// itself), and the sounds noted are decoded and checked to be heard.
///
/// The earlier checks sent hook events straight into the model (`AgentMonitor.simulate`) and never asked
/// what sounded: a Claude you were watching never made a sound, and none did in another app, and every
/// check still passed.
extension PerfSuite {
    func alertsCheck() async {
        await AlertsRun(suite: self).run()
    }
}

@MainActor
private final class AlertsRun {
    let suite: PerfSuite
    var workbench: Workbench { suite.workbench }
    let place: URL
    let records: URL
    private var step = 0
    private var claude: Pane!
    private var shell: Pane!
    private let session = "alerts-1"

    init(suite: PerfSuite) {
        self.suite = suite
        place = URL(fileURLWithPath: suite.folder("alerts"), isDirectory: true)
        records = place.appendingPathComponent("records", isDirectory: true)
    }

    func check(_ name: String, _ passed: Bool, _ detail: String = "") { suite.check("alerts: \(name)", passed, detail) }

    func run() async {
        hooksFileCheck()
        guard await startClaude() else { return }
        await watchingCheck()
        await typingThereCheck()
        await otherAppCheck()
        await helperCheck()
        await bellCheck()
        await pauseCheck()
        await customSoundCheck()
        audibleCheck()
        await settingsCheck()
        await permissionNote()
        _ = await fire("exit")
        workbench.appIsActive = { NSApp.isActive }
    }

    // MARK: The hooks

    /// The settings every pane's `claude` gets carry a hook for each event an alert comes from.
    private func hooksFileCheck() {
        let document = (try? Data(contentsOf: Workbench.hooksFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let hooks = Set((document?["hooks"] as? [String: Any] ?? [:]).keys)
        let needed = Set(AlertEvent.allCases.flatMap(\.hookEvents).map { String($0.prefix { $0 != " " }) })
        check("the hooks file asks Claude Code for every event an alert comes from", !needed.isEmpty && needed.isSubset(of: hooks),
              "missing \(needed.subtracting(hooks).sorted())")
    }

    /// Starts the stand-in Claude in a tab of its own, through a shell function with `--settings`, and a
    /// plain shell in another tab of the same workspace (for the bell).
    private func startClaude() async -> Bool {
        try? FileManager.default.removeItem(at: records)
        try? FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let bin = AlertsFakeClaude.install(in: place)
        let mine = place.appendingPathComponent("my-settings.json")
        try? Data(#"{"env":{"ALERTS_MINE":"1"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}"#.utf8).write(to: mine)
        shell = workbench.newWorkspace(folder: place.path)
        guard await suite.shellReady(shell) else { check("a shell to start in", false); return false }
        claude = workbench.newTab()
        guard await suite.shellReady(claude) else { check("a shell for Claude", false); return false }
        claude.type("export PATH=\(ShellQuote.quote(bin.path)):$PATH ALERTS_RECORDS=\(ShellQuote.quote(records.path)); "
                    + "claude() { command claude --settings \(ShellQuote.quote(mine.path)) \"$@\"; }; clear\r")
        await PerfWait.sleep(500)
        claude.type("claude\r")
        // Written by the stand-in as it starts: whole once it has both lines.
        let started = await PerfWait.until(8000) {
            ((try? String(contentsOf: self.records.appendingPathComponent("argv"), encoding: .utf8))?.split(separator: "\n").count ?? 0) >= 2
        }
        let argv = (try? String(contentsOf: records.appendingPathComponent("argv"), encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let settings = argv.firstIndex(of: "--settings").flatMap { argv.indices.contains($0 + 1) ? argv[$0 + 1] : nil }
        check("Claude from your own function with --settings gets one --settings: yours with the pane's hooks, in the app's folder",
              started != nil && argv.filter { $0.hasPrefix("--settings") }.count == 1 && settings.map { $0.hasPrefix(Workbench.hooksFolder.path) } == true,
              "argv \(argv)")
        let ran = await fire("SessionStart", #","source":"startup""#)
        let reported = await PerfWait.until(5000) { self.sessionNow != nil } != nil && ran
        check("its SessionStart reaches the app through the hook command, over HTTP", reported,
              "sessions \(workbench.monitor.sessions.map { "\($0.id) \($0.paneID ?? "-")" })")
        return reported
    }

    private var sessionNow: SessionSnapshot? {
        workbench.monitor.sessions.first { $0.id == session && $0.paneID == claude.id.uuidString && !$0.ended }
    }

    /// Runs one event's hooks in the stand-in and waits until they have run.
    @discardableResult
    private func fire(_ event: String, _ extra: String = "") async -> Bool {
        step += 1
        let step = step
        try? Data("\(event)|\(extra)".utf8).write(to: records.appendingPathComponent("go-\(step)"))
        guard event != "exit" else { return true }
        return await PerfWait.until(8000) { FileManager.default.fileExists(atPath: self.records.appendingPathComponent("done-\(step)").path) } != nil
    }

    private func status(_ wanted: @escaping (SessionSnapshot) -> Bool) async -> Bool {
        await PerfWait.until(5000) { self.sessionNow.map(wanted) ?? false } != nil
    }

    // MARK: Where you are

    /// You are in Whiskr, looking at Claude's terminal, which has the keyboard; you last typed to it
    /// `typedAgo` seconds ago.
    private func beInWhiskr(typedAgo: TimeInterval, at pane: Pane? = nil) async {
        let pane = pane ?? claude!
        workbench.appIsActive = { true }
        if let tab = workbench.workspace(of: pane.id)?.1 { workbench.select(tab: tab) }
        workbench.focus(pane: pane.id)
        _ = await PerfWait.until(2000) { self.workbench.focusedPane === pane }
        workbench.isLookingAtWindow = true
        workbench.lastKeystroke = Date().addingTimeInterval(-typedAgo)
    }

    /// You are in another app.
    private func beElsewhere() {
        workbench.appIsActive = { false }
        workbench.isLookingAtWindow = false
    }

    private var played: [(choice: AlertSoundChoice, volume: Float, event: AlertEvent?)] { AlertCenter.shared.played }

    /// Waits until a sound for `event` has been played since `count` sounds, and returns it.
    private func playedSound(for event: AlertEvent, after count: Int, within timeout: Double = 4000) async -> (choice: AlertSoundChoice, volume: Float, event: AlertEvent?)? {
        _ = await PerfWait.until(timeout) { self.played.dropFirst(count).contains { $0.event == event } }
        return played.dropFirst(count).first { $0.event == event }
    }

    private func posted(after count: Int, within timeout: Double = 3500) async -> UNNotificationRequest? {
        _ = await PerfWait.until(timeout) { Notifier.posted.count > count }
        return Notifier.posted.dropFirst(count).first
    }

    private let permission = #","tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"rm -rf build"}"#
    private let question = #","tool_name":"AskUserQuestion","tool_use_id":"q1","tool_input":{"questions":[{"question":"Which branch?"}]}"#

    // MARK: Cases

    /// The owner's case: you typed a prompt into Claude a while ago and watch its terminal. A request, a
    /// question and the finished turn are each heard, at the volume set; nothing is posted (you are here).
    private func watchingCheck() async {
        await beInWhiskr(typedAgo: 20)
        let volume = Float(Preferences.shared.alerts.volume)
        await fire("UserPromptSubmit", #","prompt":"clean the build""#)
        _ = await status { $0.status == .working }
        let postedBefore = Notifier.posted.count
        var count = played.count
        await fire("PreToolUse", permission)
        await fire("PermissionRequest", permission)
        await fire("Notification", #","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash""#)
        let blocked = await status { $0.status == .blocked && $0.request == .permission }
        let request = await playedSound(for: .request, after: count)
        check("watching Claude's terminal (typed to it 20 s ago): a permission request is heard", blocked && request?.choice == .whiskr(.request) && request?.volume == volume,
              "state \(sessionNow.map { "\($0.status) \(String(describing: $0.request))" } ?? "none"), played \(played.dropFirst(count).map { "\($0.choice.stored) \($0.volume)" })")
        await fire("PostToolUse", permission)
        _ = await status { $0.status == .working }
        count = played.count
        await fire("PreToolUse", question)
        await fire("PermissionRequest", question)
        let asked = await status { $0.status == .blocked && $0.request == .question }
        let heard = await playedSound(for: .question, after: count)
        check("watching: a question (AskUserQuestion) is heard, as a question", asked && heard?.choice == .whiskr(.request),
              "state \(sessionNow.map { "\($0.status) \(String(describing: $0.request))" } ?? "none"), played \(played.dropFirst(count).map(\.choice.stored))")
        await fire("PostToolUse", question)
        count = played.count
        await fire("Stop")
        let finished = await playedSound(for: .finished, after: count)
        check("watching: the finished turn is heard", finished?.choice == .whiskr(.finished), "played \(played.dropFirst(count).map(\.choice.stored))")
        await PerfWait.sleep(2500)
        check("in Whiskr: nothing is posted to Notification Center", Notifier.posted.count == postedBefore,
              "posted \(Notifier.posted.dropFirst(postedBefore).map(\.content.body))")
    }

    /// Typing to that very Claude right now: you see what it does, so its request makes no sound.
    private func typingThereCheck() async {
        await fire("UserPromptSubmit", #","prompt":"and the tests""#)
        _ = await status { $0.status == .working }
        await beInWhiskr(typedAgo: 1)
        let count = played.count, decided = AlertCenter.shared.decisions.count
        await fire("PreToolUse", permission)
        await fire("PermissionRequest", permission)
        let blocked = await status { $0.status == .blocked }
        await PerfWait.sleep(2500)
        let decision = AlertCenter.shared.decisions.dropFirst(decided).first { $0.event == .request }
        check("typing to that Claude right now: its request makes no sound", blocked && decision?.decision.sound == nil && !played.dropFirst(count).contains { $0.event == .request },
              "decision \(decision.map { "\($0.decision)" } ?? "none"), played \(played.dropFirst(count).map(\.choice.stored))")
        await fire("PostToolUse", permission)
    }

    /// In another app: each event is heard, and requests, errors and long turns are posted; a short turn
    /// is heard only.
    private func otherAppCheck() async {
        _ = await status { $0.status == .working }
        beElsewhere()
        var count = played.count, shown = Notifier.posted.count
        await fire("PreToolUse", permission)
        await fire("PermissionRequest", permission)
        await fire("Notification", #","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash""#)
        let sound = await playedSound(for: .request, after: count)
        let request = await posted(after: shown)
        let workspace = workbench.workspace(of: claude.id)?.0.name ?? "?"
        check("in another app: a permission request is heard and posted, with Allow and Deny, saying where",
              sound?.choice == .whiskr(.request) && request?.content.categoryIdentifier == "request" && request?.content.title.hasPrefix(workspace) == true
                && request?.content.body.contains("rm -rf build") == true && request?.content.sound == nil,
              "played \(played.dropFirst(count).map(\.choice.stored)), posted \(request.map { "\($0.content.title) | \($0.content.body) | \($0.content.categoryIdentifier)" } ?? "nothing")")
        await fire("PostToolUse", permission)
        count = played.count
        shown = Notifier.posted.count
        await fire("Stop")
        let finished = await playedSound(for: .finished, after: count)
        await PerfWait.sleep(2500)
        check("in another app: a short turn's end is heard, not posted", finished != nil && Notifier.posted.count == shown,
              "played \(played.dropFirst(count).map(\.choice.stored)), posted \(Notifier.posted.dropFirst(shown).map(\.content.body))")
        count = played.count
        shown = Notifier.posted.count
        await fire("UserPromptSubmit", #","prompt":"once more""#)
        await fire("StopFailure", #","error":"overloaded""#)
        let error = await playedSound(for: .error, after: count)
        let errorPosted = await posted(after: shown)
        check("in another app: an error stop is heard and posted", error?.choice == .whiskr(.error) && errorPosted?.content.categoryIdentifier.isEmpty == true
                && errorPosted?.content.body == String(localized: "Stopped on an error", comment: "Notification body: Claude's turn ended on an error"),
              "played \(played.dropFirst(count).map(\.choice.stored)), posted \(errorPosted.map(\.content.body) ?? "nothing")")
        // A long turn: posted when it ends.
        shown = Notifier.posted.count
        await fire("UserPromptSubmit", #","prompt":"the long one""#)
        _ = await status { $0.status == .working }
        await PerfWait.sleep((AlertPreferences.longTurn + 1) * 1000)
        await fire("Stop")
        let long = await posted(after: shown)
        check("in another app: a turn of 30 s or more is posted when it ends", long?.content.body == String(localized: "Finished", comment: "Notification body: Claude's turn ended"),
              "posted \(long.map(\.content.body) ?? "nothing")")
    }

    /// A helper's end, during a turn: silent by default, and heard and posted once you ask for it.
    private func helperCheck() async {
        await fire("UserPromptSubmit", #","prompt":"look around""#)
        _ = await status { $0.status == .working }
        let decided = AlertCenter.shared.decisions.count
        await fire("SubagentStart", #","agent_id":"h1","agent_type":"Explore""#)
        await fire("PreToolUse", #","agent_id":"h1","tool_name":"Read","tool_use_id":"h1r","tool_input":{"file_path":"a.swift"}"#)
        await fire("SubagentStop", #","agent_id":"h1","agent_type":"Explore""#)
        _ = await PerfWait.until(3000) { AlertCenter.shared.decisions.dropFirst(decided).contains { $0.event == .helperFinished } }
        let quiet = AlertCenter.shared.decisions.dropFirst(decided).first { $0.event == .helperFinished }
        check("a helper's end: known, silent and not posted by default", quiet?.decision == .nothing, "decision \(quiet.map { "\($0.decision)" } ?? "none")")
        let saved = Preferences.shared.alerts
        Preferences.shared.alerts[.helperFinished] = AlertEventSetting(sound: .system("Glass"), notify: true)
        let count = played.count, shown = Notifier.posted.count
        await fire("SubagentStart", #","agent_id":"h2","agent_type":"Explore""#)
        await fire("SubagentStop", #","agent_id":"h2","agent_type":"Explore""#)
        let sound = await playedSound(for: .helperFinished, after: count)
        let note = await posted(after: shown, within: 1500)
        check("a helper's end, once asked for: heard with the sound chosen, and posted", sound?.choice == .system("Glass") && note != nil,
              "played \(played.dropFirst(count).map(\.choice.stored)), posted \(note.map(\.content.body) ?? "nothing")")
        Preferences.shared.alerts = saved
        await fire("Stop")
    }

    /// A plain terminal's bell: heard out of sight and in sight (it is the terminal answering what you
    /// typed), its tab marked out of sight; not posted unless asked for.
    private func bellCheck() async {
        await beInWhiskr(typedAgo: 20)
        var count = played.count
        let shown = Notifier.posted.count
        shell.type("printf '\\a'\r")
        let away = await playedSound(for: .bell, after: count)
        _ = await PerfWait.until(2000) { self.shell.rang }
        check("a bell out of sight: heard (the Mac's alert sound), its tab marked, not posted", away?.choice == .macAlert && shell.rang && Notifier.posted.count == shown,
              "played \(played.dropFirst(count).map(\.choice.stored)), marked \(shell.rang)")
        await PerfWait.sleep(1100)
        await beInWhiskr(typedAgo: 0, at: shell)
        count = played.count
        shell.type("printf '\\a'\r")
        let here = await playedSound(for: .bell, after: count)
        check("a bell in the terminal you type in: heard", here?.choice == .macAlert, "played \(played.dropFirst(count).map(\.choice.stored))")
    }

    /// Paused: nothing heard, nothing posted.
    private func pauseCheck() async {
        beElsewhere()
        Preferences.shared.alertsPausedUntil = Date().addingTimeInterval(3600)
        defer { Preferences.shared.alertsPausedUntil = nil }
        let count = played.count, shown = Notifier.posted.count
        await fire("UserPromptSubmit", #","prompt":"paused""#)
        await fire("PreToolUse", permission)
        await fire("PermissionRequest", permission)
        _ = await status { $0.status == .blocked }
        await PerfWait.sleep(3000)
        check("Pause Alerts: a request is neither heard nor posted", played.count == count && Notifier.posted.count == shown,
              "played \(played.dropFirst(count).map(\.choice.stored)), posted \(Notifier.posted.dropFirst(shown).map(\.content.body))")
        await fire("PostToolUse", permission)
        await fire("Stop")
    }

    // MARK: Sounds

    /// A WAV file of `seconds` of a 660 Hz tone at `level`.
    private func tone(_ name: String, seconds: Double, level: Float) -> URL {
        let rate = AlertSound.sampleRate
        let samples = (0..<Int(seconds * Double(rate))).map { level * Float(sin(2 * Double.pi * 660 * Double($0) / Double(rate))) }
        let url = place.appendingPathComponent(name)
        try? AlertSound.wav(samples).write(to: url)
        return url
    }

    /// Choose…: a short sound is taken (copied into the run's own Sounds folder) and plays; a silent, a
    /// long or a broken one is refused; a removed one falls back to the default, and removing it puts
    /// back who used it.
    private func customSoundCheck() async {
        let saved = Preferences.shared.alerts
        let added = CustomSoundFiles.add(tone("Ding.wav", seconds: 0.5, level: 0.5))
        guard case .success(let name) = added else { return check("Choose…: a short sound is taken", false, "\(added)") }
        let kept = AlertCenter.soundsFolder.appendingPathComponent(name)
        check("Choose…: a short sound is taken, copied into the app's own Sounds folder", kept.path.hasPrefix(AppPlaces.supportFolder.path) && FileManager.default.fileExists(atPath: kept.path), kept.path)
        Preferences.shared.alerts[.finished].sound = .custom(name)
        let count = played.count
        AlertCenter.shared.play(.finished)
        check("a sound you chose plays for its event", played.dropFirst(count).first?.choice == .custom(name))
        let again = CustomSoundFiles.add(tone("Ding.wav", seconds: 0.5, level: 0.5))
        check("the same name twice is kept twice", (try? again.get()) == "Ding 2.wav", "\(again)")
        if case .success(let second) = again { CustomSoundFiles.remove(second) }
        let silent = CustomSoundFiles.add(tone("Silent.wav", seconds: 0.5, level: 0))
        let long = CustomSoundFiles.add(tone("Long.wav", seconds: CustomSounds.longest + 2, level: 0.5))
        let broken = place.appendingPathComponent("Broken.wav")
        try? Data("not a sound".utf8).write(to: broken)
        check("a silent, a long and a broken file are refused", silent == .failure(.silent) && long == .failure(.tooLong(CustomSounds.longest + 2)) && CustomSoundFiles.add(broken) == .failure(.unreadable),
              "silent \(silent), long \(long)")
        // Gone behind the app's back: the default plays.
        let aside = place.appendingPathComponent("aside.wav")
        try? FileManager.default.moveItem(at: kept, to: aside)
        check("a sound you chose that is gone: its event plays its default", AlertCenter.shared.sound(for: .finished) == .whiskr(.finished))
        try? FileManager.default.moveItem(at: aside, to: kept)
        CustomSoundFiles.remove(name)
        check("removing a sound puts its event back on its default", Preferences.shared.alerts[.finished].sound == .whiskr(.finished) && !FileManager.default.fileExists(atPath: kept.path))
        Preferences.shared.alerts = saved
    }

    /// Every sound the run would have played decodes and is heard: the app's own (as the WAV data
    /// `NSSound` is given, read back by Core Audio), the Mac's, yours.
    private func audibleCheck() {
        var quiet: [String] = []
        for sound in AlertSound.allCases {
            let file = place.appendingPathComponent("\(sound.rawValue).wav")
            try? sound.wav.write(to: file)
            let read = CustomSoundFiles.inspect(file)
            if NSSound(data: sound.wav) == nil || (read?.peak ?? 0) < 0.2 { quiet.append("\(sound.rawValue) \(read.map { "\($0.peak)" } ?? "unreadable")") }
        }
        for name in Set(played.compactMap { if case .system(let name) = $0.choice { name } else { nil } }) {
            let read = CustomSoundFiles.inspect(AlertCenter.systemSoundsFolder.appendingPathComponent(name + ".aiff"))
            if (read?.peak ?? 0) < 0.05 { quiet.append("\(name) \(read.map { "\($0.peak)" } ?? "unreadable")") }
        }
        let loudness = Set(played.filter { $0.choice != .macAlert }.map(\.volume))
        check("every sound played decodes and is heard, at the volume set (not 0)", quiet.isEmpty && !loudness.isEmpty && !loudness.contains(0),
              "quiet \(quiet), volumes \(loudness.sorted())")
    }

    // MARK: Settings

    /// Settings › Alerts: a row per event, each with its sound menu and a Notify box; each box, clicked,
    /// changes its setting and goes back. (SwiftUI fills a sound menu only as it opens, and builds its
    /// accessibility tree only for a client such as VoiceOver, neither of which a test run has: the rows are
    /// found as AppKit lays them out, a menu, its Play button, its box; the menus are seen in the snapshot.)
    private func settingsCheck() async {
        let settings = SettingsWindowController.shared
        settings.show()
        defer { settings.close() }
        guard let window = settings.window, let tabs = window.contentViewController as? SettingsTabs else { return check("Settings opened", false) }
        tabs.select(pane: "alerts")
        let events = AlertEvent.allCases
        let rows = { window.contentView.map(Self.rows(in:)) ?? [] }
        _ = await PerfWait.until(3000) { rows().count >= events.count }
        await PerfWait.sleep(300)
        let found = rows()
        guard found.count == events.count else { return check("Settings › Alerts: a row per event, with a sound menu and a Notify box", false, "\(found.count) rows") }
        // AppKit drops the first click a window ever gets in a run like this one (the one that would bring an
        // inactive window forward): one on the pane's empty top takes its place.
        if let content = window.contentView, let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 4, y: content.bounds.maxY - 4), modifierFlags: [],
                                                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            NSApp.sendEvent(event)
            NSApp.sendEvent(NSEvent.mouseEvent(with: .leftMouseUp, location: event.locationInWindow, modifierFlags: [], timestamp: event.timestamp,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) ?? event)
        }
        var failed: [String] = []
        for (index, event) in events.enumerated() {
            let before = Preferences.shared.alerts[event].notify
            let box = { rows().indices.contains(index) ? rows()[index].box : nil }
            Self.click(box())
            let changed = await PerfWait.until(1500) { Preferences.shared.alerts[event].notify != before
                && AppPlaces.defaults.object(forKey: AlertPreferences.Key.notify(event)) as? Bool == !before }
            Self.click(box())
            let back = await PerfWait.until(1500) { Preferences.shared.alerts[event].notify == before }
            if changed == nil || back == nil { failed.append("\(event): changed \(changed != nil), back \(back != nil)") }
        }
        check("Settings › Alerts: each Notify box changes its event's setting, kept in the run's settings, and back", failed.isEmpty, "\(failed)")
    }
    /// A click on a box, as the window delivers one: SwiftUI's controls answer only real clicks.
    static func click(_ box: NSButton?) {
        guard let box, let window = box.window else { return }
        let location = box.convert(NSPoint(x: box.bounds.midX, y: box.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            NSApp.sendEvent(event)
        }
    }

    /// Each event's row in Settings › Alerts: its sound menu, and its Notify box (the last button before
    /// the next menu, after the Play button).
    static func rows(in root: NSView) -> [(menu: NSPopUpButton, box: NSButton)] {
        var controls: [NSControl] = []
        func walk(_ view: NSView) {
            if !view.isHiddenOrHasHiddenAncestor, let control = view as? NSControl { controls.append(control) }
            view.subviews.forEach(walk)
        }
        walk(root)
        var rows: [(NSPopUpButton, NSButton)] = []
        var menu: NSPopUpButton?
        var buttons: [NSButton] = []
        func close() {
            if let menu, buttons.count == 2 { rows.append((menu, buttons[1])) }
            menu = nil
            buttons = []
        }
        for control in controls {
            if let popup = control as? NSPopUpButton, !popup.pullsDown {
                close()
                menu = popup
            } else if let button = control as? NSButton, menu != nil {
                buttons.append(button)
            } else if menu != nil {
                close()
            }
        }
        close()
        return rows
    }

    static func title(of choice: AlertSoundChoice) -> String {
        switch choice {
        case .none: String(localized: "None", comment: "Settings › Alerts: no sound")
        case .whiskr(let sound): sound.name
        case .macAlert: String(localized: "Alert Sound", comment: "Settings › Alerts: the alert sound chosen in System Settings › Sound")
        case .system(let name): name
        case .custom(let file): CustomSounds.displayName(file)
        }
    }

    /// What macOS says of Whiskr's notifications on this Mac (read only; never asks): said, not checked.
    private func permissionNote() async {
        await NotificationAccess.shared.refresh()
        print("alerts: macOS notifications for \(Bundle.main.bundleIdentifier ?? "?") on this Mac: \(NotificationAccess.shared.status)")
    }
}

/// The alerts check's stand-in for Claude Code: never the real one. `claude` (a script) writes its
/// arguments to `$ALERTS_RECORDS/argv`, then, for each step the check writes (`go-<n>`: an event's name,
/// `|`, the rest of its JSON), runs every command hook the settings it was given hold for that event, as
/// Claude Code runs one (through a shell, the JSON on standard input), and says it is done (`done-<n>`).
/// "exit" ends it.
enum AlertsFakeClaude {
    static func install(in folder: URL) -> URL {
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = #"""
        #!/bin/sh
        # The alerts check's stand-in for Claude Code (DebugFlowAlerts.swift): never the real one.
        printf '%s\n' "$@" > "$ALERTS_RECORDS/argv"
        settings=
        previous=
        for argument in "$@"; do
          [ "$previous" = "--settings" ] && settings=$argument
          case $argument in --settings=*) settings=${argument#--settings=} ;; esac
          previous=$argument
        done
        [ -r "$settings" ] || exit 3
        step=0
        while :; do
          step=$((step + 1))
          waited=0
          while [ ! -e "$ALERTS_RECORDS/go-$step" ]; do
            /bin/sleep 0.05
            waited=$((waited + 1))
            [ "$waited" -gt 6000 ] && exit 4
          done
          line=$(/bin/cat "$ALERTS_RECORDS/go-$step")
          event=${line%%|*}
          rest=${line#*|}
          [ "$event" = "exit" ] && exit 0
          json=$(printf '{"hook_event_name":"%s","session_id":"alerts-1","cwd":"%s"%s}' "$event" "$PWD" "$rest")
          /usr/bin/jq -r --arg e "$event" '.hooks[$e][]?.hooks[]? | select(.type == "command") | .command' "$settings" | while IFS= read -r command; do
            printf '%s' "$json" | /bin/sh -c "$command" > /dev/null
          done
          : > "$ALERTS_RECORDS/done-$step"
        done
        """#
        let file = bin.appendingPathComponent("claude")
        try? Data(script.utf8).write(to: file)
        chmod(file.path, 0o755)
        return bin
    }
}

extension DebugScript {
    /// `--script` commands of the alerts flow; true when `command` was one of them.
    ///
    ///   alerts-permission       prints what macOS says of Whiskr's notifications (read only, never asks)
    ///   alerts-status <s>       Settings › Alerts as if macOS said allowed, off or notAsked (to look at each)
    static func alertsCommand(_ command: String, _ argument: String, _ workbench: Workbench, _ controller: MainWindowController) -> Bool {
        switch command {
        case "alerts-permission":
            Task {
                await NotificationAccess.shared.refresh()
                print("  notifications: \(NotificationAccess.shared.status)")
            }
        case "alerts-status":
            let status: NotificationAccess.Status = switch argument {
            case "allowed": .allowed
            case "off": .off
            default: .notAsked
            }
            NotificationAccess.shared.debugSet(status)
        default:
            return false
        }
        return true
    }
}
#endif
