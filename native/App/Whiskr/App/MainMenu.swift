import AppKit
import WhiskrKit

/// The menu bar (docs/DESIGN.md): every command, with its key, in the app's own words. Every app
/// shortcut uses ⌘; Esc, bare ⌃-letters, ⇧Tab and ⌥-letters always reach the program in the terminal
/// (⌃Tab and ⌃⇧Tab, for tabs, are the one exception, as in Terminal). The editor's keys without ⌘ (VS Code's
/// ⌥↑ ⌥↓ line moves, ⌃G) count only while it has the keyboard (`ScopedKeyItem`). `KeyTable` holds
/// every key and the test that no two collide; keep it in step with this file.
enum MainMenu {
    /// File › Open Recent, filled when it opens.
    static let openRecent = NSMenu(title: String(localized: "Open Recent"))

    static func build() -> NSMenu {
        let bar = NSMenu()
        bar.addItem(submenu(appMenu()))
        bar.addItem(submenu(fileMenu()))
        bar.addItem(submenu(editMenu()))
        bar.addItem(submenu(viewMenu()))
        bar.addItem(submenu(editorMenu()))
        bar.addItem(submenu(goMenu()))
        let window = windowMenu()
        bar.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: String(localized: "Help"))
        let guide = item(String(localized: "Whiskr Help"), #selector(HelpWindowController.showHelp(_:)), "?")
        guide.target = HelpWindowController.shared
        help.addItem(guide)
        bar.addItem(submenu(help))
        NSApp.helpMenu = help
        return bar
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        return item
    }

    /// A second key for a command already in the menu: not shown, still works.
    private static func hiddenKey(_ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = item("", action, key, modifiers)
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    /// A command whose key counts only while the editor (or a terminal) has the keyboard (`ScopedKeyItem`):
    /// the key is the view's own everywhere else. Its menu must be a `ScopedKeysMenu`.
    private static func scoped(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags,
                               in scope: ScopedKeyItem.Scope, hidden: Bool = false) -> NSMenuItem {
        let item = ScopedKeyItem(title, action, key: key, modifiers, scope: scope)
        item.isHidden = hidden
        item.allowsKeyEquivalentWhenHidden = hidden
        return item
    }

    private static func arrowKey(_ key: Int) -> String { String(Character(UnicodeScalar(key)!)) }
    private static let left = arrowKey(NSLeftArrowFunctionKey), right = arrowKey(NSRightArrowFunctionKey)
    private static let up = arrowKey(NSUpArrowFunctionKey), down = arrowKey(NSDownArrowFunctionKey)

    private static func appMenu() -> NSMenu {
        let name = String(localized: "Whiskr", comment: "The app's name in its menus")
        let menu = NSMenu(title: name)
        menu.addItem(item(String(localized: "About \(name)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ","))
        let pause = item(String(localized: "Pause Alerts"), nil)
        pause.submenu = AlertCenter.pauseMenu()
        menu.addItem(pause)
        // As in Terminal: no other app can read what is typed (passwords) while it is on.
        menu.addItem(item(String(localized: "Secure Keyboard Entry"), #selector(AppDelegate.toggleSecureKeyboardEntry(_:))))
        menu.addItem(.separator())
        let services = item(String(localized: "Services"), nil)
        services.submenu = NSMenu(title: String(localized: "Services"))
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Hide \(name)"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        // Quit leaves every terminal running in the session host; with Option held it stops them too.
        menu.addItem(item(String(localized: "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"))
        let stopping = item(String(localized: "Quit and Stop All Terminals"), #selector(AppDelegate.quitAndStopAllTerminals(_:)), "q", [.command, .option])
        stopping.isAlternate = true
        menu.addItem(stopping)
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(item(String(localized: "New Workspace"), #selector(MainWindowController.newWorkspace(_:)), "n"))
        menu.addItem(item(String(localized: "New Tab"), #selector(MainWindowController.newTab(_:)), "t"))
        menu.addItem(item(String(localized: "New File…"), #selector(MainWindowController.newFile(_:)), "n", [.command, .option]))
        menu.addItem(item(String(localized: "Open Folder…"), #selector(MainWindowController.openFolder(_:)), "o"))
        let recent = item(String(localized: "Open Recent"), nil)
        recent.submenu = openRecent
        menu.addItem(recent)
        menu.addItem(.separator())
        // Git worktrees of the selected workspace's repository, each opened as a workspace of its own.
        menu.addItem(item(String(localized: "New Worktree…"), #selector(MainWindowController.newWorktree(_:)), "n", [.command, .shift]))
        menu.addItem(item(String(localized: "Open Worktree…"), #selector(MainWindowController.openWorktree(_:))))
        menu.addItem(item(String(localized: "Remove Worktree…"), #selector(MainWindowController.removeWorktree(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Split Right"), #selector(MainWindowController.splitRight(_:)), "d"))
        // VS Code's and Cursor's split key.
        menu.addItem(hiddenKey(#selector(MainWindowController.splitRight(_:)), "\\", .command))
        menu.addItem(item(String(localized: "Split Down"), #selector(MainWindowController.splitDown(_:)), "d", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Close", comment: "File menu: closes the focused pane"), #selector(MainWindowController.closePane(_:)), "w"))
        menu.addItem(item(String(localized: "Close Tab"), #selector(MainWindowController.closeTab(_:)), "w", [.command, .option]))
        menu.addItem(item(String(localized: "Close Workspace"), #selector(MainWindowController.closeWorkspace(_:))))
        menu.addItem(item(String(localized: "Close Window"), #selector(NSWindow.performClose(_:)), "w", [.command, .shift]))
        menu.addItem(item(String(localized: "Reopen Closed Tab"), #selector(MainWindowController.reopenClosedTab(_:)), "t", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Save"), #selector(MainWindowController.saveDocument(_:)), "s"))
        menu.addItem(item(String(localized: "Save As…"), #selector(MainWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
        menu.addItem(item(String(localized: "Save All"), #selector(MainWindowController.saveAllDocuments(_:)), "s", [.command, .option]))
        menu.addItem(item(String(localized: "Revert to Saved"), #selector(MainWindowController.revertDocumentToSaved(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Rename Tab…"), #selector(MainWindowController.renameTab(_:))))
        menu.addItem(item(String(localized: "Rename Workspace…"), #selector(MainWindowController.renameWorkspace(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Import Themes and Languages…"), #selector(AppDelegate.importThemes(_:))))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = ScopedKeysMenu(title: String(localized: "Edit"))
        // The window's undo manager names what it undoes ("Undo Close Tab"); text fields undo their typing.
        menu.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z"))
        menu.addItem(item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"))
        menu.addItem(item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        let find = NSMenu(title: String(localized: "Find"))
        let finder = #selector(NSResponder.performTextFinderAction(_:))
        find.addItem(item(String(localized: "Find…"), finder, "f", tag: NSTextFinder.Action.showFindInterface.rawValue))
        find.addItem(item(String(localized: "Find Next"), finder, "g", tag: NSTextFinder.Action.nextMatch.rawValue))
        find.addItem(item(String(localized: "Find Previous"), finder, "g", [.command, .shift], tag: NSTextFinder.Action.previousMatch.rawValue))
        find.addItem(item(String(localized: "Use Selection for Find"), finder, "e", tag: NSTextFinder.Action.setSearchString.rawValue))
        find.addItem(.separator())
        // In the editor: the find bar with its replace field.
        find.addItem(item(String(localized: "Find and Replace…"), finder, "f", [.command, .option], tag: NSTextFinder.Action.showReplaceInterface.rawValue))
        menu.addItem(submenu(find))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Clear", comment: "Edit menu: clears the terminal's scrollback"), #selector(MainWindowController.clearScrollback(_:)), "k"))
        // The commands the shell marked (Terminal's marks): in a terminal only, so the editor keeps ⌘↑ and ⌘↓.
        menu.addItem(.separator())
        menu.addItem(scoped(String(localized: "Previous Command", comment: "Edit menu: scrolls the terminal to the prompt before"), #selector(TerminalSurface.jumpToPreviousCommand(_:)), up, .command, in: .terminal))
        menu.addItem(scoped(String(localized: "Next Command", comment: "Edit menu: scrolls the terminal to the next prompt"), #selector(TerminalSurface.jumpToNextCommand(_:)), down, .command, in: .terminal))
        menu.addItem(scoped(String(localized: "Select Previous Output", comment: "Edit menu: selects what the command before printed"), #selector(TerminalSurface.selectPreviousCommandOutput(_:)), up, [.command, .shift], in: .terminal))
        menu.addItem(scoped(String(localized: "Select Next Output", comment: "Edit menu: selects what the next command printed"), #selector(TerminalSurface.selectNextCommandOutput(_:)), down, [.command, .shift], in: .terminal))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(item(String(localized: "Meadow and Terminals"), #selector(MainWindowController.showMeadowAndTerminals(_:)), "1", [.command, .control]))
        menu.addItem(item(String(localized: "Terminals Only"), #selector(MainWindowController.showTerminalsOnly(_:)), "2", [.command, .control]))
        menu.addItem(item(String(localized: "Meadow Only"), #selector(MainWindowController.showMeadowOnly(_:)), "3", [.command, .control]))
        menu.addItem(item(String(localized: "Hide Meadow"), #selector(MainWindowController.toggleNavigator(_:)), "s", [.command, .control]))
        // VS Code's and Cursor's key for the side bar, which the meadow is here.
        menu.addItem(hiddenKey(#selector(MainWindowController.toggleNavigator(_:)), "b", .command))
        // ⌘/ is Toggle Comment in the editor; the Finder's Status Bar key with Option.
        menu.addItem(item(String(localized: "Hide Status Bar"), #selector(MainWindowController.toggleStatusBar(_:)), "/", [.command, .option]))
        menu.addItem(item(String(localized: "Reset Layout"), #selector(MainWindowController.resetLayout(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Show Workspaces as List"), #selector(MainWindowController.toggleWorkspacesAsList(_:))))
        // A way to stop the meadow's ambient motion (WCAG 2.2.2); cats still change as Claude does.
        menu.addItem(item(String(localized: "Animate Meadow"), #selector(MainWindowController.toggleAnimateMeadow(_:))))
        // The meadow fills the window and its scenery can be moved, turned, copied and taken away.
        menu.addItem(item(String(localized: "Edit Meadow"), #selector(MainWindowController.toggleMeadowEditing(_:)), "e", [.command, .control]))
        // While editing: the tray's tools (their keys, V B E G, are the meadow's own, so a terminal keeps them),
        // and the tray folded to its top row.
        let tools = NSMenu(title: String(localized: "Editor Tools", comment: "View menu: the meadow editor's tools"))
        for (index, title) in [String(localized: "Select", comment: "Meadow editor's tool: choose, move and place things"),
                               String(localized: "Brush", comment: "Meadow editor's tool: paints flowers"),
                               String(localized: "Erase", comment: "Meadow editor's tool: takes things away"),
                               String(localized: "Ground", comment: "Meadow editor's tool: paints paths, lawn and soil")].enumerated() {
            tools.addItem(item(title, #selector(MainWindowController.chooseEditorTool(_:)), tag: index))
        }
        menu.addItem(submenu(tools))
        // The view while editing, for a pointer alone (the keys are the meadow's own: , . 0).
        let view = NSMenu(title: String(localized: "Editor View", comment: "View menu: turning and framing the meadow while it is edited"))
        for command in EditModeController.ViewCommand.allCases {
            view.addItem(item(command.title, #selector(MainWindowController.performEditorView(_:)), tag: command.rawValue))
        }
        menu.addItem(submenu(view))
        menu.addItem(item(String(localized: "Hide Editor Tray", comment: "View menu: folds the meadow editor's tray to its top row"),
                          #selector(MainWindowController.toggleEditorTray(_:)), "t", [.command, .option]))
        menu.addItem(.separator())
        // The side panel: choosing the mode it already shows hides it.
        menu.addItem(item(String(localized: "Files"), #selector(MainWindowController.showFilesPanel(_:)), "e", [.command, .shift]))
        menu.addItem(item(String(localized: "Changes"), #selector(MainWindowController.showChangesPanel(_:)), "c", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Show Preview"), #selector(MainWindowController.togglePreview(_:)), "p", [.command, .option]))
        // VS Code's Markdown preview key.
        menu.addItem(hiddenKey(#selector(MainWindowController.togglePreview(_:)), "v", [.command, .shift]))
        menu.addItem(item(String(localized: "Preview Side by Side"), #selector(MainWindowController.togglePreviewSideBySide(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Zoom Pane"), #selector(MainWindowController.toggleZoom(_:)), "\r", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Bigger Text"), #selector(MainWindowController.biggerText(_:)), "="))
        menu.addItem(hiddenKey(#selector(MainWindowController.biggerText(_:)), "+", .command))
        // "=" needs Shift on a Japanese keyboard.
        menu.addItem(hiddenKey(#selector(MainWindowController.biggerText(_:)), ";", .command))
        menu.addItem(item(String(localized: "Smaller Text"), #selector(MainWindowController.smallerText(_:)), "-"))
        menu.addItem(item(String(localized: "Actual Size"), #selector(MainWindowController.actualSizeText(_:)), "0"))
        menu.addItem(.separator())
        // AppKit puts its own Enter Full Screen (🌐F) here and hides this one; ⌃⌘F, the key every Mac app
        // has had, must still work.
        let fullScreen = item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        fullScreen.allowsKeyEquivalentWhenHidden = true
        menu.addItem(fullScreen)
        return menu
    }

    /// The editor's own commands (Xcode's Editor menu, kept short): they act on the file with the keyboard.
    private static func editorMenu() -> NSMenu {
        // Its keys without ⌘ (VS Code's and Cursor's) count only in the editor: a terminal keeps them.
        let menu = ScopedKeysMenu(title: String(localized: "Editor"))
        menu.addItem(item(String(localized: "Go to Line…"), #selector(CodeTextView.goToLine(_:)), "l"))
        menu.addItem(scoped("", #selector(CodeTextView.goToLine(_:)), "g", .control, in: .editor, hidden: true))
        menu.addItem(item(String(localized: "Go to Bracket"), #selector(CodeTextView.goToMatchingBracket(_:)), "\\", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Toggle Comment"), #selector(CodeTextView.toggleComment(_:)), "/"))
        menu.addItem(item(String(localized: "Shift Right"), #selector(CodeTextView.shiftRight(_:)), "]", [.command, .option]))
        menu.addItem(item(String(localized: "Shift Left"), #selector(CodeTextView.shiftLeft(_:)), "[", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(scoped(String(localized: "Move Line Up"), #selector(CodeTextView.moveLineUp(_:)), up, .option, in: .editor))
        menu.addItem(scoped(String(localized: "Move Line Down"), #selector(CodeTextView.moveLineDown(_:)), down, .option, in: .editor))
        menu.addItem(scoped(String(localized: "Copy Line Up"), #selector(CodeTextView.copyLineUp(_:)), up, [.option, .shift], in: .editor))
        menu.addItem(scoped(String(localized: "Copy Line Down"), #selector(CodeTextView.copyLineDown(_:)), down, [.option, .shift], in: .editor))
        menu.addItem(item(String(localized: "Delete Line"), #selector(CodeTextView.deleteLine(_:)), "k", [.command, .shift]))
        menu.addItem(.separator())
        let indentation = NSMenu(title: String(localized: "Indentation"))
        for width in [2, 4, 8] {
            indentation.addItem(item(String(localized: "Spaces: \(width)"), #selector(MainWindowController.setIndentation(_:)), tag: width))
        }
        indentation.addItem(item(String(localized: "Tabs"), #selector(MainWindowController.setIndentation(_:)), tag: 0))
        menu.addItem(submenu(indentation))
        let endings = NSMenu(title: String(localized: "Line Endings"))
        for (index, ending) in LineEnding.allCases.enumerated() {
            endings.addItem(item(ending.label, #selector(MainWindowController.setLineEnding(_:)), tag: index))
        }
        menu.addItem(submenu(endings))
        // No key: VS Code's ⌥Z types a letter on some keyboards ("ż" on a Polish one), which the menu would take.
        menu.addItem(item(String(localized: "Wrap Lines"), #selector(MainWindowController.toggleWrapLines(_:))))
        menu.addItem(item(String(localized: "Show Invisibles"), #selector(MainWindowController.toggleInvisibles(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Compare with HEAD"), #selector(MainWindowController.compareWithHEAD(_:))))
        menu.addItem(item(String(localized: "Next Change"), #selector(MainWindowController.nextChange(_:)), down, [.command, .control]))
        menu.addItem(item(String(localized: "Previous Change"), #selector(MainWindowController.previousChange(_:)), up, [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Reveal in Files"), #selector(MainWindowController.revealInFiles(_:)), "j", [.command, .shift]))
        return menu
    }

    private static func goMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Go"))
        // Home is no workspace selected: the Home page beside the meadow (⇧⌘H, as in the Finder and Safari).
        menu.addItem(item(String(localized: "Home", comment: "Go menu and the workspace menu: no workspace selected"), #selector(MainWindowController.goHome(_:)), "h", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Next Request"), #selector(MainWindowController.goToNextThing(_:)), "j"))
        menu.addItem(item(String(localized: "Go to…"), #selector(MainWindowController.goTo(_:)), "p"))
        menu.addItem(item(String(localized: "Command Palette…"), #selector(MainWindowController.showCommandPalette(_:)), "p", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Next Tab"), #selector(MainWindowController.nextTab(_:)), "]", [.command, .shift]))
        menu.addItem(item(String(localized: "Previous Tab"), #selector(MainWindowController.previousTab(_:)), "[", [.command, .shift]))
        // ⌃Tab goes back to the tab before (the most recent first), as a held ⌃ steps further (`TabSwitcher`).
        menu.addItem(hiddenKey(#selector(MainWindowController.switchToRecentTab(_:)), "\t", .control))
        menu.addItem(hiddenKey(#selector(MainWindowController.switchToRecentTabBackward(_:)), "\t", [.control, .shift]))
        let tabs = NSMenu(title: String(localized: "Tab"))
        for number in 1...8 {
            tabs.addItem(item(String(localized: "Tab \(number)"), #selector(MainWindowController.selectTabByNumber(_:)), "\(number)", tag: number))
        }
        tabs.addItem(item(String(localized: "Last Tab"), #selector(MainWindowController.selectTabByNumber(_:)), "9", tag: 9))
        menu.addItem(submenu(tabs))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Next Workspace"), #selector(MainWindowController.nextWorkspace(_:)), "]", [.command, .control]))
        menu.addItem(item(String(localized: "Previous Workspace"), #selector(MainWindowController.previousWorkspace(_:)), "[", [.command, .control]))
        let workspaces = NSMenu(title: String(localized: "Workspace"))
        for number in 1...9 {
            workspaces.addItem(item(String(localized: "Workspace \(number)"), #selector(MainWindowController.selectWorkspaceByNumber(_:)), "\(number)", [.command, .option], tag: number))
        }
        menu.addItem(submenu(workspaces))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Next Pane"), #selector(MainWindowController.nextPane(_:)), "]"))
        menu.addItem(item(String(localized: "Previous Pane"), #selector(MainWindowController.previousPane(_:)), "["))
        let focus = [(String(localized: "Pane Left"), #selector(MainWindowController.focusLeft(_:)), left),
                     (String(localized: "Pane Right"), #selector(MainWindowController.focusRight(_:)), right),
                     (String(localized: "Pane Up"), #selector(MainWindowController.focusUp(_:)), up),
                     (String(localized: "Pane Down"), #selector(MainWindowController.focusDown(_:)), down)]
        for (title, action, key) in focus { menu.addItem(item(title, action, key, [.command, .option])) }
        let swap = [(String(localized: "Swap Pane Left"), #selector(MainWindowController.swapLeft(_:)), left),
                    (String(localized: "Swap Pane Right"), #selector(MainWindowController.swapRight(_:)), right),
                    (String(localized: "Swap Pane Up"), #selector(MainWindowController.swapUp(_:)), up),
                    (String(localized: "Swap Pane Down"), #selector(MainWindowController.swapDown(_:)), down)]
        for (title, action, key) in swap { menu.addItem(item(title, action, key, [.command, .option, .shift])) }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Move Focus to Meadow"), #selector(MainWindowController.moveFocusToMeadow(_:)), "0", [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Pin Claude"), #selector(MainWindowController.togglePin(_:))))
        menu.addItem(item(String(localized: "Mark as Unread"), #selector(MainWindowController.markUnread(_:))))
        menu.addItem(item(String(localized: "Interrupt"), #selector(MainWindowController.interrupt(_:)), "."))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Whiskr", comment: "Window menu: brings back the main window"), #selector(AppDelegate.showMainWindow(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
