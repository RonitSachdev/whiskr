import AppKit
import Carbon

/// Whiskr › Secure Keyboard Entry, as Terminal has it: while on, no other app can read the keys typed
/// (a password at a `sudo` prompt). The system asks that it be held only while the app is in front, so it
/// is let go when the app is left and taken again on coming back. The choice is remembered.
@MainActor
final class SecureKeyboard {
    static let shared = SecureKeyboard()
    private static let key = "secureKeyboardEntry"
    private var held = false

    var isOn: Bool {
        get { AppPlaces.defaults.bool(forKey: Self.key) }
        set {
            AppPlaces.defaults.set(newValue, forKey: Self.key)
            update()
        }
    }

    private init() {
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SecureKeyboard.shared.update() }
            }
        }
    }

    /// Held exactly while it is on and the app is active; each enable is matched by one disable.
    func update() {
        let wanted = isOn && NSApp.isActive
        guard wanted != held else { return }
        held = wanted
        if wanted { EnableSecureEventInput() } else { DisableSecureEventInput() }
    }
}
