import AppKit
import WhiskrKit

/// A menu item whose key belongs to one kind of view (`KeyContext.menuInEditor`, `.menuInTerminal`): the key
/// counts only while that view has the keyboard, and elsewhere goes on to whatever has it. A menu takes
/// its keys before any view, and a disabled item's key too (AppKit's `performKeyEquivalent` answers yes
/// for it), so without this ⌥↑ in a terminal, or ⌘↑ in the editor, would reach nothing. The item itself
/// works from the menu bar and the palette as any other. (AppKit's menus are not tied to the main actor;
/// they are only used on the main thread.)
nonisolated final class ScopedKeyItem: NSMenuItem {
    enum Scope: Sendable {
        case editor, terminal

        /// The scope whose view has the keyboard in `window`, if either does.
        @MainActor
        static func holding(_ window: NSWindow?) -> Scope? {
            switch window?.firstResponder {
            case is CodeTextView: .editor
            case is TerminalSurface: .terminal
            default: nil
            }
        }
    }

    let scope: Scope

    init(_ title: String, _ action: Selector, key: String, _ modifiers: NSEvent.ModifierFlags, scope: Scope) {
        self.scope = scope
        super.init(title: title, action: action, keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
    }

    required init(coder: NSCoder) {
        fatalError("ScopedKeyItem is created in code")
    }

    /// Whether `event` is this item's key: the same key, the same modifiers.
    func isKey(of event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return flags == keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            && event.charactersIgnoringModifiers?.lowercased() == keyEquivalent.lowercased()
    }
}

/// A menu holding `ScopedKeyItem`s: a key of one of them is passed on while its view does not have the
/// keyboard of the key window.
nonisolated final class ScopedKeysMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let keyboard = MainActor.assumeIsolated { ScopedKeyItem.Scope.holding(NSApp.keyWindow) }
        return passesOn(event, keyboard: keyboard) ? false : super.performKeyEquivalent(with: event)
    }

    /// Whether `event` is the key of a scoped item whose view does not have the keyboard (`keyboard` is the
    /// scope that does), so it should go on to the view.
    func passesOn(_ event: NSEvent, keyboard: ScopedKeyItem.Scope?) -> Bool {
        items.contains { item in
            guard let scoped = item as? ScopedKeyItem, scoped.isKey(of: event) else { return false }
            return scoped.scope != keyboard
        }
    }
}
