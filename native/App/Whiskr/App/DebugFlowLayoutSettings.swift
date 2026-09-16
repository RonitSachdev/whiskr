#if DEBUG
import AppKit
import WhiskrKit

/// Settings, for `--perf-flows layout`: every pane opened (unseen, as every window of a background run),
/// and every switch, choice, menu, stepper and slider in it changed as a click would change it (its value
/// set, its action sent), the change kept in the run's own settings, then put back. Left alone on purpose:
/// Settings › Meadow's Real weather (it asks the system for your location) and the buttons, which SwiftUI
/// draws itself (Play makes a sound; Choose…, Add Theme…, Show Themes Folder and Open Language & Region…
/// open other windows or apps); Pause Alerts' buttons and Picnic things' radio buttons are checked through
/// the settings they change.
extension PerfSuite {
    func settingsCheck() async {
        let settings = SettingsWindowController.shared
        settings.show()
        guard let window = settings.window, let tabs = window.contentViewController as? SettingsTabs else { return check("settings: the window opened", false) }
        // Controls, by their place in a pane, that must not be worked here: Settings › Meadow's fourth control
        // (after Time of day, Real sunrise and sunset, and Moon phase) is Real weather. The switches under it
        // are disabled while it is off, so not worked here either (`--perf-flows sky` checks them).
        let leaveAlone: [String: Set<Int>] = ["meadow": [3]]
        for pane in ["general", "terminal", "editor", "alerts", "meadow"] {
            tabs.select(pane: pane)
            let found = await PerfWait.until(3000) { (window.contentView.map(Self.controls(in:)) ?? []).count > 1 }
            await PerfWait.sleep(300)
            guard found != nil, let root = window.contentView else { check("settings \(pane): its controls", false); continue }
            var worked: [String] = [], failed: [String] = [], skipped: [String] = []
            let count = Self.controls(in: root).count
            for index in 0..<count where !(leaveAlone[pane]?.contains(index) ?? false) {
                // SwiftUI may make a control afresh when its setting changes: each step finds it again by its place.
                let control = { Self.controls(in: root).indices.contains(index) ? Self.controls(in: root)[index] : nil }
                guard let first = control(), let original = Self.value(of: first), let other = Self.other(than: original, in: first) else {
                    if let first = control() { skipped.append("\(index) \(type(of: first))") }
                    continue
                }
                let name = "\(index) \(type(of: first))"
                // A setting never changed yet has no value of its own in the run's settings, only its default:
                // one change and back first gives it one, so "as it was" can be compared.
                if let now = control() { Self.set(now, to: other) }
                await PerfWait.sleep(400)
                if let now = control() { Self.undo(now, from: other, to: original) }
                await PerfWait.sleep(400)
                let before = Self.settingsNow()
                if let now = control() { Self.set(now, to: other) }
                let changed = await PerfWait.until(1500) { Self.settingsNow() != before }
                // What it changed, and only that, is as it was once changed back.
                let keys = Set(Self.settingsNow().filter { before[$0.key] != $0.value }.map(\.key))
                await PerfWait.sleep(400)
                if let now = control() { Self.undo(now, from: other, to: original) }
                let restored = await PerfWait.until(3000) { let now = Self.settingsNow(); return keys.allSatisfy { now[$0] == before[$0] } }
                if changed != nil && restored != nil { worked.append(name) } else { failed.append("\(name) (changed \(keys.sorted()), restored \(restored != nil))") }
            }
            check("settings \(pane): every switch, choice, menu, stepper and slider changes its setting and goes back", !worked.isEmpty && failed.isEmpty,
                  "worked \(worked); failed \(failed); not worked here \(skipped)")
        }
        // Pause Alerts' buttons, through the setting they change.
        Preferences.shared.alertsPausedUntil = Date().addingTimeInterval(3600)
        let paused = Self.settingsNow()["alertsPausedUntil"] != nil
        Preferences.shared.alertsPausedUntil = nil
        check("settings alerts: Pause Alerts is kept in the run's own settings, and Resume clears it", paused && !Preferences.shared.alertsPaused)
        // The pop-up menus SwiftUI fills only as they open: their settings, through the model.
        let preferences = Preferences.shared, editor = EditorPreferences.shared, theme = ThemeStore.shared
        let menus: [(String, () -> Void)] = [
            ("New tabs and panes open in", { preferences.newTerminalFolder = preferences.newTerminalFolder == .home ? .current : .home }),
            ("Option key acts as Meta", { preferences.optionKey = preferences.optionKey == .both ? .left : .both }),
            ("Terminal › Font", { theme.fontFamily = theme.fontFamily == "Menlo" ? "Monaco" : "Menlo" }),
            ("Editor › Font", { editor.fontFamily = editor.fontFamily == "Menlo" ? "Monaco" : "Menlo" }),
            ("Editor › Indent with", { editor.insertSpaces.toggle() }),
            ("Editor › Tab width", { editor.tabWidth = editor.tabWidth == 2 ? 4 : 2 }),
        ]
        for (name, change) in menus {
            let before = Self.settingsNow()
            change()
            let kept = Self.settingsNow() != before
            change()
            check("settings: \(name) is kept in the run's own settings", kept)
        }
        // Picnic things' radio buttons answer only a real click: their setting, through the model.
        let world = WorldStore.shared, picnic = world.settings.picnic
        let before = Self.settingsNow()
        world.settings.picnic = picnic == .hamper ? .nothing : .hamper
        let kept = Self.settingsNow() != before
        world.settings.picnic = picnic
        check("settings meadow: Picnic things is kept in the run's own settings", kept)
        settings.close()
    }

    /// The run's own settings as text, key by key (the isolated suite with what it falls back on, of which
    /// only the run's own part changes).
    static func settingsNow() -> [String: String] {
        AppPlaces.defaults.dictionaryRepresentation().mapValues { "\($0)" }
    }

    /// Every control a person works in a view (switches, choices, menus, steppers, sliders), in the order
    /// they are laid out.
    static func controls(in root: NSView) -> [NSControl] {
        var found: [NSControl] = []
        func walk(_ view: NSView) {
            if !view.isHiddenOrHasHiddenAncestor, let control = view as? NSControl, control.isEnabled {
                switch control {
                case let popup as NSPopUpButton:
                    // A pull-down runs a command (Import Settings) rather than holding a setting.
                    if !popup.pullsDown { found.append(popup) }
                case is NSSwitch, is NSSegmentedControl, is NSStepper, is NSSlider:
                    found.append(control)
                default:
                    break
                }
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    /// What a control holds: a switch's state, the segment or menu item chosen, a stepper's or slider's value.
    static func value(of control: NSControl) -> Double? {
        switch control {
        case let toggle as NSSwitch: Double(toggle.state.rawValue)
        case let segments as NSSegmentedControl where segments.segmentCount > 1: Double(segments.selectedSegment)
        case let popup as NSPopUpButton where popup.numberOfItems > 1: Double(popup.indexOfSelectedItem)
        case let stepper as NSStepper: stepper.doubleValue
        case let slider as NSSlider: slider.doubleValue
        default: nil
        }
    }

    /// Another value the control can hold.
    static func other(than value: Double, in control: NSControl) -> Double? {
        switch control {
        case is NSSwitch: value == 0 ? 1 : 0
        case let segments as NSSegmentedControl: Double((Int(value) + 1) % segments.segmentCount)
        case let popup as NSPopUpButton:
            (0..<popup.numberOfItems).first { $0 != Int(value) && popup.item(at: $0)?.isEnabled == true && popup.item(at: $0)?.isSeparatorItem == false }.map(Double.init)
        case let stepper as NSStepper: value + stepper.increment <= stepper.maxValue ? value + stepper.increment : value - stepper.increment
        case let slider as NSSlider: value + (slider.maxValue - slider.minValue) / 4 <= slider.maxValue ? value + (slider.maxValue - slider.minValue) / 4 : slider.minValue
        default: nil
        }
    }

    /// Puts a control back. A stepper counts its clicks from wherever SwiftUI left it, so it takes a
    /// click the other way from where it is now; anything else is set to what it held.
    static func undo(_ control: NSControl, from changed: Double, to original: Double) {
        if let stepper = control as? NSStepper {
            set(stepper, to: stepper.doubleValue + (changed > original ? -stepper.increment : stepper.increment))
        } else {
            set(control, to: original)
        }
    }

    /// Sets a control as a click would leave it, and sends its action to its target, as AppKit does at the
    /// end of a click.
    static func set(_ control: NSControl, to value: Double) {
        switch control {
        case let toggle as NSSwitch: toggle.state = NSControl.StateValue(rawValue: Int(value))
        case let segments as NSSegmentedControl: segments.selectedSegment = Int(value)
        case let popup as NSPopUpButton: popup.selectItem(at: Int(value))
        default: control.doubleValue = value
        }
        _ = control.sendAction(control.action, to: control.target)
    }
}
#endif
