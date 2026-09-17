#if DEBUG
import AppKit
import MeadowFile
@_spi(Diagnostics) import MeadowScene
import SwiftUI
import WhiskrKit
import WhiskrMeadow

/// The editor flow's part for VoiceOver, the keyboard and Help (`DebugFlowEditor.swift`), through the accessibility
/// tree as VoiceOver reads it (a real screen reader cannot run in an invisible run):
/// - the first hint: shown the first time editing opens, put away by its ×, never again;
/// - the tray's tools, categories, tiles, filter and fold, and the selection's bar, each named;
/// - things in the meadow described with their state ("Garden lamp, lit" by night, "not lit" by day; "Wooden fence,
///   with a gate"; a colour chosen), Press choosing them, the chosen one selected;
/// - the colours' row in the selection's bar (C, its swatches named, Esc puts it away) and its picture in each theme;
/// - the keyboard after each step: ⌘F to the filter, Tab from it to the shelf as filtered, ⇧Tab and Esc back to the
///   meadow, Tab to the selection's bar;
/// - Reduce Motion (nothing settles or springs: placed things are simply there) and Increase Contrast (the marks and
///   the bars' lines stronger), by the debug switches;
/// - Help: every key of the editor has its line in Help's table (read from `KeyTable`), and the Help menu's search
///   finds the editor's topics.
extension EditorFlow {
    func access() async {
        await firstHint()
        await enter()
        editor.debugChoose([])
        await trayRead()
        await thingsRead()
        await keyboardPaths()
        await motionAndContrast()
        helpTable()
        suite.shortcut("esc")
        suite.shortcut("esc")
    }

    // MARK: The first hint

    private func firstHint() async {
        if controller.meadowEditing { editor.leave() }
        AppPlaces.defaults.removeObject(forKey: "meadowEditorHintSeen")
        await enter()
        let shown = await PerfWait.until(2000) { self.editor.noticeModel.text == EditModeController.firstHint && !self.editor.noticeHost.isHidden }
        check("the first time editing opens, one quiet hint says where the tools are and how to leave", shown != nil, editor.noticeModel.text ?? "no note")
        check("…with Editing Help and a × to put it away", editor.noticeModel.closable && editor.noticeModel.choices.map(\.id) == ["help"])
        await picture("first-hint")
        editor.noticeModel.chose("close")
        let gone = await PerfWait.until(2000) { self.editor.noticeModel.text == nil }
        check("its × puts it away, and it is not shown again", gone != nil && !EditModeController.hintDue)
        editor.leave()
        await enter()
        await PerfWait.sleep(300)
        check("…not the next time either", editor.noticeModel.text == nil, editor.noticeModel.text ?? "")
    }

    // MARK: The tray and the bar, read

    private func trayRead() async {
        suite.shortcut("1")
        _ = await PerfWait.until(1500) { self.tile("tree.oak") != nil }
        // SwiftUI builds its part of the tree only for a reading client (an invisible run has none: its views read
        // as empty groups), so what is read here is each control's AppKit view: its name in its tooltip, as the
        // pointer shows it, and the label SwiftUI is given beside it in the same call (`barButton`).
        var unnamed: [String] = []
        for tool in EditorTray.Tool.allCases where suite.barView("tray.tool.\(tool.rawValue)")?.toolTip?.hasPrefix(EditorTrayView.describe(tool).name) != true {
            unnamed.append(tool.rawValue)
        }
        for category in EditorTray.categories where suite.barView("tray.category.\(category.rawValue)")?.toolTip?.hasPrefix(MeadowWords.categoryName(category)) != true {
            unnamed.append(category.rawValue)
        }
        for item in tray.shelf where tile(item.id)?.toolTip != item.name { unnamed.append(item.id) }
        if suite.barView("tray.fold")?.toolTip?.isEmpty != false { unnamed.append("fold") }
        let filter = tray.filterField?.accessibilityLabel()
        check("the tray's tools, shelves, things and fold are each named (tooltip and VoiceOver label), and the filter field for VoiceOver",
              unnamed.isEmpty && filter == String(localized: "Filter things", comment: "VoiceOver: the tray's filter field"), "unnamed \(unnamed), filter “\(filter ?? "")”")
    }

    // MARK: Things, read with their state

    /// The meadow's element for a thing.
    private func element(of id: Int) -> SceneryAccessibilityElement? {
        guard let item = library.session.item(id) else { return nil }
        let place = MeadowWords.whereIs(item.at)
        return (meadow.accessibilityChildren() ?? []).compactMap { $0 as? SceneryAccessibilityElement }.first {
            ($0.accessibilityLabel() ?? "").hasPrefix(MeadowWords.name(item.asset)) && ($0.accessibilityLabel() ?? "").hasSuffix(place)
        }
    }

    private func thingsRead() async {
        let before = count
        var random = SystemRandomNumberGenerator()
        // A lamp, a bench and a fence beside the picnic ground, made as the editor makes them.
        guard let lamp = library.session.fresh("work.lampPost", at: SIMD2(34, 30), turn: 0, using: &random),
              let bench = library.session.fresh("work.bench", at: SIMD2(-34, 30), turn: 0, using: &random),
              let laying = library.session.fenceLaying(MeadowEditSession.shortFence(at: SIMD2(-30, 44), turn: 0)) else {
            return check("a lamp, a bench and a fence to read", false)
        }
        _ = library.edit(MeadowWords.place([lamp.asset])) { $0.add([lamp], around: SIMD2(34, 30)) }
        _ = library.edit(MeadowWords.place([bench.asset])) { $0.add([bench], around: SIMD2(-34, 30)) }
        _ = library.edit(MeadowWords.layFence) { $0.layFence(laying) }
        let ids = library.session.drawnIDs.suffix(3)
        guard ids.count == 3, let lampID = ids.first(where: { library.session.item($0)?.asset == "work.lampPost" }),
              let benchID = ids.first(where: { library.session.item($0)?.asset == "work.bench" }),
              let fenceID = ids.first(where: { library.session.item($0)?.asset == MeadowEditSession.fence }) else {
            return check("a lamp, a bench and a fence placed to read", false, "\(count - before) placed")
        }
        editor.meadowSwitched()
        let store = WorldStore.shared, time = store.settings.timeOfDay
        check("by day a lamp reads as not lit", element(of: lampID)?.accessibilityLabel()?.contains(MeadowWords.described(library.session.item(lampID)!, lit: false)) == true,
              element(of: lampID)?.accessibilityLabel() ?? "no element")
        store.settings.timeOfDay = .night
        _ = await PerfWait.until(4000) { self.meadow.lampsAreLit }
        let night = element(of: lampID)?.accessibilityLabel() ?? "no element"
        check("by night the same element reads the lamp as lit, as it is asked", meadow.lampsAreLit && night.hasPrefix(MeadowWords.described(library.session.item(lampID)!, lit: true)), night)
        store.settings.timeOfDay = time
        _ = await PerfWait.until(4000) { !self.meadow.lampsAreLit }

        // A gate hung, and a colour chosen, are read as they are now.
        _ = library.edit(MeadowWords.addGate) { $0.toggleGate(fenceID) }
        let fence = element(of: fenceID)?.accessibilityLabel() ?? "no element"
        check("a fence with a gate reads so", fence.contains(String(localized: "\(MeadowWords.name(MeadowEditSession.fence)), with a gate", comment: "VoiceOver: a fence that has a gate")), fence)

        // Press chooses, and the chosen one says it is selected.
        if let benchElement = element(of: benchID) {
            _ = benchElement.accessibilityPerformPress()
            check("Press on a thing chooses it, and it reads as selected", editor.debugSelection == [benchID] && benchElement.isAccessibilitySelected())
        } else {
            check("the bench has an element", false)
        }
        await still()
        _ = await PerfWait.until(1500) { self.editor.debugSelectionBarShown }
        let buttons: [(String, String)] = [("turnLeft", String(localized: "Turn Left", comment: "Selection bar")), ("turnRight", String(localized: "Turn Right", comment: "Selection bar")),
                                           ("colour", String(localized: "Colour", comment: "Selection bar: chooses a made thing's colour from its palette")),
                                           ("duplicate", String(localized: "Duplicate", comment: "Selection bar")), ("delete", String(localized: "Delete", comment: "Selection bar")),
                                           ("more", String(localized: "More", comment: "Selection bar: a menu of further commands"))]
        let unnamed = buttons.filter { id, name in suite.barView("bar.selection.\(id)")?.toolTip?.hasPrefix(name) != true }.map(\.0)
        check("the selection's bar: each button a control of the bars, named in its tooltip (with its key) and for VoiceOver", unnamed.isEmpty, "unnamed \(unnamed)")

        // C: the colours in the bar itself (never a window of its own), each swatch named; the bar grows to hold them.
        let shut = editor.selectionBar.frame.height
        meadow.window?.makeFirstResponder(meadow)
        suite.shortcut("c")
        let open = await PerfWait.until(1500) { self.editor.barModel.paletteOpen && self.editor.selectionBar.frame.height > shut + 20 }
        let swatches = editor.barModel.swatches.map(\.label)
        _ = await PerfWait.until(1500) { self.suite.barView("bar.swatch.\(self.editor.barModel.swatches.last?.name ?? "")") != nil }
        let named = editor.barModel.swatches.allSatisfy { suite.barView("bar.swatch.\($0.name)")?.toolTip == $0.label }
        check("C opens the bench's colours in its bar (no window of its own), the bar grown to hold them, each swatch a control named for its colour",
              open != nil && !swatches.isEmpty && named && (window.childWindows ?? []).isEmpty,
              "open \(editor.barModel.paletteOpen), height \(shut) → \(editor.selectionBar.frame.height), swatches \(swatches)")
        await colourPictures()
        if let sage = editor.barModel.swatches.first(where: { $0.name == "sage" }) {
            editor.barModel.act(.colour(sage.name))
            check("a colour chosen is one step, the row still open, the bench read in it", undoName == MeadowWords.colour(["work.bench"], "sage") && editor.barModel.paletteOpen
                  && (element(of: benchID)?.accessibilityLabel() ?? "").contains(MeadowWords.colourName("sage").lowercased()),
                  "step “\(undoName)”, \(element(of: benchID)?.accessibilityLabel() ?? "")")
        }
        suite.shortcut("esc")
        check("Esc puts the colours away first, the bench still chosen", !editor.barModel.paletteOpen && editor.debugSelection == [benchID])

        // Tab from the meadow with something chosen: the selection's bar.
        meadow.window?.makeFirstResponder(meadow)
        suite.shortcut("tab")
        let inBar = (window.firstResponder as? NSView)?.isDescendant(of: editor.selectionBar) == true || window.firstResponder === editor.selectionBar
        check("Tab with something chosen goes on to the selection's bar", inBar, "\(String(describing: window.firstResponder.map { type(of: $0) }))")
        meadow.window?.makeFirstResponder(meadow)
        while count > before, library.undoManager.canUndo { library.undoManager.undo() }
        check("⌘Z takes the lamp, the bench and the fence away again", count == before, "\(count - before) left")
        editor.debugChoose([])
    }

    /// The colours' row, in each theme and with Increase Contrast: drawn in the window itself, so a picture shows it
    /// as it is.
    private func colourPictures() async {
        let store = ThemeStore.shared
        let before = (store.themeID, store.appearance)
        for (name, id, appearance) in [("whiskr-light", BuiltInThemes.defaultID, ThemeStore.Appearance.light), ("whiskr-dark", BuiltInThemes.defaultID, .dark),
                                       ("graphite", "graphite", .dark)] {
            store.themeID = id
            store.appearance = appearance
            await PerfWait.sleep(400)
            await picture("colours-\(name)")
        }
        Look.debugIncreasesContrast = true
        editor.updateMarks()
        await PerfWait.sleep(400)
        await picture("colours-contrast")
        Look.debugIncreasesContrast = false
        editor.updateMarks()
        store.themeID = before.0
        store.appearance = before.1
        await PerfWait.sleep(300)
    }

    // MARK: The keyboard's paths

    private func keyboardPaths() async {
        meadow.window?.makeFirstResponder(meadow)
        suite.shortcut("cmd+f")
        check("⌘F: the filter has the keyboard at once, its well ringed", tray.filterHasKeyboard && window.firstResponder is NSText)
        await picture("filter-focused")
        suite.typeKeys("stone")
        _ = await PerfWait.until(2000) { self.tray.filter == "stone" }
        let found = tray.shelf.map(\.id)
        suite.shortcut("tab")
        check("Tab in the filter: the shelf, as filtered, has the keyboard, on what it found first",
              window.firstResponder === editor.trayKeys && tray.shelf.map(\.id) == found && tray.highlighted == found.first, "on \(tray.highlighted ?? "none")")
        suite.shortcut("tab")
        check("Tab on the shelf: back to the meadow", window.firstResponder === meadow)
        suite.shortcut("cmd+f")
        // ⇧Tab as the keyboard sends it: a backtab, through the window.
        if let backtab = suite.keyEvent("\u{19}", modifiers: .shift, code: 48) { NSApp.sendEvent(backtab) }
        check("⇧Tab in the filter: back to the meadow, the filter kept", window.firstResponder === meadow && tray.filter == "stone" && !tray.filterHasKeyboard)
        suite.shortcut("cmd+f")
        suite.shortcut("esc")
        check("Esc in the filter: emptied, the meadow has the keyboard", window.firstResponder === meadow && tray.filter.isEmpty)
        // ⌘↩ while typing in the filter: Done, as everywhere in the editor.
        suite.shortcut("cmd+f")
        suite.typeKeys("oak")
        suite.shortcut("cmd+return")
        let left = await PerfWait.until(2000) { !self.controller.meadowEditing }
        check("⌘↩ in the filter is Done", left != nil)
        await enter()
    }

    // MARK: Reduce Motion and Increase Contrast

    private func motionAndContrast() async {
        Look.Motion.debugReducesMotion = true
        defer { Look.Motion.debugReducesMotion = false }
        let before = count
        suite.shortcut("1")
        await pressTray("tray.item.tree.young")
        meadow.window?.makeFirstResponder(meadow)
        suite.shortcut("return")
        check("with Reduce Motion a placed thing is simply there (nothing settles)", count == before + 1 && !editor.debugSettling)
        Look.debugIncreasesContrast = true
        editor.updateMarks()
        check("with Increase Contrast the editor's marks are drawn strong", meadow.editMarks.highContrast)
        await picture("contrast-chosen")
        Look.debugIncreasesContrast = false
        editor.updateMarks()
        if count > before { suite.shortcut("cmd+z") }
        editor.debugChoose([])
    }

    // MARK: Help

    private func helpTable() {
        let rows = HelpEditorKeys.rows
        check("Help's table of the editor's keys has a line for every key KeyTable gives it", HelpEditorKeys.unsaid.isEmpty, "\(HelpEditorKeys.unsaid.map(\.command))")
        check("…its own keys and the menus' it uses: ⌃⌘E, C, ⌘↩, ⌥⌘T, the arrows on one line",
              ["⌃⌘E", "C", "⌘↩", "⌥⌘T"].allSatisfy { key in rows.contains { $0.keys.split(separator: " ").contains(Substring(key)) } }
                  && rows.contains { $0.keys.split(separator: " ").count == 4 && $0.keys.contains("←") },
              "\(rows.map(\.keys))")
        var found: [String: [String]] = [:]
        for query in ["fence", "import", "shortcuts"] {
            HelpSearch.shared.searchForItems(withSearch: query, resultLimit: 5) { items in found[query] = items.compactMap { $0 as? String } }
        }
        // The editor's Help pages as the Help window lays them out, light and dark (drawn here, never shown).
        for dark in [false, true] {
            let page = NSHostingView(rootView: VStack(alignment: .leading, spacing: 24) { HelpMeadowEditorSections() }
                .padding(28).frame(width: 600, alignment: .leading).background(Color(nsColor: .windowBackgroundColor)))
            page.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            page.frame = NSRect(origin: .zero, size: page.fittingSize)
            page.layoutSubtreeIfNeeded()
            if let rep = page.bitmapImageRepForCachingDisplay(in: page.bounds) {
                page.cacheDisplay(in: page.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: pictures.appendingPathComponent("editor-help-\(dark ? "dark" : "light").png"))
            }
        }
        check("the Help menu's search finds the editor's topics", found["fence"] == [HelpTopic.placing.rawValue] && found["import"] == [HelpTopic.meadows.rawValue]
              && found["shortcuts"] == [HelpTopic.editorKeys.rawValue], "\(found)")
    }
}
#endif
