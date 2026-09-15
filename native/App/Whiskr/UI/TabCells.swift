import AppKit
import SwiftUI
import WhiskrKit

/// The tabs themselves (`TabRowLayout`): equal shares of the room for every titled segment, up to
/// `TabStrip.maxTab`; a tab split into panes is one tab of joined segments, one per pane in the panes'
/// order, as Chrome draws a split view. When even `minTab` each will not fit, a split tab keeps only its
/// focused pane's title and shows its other panes as icons; when that will not fit either, as many tabs
/// as fit, a run that always holds the selected tab whole, and the list of every tab after them. No
/// scrolling: every tab in sight is wholly there, its close buttons in reach, and every click is AppKit's
/// (`TabMouse`). "+" follows the last tab, as in Chrome; the stretch after it belongs to the window, as
/// the top bar's empty stretches do: it moves the window, and a double-click does what a title bar's does.
///
/// The row is drawn twice over the same places (docs/DESIGN.md, "Motion of the interface"). Underneath,
/// where clicks land (`TabHit`): every tab at its new place the moment the tabs change, never animated, so
/// a click goes to the tab (and the pane) that is there now and a closed one takes none. On top, what you
/// see (`TabButton`, which takes no click but its own to-do button's): the same tabs easing into those
/// places at `Look.Motion.standard`, a new tab or pane opening out from its leading edge, a closed one
/// folding into it as its neighbour slides over, and the selected tab's fill and line moving across at
/// `Look.Motion.quick`. While a tab is dragged (`TabDragging`) its picture leaves the row: the others part
/// to open its place where it would land, or close up when it would leave the row. With Reduce Motion the
/// pictures are where the tabs are, at once.
struct TabCells: View {
    let workbench: Workbench
    let workspace: Workspace
    /// Where the run of tabs began last time: it moves only when the selected tab would leave it.
    @State private var start = 0
    /// The segment under the pointer, as AppKit follows it (`TabMouseView`).
    @State private var hovered: Hovered?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Hovered: Equatable {
        let tab: UUID
        let pane: UUID
    }

    /// What moves the tabs' pictures when it changes: which tabs and panes are in sight, in what order,
    /// how wide.
    private struct Arrangement: Equatable {
        let cells: [UUID]
        let widths: [Double]
        let overflowing: Bool
    }

    /// One tab in sight: its place among the workspace's tabs and how the row lays it out.
    struct Shown {
        let index: Int
        let tab: Tab
        let item: TabRowLayout.Tab
    }

    var body: some View {
        GeometryReader { room in
            let tabs = workspace.tabs
            let drag = TabDragState.shared
            let selected = tabs.firstIndex { $0 === workspace.selectedTab } ?? 0
            let items = tabs.map(item(for:))
            let layout = TabRowLayout(width: Double(max(room.size.width - NewTabButton.room, 0)), tabs: items, selected: selected, previousStart: start,
                                      minimum: Double(TabStrip.minTab), maximum: Double(TabStrip.maxTab), iconWidth: Double(TabStrip.iconSegment),
                                      listWidth: Double(TabListButton.width))
            // Each tab keeps its views by its own id, so a tab opened or closed before it rebuilds nothing.
            let shown = layout.range.map { Shown(index: $0, tab: tabs[$0], item: items[$0]) }
            let pictures = Self.pictures(shown, dragged: drag.tab, slot: drag.slot, layout: layout)
            let arrangement = Arrangement(cells: pictures.map(\.shown.tab.id), widths: pictures.flatMap { $0.widths },
                                          overflowing: layout.overflowing)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(shown, id: \.tab.id) { each in
                        TabHit(workbench: workbench, tab: each.tab, index: each.index, selected: workspace.selectedTab === each.tab, last: tabs.count == 1,
                               slots: TabMouseView.slots(panes: each.tab.tree.panes, widths: layout.segmentWidths(each.item), label: each.item.label),
                               hover: { pane in
                                   if let pane { hovered = Hovered(tab: each.tab.id, pane: pane) } else if hovered?.tab == each.tab.id { hovered = nil }
                               })
                            .frame(width: CGFloat(layout.width(each.item)))
                    }
                    if layout.overflowing { Color.clear.frame(width: TabListButton.width) }
                    NewTabButton(workbench: workbench)
                }
                .transaction { $0.animation = nil }
                HStack(spacing: 0) {
                    ForEach(pictures, id: \.shown.tab.id) { picture in
                        let tab = picture.shown.tab
                        TabButton(workbench: workbench, tab: tab, index: picture.shown.index, selected: workspace.selectedTab === tab,
                                  widths: picture.widths, label: picture.label, hovered: hovered?.tab == tab.id ? hovered?.pane : nil)
                            .frame(width: CGFloat(picture.widths.reduce(picture.label, +)), alignment: .leading)
                            // The held picture (`TabDragging`) stands for it while it is dragged and until it lands.
                            .opacity(drag.tab == tab.id || drag.landing == tab.id ? 0 : 1)
                            .transition(.tabOpening)
                    }
                    if layout.overflowing {
                        TabListButton(workbench: workbench, workspace: workspace, hidden: tabs.count - layout.count)
                            // It fades in, but goes at once: fading where a tab now is, it would take that tab's
                            // click (`make perf`'s rapid × found it).
                            .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                    NewTabButton.Picture()
                }
                // The selected tab's fill: the content's colour, the whole tab, which opens into its panes. One
                // mark under the pictures that slides to the tab chosen, not two crossing fades. (A matched
                // geometry effect did this, until a tab dropped into the shown one, both mid-transition, brought
                // SwiftUI down.)
                .background(alignment: .leading) {
                    if let fill = Self.selectedFill(pictures, selected: workspace.selectedTab, dragged: drag.tab ?? drag.landing) {
                        Color.content
                            .frame(width: CGFloat(fill.width))
                            .offset(x: CGFloat(fill.x))
                            .allowsHitTesting(false)
                    }
                }
                // The arrangement's ease wins over the selection's when both change (a new tab chosen).
                .animation(reduceMotion ? nil : Look.Motion.animation(Look.Motion.standard), value: arrangement)
                .animation(reduceMotion ? nil : Look.Motion.animation(Look.Motion.quick), value: workspace.selectedTab.map { [$0.id, $0.focusedPane] })
            }
            .frame(width: room.size.width, alignment: .leading)
            // Never past the row's end (`TabRowLayout` keeps within it; this is the guarantee).
            .clipped()
            .background(WindowDragArea())
            .onChange(of: layout.start) { _, value in start = value }
        }
    }

    /// How the row lays out a tab: its panes, which has the keyboard, and the name leading a split tab you
    /// named (or its rename field).
    private func item(for tab: Tab) -> TabRowLayout.Tab {
        let panes = tab.tree.panes
        let focused = panes.firstIndex(of: tab.focusedPane) ?? 0
        guard panes.count > 1 else { return TabRowLayout.Tab() }
        if workbench.renamingTabID == tab.id { return TabRowLayout.Tab(panes: panes.count, focused: focused, label: Double(TabGroupLabel.fieldWidth)) }
        let name = tab.name ?? ""
        return TabRowLayout.Tab(panes: panes.count, focused: focused, label: name.isEmpty ? 0 : Double(TabGroupLabel.width(of: name)))
    }

    /// One tab's picture: its segments' widths and its name's, in the order drawn.
    struct Picture {
        let shown: Shown
        let widths: [Double]
        let label: Double
    }

    /// Where the selected tab's fill goes: after the pictures drawn before it, as wide as it. None while it
    /// is held (its picture is the held one) or out of sight.
    static func selectedFill(_ pictures: [Picture], selected: Tab?, dragged: UUID?) -> (x: Double, width: Double)? {
        guard let selected, selected.id != dragged, let index = pictures.firstIndex(where: { $0.shown.tab === selected }) else { return nil }
        let width = { (picture: Picture) in picture.widths.reduce(picture.label, +) }
        return (pictures[..<index].reduce(0) { $0 + width($1) }, width(pictures[index]))
    }

    /// The tabs' pictures in the order drawn. While a tab is dragged it is drawn at `slot` (its place among
    /// the others), where it would land, still at its width, so the others part to make room for it; with
    /// no slot (it would leave the row) it is drawn with no width, and they close up.
    static func pictures(_ shown: [Shown], dragged: UUID?, slot: Int?, layout: TabRowLayout) -> [Picture] {
        var pictures = shown.map { Picture(shown: $0, widths: layout.segmentWidths($0.item), label: $0.item.label) }
        guard let dragged, let from = pictures.firstIndex(where: { $0.shown.tab.id == dragged }) else { return pictures }
        let held = pictures.remove(at: from)
        guard let slot else {
            pictures.insert(Picture(shown: held.shown, widths: held.widths.map { _ in 0 }, label: 0), at: from)
            return pictures
        }
        // `slot` counts the workspace's tabs other than the dragged one; the run may start after some.
        let before = pictures.filter { $0.shown.index - ($0.shown.index > held.shown.index ? 1 : 0) < slot }.count
        pictures.insert(held, at: min(max(before, 0), pictures.count))
        return pictures
    }
}

extension AnyTransition {
    /// A tab or a pane's segment opening out from its leading edge, or folding into it as it closes:
    /// revealed rather than squeezed, so its title never stretches.
    static var tabOpening: AnyTransition {
        .modifier(active: TabReveal(shown: 0), identity: TabReveal(shown: 1))
    }
}

/// How much of a tab is shown, from its leading edge (`AnyTransition.tabOpening`).
private struct TabReveal: ViewModifier {
    let shown: CGFloat

    func body(content: Content) -> some View {
        content.mask(alignment: .leading) {
            Rectangle().scaleEffect(x: shown, y: 1, anchor: .leading)
        }
    }
}

/// "+", directly after the last tab (after the list of every tab while some are out of sight), as in
/// Chrome. Its control (`barButton`, under the row's clicks) is at its place at once; its picture
/// (`Picture`, with the tabs' pictures) eases there with them. The top bar's "+" is a menu of every way to
/// start something; this one is New Tab.
struct NewTabButton: View {
    let workbench: Workbench

    /// Its width with the room round it.
    static let room = Look.Height.iconButton + 2 * Look.Space.xs

    var body: some View {
        Color.clear
            .frame(width: Look.Height.iconButton, height: Look.Height.control)
            .barButton("bar.tabs.new", label: String(localized: "New Tab"), help: String(localized: "New Tab (⌘T)")) { workbench.newTab() }
            .padding(.horizontal, Look.Space.xs)
    }

    /// What you see of it, moving with the tabs.
    struct Picture: View {
        var body: some View {
            ChromeIcon(symbol: "plus")
                .padding(.horizontal, Look.Space.xs)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

/// The name you gave a split tab, leading its segments as a small label (as Chrome labels a tab group),
/// or its rename field.
struct TabGroupLabel: View {
    let name: String
    let selected: Bool

    static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// The rename field's room.
    static let fieldWidth: CGFloat = 120
    private static let padding: CGFloat = 2 * Look.Space.s + 2 * Look.Space.m

    /// The label's width for a name: its text up to 140 pt and the room round it.
    static func width(of name: String) -> CGFloat {
        let text = (name as NSString).size(withAttributes: [.font: font]).width
        return min(text.rounded(.up), 140) + padding
    }

    var body: some View {
        Text(name)
            .font(Font(Self.font))
            .foregroundStyle(selected ? Color.ink : Color.ink2)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, Look.Space.s)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: Look.Radius.small).fill(Look.Fill.selected))
            .padding(.horizontal, Look.Space.m)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }
}

/// A tab as you see it (`TabCells` draws it over its `TabHit`): a tab of one pane shows what it is, its
/// title and its close button; a split tab, one segment per pane (`TabSegment`), joined, with a short line
/// between them and the name you gave it, if any, leading them. Chosen, it has the content's fill (the
/// whole tab: it opens into its panes; `TabCells` draws it under the tabs) and the focus line along the top of the pane with the keyboard. It
/// takes no click itself (they reach `TabMouse` under it), but its to-do button's and its rename field's.
struct TabButton: View {
    let workbench: Workbench
    let tab: Tab
    let index: Int
    let selected: Bool
    /// Each segment's width, in the panes' order.
    let widths: [Double]
    /// The width of the name leading a split tab you named.
    let label: Double
    /// The pane whose segment is under the pointer (AppKit's account of it, from `TabMouse`).
    let hovered: UUID?
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        let panes = tab.tree.panes
        let split = panes.count > 1
        let segments = Array(zip(panes, widths.count == panes.count ? widths : panes.map { _ in widths.first ?? 0 }))
        HStack(spacing: 0) {
            if split, label > 0 {
                if workbench.renamingTabID == tab.id { renameField.frame(width: CGFloat(label)) } else {
                    TabGroupLabel(name: tab.name ?? "", selected: selected).frame(width: CGFloat(label))
                }
            }
            ForEach(Array(segments.enumerated()), id: \.element.0) { position, segment in
                TabSegment(workbench: workbench, tab: tab, index: index, pane: segment.0, selected: selected, split: split,
                           titled: segment.1 > Double(TabStrip.iconSegment) + 0.5, hovering: hovered == segment.0,
                           separated: position > 0 || label > 0) {
                    renameField
                }
                .frame(width: CGFloat(segment.1))
                .transition(.tabOpening)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) { Color.line.frame(width: 1).allowsHitTesting(false) }
        .modifier(SplitTabAccessibility(workbench: workbench, tab: tab, index: index, split: split))
    }

    /// The tab's name in a field where its title (or a split tab's label) was.
    private var renameField: some View {
        TextField(String(localized: "Tab name"), text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .frame(minWidth: 60, maxWidth: .infinity)
            .padding(.horizontal, tab.tree.panes.count > 1 ? Look.Space.m : 0)
            .focused($editing)
            .onSubmit { commit() }
            .onExitCommand {
                workbench.renamingTabID = nil
                editing = false
            }
            // The keyboard goes back to the tab once the field has gone, not nowhere.
            .onDisappear { workbench.returnKeyboardIfLost() }
            .onChange(of: editing) { _, focused in if !focused { commit() } }
            .onAppear {
                draft = tab.name ?? (tab.tree.panes.count > 1 ? "" : workbench.title(of: tab))
                editing = true
            }
    }

    private func commit() {
        guard workbench.renamingTabID == tab.id else { return }
        workbench.rename(tab: tab, to: draft)
        workbench.renamingTabID = nil
        // Let go of the field's focus as it goes: still set, the next rename's field would not take the keyboard.
        editing = false
    }
}

/// VoiceOver on a split tab: one element, "Tab 2, Claude Code, notes.txt", holding its panes' segments
/// (each chosen, or closed, by itself), with Close Tab and Rename Tab… for the whole. A tab of one pane is
/// its one segment.
private struct SplitTabAccessibility: ViewModifier {
    let workbench: Workbench
    let tab: Tab
    let index: Int
    let split: Bool

    func body(content: Content) -> some View {
        if split {
            content
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Tab \(index + 1), \(workbench.title(of: tab))", comment: "Accessibility: a tab's number and title"))
                .accessibilityAction(named: String(localized: "Close Tab")) { workbench.requestClose(tab: tab) }
                .accessibilityAction(named: String(localized: "Rename Tab…")) { workbench.renamingTabID = tab.id }
        } else {
            content
        }
    }
}

/// One pane of a tab in the row: what it is (a Claude's state mark in its place, a bell, a terminal, a file,
/// changes), its title, its to-do ring, and its close button at its trailing end: always on the selected
/// tab's pane with the keyboard, on any other under the pointer; a dot in its place while its file is
/// unsaved. A segment too narrow for its title shows its icon alone, and no close button (its tooltip, its
/// menu and its pane's header still close it). A tab of one pane is one segment, its title the tab's.
private struct TabSegment<Field: View>: View {
    let workbench: Workbench
    let tab: Tab
    let index: Int
    let pane: UUID
    let selected: Bool
    let split: Bool
    let titled: Bool
    let hovering: Bool
    /// A short line before it: it follows another segment, or the tab's name.
    let separated: Bool
    @ViewBuilder let renameField: () -> Field
    @State private var showingTasks = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        // The one the tab's title and focus belong to: the tab's only pane, or a split tab's focused one.
        let active = selected && (!split || tab.focusedPane == pane)
        let emphasised = active
        let title = split ? workbench.name(ofLeaf: pane) : workbench.title(of: tab)
        let tasks = tasks
        let edited = editedFile
        let preview = !split && workbench.isPreview(tab)
        HStack(spacing: Look.Space.s) {
            PaneKindMark(workbench: workbench, id: pane, emphasised: emphasised || (!split && selected))
                .frame(width: 14)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if titled {
                if workbench.pinnedPanes.contains(pane) {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Color.ink3).rotationEffect(.degrees(30))
                        .allowsHitTesting(false)
                        .accessibilityLabel(String(localized: "Pinned"))
                }
                if !split, workbench.renamingTabID == tab.id {
                    renameField()
                } else {
                    Text(title)
                        .font(.system(size: 13, weight: emphasised ? .medium : .regular))
                        .italic(preview)
                        .foregroundStyle(emphasised ? Color.ink : Color.ink2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // The title takes the room; the close button stays at the end.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                }
                if !tasks.isEmpty {
                    let done = tasks.filter { $0.state == .completed }.count
                    Button { showingTasks.toggle() } label: {
                        ProgressMark(done: done, total: tasks.count)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "To-do list: \(done) of \(tasks.count) done"))
                    .popover(isPresented: $showingTasks, arrowEdge: .bottom) { TaskList(tasks: tasks) }
                }
                // Drawn here, clicked through `TabMouse`, which closes the moment the button goes down. A file
                // with unsaved changes shows a dot in its place until the pointer comes, as Xcode and VS Code do.
                ZStack {
                    if edited && !hovering {
                        Circle().fill(Color.ink2).frame(width: 7, height: 7)
                    } else if active || hovering {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(hovering ? Color.ink : Color.ink2)
                    }
                }
                .frame(width: TabMouseView.closeSize, height: TabMouseView.closeSize)
                .background(RoundedRectangle(cornerRadius: Look.Radius.small).fill(hovering ? Look.Fill.hover : .clear))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .padding(.leading, titled ? Look.Space.l - 2 : 0)
        .padding(.trailing, titled ? Look.Space.xs : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if hovering && !active {
                Look.Fill.hover.allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if active {
                // Where the keys go: the line along the top of the pane that has them. Not a matched geometry
                // of its own beside the selected tab's fill: two such sources at once (a tab dropped into the
                // shown one, mid-transition) brought SwiftUI down.
                Look.focusLine(active: activeState.inUse)
                    .frame(height: Look.focusLineWidth)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if separated {
                // Between the panes of one tab: shorter than the line after a tab, so the tab reads as one.
                Color.lineStrong.frame(width: 1, height: 14).allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: split ? .ignore : .combine)
        .accessibilityLabel(accessibility(title: title, preview: preview, edited: edited))
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { workbench.select(tab: tab, pane: pane) }
        .accessibilityAction(named: split ? String(localized: "Close Pane") : String(localized: "Close Tab")) {
            if split { workbench.requestClose(pane: pane) } else { workbench.requestClose(tab: tab) }
        }
        .accessibilityAction(named: String(localized: "Rename Tab…")) { workbench.renamingTabID = tab.id }
    }

    /// The to-do list of this pane's Claude, when it keeps one.
    private var tasks: [TaskItem] {
        guard let pane = workbench.panes[pane], let session = workbench.session(of: pane) else { return [] }
        return workbench.monitor.details[session.id]?.tasks ?? []
    }

    /// This segment's file has unsaved changes.
    private var editedFile: Bool {
        guard case .file(let path) = workbench.pages[pane] else { return false }
        return workbench.files.openDocument(path)?.isEdited ?? false
    }

    private func accessibility(title: String, preview: Bool, edited: Bool) -> String {
        let status = workbench.status(ofLeaf: pane)
        let failed = workbench.panes[pane].flatMap(workbench.session(of:))?.failed ?? false
        var parts = [split ? String(localized: "Pane \(title)", comment: "Accessibility: one pane's segment of a split tab")
                           : String(localized: "Tab \(index + 1), \(title)", comment: "Accessibility: a tab's number and title")]
        if let status, status == .blocked || status == .done { parts.append(failed ? String(localized: "Error") : status.label) }
        if let terminal = workbench.panes[pane], terminal.rang, !terminal.agentRunning { parts.append(String(localized: "Bell", comment: "A terminal rang its bell while out of sight")) }
        if workbench.pinnedPanes.contains(pane) { parts.append(String(localized: "Pinned")) }
        if edited { parts.append(String(localized: "Edited")) }
        if preview { parts.append(String(localized: "Preview")) }
        return parts.joined(separator: ", ")
    }
}

/// Where a tab takes its clicks and drags (`TabCells` lays these out under the tabs' pictures, at the tabs'
/// places at once): AppKit's `TabMouse`, which knows the tab's segments. `make perf`'s closing check clicks
/// every part of every tab, and the split check every segment and its close button.
private struct TabHit: View {
    let workbench: Workbench
    let tab: Tab
    let index: Int
    let selected: Bool
    /// The workspace's only tab: closing it closes the workspace and goes Home, which its close button says.
    let last: Bool
    let slots: [TabMouseView.Slot]
    let hover: (UUID?) -> Void

    var body: some View {
        TabMouse(tab: tab.id, last: last, slots: slots, focused: tab.focusedPane, selected: selected, index: index,
                 select: { pane in workbench.select(tab: tab, pane: pane) },
                 close: { pane in
                     // A tab of one pane closes as a tab (asking about its unsaved file); a split tab's segment, its pane.
                     if tab.tree.panes.count > 1 { workbench.requestClose(pane: pane) } else { workbench.requestClose(tab: tab) }
                 },
                 shown: { workbench.selectedTab?.id }, show: { id in
                     // A drag shows the panes it can be dropped beside: those of the tab shown before.
                     if let before = workbench.selectedWorkspace?.tabs.first(where: { $0.id == id }) { workbench.select(tab: before) }
                 },
                 rename: {
                     // A second click on a preview keeps it (as in Xcode); on any other tab it renames.
                     if workbench.isPreview(tab) { workbench.keep(page: tab.focusedPane) } else { workbench.renamingTabID = tab.id }
                 },
                 menu: { pane in TabMenu.make(workbench: workbench, tab: tab, pane: pane) },
                 title: { pane in tab.tree.panes.count > 1 ? workbench.name(ofLeaf: pane) : workbench.title(of: tab) },
                 // One account of the pointer, AppKit's (in any window, key or not): the close button is drawn
                 // where a click closes, and nowhere else.
                 hover: hover)
            .accessibilityHidden(true)
    }
}

/// A tab's right-click menu (§3): Rename Tab…, Move to Workspace ▸, Pin, Mark as Unread, Zoom Pane (in
/// a split), Close Pane (in a split: the pane clicked), Close Tab (saying how many panes it closes),
/// Close Other Tabs.
enum TabMenu {
    static func make(workbench: Workbench, tab: Tab, pane: UUID? = nil) -> NSMenu {
        let menu = NSMenu()
        let pane = pane.flatMap { tab.tree.contains($0) ? $0 : nil } ?? tab.focusedPane
        menu.addItem(closureMenuItem(title: String(localized: "Rename Tab…")) { workbench.renamingTabID = tab.id })
        let move = NSMenuItem(title: String(localized: "Move to Workspace"), action: nil, keyEquivalent: "")
        let targets = NSMenu()
        for workspace in workbench.workspaces where !workspace.tabs.contains(where: { $0 === tab }) {
            let item = closureMenuItem(title: workspace.name) { workbench.move(tab: tab, to: workspace) }
            item.image = WorkspaceMenu.swatch(workspace.colorIndex)
            targets.addItem(item)
        }
        move.submenu = targets
        move.isEnabled = targets.numberOfItems > 0
        menu.addItem(move)
        menu.autoenablesItems = false
        // The Claude clicked, else the tab's first.
        let claude = workbench.panes[pane]?.agentRunning == true ? pane : tab.tree.panes.first { workbench.panes[$0]?.agentRunning ?? false }
        if let claude {
            menu.addItem(.separator())
            let pinned = workbench.pinnedPanes.contains(claude)
            menu.addItem(closureMenuItem(title: pinned ? String(localized: "Unpin Claude") : String(localized: "Pin Claude")) { workbench.togglePin(pane: claude) })
            let unread = closureMenuItem(title: String(localized: "Mark as Unread")) { workbench.markUnread(pane: claude) }
            unread.isEnabled = workbench.canMarkUnread(pane: claude)
            menu.addItem(unread)
        }
        if let path = workbench.pages[pane]?.path {
            menu.addItem(.separator())
            if workbench.isPreview(tab) {
                menu.addItem(closureMenuItem(title: String(localized: "Keep Open")) { workbench.keep(page: pane) })
            }
            menu.addItem(closureMenuItem(title: String(localized: "Reveal in Files")) { workbench.revealInFiles(path: path) })
            menu.addItem(closureMenuItem(title: String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) })
            menu.addItem(closureMenuItem(title: String(localized: "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            })
        }
        let count = tab.tree.panes.count
        if count > 1 {
            menu.addItem(.separator())
            let zoom = closureMenuItem(title: tab.zoomedPane == nil ? String(localized: "Zoom Pane") : String(localized: "Restore Panes")) {
                workbench.select(tab: tab, pane: pane)
                workbench.toggleZoom()
            }
            zoom.keyEquivalent = "\r"
            zoom.keyEquivalentModifierMask = [.command, .shift]
            menu.addItem(zoom)
        }
        menu.addItem(.separator())
        if count > 1 {
            let close = closureMenuItem(title: String(localized: "Close Pane")) { workbench.requestClose(pane: pane) }
            close.keyEquivalent = "w"
            close.keyEquivalentModifierMask = [.command]
            menu.addItem(close)
        }
        let closeTab = closureMenuItem(title: count > 1 ? String(localized: "Close Tab (\(count) Panes)", comment: "A split tab's menu: closes every pane of it")
                                                       : String(localized: "Close Tab")) { workbench.requestClose(tab: tab) }
        closeTab.keyEquivalent = "w"
        closeTab.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(closeTab)
        let others = closureMenuItem(title: String(localized: "Close Other Tabs")) {
            workbench.requestClose(tabs: (workbench.workspaces.first { $0.tabs.contains { $0 === tab } }?.tabs ?? []).filter { $0 !== tab })
        }
        others.isEnabled = (workbench.workspaces.first { $0.tabs.contains { $0 === tab } }?.tabs.count ?? 0) > 1
        menu.addItem(others)
        return menu
    }
}

/// The mouse on a tab, in AppKit: chosen on mouse down (the segment's pane given the keyboard), renamed on
/// a second click, a pane or the tab closed by its close button or a middle click, dragged after a few
/// points of movement (`TabDragging`), its menu on a right click.
private struct TabMouse: NSViewRepresentable {
    let tab: UUID
    let last: Bool
    let slots: [TabMouseView.Slot]
    let focused: UUID
    let selected: Bool
    let index: Int
    let select: (UUID) -> Void
    let close: (UUID) -> Void
    let shown: () -> UUID?
    let show: (UUID) -> Void
    let rename: () -> Void
    let menu: (UUID) -> NSMenu
    let title: (UUID) -> String
    let hover: (UUID?) -> Void

    func makeNSView(context: Context) -> TabMouseView { TabMouseView() }

    func updateNSView(_ view: TabMouseView, context: Context) {
        view.tab = tab
        view.isLast = last
        view.slots = slots
        view.focusedPane = focused
        view.index = index
        view.onSelect = select
        view.shownTab = shown
        view.onShow = show
        view.onClose = close
        view.onRename = rename
        view.makeMenu = menu
        view.title = title
        view.isSelected = selected
        view.onHover = hover
    }
}

final class TabMouseView: NSView, NSViewToolTipOwner {
    /// One pane's segment: where it is across the tab, and whether it shows its title (and so its close
    /// button) or only its icon.
    struct Slot: Equatable {
        let pane: UUID
        let minX: CGFloat
        let width: CGFloat
        let titled: Bool
    }

    /// The segments of a tab's panes, after the name leading it.
    static func slots(panes: [UUID], widths: [Double], label: Double) -> [Slot] {
        var x = CGFloat(label)
        return zip(panes, widths).map { pane, width in
            defer { x += CGFloat(width) }
            return Slot(pane: pane, minX: x, width: CGFloat(width), titled: width > Double(TabStrip.iconSegment) + 0.5)
        }
    }

    var tab = UUID()
    /// The workspace's only tab: its close button's tooltip says the workspace closes and Home comes.
    var isLast = false {
        didSet { if isLast != oldValue { needsLayout = true } }
    }
    var slots: [Slot] = [] {
        didSet {
            guard slots != oldValue else { return }
            needsLayout = true
            hoverFromPointer()
        }
    }
    /// The tab's pane with the keyboard: its segment shows its close button on the selected tab.
    var focusedPane = UUID()
    /// The tab's place in the row (its ⌘ number).
    var index = 0
    var onSelect: (UUID) -> Void = { _ in }
    var onClose: (UUID) -> Void = { _ in }
    var onRename: () -> Void = {}
    var makeMenu: (UUID) -> NSMenu = { _ in NSMenu() }
    var title: (UUID) -> String = { _ in "" }
    var shownTab: () -> UUID? = { nil }
    var onShow: (UUID) -> Void = { _ in }
    var isSelected = false
    var onHover: (UUID?) -> Void = { _ in }
    /// The pane whose segment the pointer is on. Told after the turn: it can change while SwiftUI is laying
    /// the row out (new segments, a new frame), when its state must not be changed.
    private var hoveredPane: UUID? {
        didSet {
            guard hoveredPane != oldValue else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onHover(self.hoveredPane)
            }
        }
    }
    private var hoverArea: NSTrackingArea?
    private var downAt: NSPoint?
    /// The tab shown before this one was pressed: a drag goes back to it, so the tab can be dropped
    /// beside its panes.
    private var shownBefore: UUID?
    /// What each tooltip rectangle is for.
    private var tips: [NSView.ToolTipTag: (pane: UUID, close: Bool)] = [:]

    /// The close button, drawn by a segment at its trailing end, and its reach: the button and the
    /// segment's padding after it, the row's full height.
    static let closeSize: CGFloat = 20
    static let closeReach: CGFloat = 30

    private func slot(at point: NSPoint) -> Slot? {
        slots.first { point.x >= $0.minX && point.x < $0.minX + $0.width } ?? (slots.count == 1 ? slots.first : nil)
    }

    private func closeRect(_ slot: Slot) -> NSRect? {
        guard slot.titled else { return nil }
        return NSRect(x: slot.minX + slot.width - Self.closeReach, y: 0, width: Self.closeReach, height: bounds.height)
    }

    /// The close button is drawn on the selected tab's pane with the keyboard (a tab of one pane: the
    /// tab), and on another while the pointer is on it.
    private func showsClose(_ slot: Slot) -> Bool {
        slot.titled && ((isSelected && (slots.count == 1 || slot.pane == focusedPane)) || hoveredPane == slot.pane)
    }

    /// The middle of the close button of the tab's pane with the keyboard (where `DebugPerf` clicks it).
    var closePoint: NSPoint {
        (slots.first { $0.pane == focusedPane } ?? slots.first).flatMap { closePoint(of: $0.pane) } ?? NSPoint(x: bounds.maxX - Self.closeReach / 2, y: bounds.midY)
    }

    /// The middle of a pane's close button; nil for a segment showing only its icon.
    func closePoint(of pane: UUID) -> NSPoint? {
        slots.first { $0.pane == pane }.flatMap(closeRect).map { NSPoint(x: $0.midX, y: bounds.midY) }
    }

    /// A point on a pane's segment that chooses it: its title's middle, or its icon's.
    func point(of pane: UUID) -> NSPoint? {
        slots.first { $0.pane == pane }.map { slot in
            NSPoint(x: slot.minX + (slot.titled ? (slot.width - Self.closeReach) / 2 : slot.width / 2), y: bounds.midY)
        }
    }

    /// A tab chosen (or closed) in a window that is not the key one takes effect at once, as in Safari
    /// and the Finder: the click is not spent on bringing the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The pointer, followed in every window (key or not, the app active or not), so that a first click in
    /// a background window finds the close button exactly where it is drawn. Over the tab's own bounds, set
    /// again whenever they change: inside a hosting view a platform view's visible rectangle can reach far
    /// past it (`.inVisibleRect` then hovered tabs the pointer was not on). Moves too: which segment it is on.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        hoverFromPointer()
    }

    /// The tabs moved under a pointer that did not (one closed and the next took its place): the tab now
    /// under it shows its close button at once, ready for the next click, without waiting for a move. AppKit
    /// sends no entered event for an area that comes under a resting pointer, and does not always ask a view
    /// that only moved to update its areas, so every change of place asks where the pointer is (in any window,
    /// key or not: the tracking is `.activeAlways`, so a first click in a window behind others closes too).
    private func hoverFromPointer() {
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hoveredPane = bounds.contains(point) && !TabDragState.shared.isDragging ? slot(at: point)?.pane : nil
    }

    override func mouseEntered(with event: NSEvent) { hoverFromPointer() }
    override func mouseMoved(with event: NSEvent) { hoverFromPointer() }
    override func mouseExited(with event: NSEvent) { hoveredPane = nil }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        hoverFromPointer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        hoverFromPointer()
    }

    #if DEBUG
    /// Debug builds (`DebugAnimations`): the tab counts the pointer as on it.
    var debugIsHovered: Bool { hoveredPane != nil }
    #endif

    override func mouseDown(with event: NSEvent) {
        downAt = nil
        let point = convert(event.locationInWindow, from: nil)
        let slot = slot(at: point)
        // A close button's reach closes only where the button is drawn; elsewhere the segment is chosen.
        if let slot, showsClose(slot), closeRect(slot)?.contains(point) == true { return onClose(slot.pane) }
        downAt = event.locationInWindow
        shownBefore = shownTab()
        if event.clickCount == 2 { onRename() } else { onSelect(slot?.pane ?? focusedPane) }
    }

    /// A middle click closes the segment's pane (a tab of one pane: the tab), as every browser closes a tab.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        // On a split tab's name, no pane is pointed at: nothing closes.
        guard let pane = slot(at: convert(event.locationInWindow, from: nil))?.pane else { return }
        onClose(pane)
    }

    /// The tooltips: each segment's title over it, and its close button's over the button. The view answers
    /// for them itself: AppKit does not keep a tooltip's owner, and a string handed over as one was gone by
    /// the time the tooltip came up (a crash with the pointer resting on ×).
    override func layout() {
        super.layout()
        removeAllToolTips()
        tips = [:]
        for slot in slots {
            let close = closeRect(slot)
            let title = NSRect(x: slot.minX, y: 0, width: slot.width - (close?.width ?? 0), height: bounds.height)
            tips[addToolTip(title, owner: self, userData: nil)] = (slot.pane, false)
            if let close { tips[addToolTip(close, owner: self, userData: nil)] = (slot.pane, true) }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        // By the rectangle it was asked for, else by where the pointer is.
        let tip = tips[tag] ?? slot(at: point).map { ($0.pane, closeRect($0)?.contains(point) == true) }
        guard let tip else { return "" }
        if !tip.close { return index < 8 ? String(localized: "\(title(tip.pane)) (⌘\(index + 1))") : title(tip.pane) }
        if slots.count > 1 { return String(localized: "Close Pane (⌘W)", comment: "Tooltip of a split tab's segment's close button") }
        return isLast
            ? String(localized: "Close Tab (⌥⌘W): the workspace's last tab, so the workspace closes and you go Home", comment: "Tooltip of the close button on a workspace's only tab")
            : String(localized: "Close Tab (⌥⌘W)")
    }

    /// Past a few points the tab is picked up and held (`TabDragging`), the whole tab with all its panes.
    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        downAt = nil
        hoveredPane = nil
        let before = shownBefore != tab ? shownBefore : nil
        TabDragging.shared.begin(tab: tab, from: self, event: event, grabbedAt: start) { [onShow] in
            if let before { onShow(before) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        downAt = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pane = slot(at: convert(event.locationInWindow, from: nil))?.pane ?? focusedPane
        onSelect(pane)
        return makeMenu(pane)
    }
}
