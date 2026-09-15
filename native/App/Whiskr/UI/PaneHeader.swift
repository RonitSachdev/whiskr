import AppKit
import SwiftUI
import WhiskrKit

// The header every pane of a split tab has (docs/DESIGN.md, "Where the keys go"): a file's and a diff's
// slim header, and in a split a terminal's too, so panes side by side read as separate things. Each says
// what its pane is and, at its trailing end, offers Zoom Pane and Close Pane. The pane with the keyboard
// has its header tinted with the accent and the accent along its foot; the others recede (the
// veil of `PaneFocusView`). A tab of one pane, or one zoomed to a pane, shows no terminal header.

/// How a pane of a tab stands, for its header.
enum PaneHeaderPlace {
    /// Its tab shows several panes (not zoomed to one): the pane has a header with its tools.
    @MainActor static func inSplit(_ workbench: Workbench, _ id: UUID) -> Bool {
        guard let tab = workbench.workspace(of: id)?.1 else { return false }
        return tab.tree.panes.count > 1 && tab.zoomedPane == nil
    }

    /// In a split, and the one with the keyboard.
    @MainActor static func focused(_ workbench: Workbench, _ id: UUID) -> Bool {
        inSplit(workbench, id) && workbench.workspace(of: id)?.1.focusedPane == id
    }
}

/// Zoom Pane and Close Pane, at the trailing end of a pane's header while its tab shows several panes.
/// Buttons of the bars' kind (`barButton`): AppKit takes their clicks, the rest of the header passes its
/// clicks to the pane (`PaneHeaderHost`), which takes the keyboard.
struct PaneHeaderTools: View {
    let workbench: Workbench
    let id: UUID

    var body: some View {
        if PaneHeaderPlace.inSplit(workbench, id) {
            HStack(spacing: Look.Space.xxs) {
                PaneHeaderButton(id: "pane.zoom", symbol: "arrow.up.left.and.arrow.down.right", label: String(localized: "Zoom Pane"),
                                 help: String(localized: "Zoom Pane (⇧⌘↩)", comment: "Tooltip of a pane header's zoom button")) {
                    guard let tab = workbench.workspace(of: id)?.1 else { return }
                    workbench.select(tab: tab, pane: id)
                    workbench.toggleZoom()
                }
                PaneHeaderButton(id: "pane.close", symbol: "xmark", label: String(localized: "Close Pane"),
                                 help: String(localized: "Close Pane (⌘W)", comment: "Tooltip of a pane header's close button")) {
                    workbench.requestClose(pane: id)
                }
            }
        }
    }
}

/// A small icon button in a pane's header: the bars' fills and tooltip, a header's size.
private struct PaneHeaderButton: View {
    let id: String
    let symbol: String
    let label: String
    let help: String
    let action: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .font(Look.smallIcon.weight(symbol == "xmark" ? .semibold : .regular))
            .foregroundStyle(Color.ink2)
            .frame(width: 24, height: 22)
            .barButton(id, label: label, help: help, radius: Look.Radius.small, action: action)
    }
}

extension View {
    /// A pane's header's ground and foot (the content's colour, the line), and in a split the focused pane's
    /// tinted with the accent (grey while the window is not the one in use), the accent along its foot. Not a line along its top: a pane at the top of its tab would
    /// draw it right under the tab row, where it read as a line shutting the selected tab off from its panes.
    func paneHeaderFocus(workbench: Workbench, id: UUID) -> some View {
        modifier(PaneHeaderFocus(workbench: workbench, id: id))
    }
}

private struct PaneHeaderFocus: ViewModifier {
    let workbench: Workbench
    let id: UUID
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        let focused = PaneHeaderPlace.focused(workbench, id)
        let accent: Color = Look.focusLine(active: activeState.inUse)
        content
            .background {
                if focused { accent.opacity(0.09).allowsHitTesting(false) }
            }
            .background(Color.content)
            // The header's foot: the accent on the focused one, the line on the others (and on a header alone).
            .overlay(alignment: .bottom) {
                (focused ? accent : Color.line).frame(height: focused ? Look.focusLineWidth : 1).allowsHitTesting(false)
            }
    }
}

/// A terminal's header in a split tab: what runs in it (Claude's state mark in its place, as on its
/// segment in the tab row), its title, the folder it is in, and the tools.
struct TerminalHeader: View {
    let workbench: Workbench
    let pane: Pane

    var body: some View {
        let focused = PaneHeaderPlace.focused(workbench, pane.id)
        let title = workbench.name(of: pane)
        let folder = abbreviatingHome(pane.currentFolder)
        HStack(spacing: Look.Space.m) {
            PaneKindMark(workbench: workbench, id: pane.id, emphasised: focused)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(focused ? Color.ink : Color.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            // Where the shell is, when the title does not already say it.
            if title != workbench.folderName(pane.currentFolder) {
                Text(folder)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: Look.Space.l)
            PaneHeaderTools(workbench: workbench, id: pane.id)
        }
        .padding(.leading, Look.Space.l)
        .padding(.trailing, Look.Space.s)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paneHeaderFocus(workbench: workbench, id: pane.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Pane \(title)", comment: "Accessibility: a terminal pane's header in a split tab"))
    }
}

/// A terminal header's hosting view. Its buttons are AppKit's (`barButton`); anywhere else a click falls
/// through to the pane under it, which takes the keyboard, as a click on the terminal does.
final class PaneHeaderHost<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var view: NSView? = hit
        while let each = view, each !== self {
            if each is BarControlView { return hit }
            view = each.superview
        }
        return nil
    }
}

/// What one pane or page is, as its segment in the tab row and its header draw it: a Claude's request or
/// finished mark, a bell its terminal rang out of sight, else a terminal, a file or changes.
struct PaneKindMark: View {
    let workbench: Workbench
    let id: UUID
    /// The pane's segment is the chosen one, or its header the focused one: the icon a step stronger.
    let emphasised: Bool

    var body: some View {
        let status = workbench.status(ofLeaf: id)
        let pane = workbench.panes[id]
        let failed = pane.flatMap(workbench.session(of:))?.failed ?? false
        let page = workbench.pages[id]
        if let status, status == .blocked || status == .done {
            StateMark(status: status, failed: failed)
        } else if let pane, pane.rang, !pane.agentRunning {
            Image(systemName: "bell.fill")
                .font(Look.smallIcon)
                .foregroundStyle(Color.ink2)
                .accessibilityLabel(String(localized: "Bell", comment: "A terminal rang its bell while out of sight"))
        } else if let page, !page.isDiff {
            FileIconView(name: page.title, size: 11)
                .foregroundStyle(emphasised ? Color.ink2 : Color.ink3)
        } else {
            Image(systemName: page == nil ? "terminal" : "arrow.left.arrow.right")
                .font(Look.smallIcon)
                .foregroundStyle(emphasised ? Color.ink2 : Color.ink3)
                .accessibilityHidden(true)
        }
    }
}
