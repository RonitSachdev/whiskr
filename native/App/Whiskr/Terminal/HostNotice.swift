import AppKit

/// Says, once at launch, that terminals started by another version of the app are still running where
/// this version cannot show them. Nothing is stopped: an update never ends work in progress.
enum HostNotice {
    static func show(for host: HostLink, on window: NSWindow?) {
        guard host.strangers > 0, !AppPlaces.isIsolated, let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Sessions from another version are still running")
        alert.informativeText = String(localized: "\(host.strangers) terminals started by a different version of Whiskr keep running in the background. This version cannot show them. They stay until their programs end; open that version to see them again.",
                                       comment: "Launch notice: how many terminals an incompatible session host holds")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window)
    }
}
