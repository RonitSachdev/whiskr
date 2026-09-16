import AppKit
import MeadowFile
import MeadowScene
import Observation
import WhiskrKit
import WhiskrMeadow

/// The meadows (docs/DESIGN.md, "The meadow's scenery" and "My Meadows"): the Default, built in and never
/// changed, and your own, one `.whiskrmeadow` file each in the support folder's `Meadows` (an isolated run's
/// own folder when testing). The one shown is `WorldSettings.meadow`.
///
/// - The first change made while the Default is shown makes "My Meadow", a copy, and shows it, in the same
///   step: undone, the Default is shown again and the copy goes; Revert to Default (choosing the Default)
///   is always there, and your meadow stays.
/// - Every change is saved a second after the last (encoded here, written off the main thread, whole: a
///   temporary file renamed over the old), and at once when editing ends and at quit.
/// - Every edit is a step of one history for the app's session, across leaving and coming back to editing
///   and across meadows (choosing another meadow is a step too, so steps always apply to the meadow shown).
///   A meadow renamed keeps its steps; one moved to the Trash, or changed on disk by something else, ends the
///   history (its steps would no longer fit it).
/// - A meadow chosen that cannot be read at launch is left as it was; the Default is shown, and Settings ›
///   Meadow says so.
/// - The folder is watched (`MeadowFolderWatch`): meadows added, removed or renamed in the Finder or by a sync
///   tool show as they are, and the meadow shown, changed on disk by something else, is read again; while it is
///   being edited the person chooses, and neither side is lost (`MeadowDiskChange`).
/// - Meadows are made new (from the Default or empty), copied, renamed, moved to the Trash and imported here,
///   never one over another.
@MainActor @Observable
final class MeadowLibrary {
    static let shared = MeadowLibrary()

    /// The meadow shown: its file's name, or nil for the Default.
    private(set) var active: String?
    /// The meadow shown, being edited.
    private(set) var session: MeadowEditSession
    /// Your meadows' files, in name order.
    private(set) var files: [String] = []
    /// What each of your meadows' files was when last looked at (a picture of it is kept while this holds).
    private(set) var stamps: [String: MeadowLibraryFolder.Stamp] = [:]
    /// A meadow that could not be read when it was to be shown, kept as it was.
    private(set) var unreadable: String?
    /// The meadow shown was taken out of the folder by something else and the Default is shown instead.
    private(set) var removedOnDisk: String?
    /// The meadow being edited changed on disk (or went), and the person is asked what to keep.
    private(set) var conflict: DiskConflict?
    /// Where the side not chosen was kept, the last time the person answered ("Orchard Study 2"): said while that
    /// meadow is still being edited, and forgotten when editing ends or another meadow is shown.
    var keptCopy: String?
    /// The meadow is being edited (things from a newer Whiskr then show as parcels).
    var isEditing = false {
        didSet {
            session.showsParcels = isEditing
            if !isEditing, conflict != nil { settleConflictOnLeaving() }
        }
    }
    /// One history of edits for the app's session (`MeadowLibrary` registers each step).
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored let folder: MeadowLibraryFolder
    /// After a step is undone or done again: what it changed now, so the editor can choose those things.
    @ObservationIgnored var onStep: ((MeadowChange) -> Void)?

    /// What the person is asked about the meadow being edited: changed on disk by something else, or gone.
    enum DiskConflict: Equatable {
        case changed(String)
        case gone(String)
    }

    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var unsaved = false
    /// The digest of the shown meadow's bytes as last read or written here: another on disk is someone else's.
    @ObservationIgnored private var known: UInt64?
    /// Meadows renamed this session, old file name to new: a step made on one before still finds it.
    @ObservationIgnored private var renamed: [String: String] = [:]
    @ObservationIgnored private var watch: MeadowFolderWatch?
    /// Saves go one after another on a queue of their own, so the last one written is the last one made.
    @ObservationIgnored private let writes = DispatchQueue(label: "app.whiskr.meadow-saves")
    /// How long after the last change a meadow is saved.
    static let saveDelay: TimeInterval = 1

    private init() {
        folder = MeadowLibraryFolder(AppPlaces.supportFolder.appendingPathComponent("Meadows", isDirectory: true))
        session = MeadowEditSession(.standard)
        undoManager.levelsOfUndo = 200
        // One step per gesture, however quickly gestures come (keys held, a script): each is a group of its own.
        undoManager.groupsByEvent = false
        load()
        watch = MeadowFolderWatch(folder: folder.url) { [weak self] in self?.folderChanged() }
        watch?.watch(file: active.map(folder.fileURL))
        // A change missed while the app was away (asleep, a sync while it was closed) is caught as it comes back.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
    }

    /// The meadow `WorldSettings.meadow` names, or the Default.
    func load() {
        refreshFiles()
        unreadable = nil
        guard let file = WorldStore.shared.settings.meadow else { return show(nil, MeadowEditSession(.standard)) }
        if MeadowLibraryFolder.isPlain(file), let data = try? folder.data(file), let reading = try? MeadowDocument.read(data) {
            show(file, MeadowEditSession(reading.document), digest: MeadowLibraryFolder.digest(data))
        } else {
            unreadable = file
            show(nil, MeadowEditSession(.standard))
        }
    }

    private func show(_ file: String?, _ session: MeadowEditSession, digest: UInt64? = nil) {
        active = file
        var shown = session
        shown.showsParcels = isEditing
        self.session = shown
        known = digest
        watch?.watch(file: file.map(folder.fileURL))
    }

    /// What the meadow draws.
    var scenery: MeadowScenery { session.scenery }

    /// A meadow's name as people read it: "Default", or its file's name without the extension.
    func displayName(_ file: String?) -> String {
        guard let file else { return String(localized: "Default", comment: "The built-in meadow, as it always was") }
        return MeadowLibraryFolder.name(of: file)
    }

    var activeName: String { displayName(active) }

    /// The Whiskr that writes a meadow, as its files say.
    static var writtenBy: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return MeadowFormat.isWellFormedVersion(version) ? version : "0.0.0"
    }

    // MARK: Editing

    /// Makes an edit of the meadow shown, as one step of the history named `name` ("Move Oak"). Made while
    /// the Default is shown, the step makes "My Meadow" from it first. Refused, nothing changes.
    @discardableResult
    func edit(_ name: String, _ make: (inout MeadowEditSession) -> Result<MeadowChange, MeadowEditRefused>) -> Result<MeadowChange, MeadowEditRefused> {
        var trial = session
        let result = make(&trial)
        guard case .success(let change) = result, !change.isEmpty else { return result }
        var promoted: String?
        if active == nil {
            promoted = folder.fileName(forNew: String(localized: "My Meadow", comment: "The meadow the first edit of the Default makes"))
            trial.rename(displayName(promoted))
        }
        session = trial
        if let promoted { adopt(promoted) }
        changed()
        register(change, name: name, file: active, promoted: promoted)
        return result
    }

    /// The step's undo: the change taken back on the meadow it was made on (and the meadow it made taken
    /// away again); then its redo.
    private func register(_ change: MeadowChange, name: String, file: String?, promoted: String?) {
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated { library.undo(change, name: name, file: file, promoted: promoted) }
        }
        undoManager.setActionName(name)
        if grouping { undoManager.endUndoGrouping() }
    }

    private func undo(_ change: MeadowChange, name: String, file: String?, promoted: String?) {
        let file = current(file), promoted = promoted.flatMap(current)
        // A step is taken back only on the meadow it was made on.
        if active != file, !switchQuietly(to: file) { return }
        session.apply(change.inverse)
        if let promoted {
            // The copy this step made goes; the Default is shown again, as it was.
            saveTimer?.invalidate()
            unsaved = false
            let folder = folder
            writes.async { try? folder.remove(promoted) }
            files.removeAll { $0 == promoted }
            stamps[promoted] = nil
            session.rename(displayName(nil))
            active = nil
            known = nil
            watch?.watch(file: nil)
            WorldStore.shared.settings.meadow = nil
        } else {
            changed()
        }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated { library.redo(change, name: name, file: file, promoted: promoted) }
        }
        undoManager.setActionName(name)
        onStep?(change.inverse)
    }

    private func redo(_ change: MeadowChange, name: String, file: String?, promoted: String?) {
        let file = current(file), promoted = promoted.flatMap(current)
        if let promoted {
            if active != nil, !switchQuietly(to: nil) { return }
            session.rename(displayName(promoted))
            session.apply(change)
            adopt(promoted)
        } else {
            if active != file, !switchQuietly(to: file) { return }
            session.apply(change)
        }
        changed()
        register(change, name: name, file: file, promoted: promoted)
        onStep?(change)
    }

    /// A meadow's file name now, after the renames made since a step named it.
    private func current(_ file: String?) -> String? {
        guard var name = file else { return nil }
        while let next = renamed[name], next != name { name = next }
        return name
    }

    /// `file`, just made from the Default, is the meadow shown (it is saved with the edit that made it).
    private func adopt(_ file: String) {
        active = file
        if !files.contains(file) { files = (files + [file]).sorted(by: MeadowLibraryFolder.inNameOrder) }
        WorldStore.shared.settings.meadow = file
        unreadable = nil
        removedOnDisk = nil
        known = nil
        watch?.watch(file: folder.fileURL(file))
    }

    /// The meadow changed: saved a second after the last change.
    private func changed() {
        guard active != nil else { return }
        unsaved = true
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    /// Writes the meadow shown, if it has changes, off the main thread (`wait`: and waits for it, at quit).
    /// Not while the person is asked about a change on disk: their answer decides what is written.
    func save(wait: Bool = false) {
        saveTimer?.invalidate()
        saveTimer = nil
        guard unsaved, conflict == nil, let file = active else { return }
        unsaved = false
        guard let data = try? session.document.fileData(writtenBy: Self.writtenBy) else { return }
        write(data, as: file, wait: wait)
    }

    /// Writes `data` as `file` (the meadow shown), known as this app's own from now on.
    private func write(_ data: Data, as file: String, wait: Bool = false) {
        known = MeadowLibraryFolder.digest(data)
        let folder = folder
        let write: @Sendable () -> Void = { try? folder.write(data, as: file) }
        if wait { writes.sync(execute: write) } else { writes.async(execute: write) }
    }

    /// Waits for every save asked for so far (tests, and quitting).
    func waitForSaves() { writes.sync {} }

    // MARK: Choosing a meadow

    /// Shows another meadow (nil: the Default), as a step of the history named `name`.
    func use(_ file: String?, name: String) {
        keptCopy = nil
        guard file != active else { return }
        let before = active
        guard switchQuietly(to: file) else { return }
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated { library.use(library.current(before), name: name) }
        }
        undoManager.setActionName(name)
        if grouping { undoManager.endUndoGrouping() }
        onStep?(MeadowChange())
    }

    /// "Use “Orchard Study”", or Revert to Default: the step choosing `file` is named.
    func use(_ file: String?) {
        use(file, name: file == nil ? String(localized: "Revert to Default")
                                    : String(localized: "Use “\(displayName(file))”", comment: "Meadow editor: a step's name (choosing a meadow)"))
    }

    /// Revert to Default: the Default shown; your meadow stays in the folder.
    func revertToDefault() {
        use(nil, name: String(localized: "Revert to Default"))
    }

    /// Shows `file` (nil: the Default), saving the one shown first. False, with nothing changed, when it
    /// cannot be read.
    @discardableResult
    private func switchQuietly(to file: String?) -> Bool {
        save()
        guard let file else {
            show(nil, MeadowEditSession(.standard))
            removedOnDisk = nil
            WorldStore.shared.settings.meadow = nil
            return true
        }
        guard let data = try? folder.data(file), let reading = try? MeadowDocument.read(data) else {
            unreadable = file
            refreshFiles()
            return false
        }
        unreadable = nil
        removedOnDisk = nil
        show(file, MeadowEditSession(reading.document), digest: MeadowLibraryFolder.digest(data))
        WorldStore.shared.settings.meadow = file
        return true
    }

    /// Your meadows' files, looked at again (a menu or Settings opening, the folder changing).
    func refreshFiles() {
        let now = folder.fileNames()
        if now != files { files = now }
        // A meadow that could not be read and is gone now is nothing to say any more.
        if let unreadable, !now.contains(unreadable) { self.unreadable = nil }
        let stamped = Dictionary(uniqueKeysWithValues: now.compactMap { file in folder.stamp(file).map { (file, $0) } })
        if stamped != stamps { stamps = stamped }
    }

    // MARK: Your meadows

    /// What a meadow holds, to picture it or send it: the one shown as it is now, or one of yours as its file
    /// says (nil when it cannot be read), or the Default.
    func document(_ file: String?) -> MeadowDocument? {
        if file == active { return session.document }
        guard let file else { return .standard }
        return try? folder.read(file).document
    }

    /// What one of your meadows holds, as its card says it (nil: it cannot be read), kept while its file's stamp
    /// holds; the Default's for nil.
    func summary(_ file: String?) -> MeadowSummary? {
        guard let file else {
            let standard = MeadowDocument.standard
            return MeadowSummary(things: standard.entries.count, paints: standard.paintsShown(), writtenBy: nil, newerThings: 0,
                                 needsNewerCatalog: false, newerFormat: false, keepsNewerContent: false, leftOutside: 0)
        }
        let stamp = stamps[file]
        if let kept = summaries[file], kept.stamp == stamp { return kept.summary }
        let summary = (try? folder.read(file))?.summary()
        summaries[file] = (stamp, summary)
        return summary
    }
    @ObservationIgnored private var summaries: [String: (stamp: MeadowLibraryFolder.Stamp?, summary: MeadowSummary?)] = [:]

    /// A new meadow, from the Default or empty, named "My Meadow" (the next free name), shown as a step.
    @discardableResult
    func newMeadow(fromDefault: Bool) -> String? {
        let name = String(localized: "My Meadow", comment: "The meadow the first edit of the Default makes")
        guard let file = try? folder.add(fromDefault ? .standard : .empty, named: name, writtenBy: Self.writtenBy) else { return nil }
        refreshFiles()
        use(file)
        return file
    }

    /// A copy of `file` (the Default: a meadow of its own made from it) under the next free name. Its file's name.
    @discardableResult
    func duplicate(_ file: String?) -> String? {
        if file == active { save(wait: true) }
        let made: String?
        if let file {
            made = try? folder.duplicate(file, writtenBy: Self.writtenBy)
        } else {
            made = try? folder.add(.standard, named: String(localized: "My Meadow", comment: "The meadow the first edit of the Default makes"), writtenBy: Self.writtenBy)
        }
        refreshFiles()
        return made
    }

    /// Why a name cannot be given to `file` (nil: it can): empty, or longer than a meadow's name may be.
    /// Another meadow of the name is no reason: it takes the next free one, " 2".
    static func renameProblem(_ name: String) -> String? {
        let clean = MeadowText.sanitised(name)
        if clean.isEmpty { return String(localized: "A meadow needs a name.", comment: "Renaming a meadow: the name is empty") }
        if !MeadowText.fits(clean, .name) {
            return String(localized: "A meadow's name is at most \(MeadowText.Field.name.limit) characters.", comment: "Renaming a meadow: the name is too long")
        }
        return nil
    }

    /// The file name `name` would take for `file` (another meadow of that name: " 2" after it).
    func renamedFileName(_ file: String, to name: String) -> String {
        folder.fileName(forNew: MeadowText.sanitised(name), excluding: file)
    }

    /// Renames one of your meadows (its file and the name inside); the meadow shown keeps being shown, and steps
    /// made on it before still find it. Its new file's name.
    @discardableResult
    func rename(_ file: String, to name: String) throws -> String {
        if file == active {
            save(wait: true)
        }
        writes.sync {}
        let renamedTo = try folder.rename(file, to: name, writtenBy: Self.writtenBy)
        guard renamedTo != file else { return file }
        renamed[file] = renamedTo
        if file == active {
            active = renamedTo
            session.rename(displayName(renamedTo))
            known = folder.digest(renamedTo)
            watch?.watch(file: folder.fileURL(renamedTo))
            WorldStore.shared.settings.meadow = renamedTo
        }
        if unreadable == file { unreadable = nil }
        refreshFiles()
        return renamedTo
    }

    /// Moves one of your meadows to the Trash (where the Finder can put it back). The meadow shown: the Default is
    /// shown instead. The history ends, as its steps no longer fit what is left.
    func moveToTrash(_ file: String, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        if file == active {
            saveTimer?.invalidate()
            unsaved = false
            conflict = nil
            show(nil, MeadowEditSession(.standard))
            WorldStore.shared.settings.meadow = nil
        }
        writes.sync {}
        undoManager.removeAllActions()
        onStep?(MeadowChange())
        NSWorkspace.shared.recycle([folder.fileURL(file)]) { moved, _ in
            let trashed = !moved.isEmpty
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.unreadable == file { self.unreadable = nil }
                self.refreshFiles()
                done(trashed)
            }
        }
    }

    /// A meadow file someone shared, already read and checked (`MeadowImport`), added as it came under a name
    /// of its own. Its file's name.
    func add(imported data: Data, _ reading: MeadowReading, fallback: String) throws -> String {
        let file = try folder.addImported(data, reading, fallback: fallback)
        refreshFiles()
        return file
    }

    /// A meadow as a file to send (Export…, Share…, a card dragged out): the newest format, the name it has here,
    /// and the author and description given (or those it has). Data only: nothing of this Mac, its folders,
    /// workspaces, the date or who you are, unless you typed your name as its author.
    func exportData(_ file: String?, author: String? = nil, description: String? = nil) throws -> Data {
        if file == active { save(wait: true) }
        guard var document = document(file) else { throw CocoaError(.fileReadCorruptFile) }
        document.name = displayName(file)
        if let author { document.author = MeadowText.sanitised(author) }
        if let description { document.description = MeadowText.sanitised(description) }
        return try document.fileData(writtenBy: Self.writtenBy)
    }

    // MARK: Changes on disk

    /// The folder (or the meadow shown) changed on disk: the list and pictures follow it, and the meadow shown,
    /// changed by something else, is read again (or, while edited, the person is asked).
    private func folderChanged() {
        refreshFiles()
        guard let file = active, conflict == nil else { return }
        let onDisk = folder.digest(file)
        switch MeadowDiskChange.judge(known: known, onDisk: onDisk, editing: isEditing) {
        case .nothing:
            break
        case .reload:
            reload(file)
        case .gone:
            saveTimer?.invalidate()
            unsaved = false
            removedOnDisk = file
            show(nil, MeadowEditSession(.standard))
            WorldStore.shared.settings.meadow = nil
            undoManager.removeAllActions()
            onStep?(MeadowChange())
        case .ask:
            saveTimer?.invalidate()
            conflict = .changed(file)
        case .askGone:
            saveTimer?.invalidate()
            conflict = .gone(file)
        }
    }

    /// The meadow shown, read again from its file (something else changed it); the history ends.
    private func reload(_ file: String) {
        guard let data = try? folder.data(file), let reading = try? MeadowDocument.read(data) else {
            // Changed into something this Whiskr cannot read: shown as it was, the file left alone, as at launch.
            unreadable = file
            show(nil, MeadowEditSession(.standard))
            WorldStore.shared.settings.meadow = nil
            undoManager.removeAllActions()
            onStep?(MeadowChange())
            return
        }
        saveTimer?.invalidate()
        unsaved = false
        show(file, MeadowEditSession(reading.document), digest: MeadowLibraryFolder.digest(data))
        undoManager.removeAllActions()
        onStep?(MeadowChange())
    }

    /// Reload: the disk's version is shown and yours is kept as a meadow of its own; for a meadow gone from disk,
    /// Close It: the Default is shown (yours is let go, as its file was).
    func reloadFromDisk() {
        guard let conflict else { return }
        self.conflict = nil
        switch conflict {
        case .changed(let file):
            keepCopyOfMine(of: file)
            reload(file)
        case .gone(let file):
            saveTimer?.invalidate()
            unsaved = false
            removedOnDisk = file
            show(nil, MeadowEditSession(.standard))
            WorldStore.shared.settings.meadow = nil
            undoManager.removeAllActions()
            onStep?(MeadowChange())
        }
        refreshFiles()
    }

    /// Keep Mine: yours is written over the file; the disk's version (when there is one) is kept as a meadow of
    /// its own. For a meadow gone from disk: written back where it was (Save Again).
    func keepMine() {
        guard let conflict else { return }
        self.conflict = nil
        let file: String
        switch conflict {
        case .changed(let changed):
            file = changed
            if let data = try? folder.data(file), let reading = try? MeadowDocument.read(data) {
                keptCopy = try? folder.addImported(data, reading, fallback: displayName(file))
            }
        case .gone(let gone):
            file = gone
        }
        unsaved = true
        save()
        watch?.watch(file: folder.fileURL(file))
        refreshFiles()
    }

    /// Your version of `file` as you have it now, kept as a meadow of its own ("Orchard Study 2").
    private func keepCopyOfMine(of file: String) {
        guard let data = try? session.document.fileData(writtenBy: Self.writtenBy), let reading = try? MeadowDocument.read(data) else { return }
        keptCopy = try? folder.addImported(data, reading, fallback: displayName(file))
    }

    /// Editing ended while the person was being asked: nothing of theirs is lost, so the disk's side is kept as the
    /// meadow and theirs as a copy (Reload), the safe choice when no one chose.
    private func settleConflictOnLeaving() {
        reloadFromDisk()
    }

    // MARK: Debug builds: what the library flow looks at

    #if DEBUG
    /// The digest the meadow shown is known by (its own saves).
    var debugKnown: UInt64? { known }
    #endif
}
