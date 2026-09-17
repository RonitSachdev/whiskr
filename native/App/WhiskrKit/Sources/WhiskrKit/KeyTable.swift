import Foundation

/// A key with its modifiers, as a menu shows it: "⇧⌘K", "⌥↑", "⌃⇥". Shifted symbols are read as the key
/// and ⇧ ("⌘?" is "⇧⌘/", "⌘+" is "⇧⌘="), and a capital letter as ⇧ and the letter, so two ways of writing
/// the same key press compare equal (US layout).
public struct KeyChord: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    public var modifiers: Modifiers
    /// Lower-case letter, unshifted symbol, or a name: ↑ ↓ ← → ↩ ⇥ ⎋ ⌫ ⌦ Space F1…F12.
    public var key: String

    static let shifted: [Character: Character] = [
        "?": "/", "+": "=", "|": "\\", "_": "-", "{": "[", "}": "]", ":": ";", "\"": "'", "<": ",", ">": ".", "~": "`",
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    ]

    public init(_ key: String, _ modifiers: Modifiers) {
        var modifiers = modifiers
        var key = key
        if key.count == 1, let character = key.first {
            if let base = Self.shifted[character] {
                key = String(base)
                modifiers.insert(.shift)
            } else if character.isUppercase {
                key = key.lowercased()
                modifiers.insert(.shift)
            }
        }
        self.key = key
        self.modifiers = modifiers
    }

    /// Reads "⌃⌥⇧⌘" in any order, then the key as a menu shows it (a letter in capitals, without ⇧).
    public init(_ text: String) {
        var modifiers: Modifiers = []
        var rest = Substring(text)
        while let first = rest.first, let modifier: Modifiers = switch first {
            case "⌃": .control
            case "⌥": .option
            case "⇧": .shift
            case "⌘": .command
            default: nil
        } {
            modifiers.insert(modifier)
            rest = rest.dropFirst()
        }
        self.init(rest.count == 1 ? rest.lowercased() : String(rest), modifiers)
    }

    /// A menu item's key equivalent (AppKit's function-key characters for the arrows and others).
    public init(menuKey: String, _ modifiers: Modifiers) {
        let names: [UInt32: String] = [0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→", 0x0D: "↩", 0x03: "↩", 0x09: "⇥", 0x1B: "⎋",
                                       0x7F: "⌫", 0x08: "⌫", 0xF728: "⌦", 0x20: "Space"]
        let scalar = menuKey.unicodeScalars.first?.value ?? 0
        if menuKey.unicodeScalars.count == 1, let name = names[scalar] {
            self.init(name, modifiers)
        } else if (0xF704...0xF70F).contains(scalar) {
            self.init("F\(scalar - 0xF704 + 1)", modifiers)
        } else {
            self.init(menuKey, modifiers)
        }
    }

    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (key.count == 1 ? key.uppercased() : key)
    }
}

/// Where a key counts.
public enum KeyContext: String, Sendable, CaseIterable {
    /// A menu's key: wherever the keyboard is (a menu takes its key before any view, enabled or not).
    case menu
    /// A menu's key that counts only while the editor has the keyboard; elsewhere it goes on to the view.
    case menuInEditor
    /// A menu's key that counts only while a terminal has the keyboard.
    case menuInTerminal
    /// The editor's own keys (`CodeTextView`), under the menus.
    case editor
    /// AppKit's text editing, in the editor and every text field (Cocoa's standard key bindings).
    case textEditing
    /// Files' outline (`FileOutline`).
    case files
    /// The meadow and the workspace list, with the keyboard in them.
    case meadow
    /// The meadow while it is edited, with the keyboard in it. Its ⌘ keys are taken before the menus (a
    /// view's key equivalent comes first), each written down with what it takes the place of.
    case meadowEditor
    /// The meadow editor's tray, with the keyboard on its shelf of things.
    case editorTray
    /// The find bar over a terminal.
    case terminalFind
    /// ⌃Tab's list while ⌃ is held (`TabSwitcher`).
    case tabSwitcher
    /// A focused answer card or the commit box: ⌘↩ sends.
    case focusedForm
    /// macOS itself: never reaches the app.
    case system
}

/// One key and what it does.
public struct KeyBinding: Hashable, Sendable {
    public var chord: KeyChord
    /// A menu item's action selector with its tag ("selectTabByNumber:#3"), or a name for a view's key.
    public var command: String
    public var context: KeyContext
    /// For an editor key in place of a text-editing one: why it is worth the Mac's own.
    public var replaces: String?

    public init(_ chord: String, _ command: String, _ context: KeyContext, replaces: String? = nil) {
        self.chord = KeyChord(chord)
        self.command = command
        self.context = context
        self.replaces = replaces
    }
}

/// Every key Whiskr has, with the rules that keep them apart (docs/DESIGN.md, "Where the keys go"): a menu
/// key needs ⌘ (keys without it are the terminal program's: ⌃ letters, ⌥ as Meta, Esc, Tab), except ⌃Tab
/// and ⌃⇧Tab, as in Terminal; a key for the editor alone is scoped to it, so the terminal still receives
/// it; no key does two things where the keyboard is. The menus in `MainMenu` must match this table
/// (Debug builds: `--script` `keytable` lists any difference).
public enum KeyTable {
    /// Menu keys a terminal does not get, though they lack ⌘: ⌃Tab steps through tabs, as in Terminal.
    public static let terminalExceptions: Set<KeyChord> = [KeyChord("⌃⇥"), KeyChord("⌃⇧⇥")]

    public static let bindings: [KeyBinding] = menu + editor + textEditing + views + system

    /// The menus' keys, as `MainMenu` builds them.
    public static let menu: [KeyBinding] = [
        // Whiskr
        KeyBinding("⌘,", "showSettings:", .menu),
        KeyBinding("⌘H", "hide:", .menu),
        KeyBinding("⌥⌘H", "hideOtherApplications:", .menu),
        KeyBinding("⌘Q", "terminate:", .menu),
        KeyBinding("⌥⌘Q", "quitAndStopAllTerminals:", .menu),
        // File
        KeyBinding("⌘N", "newWorkspace:", .menu),
        KeyBinding("⌘T", "newTab:", .menu),
        KeyBinding("⌥⌘N", "newFile:", .menu),
        KeyBinding("⌘O", "openFolder:", .menu),
        KeyBinding("⇧⌘N", "newWorktree:", .menu),
        KeyBinding("⌘D", "splitRight:", .menu),
        KeyBinding("⌘\\", "splitRight:", .menu),
        KeyBinding("⇧⌘D", "splitDown:", .menu),
        KeyBinding("⌘W", "closePane:", .menu),
        KeyBinding("⌥⌘W", "closeTab:", .menu),
        KeyBinding("⇧⌘W", "performClose:", .menu),
        KeyBinding("⇧⌘T", "reopenClosedTab:", .menu),
        KeyBinding("⌘S", "saveDocument:", .menu),
        KeyBinding("⇧⌘S", "saveDocumentAs:", .menu),
        KeyBinding("⌥⌘S", "saveAllDocuments:", .menu),
        // Edit
        KeyBinding("⌘Z", "undo:", .menu),
        KeyBinding("⇧⌘Z", "redo:", .menu),
        KeyBinding("⌘X", "cut:", .menu),
        KeyBinding("⌘C", "copy:", .menu),
        KeyBinding("⌘V", "paste:", .menu),
        KeyBinding("⌘A", "selectAll:", .menu),
        KeyBinding("⌘F", "performTextFinderAction:#1", .menu),
        KeyBinding("⌘G", "performTextFinderAction:#2", .menu),
        KeyBinding("⇧⌘G", "performTextFinderAction:#3", .menu),
        KeyBinding("⌘E", "performTextFinderAction:#7", .menu),
        KeyBinding("⌥⌘F", "performTextFinderAction:#12", .menu),
        KeyBinding("⌘K", "clearScrollback:", .menu),
        KeyBinding("⌘↑", "jumpToPreviousCommand:", .menuInTerminal),
        KeyBinding("⌘↓", "jumpToNextCommand:", .menuInTerminal),
        KeyBinding("⇧⌘↑", "selectPreviousCommandOutput:", .menuInTerminal),
        KeyBinding("⇧⌘↓", "selectNextCommandOutput:", .menuInTerminal),
        // View
        KeyBinding("⌃⌘1", "showMeadowAndTerminals:", .menu),
        KeyBinding("⌃⌘2", "showTerminalsOnly:", .menu),
        KeyBinding("⌃⌘3", "showMeadowOnly:", .menu),
        KeyBinding("⌃⌘S", "toggleNavigator:", .menu),
        KeyBinding("⌘B", "toggleNavigator:", .menu),
        KeyBinding("⌥⌘/", "toggleStatusBar:", .menu),
        KeyBinding("⇧⌘E", "showFilesPanel:", .menu),
        KeyBinding("⇧⌘C", "showChangesPanel:", .menu),
        KeyBinding("⌥⌘P", "togglePreview:", .menu),
        KeyBinding("⇧⌘V", "togglePreview:", .menu),
        KeyBinding("⇧⌘↩", "toggleZoom:", .menu),
        KeyBinding("⌘=", "biggerText:", .menu),
        KeyBinding("⌘+", "biggerText:", .menu),
        KeyBinding("⌘;", "biggerText:", .menu),
        KeyBinding("⌘-", "smallerText:", .menu),
        KeyBinding("⌘0", "actualSizeText:", .menu),
        KeyBinding("⌃⌘F", "toggleFullScreen:", .menu),
        KeyBinding("⌃⌘E", "toggleMeadowEditing:", .menu),
        KeyBinding("⌥⌘T", "toggleEditorTray:", .menu),
        // AppKit adds Close All under Close Window, with ⌥.
        KeyBinding("⌥⇧⌘W", "closeAll:", .menu),
        // Editor
        KeyBinding("⌘L", "goToLine:", .menu),
        KeyBinding("⌃G", "goToLine:", .menuInEditor),
        KeyBinding("⌘/", "toggleComment:", .menu),
        KeyBinding("⌥⌘]", "shiftRight:", .menu),
        KeyBinding("⌥⌘[", "shiftLeft:", .menu),
        KeyBinding("⌥↑", "moveLineUp:", .menuInEditor),
        KeyBinding("⌥↓", "moveLineDown:", .menuInEditor),
        KeyBinding("⇧⌥↑", "copyLineUp:", .menuInEditor),
        KeyBinding("⇧⌥↓", "copyLineDown:", .menuInEditor),
        KeyBinding("⇧⌘K", "deleteLine:", .menu),
        KeyBinding("⇧⌘\\", "goToMatchingBracket:", .menu),
        KeyBinding("⌃⌘↓", "nextChange:", .menu),
        KeyBinding("⌃⌘↑", "previousChange:", .menu),
        KeyBinding("⇧⌘J", "revealInFiles:", .menu),
        // Go
        KeyBinding("⇧⌘H", "goHome:", .menu),
        KeyBinding("⌘J", "goToNextThing:", .menu),
        KeyBinding("⌘P", "goTo:", .menu),
        KeyBinding("⇧⌘P", "showCommandPalette:", .menu),
        KeyBinding("⇧⌘]", "nextTab:", .menu),
        KeyBinding("⇧⌘[", "previousTab:", .menu),
        KeyBinding("⌃⇥", "switchToRecentTab:", .menu),
        KeyBinding("⌃⇧⇥", "switchToRecentTabBackward:", .menu),
    ] + (1...9).map { KeyBinding("⌘\($0)", "selectTabByNumber:#\($0)", .menu) } + [
        KeyBinding("⌃⌘]", "nextWorkspace:", .menu),
        KeyBinding("⌃⌘[", "previousWorkspace:", .menu),
    ] + (1...9).map { KeyBinding("⌥⌘\($0)", "selectWorkspaceByNumber:#\($0)", .menu) } + [
        KeyBinding("⌘]", "nextPane:", .menu),
        KeyBinding("⌘[", "previousPane:", .menu),
        KeyBinding("⌥⌘←", "focusLeft:", .menu),
        KeyBinding("⌥⌘→", "focusRight:", .menu),
        KeyBinding("⌥⌘↑", "focusUp:", .menu),
        KeyBinding("⌥⌘↓", "focusDown:", .menu),
        KeyBinding("⌥⇧⌘←", "swapLeft:", .menu),
        KeyBinding("⌥⇧⌘→", "swapRight:", .menu),
        KeyBinding("⌥⇧⌘↑", "swapUp:", .menu),
        KeyBinding("⌥⇧⌘↓", "swapDown:", .menu),
        KeyBinding("⌥⌘0", "moveFocusToMeadow:", .menu),
        KeyBinding("⌘.", "interrupt:", .menu),
        // Window, Help
        KeyBinding("⌘M", "performMiniaturize:", .menu),
        KeyBinding("⌘?", "showHelp:", .menu),
    ]

    /// The editor's own keys, beyond AppKit's text editing.
    public static let editor: [KeyBinding] = [
        KeyBinding("↩", "newline keeping the indentation", .editor),
        KeyBinding("⇥", "indent, or shift the selected lines right", .editor),
        KeyBinding("⇧⇥", "shift the selected lines left", .editor),
        KeyBinding("⌫", "delete backward: a level of indentation, or an empty pair the editor closed", .editor),
    ]

    /// Cocoa's standard key bindings that matter in code. The editor replaces the four marked: VS Code's
    /// and Cursor's line moves are worth more in code than paragraph moves (⌘↑ ⌘↓ still go to the start and
    /// end, ⌃A ⌃E to the line's).
    public static let textEditing: [KeyBinding] = [
        KeyBinding("⌥↑", "moveBackward: + moveToBeginningOfParagraph:", .textEditing, replaces: "Move Line Up"),
        KeyBinding("⌥↓", "moveForward: + moveToEndOfParagraph:", .textEditing, replaces: "Move Line Down"),
        KeyBinding("⇧⌥↑", "moveParagraphBackwardAndModifySelection:", .textEditing, replaces: "Copy Line Up"),
        KeyBinding("⇧⌥↓", "moveParagraphForwardAndModifySelection:", .textEditing, replaces: "Copy Line Down"),
        KeyBinding("⌘↑", "moveToBeginningOfDocument:", .textEditing),
        KeyBinding("⌘↓", "moveToEndOfDocument:", .textEditing),
        KeyBinding("⇧⌘↑", "moveToBeginningOfDocumentAndModifySelection:", .textEditing),
        KeyBinding("⇧⌘↓", "moveToEndOfDocumentAndModifySelection:", .textEditing),
        KeyBinding("⌘←", "moveToLeftEndOfLine:", .textEditing),
        KeyBinding("⌘→", "moveToRightEndOfLine:", .textEditing),
        KeyBinding("⇧⌘←", "moveToLeftEndOfLineAndModifySelection:", .textEditing),
        KeyBinding("⇧⌘→", "moveToRightEndOfLineAndModifySelection:", .textEditing),
        KeyBinding("⌥←", "moveWordLeft:", .textEditing),
        KeyBinding("⌥→", "moveWordRight:", .textEditing),
        KeyBinding("⇧⌥←", "moveWordLeftAndModifySelection:", .textEditing),
        KeyBinding("⇧⌥→", "moveWordRightAndModifySelection:", .textEditing),
        KeyBinding("⌘⌫", "deleteToBeginningOfLine:", .textEditing),
        KeyBinding("⌥⌫", "deleteWordBackward:", .textEditing),
        KeyBinding("⌥⌦", "deleteWordForward:", .textEditing),
        KeyBinding("⌃A", "moveToBeginningOfParagraph:", .textEditing),
        KeyBinding("⌃E", "moveToEndOfParagraph:", .textEditing),
        KeyBinding("⌃K", "deleteToEndOfParagraph:", .textEditing),
        KeyBinding("⌃Y", "yank:", .textEditing),
        KeyBinding("⌃T", "transpose:", .textEditing),
        KeyBinding("⌃F", "moveForward:", .textEditing),
        KeyBinding("⌃B", "moveBackward:", .textEditing),
        KeyBinding("⌃N", "moveDown:", .textEditing),
        KeyBinding("⌃P", "moveUp:", .textEditing),
        KeyBinding("⌃D", "deleteForward:", .textEditing),
        KeyBinding("⌃H", "deleteBackward:", .textEditing),
        KeyBinding("⌃O", "insertNewlineIgnoringFieldEditor: + moveBackward:", .textEditing),
        KeyBinding("⌃V", "pageDown:", .textEditing),
        KeyBinding("⌃L", "centerSelectionInVisibleArea:", .textEditing),
        KeyBinding("⌥⎋", "complete:", .textEditing),
    ]

    /// Keys views take while they have the keyboard.
    public static let views: [KeyBinding] = [
        KeyBinding("↩", "rename", .files),
        KeyBinding("⌘↓", "open", .files),
        KeyBinding("⌘⌫", "move to Trash", .files),
        KeyBinding("Space", "Quick Look", .files),
        KeyBinding("↑", "previous workspace", .meadow),
        KeyBinding("↓", "next workspace", .meadow),
        KeyBinding("←", "previous cat", .meadow),
        KeyBinding("→", "next cat", .meadow),
        KeyBinding("↩", "open", .meadow),
        KeyBinding("Space", "show the label", .meadow),
        KeyBinding("⎋", "back to the terminal", .meadow),
        KeyBinding("⇥", "back to the terminal", .meadow),
        KeyBinding("⌘G", "performTextFinderAction:#2", .terminalFind),
        KeyBinding("⇧⌘G", "performTextFinderAction:#3", .terminalFind),
        KeyBinding("↩", "next match", .terminalFind),
        KeyBinding("⇧↩", "previous match", .terminalFind),
        KeyBinding("⎋", "close the find bar", .terminalFind),
        KeyBinding("⇥", "next tab in the list", .tabSwitcher),
        KeyBinding("⇧⇥", "previous tab in the list", .tabSwitcher),
        KeyBinding("↑", "previous tab in the list", .tabSwitcher),
        KeyBinding("↓", "next tab in the list", .tabSwitcher),
        KeyBinding("⎋", "cancel", .tabSwitcher),
        KeyBinding("↩", "open the chosen tab", .tabSwitcher),
        KeyBinding("⌘↩", "send", .focusedForm),
        // Editing the meadow (docs/DESIGN.md, "Edit Meadow"); ⌘A, ⌘C, ⌘V, ⌘Z and ⇧⌘Z are the Edit menu's.
        KeyBinding("V", "the Select tool", .meadowEditor),
        KeyBinding("B", "the Brush", .meadowEditor),
        KeyBinding("E", "the Eraser", .meadowEditor),
        KeyBinding("G", "the Ground tool", .meadowEditor),
    ] + (1...7).map { KeyBinding("\($0)", "the tray's category \($0)", .meadowEditor) } + [
        KeyBinding("C", "the chosen things' colours, in the selection's bar", .meadowEditor),
        KeyBinding("R", "turn the chosen things, or the thing to place, 15° clockwise", .meadowEditor),
        KeyBinding("⇧R", "turn the chosen things, or the thing to place, 15° anticlockwise", .meadowEditor),
        KeyBinding("⌥R", "turn the chosen things, or the thing to place, 1° clockwise", .meadowEditor),
        KeyBinding("⌥⇧R", "turn the chosen things, or the thing to place, 1° anticlockwise", .meadowEditor),
        KeyBinding("]", "grow the chosen things, the next thing round the cursor, or a larger Brush, Eraser or Ground brush", .meadowEditor),
        KeyBinding("[", "shrink the chosen things, the thing before round the cursor, or a smaller Brush, Eraser or Ground brush", .meadowEditor),
        KeyBinding("←", "nudge the chosen things, or move the cursor (and the thing to place)", .meadowEditor),
        KeyBinding("→", "nudge the chosen things, or move the cursor (and the thing to place)", .meadowEditor),
        KeyBinding("↑", "nudge the chosen things, or move the cursor (and the thing to place)", .meadowEditor),
        KeyBinding("↓", "nudge the chosen things, or move the cursor (and the thing to place)", .meadowEditor),
        KeyBinding("⇧←", "nudge further", .meadowEditor),
        KeyBinding("⇧→", "nudge further", .meadowEditor),
        KeyBinding("⇧↑", "nudge further", .meadowEditor),
        KeyBinding("⇧↓", "nudge further", .meadowEditor),
        KeyBinding("↩", "place the thing at the cursor, a dab of the Brush, the Eraser or the Ground tool there, or choose the thing nearest it", .meadowEditor),
        KeyBinding("⌫", "delete the chosen things", .meadowEditor),
        KeyBinding("⌦", "delete the chosen things", .meadowEditor),
        KeyBinding("⎋", "step back: the gesture, the thing to place, the Brush, Eraser or Ground tool, the choice, then editing", .meadowEditor),
        KeyBinding(",", "turn the view 45° left", .meadowEditor),
        KeyBinding(".", "turn the view 45° right", .meadowEditor),
        KeyBinding("0", "frame the picnic ground again", .meadowEditor),
        KeyBinding("Space", "held: a drag slides the view", .meadowEditor),
        KeyBinding("⇥", "to the selection's bar, or the tray's shelf", .meadowEditor),
        KeyBinding("⇧⇥", "to the tray's shelf", .meadowEditor),
        KeyBinding("⌘D", "duplicate the chosen things", .meadowEditor, replaces: "Split Right: no terminal is in view while editing"),
        KeyBinding("⌘F", "the tray's filter field", .meadowEditor, replaces: "Find: no terminal or file is in view while editing"),
        // The tray's shelf with the keyboard; the editor's other keys work there too.
        KeyBinding("←", "the thing before", .editorTray),
        KeyBinding("→", "the next thing", .editorTray),
        KeyBinding("↩", "choose it (a thing to place waits at the cursor)", .editorTray),
        KeyBinding("⇥", "back to the meadow", .editorTray),
        KeyBinding("⇧⇥", "back to the meadow", .editorTray),
        KeyBinding("⎋", "back to the meadow", .editorTray),
        KeyBinding("⌘↩", "done editing", .meadowEditor),
    ]

    /// macOS's own, never to be given anything else.
    public static let system: [KeyBinding] = [
        KeyBinding("⌘⇥", "switch apps", .system),
        KeyBinding("⌘`", "next window of the app", .system),
        KeyBinding("⌘Space", "Spotlight", .system),
        KeyBinding("⌃Space", "input source", .system),
        KeyBinding("⌃⌘Space", "Emoji & Symbols", .system),
        KeyBinding("⇧⌘3", "screenshot", .system),
        KeyBinding("⇧⌘4", "screenshot of a part", .system),
        KeyBinding("⇧⌘5", "screenshot and recording", .system),
        KeyBinding("⌃⌘Q", "lock screen", .system),
        KeyBinding("⌥⌘D", "show or hide the Dock", .system),
        KeyBinding("⌥⌘⎋", "Force Quit", .system),
        KeyBinding("⌃↑", "Mission Control", .system),
        KeyBinding("⌃↓", "application windows", .system),
        KeyBinding("⌃←", "space to the left", .system),
        KeyBinding("⌃→", "space to the right", .system),
    ]

    /// Two bindings whose key would do two things somewhere.
    public struct Collision: Hashable, Sendable, CustomStringConvertible {
        public var first: KeyBinding
        public var second: KeyBinding
        public var description: String {
            "\(first.chord): \(first.command) (\(first.context.rawValue)) and \(second.command) (\(second.context.rawValue))"
        }
    }

    /// Whether a terminal program receives this key when the menus leave it alone: everything without ⌘.
    public static func isTerminals(_ chord: KeyChord) -> Bool {
        !chord.modifiers.contains(.command)
    }

    /// Every pair of bindings that fight over a key, and every menu key taken from a terminal.
    public static func collisions(in bindings: [KeyBinding] = bindings) -> [Collision] {
        var found: [Collision] = []
        let byChord = Dictionary(grouping: bindings, by: \.chord)
        for (_, group) in byChord where group.count > 1 {
            for (index, first) in group.enumerated() {
                for second in group[(index + 1)...] where fight(first, second) {
                    found.append(Collision(first: first, second: second))
                }
            }
        }
        // A menu key without ⌘ is taken from the program in every terminal.
        for binding in bindings where binding.context == .menu || binding.context == .menuInTerminal {
            if isTerminals(binding.chord), !terminalExceptions.contains(binding.chord) {
                found.append(Collision(first: binding, second: KeyBinding(binding.chord.description, "the terminal's program", .menuInTerminal)))
            }
        }
        // ⌥ (or ⇧⌥) with a letter or digit types a character: "Ω" on a US keyboard, "ż" on a Polish one.
        // A menu matches its key before the text view sees it, so such a key would take that character
        // away from typing, in the editor too.
        for binding in bindings where binding.context == .menu || binding.context == .menuInEditor || binding.context == .menuInTerminal {
            if typesCharacter(binding.chord) {
                found.append(Collision(first: binding, second: KeyBinding(binding.chord.description, "a typed character", .textEditing)))
            }
        }
        return found.sorted { $0.description < $1.description }
    }

    /// ⌥ or ⇧⌥ with a letter or a digit: a character on many keyboard layouts.
    static func typesCharacter(_ chord: KeyChord) -> Bool {
        chord.modifiers.contains(.option) && chord.modifiers.isSubset(of: [.option, .shift])
            && chord.key.count == 1 && chord.key.first.map { $0.isLetter || $0.isNumber } == true
    }

    /// Whether two bindings of the same key fight: both count in one place and do different things.
    static func fight(_ a: KeyBinding, _ b: KeyBinding) -> Bool {
        if a.command == b.command { return false }
        if a.context == .system || b.context == .system { return true }
        if a.context == b.context { return true }
        // A key the meadow's editor takes before the menus is a decision, written down with the binding.
        if a.context == .meadowEditor || b.context == .meadowEditor {
            let editor = a.context == .meadowEditor ? a : b, other = a.context == .meadowEditor ? b : a
            return other.context == .menu && editor.replaces == nil
        }
        // A menu's key counts everywhere (a view that takes the same key first does the same command).
        if a.context == .menu || b.context == .menu { return true }
        let pair = Set([a.context, b.context])
        // A scoped menu key counts only where its view has the keyboard.
        if pair.contains(.menuInEditor) {
            let other = a.context == .menuInEditor ? b : a
            switch other.context {
            case .editor: return true
            // Replacing AppKit's own binding in the editor is a decision, written down with the binding.
            case .textEditing: return other.replaces == nil
            default: return false
            }
        }
        if pair.contains(.menuInTerminal) {
            // The editor and text fields keep the key; nothing else shares the terminal's keyboard.
            return false
        }
        // Views never have the keyboard at once.
        return false
    }
}
