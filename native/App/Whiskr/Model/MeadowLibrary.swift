import AppKit
import MeadowFile
import MeadowScene
import Observation
import WhiskrKit
import WhiskrMeadow

/// The meadows (docs/DESIGN.md, "The meadow's scenery"): the Default, built in and never changed, and your
/// own, one `.whiskrmeadow` file each in the support folder's `Meadows` (an isolated run's own folder when
/// testing). The one shown is `WorldSettings.meadow`.
///
/// - The first change made while the Default is shown makes "My Meadow", a copy, and shows it, in the same
///   step: undone, the Default is shown again and the copy goes; Revert to Default (choosing the Default)
///   is always there, and your meadow stays.
/// - Every change is saved a second after the last (encoded here, written off the main thread, whole: a
///   temporary file renamed over the old), and at once when editing ends and at quit.
/// - Every edit is a step of one history for the app's session, across leaving and coming back to editing
///   and across meadows (choosing another meadow is a step too, so steps always apply to the meadow shown).
/// - A meadow chosen that cannot be read at launch is left as it was; the Default is shown, and Settings ›
///   Meadow says so.
@MainActor @Observable
final class MeadowLibrary {
    static let shared = MeadowLibrary()

    /// The meadow shown: its file's name, or nil for the Default.
    private(set) var active: String?
    /// The meadow shown, being edited.
    private(set) var session: MeadowEditSession
    /// Your meadows' files, in name order.
    private(set) var files: [String] = []
    /// A meadow that could not be read when it was to be shown, kept as it was.
    private(set) var unreadable: String?
    /// One history of edits for the app's session (`MeadowLibrary` registers each step).
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored let folder: MeadowLibraryFolder
    /// After a step is undone or done again: what it changed now, so the editor can choose those things.
    @ObservationIgnored var onStep: ((MeadowChange) -> Void)?

    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var unsaved = false
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
    }

    /// The meadow `WorldSettings.meadow` names, or the Default.
    func load() {
        files = folder.fileNames()
        unreadable = nil
        guard let file = WorldStore.shared.settings.meadow else { return show(nil, MeadowEditSession(.standard)) }
        if MeadowLibraryFolder.isPlain(file), let reading = try? folder.read(file) {
            show(file, MeadowEditSession(reading.document))
        } else {
            unreadable = file
            show(nil, MeadowEditSession(.standard))
        }
    }

    private func show(_ file: String?, _ session: MeadowEditSession) {
        active = file
        self.session = session
    }

    /// What the meadow draws.
    var scenery: MeadowScenery { session.scenery }

    /// A meadow's name as people read it: "Default", or its file's name without the extension.
    func displayName(_ file: String?) -> String {
        guard let file else { return String(localized: "Default", comment: "The built-in meadow, as it always was") }
        return (file as NSString).deletingPathExtension
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
        if active != file { switchQuietly(to: file) }
        session.apply(change.inverse)
        if let promoted {
            // The copy this step made goes; the Default is shown again, as it was.
            saveTimer?.invalidate()
            unsaved = false
            let folder = folder
            writes.async { try? folder.remove(promoted) }
            files.removeAll { $0 == promoted }
            session.rename(displayName(nil))
            active = nil
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
        if let promoted {
            if active != nil { switchQuietly(to: nil) }
            session.rename(displayName(promoted))
            session.apply(change)
            adopt(promoted)
        } else {
            if active != file { switchQuietly(to: file) }
            session.apply(change)
        }
        changed()
        register(change, name: name, file: file, promoted: promoted)
        onStep?(change)
    }

    /// `file`, just made from the Default, is the meadow shown (it is saved with the edit that made it).
    private func adopt(_ file: String) {
        active = file
        if !files.contains(file) { files = (files + [file]).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        WorldStore.shared.settings.meadow = file
        unreadable = nil
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
    func save(wait: Bool = false) {
        saveTimer?.invalidate()
        saveTimer = nil
        guard unsaved, let file = active else { return }
        unsaved = false
        guard let data = try? session.document.fileData(writtenBy: Self.writtenBy) else { return }
        let folder = folder
        let write: @Sendable () -> Void = { try? folder.write(data, as: file) }
        if wait { writes.sync(execute: write) } else { writes.async(execute: write) }
    }

    /// Waits for every save asked for so far (tests, and quitting).
    func waitForSaves() { writes.sync {} }

    // MARK: Choosing a meadow

    /// Shows another meadow (nil: the Default), as a step of the history named `name`.
    func use(_ file: String?, name: String) {
        guard file != active else { return }
        let before = active
        guard switchQuietly(to: file) else { return }
        let grouping = !undoManager.isUndoing && !undoManager.isRedoing
        if grouping { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { library in
            MainActor.assumeIsolated { library.use(before, name: name) }
        }
        undoManager.setActionName(name)
        if grouping { undoManager.endUndoGrouping() }
        onStep?(MeadowChange())
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
            WorldStore.shared.settings.meadow = nil
            return true
        }
        guard let reading = try? folder.read(file) else {
            unreadable = file
            files = folder.fileNames()
            return false
        }
        unreadable = nil
        show(file, MeadowEditSession(reading.document))
        WorldStore.shared.settings.meadow = file
        return true
    }

    /// Your meadows' files, looked at again (a menu or Settings opening).
    func refreshFiles() {
        let now = folder.fileNames()
        if now != files { files = now }
    }
}
