import AppKit
import MeadowFile
import UniformTypeIdentifiers
import WhiskrMeadow

/// What can be done with a meadow (docs/DESIGN.md, "My Meadows"), the same from its card in Settings › Meadow or
/// My Meadows, from the editor's name menu and from the File menu: use it, edit it, copy, rename, send it as a file
/// (Export…, Share…, dragged out), picture it, find it, put it in the Trash, and make a new one. A meadow is named
/// by its file (nil: the Default).
@MainActor
enum MeadowLibraryActions {
    private static var library: MeadowLibrary { MeadowLibrary.shared }
    /// The name last typed as a meadow's author in Export…, offered the next time (never put in a file unasked).
    private static let authorKey = "meadowExportAuthor"

    /// Shows it (a step Edit › Undo takes back while editing).
    static func use(_ file: String?) {
        library.use(file)
    }

    /// Shows it and edits it, in the main window.
    static func edit(_ file: String?) {
        library.use(file)
        NSApp.sendAction(#selector(AppDelegate.editMeadow(_:)), to: nil, from: nil)
    }

    /// A new meadow, from the Default or empty, shown and edited.
    static func newMeadow(fromDefault: Bool) {
        guard library.newMeadow(fromDefault: fromDefault) != nil else { return }
        NSApp.sendAction(#selector(AppDelegate.editMeadow(_:)), to: nil, from: nil)
    }

    static func duplicate(_ file: String?) {
        library.duplicate(file)
    }

    /// Export…: the save panel (the file's name the meadow's, with its optional author and description), then the
    /// meadow written there in the newest format.
    static func export(_ file: String?, over window: NSWindow?) {
        let name = library.displayName(file)
        let document = library.document(file)
        let author = AppPlaces.defaults.string(forKey: authorKey) ?? ""
        MeadowPanels.chooseExport("\(name).\(MeadowFormat.fileExtension)", document?.author.isEmpty == false ? document?.author ?? author : author,
                                  document?.description ?? "", window) { choice in
            guard let choice else { return }
            let typed = MeadowText.sanitised(choice.author)
            if typed.isEmpty { AppPlaces.defaults.removeObject(forKey: authorKey) } else { AppPlaces.defaults.set(typed, forKey: authorKey) }
            do {
                try library.exportData(file, author: choice.author, description: choice.description).write(to: choice.url, options: .atomic)
            } catch {
                present(error, over: window)
            }
        }
    }

    /// Export Meadow Picture…: the meadow drawn as its card shows it, large, as a PNG (for a gallery or a post).
    static func exportPicture(_ file: String?, over window: NSWindow?) {
        let name = library.displayName(file)
        MeadowPanels.choosePicture("\(name).png", window) { url in
            guard let url else { return }
            guard let document = library.document(file), let picture = MeadowPreviews.shared.pictureNow(of: document, .export),
                  let png = MeadowPreviews.png(picture) else { return present(CocoaError(.fileWriteUnknown), over: window) }
            do { try png.write(to: url, options: .atomic) } catch { present(error, over: window) }
        }
    }

    /// The meadow as a file of its own to send, in a folder made for it (Share…, a card dragged out).
    static func fileToSend(_ file: String?) -> URL? {
        guard let data = try? library.exportData(file) else { return nil }
        let url = MeadowPanels.sendingFolder().appendingPathComponent("\(library.displayName(file)).\(MeadowFormat.fileExtension)")
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }

    /// Share…: the system's share picker with the meadow's file, beside `rect` of `view`.
    static func share(_ file: String?, from view: NSView, rect: NSRect) {
        guard let url = fileToSend(file) else { return }
        MeadowPanels.share(url, view, rect)
    }

    /// What a card dragged out of the app carries: the meadow as a file, made when it is dropped (the Finder writes
    /// it where it lands, a copy: the meadow stays in My Meadows).
    static func dragItem(_ file: String?) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = library.displayName(file)
        provider.registerFileRepresentation(forTypeIdentifier: MeadowFormat.typeIdentifier, fileOptions: [], visibility: .all) { done in
            Task { @MainActor in
                if let url = fileToSend(file) { done(url, false, nil) } else { done(nil, false, CocoaError(.fileWriteUnknown)) }
            }
            return nil
        }
        return provider
    }

    /// Show in Finder.
    static func reveal(_ file: String?) {
        guard let file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([library.folder.fileURL(file)])
    }

    /// Move to Trash…: asks first, naming the meadow (and, for the one shown, that the Default is shown instead).
    static func moveToTrash(_ file: String, over window: NSWindow?, done: @escaping @MainActor (Bool) -> Void = { _ in }) {
        let name = library.displayName(file)
        let detail = file == library.active
            ? String(localized: "It's the meadow shown; the Default is shown instead. You can put it back from the Trash.",
                     comment: "Move to Trash: the meadow shown is the one going")
            : String(localized: "You can put it back from the Trash.", comment: "Move to Trash: how to get a meadow back")
        MeadowPanels.confirm(String(localized: "Move “\(name)” to the Trash?", comment: "Move to Trash: the question, naming the meadow"), detail,
                             String(localized: "Move to Trash"), window) { yes in
            guard yes else { return done(false) }
            library.moveToTrash(file, done: done)
        }
    }

    private static func present(_ error: Error, over window: NSWindow?) {
        if let window { NSAlert(error: error).beginSheetModal(for: window) } else { NSApp.presentError(error) }
    }

    /// The meadow files among dropped or opened `urls`.
    static func meadowFiles(_ urls: [URL]) -> [URL] {
        urls.filter { $0.pathExtension.lowercased() == MeadowFormat.fileExtension }
    }
}
