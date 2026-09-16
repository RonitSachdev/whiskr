import AppKit
import MeadowFile
import UniformTypeIdentifiers

/// The system's panels a meadow file goes through (docs/DESIGN.md, "My Meadows"): the save panel of Export…
/// (with the optional author and description for the file), the save panel of Export Meadow Picture…, the open
/// panel of Import Meadow…, the share picker, and the question before a meadow goes to the Trash. Each is one
/// replaceable function: the harness's runs put stand-ins in their place (`PanelStandIn`), so a test never shows
/// a panel and every file it writes stays in its own folder.
@MainActor
enum MeadowPanels {
    /// Where Export… writes, and what the person added to the file.
    struct Export {
        var url: URL
        var author: String
        var description: String
    }

    static var chooseExport: @MainActor (_ name: String, _ author: String, _ description: String, _ window: NSWindow?, _ done: @escaping @MainActor (Export?) -> Void) -> Void = exportPanel
    static var choosePicture: @MainActor (_ name: String, _ window: NSWindow?, _ done: @escaping @MainActor (URL?) -> Void) -> Void = picturePanel
    static var chooseImports: @MainActor (_ window: NSWindow?, _ done: @escaping @MainActor ([URL]) -> Void) -> Void = importPanel
    static var share: @MainActor (_ file: URL, _ view: NSView, _ rect: NSRect) -> Void = sharePicker
    static var confirm: @MainActor (_ message: String, _ detail: String, _ button: String, _ window: NSWindow?, _ done: @escaping @MainActor (Bool) -> Void) -> Void = askFirst

    /// The meadow file's type, as the app exports it.
    static let meadowType = UTType(exportedAs: MeadowFormat.typeIdentifier, conformingTo: .json)

    /// A folder of its own for files made to be sent (Share…, a card dragged out): the system's temporary folder,
    /// or the isolated run's own.
    static func sendingFolder() -> URL {
        let base = AppPlaces.isIsolated ? AppPlaces.supportFolder.appendingPathComponent("Sending", isDirectory: true)
                                        : FileManager.default.temporaryDirectory.appendingPathComponent("Whiskr Meadows", isDirectory: true)
        let folder = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: The system's own

    private static func exportPanel(_ name: String, author: String, description: String, window: NSWindow?, done: @escaping @MainActor (Export?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [meadowType]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let fields = ExportFields(author: author, description: description)
        panel.accessoryView = fields.view
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return done(nil) }
            done(Export(url: url, author: fields.author.stringValue, description: fields.description.stringValue))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private static func picturePanel(_ name: String, window: NSWindow?, done: @escaping @MainActor (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in done(response == .OK ? panel.url : nil) }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private static func importPanel(window: NSWindow?, done: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [meadowType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "Import", comment: "The open panel's button for importing meadows")
        let finish: (NSApplication.ModalResponse) -> Void = { response in done(response == .OK ? panel.urls : []) }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private static func sharePicker(_ file: URL, view: NSView, rect: NSRect) {
        NSSharingServicePicker(items: [file]).show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    private static func askFirst(_ message: String, detail: String, button: String, window: NSWindow?, done: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        if let window {
            alert.beginSheetModal(for: window) { response in done(response == .alertFirstButtonReturn) }
        } else {
            done(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}

/// Export…'s accessory: who made the meadow and a line about it, both optional, both plain text saved in the
/// file for whoever opens it ("by Hana · Apples, a shed and a reading nook."). Empty unless typed: a file never
/// carries a name the person did not give it.
@MainActor
private final class ExportFields {
    let author = NSTextField()
    let description = NSTextField()
    let view: NSView

    init(author: String, description: String) {
        self.author.stringValue = author
        self.author.placeholderString = String(localized: "Your name, shown with this meadow (optional)", comment: "Export Meadow…: the author field")
        self.description.stringValue = description
        self.description.placeholderString = String(localized: "A line about it (optional)", comment: "Export Meadow…: the description field")
        for field in [self.author, self.description] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 320).isActive = true
            field.lineBreakMode = .byTruncatingTail
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Made by:", comment: "Export Meadow…: the author field's label")), self.author],
            [NSTextField(labelWithString: String(localized: "About it:", comment: "Export Meadow…: the description field's label")), self.description],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        let box = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 20),
        ])
        view = box
    }
}
