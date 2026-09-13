import AppKit

/// Says, once at launch, that terminals started by another version of the app (or by it under its
/// earlier name) are still running where this version cannot show them, and, when some Claudes were
/// therefore not resumed, why. Nothing is stopped: an update never ends work in progress.
enum HostNotice {
    static func show(for host: HostLink, withheld: Int, on window: NSWindow?) {
        guard host.strangers > 0, !AppPlaces.isIsolated, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Sessions from another version are still running")
        var text = String(localized: "\(host.strangers) terminals started by a different version of Whiskr keep running in the background. This version cannot show them. They stay until their programs end; open that version to see them again.",
                          comment: "Launch notice: how many terminals an incompatible session host holds")
        if withheld > 0 {
            text += "\n\n" + String(localized: "\(withheld) Claudes were not resumed here, so none runs twice: they may still be running there.",
                                     comment: "Launch notice: Claude conversations not resumed because the other version's host may still run them")
        }
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window)
    }
}
