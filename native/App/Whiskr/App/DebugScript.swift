#if DEBUG
import AppKit
import WhiskrKit

/// Debug builds only: a run driven step by step from a file, as a person would drive it, without a mouse,
/// a key window or a single event outside this process. Commands go where AppKit would send them: menu
/// items through the main window's own responder chain (a window behind others is never key, so a
/// nil-targeted action would otherwise find nothing), keys to the first responder, presses through the
/// accessibility tree (no tracking loop waiting for a mouse-up that never comes).
///
///   --script <file>     one step per line: `<seconds to wait> <command> [argument]`; `#` starts a comment
///
/// Commands:
///   menu <Menu>Item>…>      validates the item as the menu would, prints whether it is enabled, performs it
///   key <keys>              e.g. cmd+t, cmd+shift+p, return, esc, tab, down, cmd+opt+left; a key equivalent
///                           goes to the window's views, then to the menus; anything else to the first responder
///   type <text>             typed into the first responder, key by key (\r Return, \e Esc, \t Tab)
///   press <label>           the first accessibility element whose label, title or identifier is <label>
///   snapshot <png>          the window as drawn, with the palette and answer card over it
///   menus <file>            every menu item: key, enabled state for the present focus, title
///   keytable <file>         the menus' keys against `KeyTable` (differences, then collisions), "same" if none
///   views <file>            the window's view tree with frames; ax <file> its accessibility tree
///   state                   the workbench in one line, and what has the keyboard
///   window <w>x<h>          resizes the window; layout split|terminals|meadow|list|meadow-view
///   new-terminal            Home's New Terminal (its rows are SwiftUI's, out of reach of a press from here)
///   open <name>             Home's row for that open workspace (back in where it was left)
///   terminals <file>        what the session host holds and each pane's screen (as --terminals)
///   click <x>,<y> [count]   a click (or a double-click, count 2) at that point of the window, in points from
///                           its top left, through the window's own event path; prints the view it landed on
///   frame                   the window's frame, and whether it is zoomed or minimised; and the tab count
///   drag <x>,<y> <x>,<y>    a press at the first point, moved in steps to the second, released there
///   quit                    quits as ⌘Q does
@MainActor
enum DebugScript {
    /// A background run stays out of the way of whoever is at this Mac: no Dock icon, never active, every
    /// window it orders in (sheets, popovers, panels too) transparent and click-through, no full screen
    /// (who asked is printed), no Dock bounce, and the clipboard and the find text (shared with every app)
    /// pasteboards of its own.
    static func keepOutOfSight() {
        guard DebugScenario.keepsInBackground else { return }
        NSApp.setActivationPolicy(.accessory)
        let swaps: [(AnyClass, Selector, Selector)] = [
            (NSWindow.self, #selector(NSWindow.toggleFullScreen(_:)), #selector(NSWindow.debugRefusedFullScreen(_:))),
            (NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.debugOrderUnseen(_:relativeTo:))),
            (NSApplication.self, #selector(NSApplication.activate as (NSApplication) -> () -> Void), #selector(NSApplication.debugRefusedActivate as (NSApplication) -> () -> Void)),
            (NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)), #selector(NSApplication.debugRefusedActivate(ignoringOtherApps:))),
            (NSApplication.self, #selector(NSApplication.requestUserAttention(_:)), #selector(NSApplication.debugRefusedAttention(_:))),
        ]
        let pasteboards: [(Selector, Selector)] = [
            (NSSelectorFromString("pasteboardWithName:"), #selector(NSPasteboard.debugPrivatePasteboard(withName:))),
            (#selector(getter: NSPasteboard.general), #selector(getter: NSPasteboard.debugPrivateGeneral)),
        ]
        for (original, replacement) in pasteboards {
            guard let from = class_getClassMethod(NSPasteboard.self, original), let to = class_getClassMethod(NSPasteboard.self, replacement) else {
                print("keep-out-of-sight: cannot replace \(original)")
                continue
            }
            method_exchangeImplementations(from, to)
        }
        for (type, original, replacement): (AnyClass, Selector, Selector) in swaps {
            guard let from = class_getInstanceMethod(type, original), let to = class_getInstanceMethod(type, replacement) else {
                print("keep-out-of-sight: cannot replace \(original)")
                continue
            }
            method_exchangeImplementations(from, to)
        }
    }

    static func run(workbench: Workbench, window controller: MainWindowController) {
        guard let path = DebugScenario.value("--script"), let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        // Every line out at once: a crash must not swallow what led to it.
        setvbuf(stdout, nil, _IONBF, 0)
        let steps = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        Task { @MainActor in
            for step in steps {
                let parts = step.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 2, let wait = Double(parts[0]) else { print("script: cannot read “\(step)”"); continue }
                try? await Task.sleep(for: .seconds(wait))
                let argument = parts.count > 2 ? parts[2] : ""
                print("step \(parts[1]) \(argument)")
                perform(parts[1], argument, workbench: workbench, controller: controller)
                fflush(stdout)
            }
        }
    }

    private static func perform(_ command: String, _ argument: String, workbench: Workbench, controller: MainWindowController) {
        guard let window = controller.window else { return }
        switch command {
        case "menu":
            guard let item = menuItem(path: argument.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }) else { return print("  no such menu item") }
            send(item, window: window)
        case "key":
            key(argument, window: keyWindow(over: window))
        case "type":
            let window = keyWindow(over: window)
            let text = argument.replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1b}").replacingOccurrences(of: "\\t", with: "\t")
            for character in text {
                guard let event = keyEvent(characters: String(character), modifiers: [], code: 0, window: window) else { continue }
                (window.firstResponder ?? window).keyDown(with: event)
            }
        case "press":
            let root = window.contentView?.superview ?? window.contentView
            let targets: [Any] = [root as Any] + (window.childWindows ?? []).compactMap(\.contentView) + [controller.navigator.answerCardWindow?.contentView as Any]
            for target in targets {
                if let element = accessibilityElement(in: target, named: argument) {
                    print("  pressed \(describe(element)): \(element.accessibilityPerformPress())")
                    return
                }
            }
            print("  nothing called “\(argument)”")
        case "snapshot":
            DebugShell.snapshot(window: controller, workbench: workbench, to: URL(fileURLWithPath: argument))
        case "menus":
            write(menuLines(window: window), to: argument)
        case "keytable":
            write(keyTableLines(), to: argument)
        case "views":
            var lines: [String] = []
            if let frame = window.contentView?.superview { viewLines(frame, depth: 0, into: &lines) }
            for child in window.childWindows ?? [] { lines.append("child window \(child.frame)"); if let view = child.contentView { viewLines(view, depth: 1, into: &lines) } }
            write(lines, to: argument)
        case "ax":
            var lines: [String] = []
            accessibilityLines(window, depth: 0, into: &lines)
            write(lines, to: argument)
        case "state":
            state(workbench: workbench, window: window)
        case "window":
            let size = argument.split(separator: "x").compactMap { Double($0) }
            if size.count == 2 { window.setContentSize(NSSize(width: size[0], height: size[1])) }
        case "layout":
            controller.debugSetLayout { layout in
                switch argument {
                case "terminals": layout.mode = .terminalsOnly
                case "meadow": layout.mode = .meadowOnly
                case "list": layout.navigator = .list
                case "meadow-view": layout.navigator = .meadow
                default: layout.mode = .split
                }
            }
        case "surface-pdf":
            // The focused terminal drawn by its own draw(_:) into a PDF: a second way to see what it draws.
            guard let surface = workbench.focusedPane?.surface else { return print("  no terminal") }
            try? surface.dataWithPDF(inside: surface.bounds).write(to: URL(fileURLWithPath: argument))
            print("  terminal \(surface.frame) drawn to \(argument)")
        case "new-terminal":
            guard workbench.isHome else { return print("  not on Home") }
            workbench.newWorkspace()
        case "open":
            guard workbench.isHome, let row = workbench.homeRows.first(where: { $0.name == argument }) else { return print("  no such row on Home") }
            workbench.selectBlanket(row.id)
        case "terminals":
            DebugScenario.Probe.terminals(workbench: workbench, to: URL(fileURLWithPath: argument))
        case "click":
            let parts = argument.split(separator: " ")
            let point = parts.first?.split(separator: ",").compactMap { Double($0) } ?? []
            guard point.count == 2, let content = window.contentView else { return print("  click <x>,<y> [count]") }
            click(window: window, at: NSPoint(x: point[0], y: content.bounds.height - point[1]), count: parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
        case "drag":
            let points = argument.split(separator: " ").map { $0.split(separator: ",").compactMap { Double($0) } }
            guard points.count == 2, points.allSatisfy({ $0.count == 2 }), let content = window.contentView else { return print("  drag <x>,<y> <x>,<y>") }
            let flip = { (p: [Double]) in NSPoint(x: p[0], y: content.bounds.height - p[1]) }
            drag(window: window, from: flip(points[0]), to: flip(points[1]))
        case "frame":
            print("  frame \(window.frame) zoomed \(window.isZoomed) minimised \(window.isMiniaturized) tabs \(workbench.selectedWorkspace?.tabs.count ?? 0) workspaces \(workbench.workspaces.count)")
        case "quit":
            NSApp.terminate(nil)
        default:
            print("  unknown command")
        }
    }

    /// Every click of a run of `count` (as a person's double-click is: a click, then a second one that
    /// counts 2) through `NSWindow.sendEvent`. Each release is queued in this app before its press, since
    /// a press may start a tracking loop (a window drag) that waits for it; nothing leaves the process.
    private static func click(window: NSWindow, at point: NSPoint, count: Int) {
        let hit = window.contentView?.superview?.hitTest(point)
        print("  click at \(point) lands on \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
        func event(_ type: NSEvent.EventType, _ number: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: number, pressure: type == .leftMouseDown ? 1 : 0)
        }
        for number in 1...max(count, 1) {
            guard let down = event(.leftMouseDown, number), let up = event(.leftMouseUp, number) else { continue }
            NSApp.postEvent(up, atStart: false)
            window.sendEvent(down)
        }
    }

    /// A press, a drag in ten steps and a release, the moves and the release queued first for the
    /// tracking loop the press starts.
    private static func drag(window: NSWindow, from start: NSPoint, to end: NSPoint) {
        let hit = window.contentView?.superview?.hitTest(start)
        print("  drag from \(start) on \(hit.map { String(describing: type(of: $0)) } ?? "nothing") to \(end)")
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        for step in 1...10 {
            let t = CGFloat(step) / 10
            if let moved = event(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)) { NSApp.postEvent(moved, atStart: false) }
        }
        if let up = event(.leftMouseUp, end) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown, start) { window.sendEvent(down) }
    }

    // MARK: Menus

    private static func menuItem(path: [String]) -> NSMenuItem? {
        var menu = NSApp.mainMenu
        var found: NSMenuItem?
        for title in path {
            guard let item = menu?.items.first(where: { $0.title == title }) else { return nil }
            found = item
            menu?.delegate?.menuNeedsUpdate?(menu!)
            menu = item.submenu
            if let menu { menu.delegate?.menuNeedsUpdate?(menu) }
        }
        return found
    }

    /// Where AppKit would send the item's action if the window were key: its own target, else the first
    /// in the window's responder chain, the window's delegate, the app, the app's delegate. Also used by
    /// `DebugInteractions` (an item of a context menu).
    static func target(for item: NSMenuItem, window: NSWindow) -> AnyObject? {
        guard let action = item.action else { return nil }
        if let target = item.target { return target }
        var responder: NSResponder? = window.firstResponder
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        for candidate in [window as AnyObject, window.delegate as AnyObject?, window.windowController as AnyObject?, NSApp as AnyObject, NSApp.delegate as AnyObject?] {
            if let candidate, candidate.responds(to: action) { return candidate }
        }
        return nil
    }

    private static func isEnabled(_ item: NSMenuItem, window: NSWindow) -> Bool {
        guard item.action != nil else { return item.submenu != nil }
        guard let target = target(for: item, window: window) else { return false }
        if let validating = target as? NSMenuItemValidation { return validating.validateMenuItem(item) }
        if let validating = target as? NSUserInterfaceValidations { return validating.validateUserInterfaceItem(item) }
        return true
    }

    private static func send(_ item: NSMenuItem, window: NSWindow, quiet: Bool = false) {
        // A submenu's own item carries AppKit's private `submenuAction:`, meant only for menu tracking
        // (sent from here it breaks the run). Choosing it opens the submenu: its items were just refreshed.
        if let submenu = item.submenu {
            return print("  “\(item.title)” opens a submenu: \(submenu.items.map(\.title))")
        }
        let enabled = isEnabled(item, window: window)
        let target = target(for: item, window: window)
        if !quiet { print("  “\(item.title)” enabled=\(enabled) target=\(target.map { String(describing: type(of: $0)) } ?? "none")") }
        guard enabled, let action = item.action, let target else { return }
        NSApp.sendAction(action, to: target, from: item)
    }

    private static func menuLines(window: NSWindow) -> [String] {
        var lines: [String] = []
        func walk(_ menu: NSMenu, _ trail: String) {
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items where !item.isSeparatorItem {
                let enabled = isEnabled(item, window: window)
                let keys = keyLabel(item)
                lines.append("\(keys.padding(toLength: 10, withPad: " ", startingAt: 0)) \(enabled ? "on " : "off") \(item.isHidden ? "(hidden) " : "")\(item.isAlternate ? "(alt) " : "")\(trail)\(item.title)\(item.state == .on ? " ✓" : "")")
                if let submenu = item.submenu { walk(submenu, "\(trail)\(item.title) > ") }
            }
        }
        if let bar = NSApp.mainMenu { for top in bar.items { if let menu = top.submenu { walk(menu, "\(top.title) > ") } } }
        return lines
    }

    /// Every key the menus have, as `KeyTable.menu` writes them, and what differs between the two. The
    /// items macOS adds to every app's Edit and View menus (Emoji & Symbols, Dictation, and the globe key's
    /// Full Screen) are the system's, not ours.
    private static func keyTableLines() -> [String] {
        var live: [KeyBinding] = []
        let systems: Set<Selector> = [#selector(NSApplication.orderFrontCharacterPalette(_:)), Selector(("startDictation:"))]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let submenu = item.submenu { walk(submenu) }
                guard let action = item.action, !item.keyEquivalent.isEmpty, !systems.contains(action),
                      !item.keyEquivalentModifierMask.contains(.function) else { continue }
                let mask = item.keyEquivalentModifierMask
                var modifiers: KeyChord.Modifiers = []
                if mask.contains(.control) { modifiers.insert(.control) }
                if mask.contains(.option) { modifiers.insert(.option) }
                if mask.contains(.shift) { modifiers.insert(.shift) }
                if mask.contains(.command) { modifiers.insert(.command) }
                let chord = KeyChord(menuKey: item.keyEquivalent, modifiers)
                let command = NSStringFromSelector(action) + (item.tag != 0 ? "#\(item.tag)" : "")
                let context: KeyContext = switch (item as? ScopedKeyItem)?.scope {
                case .editor: .menuInEditor
                case .terminal: .menuInTerminal
                case nil: .menu
                }
                live.append(KeyBinding(chord.description, command, context))
            }
        }
        if let bar = NSApp.mainMenu { walk(bar) }
        let table = Set(KeyTable.menu), menus = Set(live)
        var lines = menus.subtracting(table).map { "only in the menus: \($0.chord) \($0.command) \($0.context.rawValue)" }.sorted()
        lines += table.subtracting(menus).map { "only in KeyTable: \($0.chord) \($0.command) \($0.context.rawValue)" }.sorted()
        lines += KeyTable.collisions(in: live + KeyTable.editor + KeyTable.textEditing + KeyTable.views + KeyTable.system).map { "collision: \($0)" }
        return lines.isEmpty ? ["same: \(live.count) menu keys, no collisions"] : lines
    }

    private static func keyLabel(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let mask = item.keyEquivalentModifierMask
        var label = ""
        if mask.contains(.control) { label += "⌃" }
        if mask.contains(.option) { label += "⌥" }
        if mask.contains(.shift) { label += "⇧" }
        if mask.contains(.command) { label += "⌘" }
        let names: [String: String] = ["\r": "↩", "\t": "⇥", "\u{1b}": "⎋", String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)): "←",
                                       String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)): "→", String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)): "↑",
                                       String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)): "↓", "\u{8}": "⌫", "\u{7f}": "⌫"]
        return label + (names[item.keyEquivalent] ?? item.keyEquivalent.uppercased())
    }

    // MARK: Keys

    /// Where typed keys go: an overlay over the window (the palette, a worktree panel) when one is open,
    /// as it would be the key window; otherwise the window itself.
    private static func keyWindow(over window: NSWindow) -> NSWindow {
        window.childWindows?.last(where: { $0.isVisible && $0.canBecomeKey }) ?? window
    }

    private static let namedKeys: [String: (String, UInt16)] = [
        "return": ("\r", 36), "esc": ("\u{1b}", 53), "tab": ("\t", 48), "space": (" ", 49), "delete": ("\u{7f}", 51),
        "left": (String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)), 123), "right": (String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)), 124),
        "down": (String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)), 125), "up": (String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)), 126),
    ]

    /// Also used by `DebugPerf`, without the lines it prints (`quiet`).
    static func key(_ spec: String, window: NSWindow, quiet: Bool = false) {
        var modifiers: NSEvent.ModifierFlags = []
        var name = ""
        for part in spec.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            case "opt", "alt": modifiers.insert(.option)
            case "ctrl": modifiers.insert(.control)
            default: name = part
            }
        }
        let (characters, code) = namedKeys[name] ?? (name, 0)
        guard let event = keyEvent(characters: characters, modifiers: modifiers, code: code, window: window) else { return }
        if !modifiers.isEmpty {
            // As NSApplication does: the window's views first, then the menus (⌥ keys too: a menu may have them).
            if window.performKeyEquivalent(with: event) { return quiet ? () : print("  taken by a view") }
            if let item = matchingItem(NSApp.mainMenu, event: event, window: window) { return send(item, window: window, quiet: quiet) }
        }
        if !quiet { print("  to \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing")") }
        (window.firstResponder ?? window).keyDown(with: event)
    }

    private static func matchingItem(_ menu: NSMenu?, event: NSEvent, window: NSWindow) -> NSMenuItem? {
        // A key scoped to a view that does not have the keyboard goes on to the view (`ScopedKeysMenu`).
        if let scoped = menu as? ScopedKeysMenu, scoped.passesOn(event, keyboard: .holding(window)) { return nil }
        let characters = event.charactersIgnoringModifiers ?? "", modifiers = event.modifierFlags
        for item in menu?.items ?? [] {
            if let submenu = item.submenu, let found = matchingItem(submenu, event: event, window: window) { return found }
            let mask = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
            if item.keyEquivalent.lowercased() == characters.lowercased(), !item.keyEquivalent.isEmpty, mask == modifiers.intersection([.command, .shift, .option, .control]),
               !item.isAlternate || modifiers.contains(.option) {
                return item
            }
        }
        return nil
    }

    private static func keyEvent(characters: String, modifiers: NSEvent.ModifierFlags, code: UInt16, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    // MARK: Looking

    private static func state(workbench: Workbench, window: NSWindow) {
        let workspace = workbench.selectedWorkspace
        let tab = workbench.selectedTab
        let page = workbench.focusedPage.map { "\($0)" } ?? "-"
        print("  workspaces \(workbench.workspaces.map(\.name)) selected “\(workspace?.name ?? "Home")” tabs \(workspace?.tabs.map { workbench.title(of: $0) } ?? []) selected “\(tab.map { workbench.title(of: $0) } ?? "-")” panes \(tab?.tree.panes.count ?? 0) focused-pane \(workbench.focusedPane != nil) page \(page) peek \(workbench.peekedPane != nil)")
        print("  first responder \(window.firstResponder.map { describe($0) } ?? "none") title “\(window.title)” size \(window.frame.size)")
    }

    private static func describe(_ object: Any) -> String {
        var text = String(describing: type(of: object))
        if let element = object as? NSAccessibilityProtocol {
            let label = element.accessibilityLabel() ?? ""
            if !label.isEmpty { text += " “\(label)”" }
        }
        if let view = object as? NSView, let window = view.window { text += " at \(view.convert(view.bounds, to: nil).integral) in \(window === NSApp.mainWindow ? "main" : "a window")" }
        return text
    }

    private static func viewLines(_ view: NSView, depth: Int, into lines: inout [String]) {
        guard depth < 40 else { return }
        let indent = String(repeating: "  ", count: depth)
        var line = "\(indent)\(type(of: view)) \(view.frame.integral)"
        if view.bounds.origin != .zero { line += " bounds-origin \(view.bounds.origin)" }
        if view.isHidden { line += " hidden" }
        if view.alphaValue < 1 { line += " alpha \(view.alphaValue)" }
        if let label = view.accessibilityLabel(), !label.isEmpty { line += " label “\(label)”" }
        if let field = view as? NSTextField, !field.stringValue.isEmpty { line += " text “\(field.stringValue.prefix(60))”" }
        if let button = view as? NSButton, !button.title.isEmpty { line += " title “\(button.title)”" }
        lines.append(line)
        guard !view.isHidden else { return }
        for child in view.subviews { viewLines(child, depth: depth + 1, into: &lines) }
    }

    private static func accessibilityLines(_ element: Any, depth: Int, into lines: inout [String]) {
        guard depth < 30, let element = element as? NSAccessibilityProtocol else { return }
        let indent = String(repeating: "  ", count: depth)
        let role = element.accessibilityRole()?.rawValue ?? "?"
        var line = "\(indent)\(role)"
        for (name, value) in [("label", element.accessibilityLabel()), ("title", element.accessibilityTitle()), ("id", element.accessibilityIdentifier()),
                              ("help", element.accessibilityHelp()), ("value", (element.accessibilityValue() as? String))] {
            if let value, !value.isEmpty { line += " \(name)=“\(value.prefix(80))”" }
        }
        if element.isAccessibilityElement() == false, role == "AXGroup" || role == "?" {
            // Only containers: their children say more.
        }
        lines.append(line)
        for child in element.accessibilityChildren() ?? [] { accessibilityLines(child, depth: depth + 1, into: &lines) }
    }

    static func accessibilityElement(in root: Any, named name: String) -> NSAccessibilityProtocol? {
        guard let element = root as? NSAccessibilityProtocol else { return nil }
        for candidate in [element.accessibilityLabel(), element.accessibilityTitle(), element.accessibilityIdentifier()] where candidate == name {
            return element
        }
        for child in element.accessibilityChildren() ?? [] {
            if let found = accessibilityElement(in: child, named: name) { return found }
        }
        return nil
    }

    private static func write(_ lines: [String], to path: String) {
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: URL(fileURLWithPath: path))
        print("  wrote \(lines.count) lines to \(path)")
    }
}

extension NSWindow {
    /// Stands in for `toggleFullScreen(_:)` in a background run (`DebugScript.refuseFullScreen`).
    @objc func debugRefusedFullScreen(_ sender: Any?) {
        print("full screen refused in a background run; asked by \(sender.map { String(describing: type(of: $0)) } ?? "nil")")
        Thread.callStackSymbols.prefix(14).forEach { print("  \($0)") }
        fflush(stdout)
    }

    /// Stands in for `order(_:relativeTo:)`: the window is ordered as asked, but nobody sees or clicks it.
    @objc func debugOrderUnseen(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out {
            alphaValue = 0
            ignoresMouseEvents = true
        }
        debugOrderUnseen(place, relativeTo: other)     // the original, exchanged
    }
}

private func noteRefusedActivation() {
    print("activation refused in a background run; asked by:")
    Thread.callStackSymbols.dropFirst(2).prefix(8).forEach { print("  \($0)") }
}

extension NSPasteboard {
    /// Stands in for `NSPasteboard(name:)` in a background run: the clipboard and the find text are this
    /// run's own (named for its process), every other pasteboard (a drag's) the one asked for.
    @objc class func debugPrivatePasteboard(withName name: NSPasteboard.Name) -> NSPasteboard {
        let own: Set<NSPasteboard.Name> = [.general, .find]
        // The original, exchanged.
        return debugPrivatePasteboard(withName: own.contains(name) ? NSPasteboard.Name("Whiskr-isolated-\(getpid())-\(name.rawValue)") : name)
    }

    /// Stands in for `NSPasteboard.general`: the run's own clipboard.
    @objc class var debugPrivateGeneral: NSPasteboard { NSPasteboard(name: .general) }
}

extension NSApplication {
    // These stand in for the originals after `keepOutOfSight` exchanges them: calling one of them by name
    // would run the original, so they share a plain function instead.
    @objc func debugRefusedActivate() { noteRefusedActivation() }
    @objc func debugRefusedActivate(ignoringOtherApps flag: Bool) { noteRefusedActivation() }
    @objc func debugRefusedAttention(_ type: NSApplication.RequestUserAttentionType) -> Int { 0 }
}
#endif
