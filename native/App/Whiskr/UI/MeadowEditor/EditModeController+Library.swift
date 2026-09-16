import AppKit
import MeadowFile
import MeadowScene
import SwiftUI
import WhiskrMeadow

// The editor and My Meadows (docs/DESIGN.md, "My Meadows"): the library as a sheet from the name menu, another
// meadow shown while editing, and the quiet note along the meadow's top edge: what this Whiskr cannot draw here,
// and the meadow changed or removed on disk by something else while it is edited (Reload / Keep Mine).

extension EditModeController {
    /// My Meadows as a sheet over the window (`renaming`: that meadow's name ready to type over).
    func showLibrary(renaming: String? = nil) {
        guard let window = meadow.window, window.attachedSheet == nil else { return }
        let host = HostWindow()
        var sheet: NSWindow?
        let close = { [weak window] in
            guard let sheet else { return }
            window?.endSheet(sheet)
        }
        let controller = NSHostingController(rootView: MeadowLibrarySheet(host: host, renaming: renaming, close: { close() }))
        controller.sizingOptions = [.preferredContentSize]
        let made = NSWindow(contentViewController: controller)
        made.styleMask = [.titled]
        sheet = made
        window.beginSheet(made) { [weak self] _ in self?.meadowSwitched() }
    }

    /// Another meadow is shown (from My Meadows, New Meadow, an import): nothing chosen, everything drawn anew.
    func meadowSwitched() {
        guard isEditing else { return }
        choose([])
        meadow.scenery = library.scenery
        updateBar()
        updateAccessibility()
        updateNotice()
    }

    // MARK: The note at the top

    /// What the note says now: a question about the meadow changed on disk first, then what was kept after one was
    /// answered, then the things this Whiskr cannot draw (until put away).
    func updateNotice() {
        guard isEditing else { return }
        let before = (noticeModel.text, noticeModel.choices.map(\.id))
        let name = library.activeName
        switch library.conflict {
        case .changed(let file)?:
            noticeModel.text = String(localized: "“\(library.displayName(file))” changed on disk. Keep yours, or reload it? The other is kept in My Meadows.",
                                      comment: "Meadow editor: the meadow being edited was changed by something else")
            noticeModel.choices = [.init(title: String(localized: "Reload", comment: "Meadow editor: shows the meadow as it is on disk"), id: "reload"),
                                   .init(title: String(localized: "Keep Mine", comment: "Meadow editor: keeps your version of the meadow"), id: "keep", isDefault: true)]
            noticeModel.closable = false
        case .gone(let file)?:
            noticeModel.text = String(localized: "“\(library.displayName(file))” was moved or deleted on disk.",
                                      comment: "Meadow editor: the meadow being edited was removed by something else")
            noticeModel.choices = [.init(title: String(localized: "Close It", comment: "Meadow editor: lets the removed meadow go and shows the Default"), id: "reload"),
                                   .init(title: String(localized: "Save Again", comment: "Meadow editor: writes the removed meadow back"), id: "keep", isDefault: true)]
            noticeModel.closable = false
        case nil:
            noticeModel.choices = []
            noticeModel.closable = true
            if let kept = library.keptCopy, noteClosed != "kept:\(kept)" {
                noticeModel.text = String(localized: "The other version is kept in My Meadows as “\(library.displayName(kept))”.",
                                          comment: "Meadow editor: where the side not chosen was kept")
            } else if library.session.undrawnCount > 0, noteClosed != name {
                noticeModel.text = MeadowFileWords.undrawn(library.session.undrawnCount)
            } else {
                noticeModel.text = nil
            }
        }
        if (noticeModel.text, noticeModel.choices.map(\.id)) != before {
            placeNotice()
            if let text = noticeModel.text, !noticeModel.choices.isEmpty { announce(text) }
        }
    }

    /// Reload or Keep Mine (Close It or Save Again), or the note put away.
    func noticeChosen(_ choice: String) {
        switch choice {
        case "reload":
            library.reloadFromDisk()
            meadowSwitched()
        case "keep":
            library.keepMine()
        default:
            if let kept = library.keptCopy, noticeModel.text?.contains(library.displayName(kept)) == true {
                noteClosed = "kept:\(kept)"
            } else {
                noteClosed = library.activeName
            }
        }
        updateNotice()
    }

    /// Along the meadow's top edge, in the middle, inside it.
    func placeNotice() {
        guard noticeHost.superview != nil else { return }
        guard noticeModel.text != nil else {
            noticeHost.isHidden = true
            return
        }
        noticeHost.isHidden = false
        let bounds = meadow.convert(meadow.bounds, to: noticeHost.superview)
        let size = noticeHost.fittingSize
        let width = min(bounds.width - 2 * Look.Space.l, size.width)
        let frame = NSRect(x: (bounds.midX - width / 2).rounded(), y: (bounds.maxY - Look.Space.m - size.height + EditorNotice.margin).rounded(),
                           width: width.rounded(), height: size.height)
        if noticeHost.frame != frame { noticeHost.frame = frame }
    }
}
