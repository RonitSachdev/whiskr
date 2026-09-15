import AppKit
import SwiftUI
import WhiskrKit

/// ⌃Tab, most recent first (`RecentTabs`), as VS Code and Safari switch: a tap goes back to the tab shown
/// before; with ⌃ still held a small list of the workspace's tabs appears, each further Tab steps down it
/// (⇧Tab up, ↑ ↓ too), letting go of ⌃ opens the one chosen, Esc stays where you were. ⌃⇧Tab starts from
/// the other end.
///
/// No key is lost and the keyboard is never left nowhere: while the list is up the keys it does not use
/// (any letter, Return) first open the chosen tab and then go to it, as if ⌃ had been let go; a click
/// anywhere or the window going to the back opens it too.
@MainActor
final class TabSwitcher {
    private let workbench: Workbench
    private weak var window: NSWindow?
    private var order: [UUID] = []
    private var index = 0
    private var monitor: Any?
    private var list: NSHostingView<TabSwitcherList>?
    private var resign: NSObjectProtocol?
    /// How long ⌃ must be held before the list shows (a quick tap only flips).
    static let delay: TimeInterval = 0.2

    init(workbench: Workbench, window: NSWindow) {
        self.workbench = workbench
        self.window = window
    }

    var isActive: Bool { monitor != nil }

    /// ⌃Tab (forward) or ⌃⇧Tab, from the menu: starts a switch, or steps an open one.
    func begin(backward: Bool) {
        if isActive { return step(backward ? -1 : 1) }
        guard let workspace = workbench.selectedWorkspace, workspace.tabs.count > 1 else { return }
        order = RecentTabs.order(workspace.tabs.map(\.id), visited: workbench.visitedTabs, shown: workspace.selectedTabID)
        index = RecentTabs.step(0, by: backward ? -1 : 1, count: order.count)
        // ⌃ already let go (a menu click, a remapped key): just go.
        guard (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.control) else { return commit() }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handle(event) ?? event
        }
        resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.commit() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            guard let self, self.isActive else { return }
            self.showList()
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            if !event.modifierFlags.contains(.control) { commit() }
            return event
        case .keyDown:
            switch event.keyCode {
            case 48:     // Tab
                step(event.modifierFlags.contains(.shift) ? -1 : 1)
                return nil
            case 126:    // ↑
                step(-1)
                return nil
            case 125:    // ↓
                step(1)
                return nil
            case 53:     // Esc
                cancel()
                return nil
            case 36, 76: // Return: open it, and nothing else
                commit()
                return nil
            default:
                // Any other key: the chosen tab opens, and the key goes to it.
                commit()
                return event
            }
        default:
            commit()
            return event
        }
    }

    private func step(_ steps: Int) {
        index = RecentTabs.step(index, by: steps, count: order.count)
        list?.rootView = listView
        if list == nil, isActive { showList() }
    }

    /// Opens the chosen tab (its keyboard goes to it in this same turn).
    private func commit() {
        guard !order.isEmpty else { return end() }
        let id = order[index]
        end()
        if let tab = workbench.selectedWorkspace?.tabs.first(where: { $0.id == id }) { workbench.select(tab: tab) }
    }

    private func cancel() { end() }

    private func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resign { NotificationCenter.default.removeObserver(resign) }
        resign = nil
        // The tab is opened (or kept) at once; only the list's picture goes, fading out the way it came.
        if let list {
            self.list = nil
            if let layer = list.layer { OverlayMotion.disappear(layer, anchor: .center) { list.removeFromSuperview() } } else { list.removeFromSuperview() }
        }
        order = []
    }

    private var listView: TabSwitcherList {
        let tabs = workbench.selectedWorkspace?.tabs ?? []
        return TabSwitcherList(workbench: workbench, tabs: order.compactMap { id in tabs.first { $0.id == id } }, chosen: index)
    }

    /// Over the work area's middle, a little above centre; never takes a click. It fades in, growing a
    /// little from its middle (`OverlayMotion`).
    private func showList() {
        guard let content = window?.contentView else { return }
        let host = NSHostingView(rootView: listView)
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        content.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            host.topAnchor.constraint(equalTo: content.topAnchor, constant: Look.Height.topBar + Look.Height.tabRow + Look.Space.xxl),
        ])
        content.layoutSubtreeIfNeeded()
        if let layer = host.layer { OverlayMotion.appear(layer, anchor: .center) }
        list = host
        NSAccessibility.post(element: host, notification: .layoutChanged)
    }

    #if DEBUG
    /// Debug builds (`DebugPerf`): the list is showing, and which tab it holds chosen.
    var debugShowsList: Bool { list != nil }
    var debugChosen: UUID? { order.indices.contains(index) ? order[index] : nil }
    #endif
}

/// The list: each tab with what it is, its state, its title; the chosen one in the selected fill.
struct TabSwitcherList: View {
    let workbench: Workbench
    let tabs: [Tab]
    let chosen: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                row(tab, chosen: index == chosen)
            }
        }
        .padding(Look.Space.xs)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: Look.Radius.card).fill(Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Look.Radius.card).strokeBorder(Color.line))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Recent tabs", comment: "Accessibility: the ⌃Tab list"))
    }

    private func row(_ tab: Tab, chosen: Bool) -> some View {
        HStack(spacing: Look.Space.m) {
            TabKindMark(workbench: workbench, tab: tab, selected: chosen)
                .frame(width: 14)
            Text(workbench.title(of: tab))
                .font(.system(size: 13, weight: chosen ? .medium : .regular))
                .foregroundStyle(chosen ? Color.ink : Color.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Look.Space.m)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: Look.Radius.control).fill(chosen ? Look.Fill.selected : .clear))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workbench.title(of: tab))
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// What a tab is, as the tab row draws it: a Claude's request or finished mark, a bell a terminal rang
/// out of sight, else a terminal, a file or changes.
struct TabKindMark: View {
    let workbench: Workbench
    let tab: Tab
    let selected: Bool

    var body: some View {
        let status = workbench.status(of: tab)
        let failed = tab.tree.panes.compactMap { workbench.panes[$0] }.contains { workbench.session(of: $0)?.failed ?? false }
        let page = workbench.pages[tab.focusedPane]
        if let status, status == .blocked || status == .done {
            StateMark(status: status, failed: failed)
        } else if workbench.rang(in: tab) {
            Image(systemName: "bell.fill")
                .font(Look.smallIcon)
                .foregroundStyle(Color.ink2)
                .accessibilityLabel(String(localized: "Bell", comment: "A terminal rang its bell while out of sight"))
        } else if let page, !page.isDiff {
            FileIconView(name: page.title, size: 11)
                .foregroundStyle(selected ? Color.ink2 : Color.ink3)
        } else {
            Image(systemName: page == nil ? "terminal" : "arrow.left.arrow.right")
                .font(Look.smallIcon)
                .foregroundStyle(selected ? Color.ink2 : Color.ink3)
                .accessibilityHidden(true)
        }
    }
}
