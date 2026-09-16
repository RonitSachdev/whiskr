#if DEBUG
import AppKit
import MeadowFile
@_spi(Diagnostics) import MeadowScene
import WhiskrKit
import WhiskrMeadow

/// `--perf-flows library` (`make perf`'s checks): My Meadows and meadow files (docs/DESIGN.md, "My Meadows" and
/// "The meadow file"), as a person goes through them. Every panel is the harness's stand-in (`PanelStandIn`) and
/// the Trash and the Finder are the run's own (`OutsideStandIn`): nothing is shown, and every file written stays in
/// the run's folder.
///
/// - Settings › Meadow's cards: the Default first, yours after, each drawn by the scene; a click shows one.
/// - New Meadow from the Default and empty; Rename in place (typed into the card's field, trimmed and made plain
///   text, a name taken given " 2"); Duplicate; Show in Finder; Move to Trash, asking first and naming it.
/// - Export…, Share… and a card dragged out: the file is the versioned, sorted-key JSON, read back whole, and a
///   scan finds no user name, machine name, path, date or workspace name in it; Export Picture… writes a picture.
/// - Importing every kind of file through the sheet (a meadow of today's catalog, one of a newer minor format, one
///   of a newer catalog, a newer major one, a damaged one, one with too many things, one too large), by File ›
///   Import Meadow…, by the Finder's open (`application(_:open:)`, the Dock's too) and dropped on the meadow: what
///   the sheet says of each, Add, Add and Use, Cancel, a name taken getting " 2", byte for byte, never over another.
/// - Things from a newer Whiskr in the editor: shown as parcels, explained, moved and taken away, and kept whole.
/// - Changes on disk by something else: a meadow added, the one shown changed (read again), changed while edited
///   (Keep Mine and Reload, each keeping the other side), and removed (the Default shown; while edited, Save Again).
/// - Pictures: My Meadows in whiskr-light, whiskr-dark and graphite (long and Japanese names among the cards), the
///   import sheet's kinds, wide and narrow, the editor's note and parcels; with `--library-phase japanese` (a run
///   in Japanese) the same pictures only.
extension PerfSuite {
    func libraryCheck() async {
        let flow = LibraryFlow(suite: self)
        if DebugScenario.value("--library-phase") == "japanese" { return await flow.japanese() }
        await flow.run()
    }
}

@MainActor
final class LibraryFlow {
    let suite: PerfSuite
    var controller: MainWindowController { suite.controller }
    var window: NSWindow { suite.window }
    var meadow: MeadowView { controller.navigator.meadow }
    var editor: EditModeController { controller.meadowEditor }
    let library = MeadowLibrary.shared
    let importer = MeadowImport.shared
    let previews = MeadowPreviews.shared
    let scratch: URL
    let pictures: URL
    let fixtures: URL
    private var eventNumber = 50_000

    init(suite: PerfSuite) {
        self.suite = suite
        scratch = URL(fileURLWithPath: suite.folder("library"), isDirectory: true)
        pictures = URL(fileURLWithPath: DebugScenario.value("--library-pictures") ?? suite.folder("library-pictures"), isDirectory: true)
        fixtures = URL(fileURLWithPath: DebugScenario.value("--meadow-fixtures") ?? "", isDirectory: true)
        try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
    }

    func check(_ name: String, _ passed: Bool, _ detail: String = "") { suite.check("library: \(name)", passed, detail) }

    func run() async {
        window.setContentSize(NSSize(width: 1440, height: 900))
        guard setUp() else { return }
        await cards()
        await making()
        await renaming()
        await sending()
        await importing()
        await parcels()
        await changesOnDisk()
        await trash()
        await lookPictures()
        tearDown()
    }

    /// The Japanese run: the pictures alone, with meadows of every kind to show.
    func japanese() async {
        window.setContentSize(NSSize(width: 1440, height: 900))
        guard setUp() else { return }
        _ = library.newMeadow(fromDefault: true)
        await leaveEditing()
        _ = try? library.rename(library.active ?? "", to: "朝の野原とりんごの木")
        await addFixture("import-newer-catalog.whiskrmeadow", use: false)
        await lookPictures(prefix: "ja-")
        tearDown()
    }

    // MARK: Setting up

    private var exports: URL { scratch.appendingPathComponent("Exports", isDirectory: true) }
    private var trashFolder: URL { scratch.appendingPathComponent("Trash", isDirectory: true) }
    /// Workspaces' folder names, which no file sent may hold.
    private var workspaceNames: [String] = []

    private func setUp() -> Bool {
        for folder in [exports, trashFolder] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        PanelStandIn.install(exports: exports)
        OutsideStandIn.install(trash: trashFolder)
        KeyWindowStandIn.install()
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("import-newer-catalog.whiskrmeadow").path) else {
            check("the meadow fixtures are found (--meadow-fixtures)", false, fixtures.path)
            return false
        }
        // A workspace, so a name of one is there to be leaked (and must not be).
        let pane = suite.workbench.newWorkspace(folder: suite.folder("orchard-workspace-\(UUID().uuidString.prefix(6))"))
        workspaceNames = suite.workbench.workspaces.map(\.name) + [URL(fileURLWithPath: pane.folder).lastPathComponent]
        check("set up: the Default shown, no meadow of yours yet", library.active == nil && library.files.isEmpty, "\(library.files)")
        return true
    }

    private func tearDown() {
        PanelStandIn.uninstall()
        OutsideStandIn.uninstall()
        SettingsWindowController.shared.window?.orderOut(nil)
    }

    // MARK: The cards

    private var settingsWindow: NSWindow? { SettingsWindowController.shared.window }

    private func openSettings(height: CGFloat = 1100) async -> NSWindow? {
        let settings = SettingsWindowController.shared
        settings.show()
        guard let window = settings.window, let tabs = window.contentViewController as? SettingsTabs else { return nil }
        tabs.select(pane: "meadow")
        let pane = tabs.tabViewItems.first { ($0.identifier as? String) == "meadow" }?.viewController
        pane?.preferredContentSize = NSSize(width: 720, height: height)
        window.setContentSize(NSSize(width: 720, height: height))
        await PerfWait.sleep(500)
        _ = await PerfWait.until(4000) { self.previews.debugWaiting == 0 }
        await PerfWait.sleep(300)
        return window
    }

    /// The cards' anchors in Settings, by file ("" for the Default), in the order they are laid out.
    private func cardAnchors(in window: NSWindow) -> [(file: String, view: NSView)] {
        var found: [(String, NSView)] = []
        func walk(_ view: NSView) {
            if let id = view.identifier?.rawValue, id.hasPrefix(MeadowCardAnchor.prefix), !view.isHiddenOrHasHiddenAncestor {
                found.append((String(id.dropFirst(MeadowCardAnchor.prefix.count)), view))
            }
            view.subviews.forEach(walk)
        }
        if let root = window.contentView?.superview { walk(root) }
        // Reading order: rows from the top, then left to right.
        return found.sorted { a, b in
            let ra = a.1.convert(a.1.bounds, to: nil), rb = b.1.convert(b.1.bounds, to: nil)
            return abs(ra.maxY - rb.maxY) > 4 ? ra.maxY > rb.maxY : ra.minX < rb.minX
        }
    }

    /// A click on a card's picture, delivered to the Settings window as the window delivers one.
    private func clickCard(_ file: String?, in window: NSWindow) async {
        guard let anchor = cardAnchors(in: window).first(where: { $0.file == (file ?? "") })?.view else { return check("a card for \(file ?? "the Default")", false) }
        let rect = anchor.convert(anchor.bounds, to: nil)
        // The picture fills the card's top.
        await click(NSPoint(x: rect.midX, y: rect.maxY - rect.width * 10 / 16 / 2), in: window)
    }

    /// A click: its release queued before the press, so whatever the press begins (SwiftUI's own tracking, which
    /// waits to tell a click from a drag) ends with it, as a person's click does.
    private func click(_ point: NSPoint, in window: NSWindow) async {
        PointerStandIn.location = point
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            eventNumber += 1
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        QueuedEvents.post(up)
        NSApp.sendEvent(down)
        await PerfWait.sleep(400)
    }

    private func cards() async {
        _ = library.newMeadow(fromDefault: true)
        await leaveEditing()
        guard let settings = await openSettings() else { return check("Settings › Meadow opens", false) }
        let anchors = cardAnchors(in: settings)
        check("Settings › Meadow: a card for the Default first, then each of yours", anchors.map(\.file) == [""] + library.files, "\(anchors.map(\.file))")
        let drawn = await PerfWait.until(6000) { self.previews.picture(nil) != nil && self.library.files.allSatisfy { self.previews.picture($0) != nil } }
        check("each card's picture is drawn by the scene from the meadow (the Default's and yours)", drawn != nil)
        if let picture = previews.picture(nil) {
            check("a card's picture is a meadow: sky above, grass below, not one flat colour", Self.looksLikeMeadow(picture), Self.describe(picture))
        }
        // AppKit drops the first click a window ever gets in a run like this: one on nothing takes its place.
        await click(NSPoint(x: 8, y: 8), in: settings)
        // A click on the Default's card is Revert to Default; on yours, Use.
        await clickCard(nil, in: settings)
        let hit = cardAnchors(in: settings).first { $0.file == "" }.map { anchor -> String in
            let rect = anchor.view.convert(anchor.view.bounds, to: nil)
            let view = settings.contentView?.superview?.hitTest(NSPoint(x: rect.midX, y: rect.maxY - 40))
            return "rect \(rect), hit \(view.map { String(describing: type(of: $0)) } ?? "none"), visible \(settings.isVisible), key \(settings.isKeyWindow)"
        } ?? "no anchor"
        check("a click on the Default's card shows the Default (Revert to Default, a step)", library.active == nil && library.undoManager.undoActionName == String(localized: "Revert to Default"),
              "active \(library.active ?? "Default"), \(hit)")
        let mine = library.files.first ?? ""
        await clickCard(mine, in: settings)
        check("a click on your meadow's card shows it", library.active == mine, "active \(library.active ?? "Default")")
    }

    // MARK: New, rename, duplicate

    private func leaveEditing() async {
        if controller.meadowEditing { editor.leave() }
        _ = await PerfWait.until(2000) { !self.controller.meadowEditing }
        await PerfWait.sleep(300)
    }

    private func making() async {
        let before = library.files
        MeadowLibraryActions.newMeadow(fromDefault: false)
        _ = await PerfWait.until(2000) { self.controller.meadowEditing }
        let empty = library.active
        check("New Meadow › Empty: a meadow of its own with nothing in it, shown and being edited",
              empty.map { !before.contains($0) } == true && library.session.document.entries.isEmpty && controller.meadowEditing && library.files.count == before.count + 1,
              "active \(empty ?? "Default"), files \(library.files)")
        await leaveEditing()
        let duplicated = library.duplicate(library.active)
        let copy = duplicated.flatMap { try? library.folder.read($0).document }
        check("Duplicate: the same meadow beside it under the next free name", duplicated == "My Meadow 3.whiskrmeadow" && copy?.entries == library.session.document.entries,
              "\(duplicated ?? "none"), files \(library.files)")
        let defaultCopy = library.duplicate(nil)
        check("Duplicate of the Default: a meadow of yours with the Default's things", defaultCopy.flatMap { try? library.folder.read($0).document.entries } == MeadowDocument.standard.entries,
              defaultCopy ?? "none")
        MeadowLibraryActions.reveal(library.active)
        let revealed = OutsideStandIn.unexpected.contains { $0.hasPrefix("Finder") && $0.contains(library.active ?? "?") }
        OutsideStandIn.unexpected.removeAll { $0.hasPrefix("Finder") }
        check("Show in Finder shows the meadow's file", revealed)
    }

    private func renaming() async {
        // In place, as typed: the editor's Rename… opens My Meadows with the name ready to type over.
        library.use("My Meadow 2.whiskrmeadow")
        editor.enter()
        _ = await PerfWait.until(2000) { self.controller.meadowEditing }
        editor.showLibrary(renaming: library.active)
        guard let sheet = await PerfWait.until(2000, { self.window.attachedSheet != nil }).flatMap({ _ in window.attachedSheet }) else {
            return check("Rename…: My Meadows opens over the window", false)
        }
        await PerfWait.sleep(500)
        let field = await PerfWait.until(2000) { sheet.firstResponder is NSTextView }
        check("Rename…: the meadow's name is ready to type over in its card", field != nil, "\(String(describing: sheet.firstResponder.map { type(of: $0) }))")
        if let editorField = sheet.firstResponder as? NSTextView {
            editorField.selectAll(nil)
            editorField.insertText("  Morning\u{202E} Orchard\u{0007}  ", replacementRange: editorField.selectedRange())
            await PerfWait.sleep(200)
            key("\r", code: 36, to: sheet)
        }
        let renamed = await PerfWait.until(2000) { self.library.active == "Morning Orchard.whiskrmeadow" }
        check("typed and Return: renamed, trimmed and made plain text; the file renamed, the name inside it too, still shown",
              renamed != nil && library.files.contains("Morning Orchard.whiskrmeadow") && !library.files.contains("My Meadow 2.whiskrmeadow")
                  && WorldStore.shared.settings.meadow == "Morning Orchard.whiskrmeadow" && (try? library.folder.read("Morning Orchard.whiskrmeadow").document.name) == "Morning Orchard",
              "active \(library.active ?? "Default"), files \(library.files)")
        await picture(sheetOf: window, name: "library-sheet")
        key("\u{1b}", code: 53, to: sheet)
        if window.attachedSheet != nil { window.endSheet(sheet) }
        await leaveEditing()
        // A steps made before a rename still finds the meadow.
        let renamedTo = try? library.rename("My Meadow 3.whiskrmeadow", to: "morning orchard")
        check("a name another meadow has takes the next free one (“Morning Orchard 2”)", renamedTo == "morning orchard 2.whiskrmeadow", renamedTo ?? "failed")
        check("an empty name, or one too long, is refused with why", MeadowLibrary.renameProblem(" \u{200B} ") != nil && MeadowLibrary.renameProblem(String(repeating: "x", count: 61)) != nil)
        _ = try? library.rename("My Meadow.whiskrmeadow", to: "A Meadow With A Name Long Enough To Run Past Its Card")
    }

    // MARK: Sending

    private func sending() async {
        let file = library.active
        PanelStandIn.author = ""
        MeadowLibraryActions.export(file, over: window)
        let exported = await PerfWait.until(2000) { PanelStandIn.exported != nil }.flatMap { _ in PanelStandIn.exported }
        guard let exported, let data = try? Data(contentsOf: exported) else { return check("Export… writes the meadow where the save panel says", false) }
        let reading = try? MeadowDocument.read(data)
        check("Export…: a meadow file read back whole, named as the meadow, in the newest format",
              reading?.document.entries == library.session.document.entries && reading?.document.name == library.activeName
                  && reading?.document.readFrom?.formatMajor == MeadowFormat.major && exported.lastPathComponent == "\(library.activeName).whiskrmeadow",
              exported.lastPathComponent)
        scan(data, "Export…")
        // Its keys sorted, as every Whiskr writes one: the same meadow, the same bytes.
        check("Export…: the same meadow is the same bytes (sorted keys, the file's own form)", (try? library.exportData(file)) == data)
        PanelStandIn.author = "Hana"
        PanelStandIn.description = "Apples and a\u{202E} reading nook."
        PanelStandIn.exported = nil
        MeadowLibraryActions.export(file, over: window)
        _ = await PerfWait.until(2000) { PanelStandIn.exported != nil }
        let signed = PanelStandIn.exported.flatMap { try? MeadowDocument.read(Data(contentsOf: $0)).document }
        check("Export… with a name typed for the author: that name, and the description made plain text, and nothing else of you",
              signed?.author == "Hana" && signed?.description == "Apples and a reading nook.", "\(signed?.author ?? "-") / \(signed?.description ?? "-")")
        PanelStandIn.author = ""
        PanelStandIn.description = ""

        // Share…: the system's picker with the file (the stand-in records it).
        guard let content = window.contentView else { return }
        MeadowLibraryActions.share(file, from: content, rect: NSRect(x: 10, y: 10, width: 10, height: 10))
        let shared = PanelStandIn.shared.last
        let sharedData = shared.flatMap { try? Data(contentsOf: $0) }
        check("Share…: the picker gets the meadow as a file, made in the run's own folder", sharedData.map { (try? MeadowDocument.read($0)) != nil } == true
                  && shared?.path.hasPrefix(AppPlaces.supportFolder.path) == true, shared?.path ?? "nothing shared")
        if let sharedData { scan(sharedData, "Share…") }

        // A card dragged out: the file is made when it lands.
        let provider = MeadowLibraryActions.dragItem(file)
        let dragged: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: MeadowFormat.typeIdentifier) { url, _ in
                // The file is gone once this returns: it is copied first.
                let copy = url.flatMap { url -> URL? in
                    let to = FileManager.default.temporaryDirectory.appendingPathComponent("drag-\(UUID().uuidString).whiskrmeadow")
                    return (try? FileManager.default.copyItem(at: url, to: to)) == nil ? nil : to
                }
                continuation.resume(returning: copy)
            }
        }
        let draggedData = dragged.flatMap { try? Data(contentsOf: $0) }
        if let dragged { try? FileManager.default.removeItem(at: dragged) }
        check("a card dragged out carries the meadow as a file, named as the meadow", draggedData.map { (try? MeadowDocument.read($0)) != nil } == true
                  && provider.suggestedName == library.activeName && provider.registeredTypeIdentifiers.contains(MeadowFormat.typeIdentifier))
        if let draggedData { scan(draggedData, "a card dragged out") }

        // Export Picture….
        MeadowLibraryActions.exportPicture(file, over: window)
        let png = await PerfWait.until(4000) { PanelStandIn.picture.map { FileManager.default.fileExists(atPath: $0.path) } == true }.flatMap { _ in PanelStandIn.picture }
        let image = png.flatMap { NSImage(contentsOf: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        check("Export Picture…: a picture of the meadow, 2400 × 1500", image?.width == 2400 && image?.height == 1500 && image.map(Self.looksLikeMeadow) == true,
              image.map(Self.describe) ?? "none")
    }

    /// A file sent holds nothing of this Mac or person: no user or machine name, no path, no date, no workspace.
    private func scan(_ data: Data, _ what: String) {
        let text = String(decoding: data, as: UTF8.self)
        let lower = text.lowercased()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var needles: [String] = [NSUserName(), home, AppPlaces.supportFolder.path, "/Users/", "/private/", "/var/", "file:", "http", "~/"]
        needles += NSFullUserName().split(separator: " ").map(String.init).filter { $0.count >= 3 }
        needles += [ProcessInfo.processInfo.hostName, Host.current().localizedName ?? ""].flatMap { name in
            [name, name.replacingOccurrences(of: ".local", with: "")]
        }.filter { $0.count >= 3 }
        needles += workspaceNames.filter { $0.count >= 3 }
        let found = needles.filter { !$0.isEmpty && lower.contains($0.lowercased()) }
        // Dates and times, as any formatter writes them.
        let year = Calendar.current.component(.year, from: Date())
        let dated = text.range(of: #"\d{4}-\d{2}-\d{2}|\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil || text.contains("\(year)")
        // Only the format's own keys at the top.
        let keys = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).map { Set($0.keys) } ?? []
        let allowed: Set<String> = ["whiskrMeadow", "formatMinor", "writtenBy", "catalog", "needsCatalog", "base", "name", "author", "description", "items", "ground"]
        check("\(what): the file holds no user name, machine name, path, date or workspace name, and only the format's keys",
              found.isEmpty && !dated && keys.isSubset(of: allowed) && !keys.isEmpty, "found \(found), dated \(dated), keys \(keys.sorted())")
    }

    // MARK: Importing

    private func fixture(_ name: String) -> URL { fixtures.appendingPathComponent(name) }

    /// The sheet over the main window, and what it shows.
    private func sheetShown() async -> MeadowImport.Shown? {
        _ = await PerfWait.until(2000) { self.window.attachedSheet != nil && self.importer.shown != nil }
        await PerfWait.sleep(250)
        return importer.shown
    }

    private func sheetClosed() async -> Bool {
        await PerfWait.until(2000) { self.window.attachedSheet == nil && self.importer.shown == nil } != nil
    }

    private func addFixture(_ name: String, use: Bool) async {
        importer.open([fixture(name)], over: window)
        _ = await sheetShown()
        importer.add(use: use)
        _ = await sheetClosed()
    }

    private func importing() async {
        // File › Import Meadow…: the open panel (the stand-in), then the sheet.
        PanelStandIn.imports = [fixture("v1-catalog1-ground.whiskrmeadow")]
        NSApp.sendAction(#selector(AppDelegate.importMeadow(_:)), to: nil, from: nil)
        guard case .candidate(let plain)? = await sheetShown() else { return check("File › Import Meadow…: the sheet shows the meadow", false, "\(String(describing: importer.shown))") }
        let drawn = await PerfWait.until(4000) { self.previews.picture(importing: plain.reading.document, digest: plain.digest) != nil }
        let things = plain.summary.things
        check("the sheet: the meadow drawn from its data, its name, what it holds (paths, lawn and soil), the Whiskr that made it, nothing to warn of",
              drawn != nil && plain.summary.paints == ["ground.path", "ground.lawn", "ground.soil"] && plain.summary.writtenBy != nil && plain.undrawn == 0
                  && !plain.summary.newerFormat && MeadowFileWords.contents(things: things, paints: plain.summary.paints).hasPrefix("\(things) things · "),
              MeadowFileWords.contents(things: things, paints: plain.summary.paints))
        await picture(sheetOf: window, name: "import-plain")
        // Return: Add and Use.
        if let sheet = window.attachedSheet { key("\r", code: 36, to: sheet) }
        _ = await sheetClosed()
        let plainName = importer.lastAdded?.file
        check("Return in the sheet is Add and Use: added as it came, byte for byte, and shown",
              plainName.map { (try? library.folder.data($0)) == (try? Data(contentsOf: fixture("v1-catalog1-ground.whiskrmeadow"))) && library.active == $0 } == true,
              "\(plainName ?? "nothing") active \(library.active ?? "Default")")

        // The same file again (the Finder's open, as a double-click or the Dock icon brings it): its name is taken.
        NSApp.delegate?.application?(NSApp, open: [fixture("v1-catalog1-ground.whiskrmeadow")])
        guard case .candidate(let again)? = await sheetShown() else { return check("the Finder's open: the sheet", false) }
        let taken = MeadowLibraryFolder.name(of: again.fileName)
        check("a name taken: the sheet says it is added as “… 2”, and never over the other", plainName.map { taken == MeadowLibraryFolder.name(of: $0) + " 2" } == true, taken)
        await picture(sheetOf: window, name: "import-name-taken")
        importer.add(use: false)
        _ = await sheetClosed()
        check("Add to My Meadows: added beside the other, the meadow shown unchanged", importer.lastAdded?.file == "\(taken).whiskrmeadow" && library.active == plainName
                  && library.files.contains("\(taken).whiskrmeadow"))

        // A newer catalog: six things this Whiskr cannot draw, kept, counted.
        importer.open([fixture("import-newer-catalog.whiskrmeadow")], over: window)
        guard case .candidate(let newer)? = await sheetShown() else { return check("a newer catalog's meadow opens in the sheet", false) }
        check("a newer catalog: “6 things can't be shown here”, by Hana, with its line and paths and lawn",
              newer.undrawn == 6 && newer.summary.needsNewerCatalog && newer.reading.document.author == "Hana"
                  && MeadowFileWords.byline(author: "Hana", writtenBy: newer.summary.writtenBy) == "by Hana · Made with Whiskr 1.8.2"
                  && newer.summary.paints == ["ground.path", "ground.lawn"], "\(newer.undrawn)")
        await picture(sheetOf: window, name: "import-newer-catalog")
        importer.add(use: true)
        _ = await sheetClosed()
        orchard = importer.lastAdded?.file

        // A newer minor format: opened, what it adds kept and written back.
        importer.open([fixture("import-newer-minor.whiskrmeadow")], over: window)
        guard case .candidate(let minor)? = await sheetShown() else { return check("a newer minor format's meadow opens in the sheet", false) }
        check("a newer minor format: opened, with the note that what it adds is kept", minor.summary.newerFormat && minor.undrawn == 0)
        await picture(sheetOf: window, name: "import-newer-minor")
        importer.add(use: false)
        _ = await sheetClosed()
        if let file = importer.lastAdded?.file {
            library.use(file)
            let daisy = library.session.document.entries.indices.first { library.session.item(library.session.ids[$0])?.asset == "flower.daisy" }.map { library.session.ids[$0] }
            if let daisy { library.edit(MeadowWords.move(["flower.daisy"])) { $0.move([daisy], by: SIMD2(0.5, 0)) } }
            library.save(wait: true)
            let back = try? library.folder.read(file)
            check("edited and saved: its newer section and the stone's newer detail written back, the file still of that minor format",
                  back?.document.unknownSections["season"] != nil && back?.document.readFrom?.formatMinor == 2
                      && back?.document.items.first { $0.asset == "stone.mossy" }?.unknownFields["moss"] == .string("thick"))
        }

        // Refused, each with why: a newer major, a damaged file, too many things, too large.
        let large = scratch.appendingPathComponent("Large Meadow.whiskrmeadow")
        try? Data(repeating: UInt8(ascii: " "), count: MeadowFormat.maxBytes + 10).write(to: large)
        let refusals: [(URL, String, (String, String) -> Bool)] = [
            (fixture("import-newer-major.whiskrmeadow"), "newer-major", { title, message in title.contains("needs a newer Whiskr") && message.contains("3.2.0") }),
            (fixture("import-damaged.whiskrmeadow"), "damaged", { _, message in message.contains("damaged") && message.contains("part way") }),
            (fixture("import-too-many.whiskrmeadow"), "too-many", { _, message in message.contains("5001") || message.contains("5,001") }),
            (large, "too-large", { _, message in message.contains("too large") }),
        ]
        let filesBefore = library.files
        // Several at once: one after another.
        importer.open(refusals.map(\.0), over: window)
        for (url, name, fits) in refusals {
            guard case .refused(let title, let message)? = await sheetShown() else { check("\(name): refused in the sheet", false); continue }
            check("\(name) (\(url.lastPathComponent)): refused, saying why and what to do", fits(title, message), "\(title) / \(message)")
            await picture(sheetOf: window, name: "import-\(name)")
            if let sheet = window.attachedSheet { key("\r", code: 36, to: sheet) }
            await PerfWait.sleep(300)
        }
        _ = await sheetClosed()
        check("nothing refused is added, and nothing else changes", library.files == filesBefore, "\(library.files)")

        // Cancel (Esc) adds nothing.
        importer.open([fixture("v1-catalog1-ground.whiskrmeadow")], over: window)
        _ = await sheetShown()
        if let sheet = window.attachedSheet { key("\u{1b}", code: 53, to: sheet) }
        check("Esc in the sheet is Cancel: nothing added", await sheetClosed() && library.files == filesBefore)

        // Dropped on the meadow.
        guard let drop = controller.navigator.view as? DropView else { return check("the meadow takes drops", false) }
        let dragging = FakeDragging(urls: [fixture("import-newer-minor.whiskrmeadow")], window: window)
        let operation = drop.draggingEntered(dragging)
        let taken2 = drop.performDragOperation(dragging)
        guard case .candidate(let dropped)? = await sheetShown() else { return check("a meadow file dropped on the meadow opens in the sheet", false) }
        check("a meadow file dropped on the meadow: a copy, through the sheet", operation == .copy && taken2 && dropped.name == "Morning Meadow")
        importer.dismiss()
        _ = await sheetClosed()
    }

    /// The newer catalog's meadow, once imported.
    private var orchard: String?

    // MARK: Things from a newer Whiskr

    private func parcels() async {
        guard let orchard else { return check("the newer catalog's meadow to edit", false) }
        library.use(orchard)
        editor.enter()
        _ = await PerfWait.until(2000) { self.controller.meadowEditing }
        await PerfWait.sleep(800)
        let parcels = meadow.scenery.things.filter { $0.id == MeadowScenery.parcel }
        check("editing: each thing from a newer Whiskr shows as a parcel where it stands", parcels.count == 6, "\(parcels.count)")
        let note = await PerfWait.until(2000) { self.editor.noticeModel.text == MeadowFileWords.undrawn(6) && !self.editor.noticeHost.isHidden }
        check("editing: the quiet note at the top says 6 things can't be shown here, and that they are kept", note != nil, editor.noticeModel.text ?? "no note")
        // Chosen, moved by the keys, taken away, undone: kept whole.
        let session = library.session
        guard let parcel = session.drawnIDs.first(where: session.isParcel), let spot = session.spot(parcel) else { return check("a parcel to choose", false) }
        if let at = meadow.viewPoint(ofGround: SIMD2(Float(spot.x), Float(spot.z))) {
            // Pointed at: what it is, by it.
            let location = meadow.convert(NSPoint(x: at.x, y: at.y + 6), to: nil)
            PointerStandIn.location = location
            if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: suite.nextEventNumber(), clickCount: 0, pressure: 0) {
                meadow.mouseMoved(with: moved)
            }
            await PerfWait.sleep(150)
        }
        check("pointed at, a parcel says what it is", editor.debugReason == nil && editor.debugParcelNoted == parcel)
        await picture(name: "parcels")
        editor.debugChoose([parcel])
        await PerfWait.sleep(200)
        check("chosen, its bar offers only Delete and More (it can be moved or taken away, nothing more)", editor.barModel.onlyMoves)
        suite.shortcut("right")
        await PerfWait.sleep(200)
        let moved = library.session.parcel(parcel)
        check("the arrow keys move it; everything else in it as it was", moved?.at.map { abs($0.x - spot.x) > 0.1 || abs($0.z - spot.z) > 0.1 } == true
                  && moved?.fields["radius"] == .number(6.5), "\(String(describing: moved?.at))")
        suite.shortcut("r")
        await PerfWait.sleep(200)
        check("R does not turn it, and says why", editor.debugReason == MeadowWords.parcelsOnlyMove && library.session.parcel(parcel) == moved)
        suite.shortcut("delete")
        await PerfWait.sleep(200)
        check("⌫ takes it away", library.session.document.parcels.count == 5)
        suite.shortcut("cmd+z")
        await PerfWait.sleep(200)
        check("⌘Z puts it back as it was", library.session.document.parcels.count == 6 && library.session.parcel(parcel) == moved)
        await leaveEditing()
        library.save(wait: true)
        let saved = try? library.folder.read(orchard)
        check("saved: the six kept whole, the meadow still saying it needs catalog 3", saved?.document.parcels.count == 6 && saved?.document.readFrom?.needsCatalog == 3
                  && saved?.document.parcels.contains { $0.fields["radius"] == .number(6.5) && $0.fields["params"] == .object(["lilies": .number(3)]) } == true)
        check("out of editing, no parcel is drawn", !meadow.scenery.things.contains { $0.id == MeadowScenery.parcel })
    }

    // MARK: Changes on disk

    private func changesOnDisk() async {
        // A meadow added in the Finder: a card for it.
        let added = MeadowDocument(name: "From The Finder", entries: [.item(MeadowFile.MeadowItem(asset: "tree.oak", placement: .at(MeadowPoint(10, 10)), seed: 4))])
        try? added.fileData(writtenBy: "1.0.0").write(to: library.folder.fileURL("From The Finder.whiskrmeadow"), options: .atomic)
        let seen = await PerfWait.until(3000) { self.library.files.contains("From The Finder.whiskrmeadow") }
        check("a meadow put in the folder by something else is noticed (its card shows)", seen != nil)

        // The meadow shown changed by something else, not editing: read again.
        guard let file = library.active else { return check("a meadow shown to change", false) }
        let pictureBefore = previews.key(file, .card)
        var changed = library.session.document
        changed.entries.append(.item(MeadowFile.MeadowItem(asset: "stone.mossy", placement: .at(MeadowPoint(-30, 40)))))
        writeOnDisk(changed, as: file)
        let reloaded = await PerfWait.until(3000) { self.library.session.document.entries.count == changed.entries.count }
        check("the meadow shown, changed on disk while not edited, is read again and drawn", reloaded != nil && meadow.scenery == library.scenery && !library.undoManager.canUndo,
              "\(library.session.document.entries.count) of \(changed.entries.count)")
        _ = previews.picture(file)
        let redrawn = await PerfWait.until(3000) { self.previews.key(file, .card) != pictureBefore && self.previews.picture(file) != nil }
        check("its card's picture is drawn again", redrawn != nil)

        // Changed while edited: asked; Keep Mine keeps yours on disk and the disk's as a meadow of its own.
        editor.enter()
        _ = await PerfWait.until(2000) { self.controller.meadowEditing }
        let mine = library.session.document
        var theirs = mine
        theirs.entries.removeLast()
        writeOnDisk(theirs, as: file)
        let asked = await PerfWait.until(3000) { self.library.conflict == .changed(file) && self.editor.noticeModel.choices.count == 2 }
        check("changed on disk while edited: asked, Reload or Keep Mine, nothing written meanwhile", asked != nil, editor.noticeModel.text ?? "no note")
        await picture(name: "changed-on-disk")
        let filesBefore = Set(library.files)
        editor.noticeChosen("keep")
        library.waitForSaves()
        let kept = Set(library.files).subtracting(filesBefore).first
        check("Keep Mine: yours written over the file, the disk's kept as a meadow of its own",
              (try? library.folder.read(file).document.entries) == mine.entries && kept.flatMap { try? library.folder.read($0).document.entries } == theirs.entries,
              "kept \(kept ?? "nothing")")
        // Again, and Reload: the disk's shown, yours kept.
        writeOnDisk(theirs, as: file)
        _ = await PerfWait.until(3000) { self.library.conflict == .changed(file) }
        let before = Set(library.files)
        editor.noticeChosen("reload")
        let yours = Set(library.files).subtracting(before).first
        check("Reload: the disk's shown, yours kept as a meadow of its own",
              library.session.document.entries == theirs.entries && yours.flatMap { try? library.folder.read($0).document.entries } == mine.entries, "kept \(yours ?? "nothing")")
        // Removed while edited: Save Again.
        try? FileManager.default.removeItem(at: library.folder.fileURL(file))
        let gone = await PerfWait.until(3000) { self.library.conflict == .gone(file) }
        check("removed on disk while edited: asked, Close It or Save Again", gone != nil)
        editor.noticeChosen("keep")
        library.waitForSaves()
        check("Save Again: written back where it was", FileManager.default.fileExists(atPath: library.folder.fileURL(file).path) && library.active == file)
        await leaveEditing()
        editor.enter()
        _ = await PerfWait.until(2000) { self.controller.meadowEditing }
        await PerfWait.sleep(300)
        check("where the other side was kept is said once: not again the next time the meadow is edited",
              library.keptCopy == nil && editor.noticeModel.text?.contains("kept in My Meadows as") != true, editor.noticeModel.text ?? "no note")
        await leaveEditing()
        // Removed while not edited: the Default shown, Settings says why.
        try? FileManager.default.removeItem(at: library.folder.fileURL(file))
        let fallen = await PerfWait.until(3000) { self.library.active == nil }
        check("removed on disk while not edited: the Default shown, and Settings › Meadow says why", fallen != nil && library.removedOnDisk == file)
    }

    /// Writes as a sync tool does: whole, by something else.
    private func writeOnDisk(_ document: MeadowDocument, as file: String) {
        try? document.fileData(writtenBy: "9.9.9").write(to: library.folder.fileURL(file), options: .atomic)
    }

    // MARK: The Trash

    private func trash() async {
        guard let file = library.files.first(where: { $0 != library.active && $0.hasPrefix("From The Finder") }) else { return check("a meadow to put in the Trash", false) }
        PanelStandIn.asked = []
        MeadowLibraryActions.moveToTrash(file, over: settingsWindow)
        let gone = await PerfWait.until(3000) { !self.library.files.contains(file) }
        check("Move to Trash: asked first, naming the meadow; then in the Trash (the run's own), out of My Meadows",
              gone != nil && PanelStandIn.asked.first?.contains("From The Finder") == true && OutsideStandIn.trashed.contains { $0.lastPathComponent == file },
              "\(PanelStandIn.asked)")
        // The one shown: the Default instead.
        if let other = library.files.first(where: { $0.hasPrefix("Garden Paths") }) { library.use(other) }
        guard let shown = library.active else { return check("a meadow shown to put in the Trash", false) }
        PanelStandIn.answer = false
        MeadowLibraryActions.moveToTrash(shown, over: settingsWindow)
        await PerfWait.sleep(300)
        check("Cancel keeps it", library.files.contains(shown) && library.active == shown && PanelStandIn.asked.last?.contains(library.displayName(shown)) == true)
        PanelStandIn.answer = true
        MeadowLibraryActions.moveToTrash(shown, over: settingsWindow)
        _ = await PerfWait.until(3000) { !self.library.files.contains(shown) }
        check("the meadow shown, put in the Trash: the Default shown instead", library.active == nil && !library.files.contains(shown))
        // Back for the pictures.
        orchard = nil
        await addFixture("import-newer-catalog.whiskrmeadow", use: false)
    }

    // MARK: Pictures

    private func lookPictures(prefix: String = "") async {
        let store = ThemeStore.shared
        let before = (store.themeID, store.appearance)
        defer {
            store.themeID = before.0
            store.appearance = before.1
        }
        library.refreshFiles()
        for (name, id, appearance) in [("whiskr-light", BuiltInThemes.defaultID, ThemeStore.Appearance.light), ("whiskr-dark", BuiltInThemes.defaultID, .dark),
                                       ("graphite", "graphite", .dark)] {
            store.themeID = id
            store.appearance = appearance
            await PerfWait.sleep(300)
            if let settings = await openSettings() { await picture(settings, name: "\(prefix)settings-\(name)") }
            for (size, width) in [(NSSize(width: 1440, height: 900), "wide"), (NSSize(width: 900, height: 700), "narrow")] {
                window.setContentSize(size)
                await PerfWait.sleep(300)
                importer.open([fixture("import-newer-catalog.whiskrmeadow")], over: window)
                _ = await sheetShown()
                _ = await PerfWait.until(4000) { self.previews.debugWaiting == 0 }
                await PerfWait.sleep(200)
                await picture(sheetOf: window, name: "\(prefix)import-\(name)-\(width)")
                importer.dismiss()
                _ = await sheetClosed()
                // The editor's note and My Meadows over the window.
                if let file = library.files.first(where: { $0.hasPrefix("Orchard Study") }) { library.use(file) }
                editor.enter()
                _ = await PerfWait.until(2000) { self.controller.meadowEditing }
                await PerfWait.sleep(700)
                await picture(name: "\(prefix)editor-\(name)-\(width)")
                editor.showLibrary()
                _ = await PerfWait.until(2000) { self.window.attachedSheet != nil }
                await PerfWait.sleep(500)
                _ = await PerfWait.until(4000) { self.previews.debugWaiting == 0 }
                await picture(sheetOf: window, name: "\(prefix)library-\(name)-\(width)")
                if let sheet = window.attachedSheet { window.endSheet(sheet) }
                await leaveEditing()
            }
        }
        window.setContentSize(NSSize(width: 1440, height: 900))
        settingsWindow?.orderOut(nil)
    }

    private func picture(name: String) async {
        DebugShell.snapshot(window: controller, workbench: suite.workbench, to: pictures.appendingPathComponent("\(name).png"))
    }

    /// The main window with its sheet drawn where the sheet hangs.
    private func picture(sheetOf parent: NSWindow, name: String) async {
        let url = pictures.appendingPathComponent("\(name).png")
        DebugShell.snapshot(window: controller, workbench: suite.workbench, to: url)
        guard let sheet = parent.attachedSheet, let frame = sheet.contentView?.superview ?? sheet.contentView,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), let base = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let scale = parent.backingScaleFactor
        guard let context = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        // A sheet hangs from the top of the window's content, in its middle.
        let size = sheet.frame.size
        let content = parent.contentLayoutRect
        let x = (content.midX - size.width / 2) * scale, y = (content.maxY - size.height) * scale
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 30 * scale, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        if let image = rep.cgImage { context.draw(image, in: CGRect(x: x, y: y, width: size.width * scale, height: size.height * scale)) }
        context.restoreGState()
        if let image = context.makeImage() { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url) }
    }

    /// A window other than the main one (Settings), as it draws.
    private func picture(_ window: NSWindow, name: String) async {
        guard let frame = window.contentView?.superview else { return }
        frame.layoutSubtreeIfNeeded()
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: pictures.appendingPathComponent("\(name).png"))
    }

    // MARK: Pieces

    private func key(_ characters: String, code: UInt16, to target: NSWindow) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: target.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
            NSApp.sendEvent(event)
        }
    }

    /// A picture of a meadow: bright, blue-ish sky at the top, green below, and more than one colour.
    static func looksLikeMeadow(_ image: CGImage) -> Bool {
        guard let top = sample(image, 0.5, 0.06), let bottom = sample(image, 0.5, 0.85) else { return false }
        return bottom.g > bottom.r && bottom.g > bottom.b && top.r + top.g + top.b > bottom.r + bottom.g + bottom.b
    }

    static func describe(_ image: CGImage) -> String {
        let top = sample(image, 0.5, 0.06), bottom = sample(image, 0.5, 0.85)
        return "\(image.width)×\(image.height) top \(String(describing: top)) bottom \(String(describing: bottom))"
    }

    /// A pixel's colour, at fractions across and down.
    static func sample(_ image: CGImage, _ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int)? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let px = Double(image.width) * x, py = Double(image.height) * (1 - y)
        context.draw(image, in: CGRect(x: -px, y: -py, width: Double(image.width), height: Double(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}

/// The meadow files' panels in a run (`MeadowPanels`): no panel is shown. Export… and Export Picture… write into
/// the run's own folder, with the author and description set here; Import Meadow… opens what is set here; the share
/// picker and the question before the Trash are recorded (the question answered as set here).
@MainActor
enum PanelStandIn {
    static var exports: URL?
    static var author = ""
    static var description = ""
    static var exported: URL?
    static var picture: URL?
    static var imports: [URL] = []
    static var shared: [URL] = []
    static var asked: [String] = []
    static var answer = true
    private static var originals: (export: Any, picture: Any, imports: Any, share: Any, confirm: Any)?

    static func install(exports folder: URL) {
        exports = folder
        guard originals == nil else { return }
        originals = (MeadowPanels.chooseExport, MeadowPanels.choosePicture, MeadowPanels.chooseImports, MeadowPanels.share, MeadowPanels.confirm)
        MeadowPanels.chooseExport = { name, _, _, _, done in
            let url = folder.appendingPathComponent(name)
            exported = url
            done(MeadowPanels.Export(url: url, author: author, description: description))
        }
        MeadowPanels.choosePicture = { name, _, done in
            let url = folder.appendingPathComponent(name)
            picture = url
            done(url)
        }
        MeadowPanels.chooseImports = { _, done in done(imports) }
        MeadowPanels.share = { url, _, _ in shared.append(url) }
        MeadowPanels.confirm = { message, detail, _, _, done in
            asked.append("\(message) \(detail)")
            done(answer)
        }
    }

    static func uninstall() {
        guard let originals else { return }
        if let export = originals.export as? @MainActor (String, String, String, NSWindow?, @escaping @MainActor (MeadowPanels.Export?) -> Void) -> Void { MeadowPanels.chooseExport = export }
        if let picture = originals.picture as? @MainActor (String, NSWindow?, @escaping @MainActor (URL?) -> Void) -> Void { MeadowPanels.choosePicture = picture }
        if let imports = originals.imports as? @MainActor (NSWindow?, @escaping @MainActor ([URL]) -> Void) -> Void { MeadowPanels.chooseImports = imports }
        if let share = originals.share as? @MainActor (URL, NSView, NSRect) -> Void { MeadowPanels.share = share }
        if let confirm = originals.confirm as? @MainActor (String, String, String, NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void { MeadowPanels.confirm = confirm }
        self.originals = nil
    }
}

/// Files dragged onto a view, as the window server hands a drop to it (`DropView`), from a pasteboard of the run's own.
final class FakeDragging: NSObject, NSDraggingInfo {
    private let pasteboard: NSPasteboard
    private let window: NSWindow

    init(urls: [URL], window: NSWindow) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("app.whiskr.library-flow.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic] }
    var draggingLocation: NSPoint { NSPoint(x: window.frame.width / 2, y: window.frame.height / 2) }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
#endif
