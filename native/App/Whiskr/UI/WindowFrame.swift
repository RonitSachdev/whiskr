import AppKit
import SwiftUI
import WhiskrKit

/// The window's frame (docs/DESIGN.md), as Cursor's: a top bar and a status bar, each the window's full
/// width, with the work between them: the meadow on the left, the tab row and the terminals (or Home)
/// on the right. Both bars are drawn here, in the app's own colours, as content under the clear title
/// bar: not toolbar items, which macOS 26 wraps each in a glass capsule.
final class FrameController: NSViewController {
    private let workbench: Workbench
    private let chrome: WindowChrome
    private let content: NSViewController
    /// How far the status bar stands below the window's foot: 0 while shown, its height while hidden.
    private var statusOffset: NSLayoutConstraint!
    /// The room left under the work for the status bar: its height while shown, 0 while hidden.
    private var contentFoot: NSLayoutConstraint!
    /// The status bar, its content there only while shown (`WhileShown`): hidden, it would still be worked
    /// out again on every Claude's and pane's change.
    private var status: NSHostingView<WhileShown<StatusBar>>!
    /// The top bar: first in the order Tab goes through the window with Full Keyboard Access.
    private(set) var topBar: NSView!
    var statusBar: NSView? { status }
    private var statusObserver: Observing?

    static let topBarHeight = Look.Height.topBar
    static let statusBarHeight = Look.Height.statusBar

    init(content: NSViewController, workbench: Workbench, chrome: WindowChrome) {
        self.content = content
        self.workbench = workbench
        self.chrome = chrome
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("FrameController is created in code")
    }

    override func loadView() {
        let view = NSView()
        let top = TitleBarHostingView(rootView: TopBar(workbench: workbench, chrome: chrome))
        let workbench = workbench
        let status = BarHostingView(rootView: WhileShown(shown: chrome.showsStatusBar) { StatusBar(workbench: workbench) })
        addChild(content)
        for part in [content.view, top, status] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        // The top bar lies under the clear title bar on purpose.
        top.sizingOptions = []
        top.safeAreaRegions = []
        status.sizingOptions = []
        status.safeAreaRegions = []
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.topAnchor),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: Self.topBarHeight),
            content.view.topAnchor.constraint(equalTo: top.bottomAnchor),
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.heightAnchor.constraint(equalToConstant: Self.statusBarHeight),
        ])
        statusOffset = status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: chrome.showsStatusBar ? 0 : Self.statusBarHeight)
        contentFoot = content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: chrome.showsStatusBar ? -Self.statusBarHeight : 0)
        NSLayoutConstraint.activate([statusOffset, contentFoot])
        status.isHidden = !chrome.showsStatusBar
        self.status = status
        topBar = top
        self.view = view
        statusObserver = Observing { [weak self] in self?.updateStatusBar() }
    }

    /// View › Show Status Bar: the bar slides down out of the window (or back up), at its own height, by
    /// Core Animation (`Look.Motion`), over the work above it, which changes size only while the bar covers
    /// the difference: at once when the bar goes, at the end when it comes. So the work is laid out once,
    /// never frame by frame, and no strip is ever left uncovered; terminals take the room once, at the end,
    /// as in a live resize. With Reduce Motion it goes or comes at once.
    private func updateStatusBar() {
        let shown = chrome.showsStatusBar
        let offset = shown ? 0 : Self.statusBarHeight
        guard statusOffset.constant != offset else { return }
        if shown {
            status.isHidden = false
            status.rootView.shown = true
        }
        guard view.window?.isVisible == true, Look.Motion.moves else {
            statusOffset.constant = offset
            contentFoot.constant = shown ? -Self.statusBarHeight : 0
            status.isHidden = !shown
            status.rootView.shown = shown
            return
        }
        // Going: the work takes the room now, under the bar that is still there.
        if !shown { contentFoot.constant = 0 }
        // The bar's content is laid out before it comes into sight, not on the way.
        view.layoutSubtreeIfNeeded()
        LiveResize.shared.slide { context in
            context.allowsImplicitAnimation = true
            statusOffset.constant = offset
            view.layoutSubtreeIfNeeded()
        } done: { [weak self] in
            guard let self else { return }
            if chrome.showsStatusBar {
                // Come: the work gives up the room it covers now.
                contentFoot.constant = -Self.statusBarHeight
            } else {
                status.isHidden = true
                status.rootView.shown = false
            }
        }
    }
}

/// What the bars need to know of the window around them: in full screen there are no traffic lights.
@MainActor @Observable
final class WindowChrome {
    var fullScreen = false
    /// View › Show Status Bar.
    var showsStatusBar = true
    /// The meadow is on screen (its button in the top bar shows as on).
    var meadowShown = true
    @ObservationIgnored var toggleMeadow: () -> Void = {}

    /// Where the close, minimise and zoom buttons end, read from the window (72 pt on macOS 26), so the
    /// bar's first button keeps its distance from them on any version of the system.
    var trafficLightsEnd: CGFloat = 72

    /// Room for the close, minimise and zoom buttons at the top bar's leading end.
    var leadingInset: CGFloat { fullScreen ? Look.Space.m : trafficLightsEnd + Look.Space.s }

    /// Debug builds draw the window as the one in use although a background run's window is never key,
    /// so a snapshot shows what you see while working (`--key-look`).
    nonisolated(unsafe) static var drawsAsKey = false
}

extension View {
    /// The window's chrome (top bar, tab row, status bar, side panel): one colour a step below the
    /// content (`AppColorKey.chrome`), so the bars recede and the terminals come forward.
    func chromeBackground() -> some View {
        background(Color.chrome)
    }
}

/// The top bar, as Cursor's and Xcode's: after the traffic lights the meadow button and Home; in the
/// middle a search field that opens Go to (⌘P); at the end New, the Files and Changes button, and
/// Settings. Its empty stretches move the window, and a double-click does what the title bar's does.
struct TopBar: View {
    let workbench: Workbench
    let chrome: WindowChrome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: Look.Space.xs) {
                ChromeButton(symbol: "sidebar.left", help: String(localized: "Show or hide the meadow (⌃⌘S)"),
                             label: String(localized: "Show or hide the meadow"), selected: chrome.meadowShown, action: chrome.toggleMeadow)
                ChromeButton(symbol: "house", help: String(localized: "Home (⇧⌘H)", comment: "Top bar: the Home button's tooltip"),
                             label: String(localized: "Home", comment: "Go menu and the workspace menu: no workspace selected"),
                             selected: workbench.isHome) { workbench.goHome() }
                Spacer(minLength: 0)
                NewMenuButton()
                PanelButton(workbench: workbench)
                ChromeButton(symbol: "gearshape", help: String(localized: "Settings (⌘,)"), label: String(localized: "Settings")) {
                    NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
                }
            }
            .padding(.leading, chrome.leadingInset)
            .padding(.trailing, Look.Space.m)
            GoToField()
                .frame(maxWidth: 480)
                .padding(.horizontal, 168)
        }
        // Not the window in use: the bar's content goes quiet, as the system's title bars do.
        .opacity(activeState.inUse ? 1 : 0.6)
        .frame(maxWidth: .infinity, minHeight: Look.Height.topBar, maxHeight: Look.Height.topBar)
        .chromeBackground()
        // The line drags the window as the rest of the bar does.
        .overlay(alignment: .bottom) { Color.line.frame(height: 1).allowsHitTesting(false) }
        // In a window that is not the one in use, the first click on any control acts as well as bringing
        // the window forward, as the bar's empty stretches and the tabs (AppKit's) do.
        .allowsWindowActivationEvents()
        .animation(reduceMotion ? nil : Look.Motion.animation(Look.Motion.standard), value: chrome.leadingInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Top bar", comment: "Accessibility label of the window's top bar"))
    }
}

/// The middle of the top bar, as Cursor's and Safari's: a field that looks like one (inset in the
/// content's colour, a line round it) and opens Go to, where you find any workspace, tab, Claude or file.
/// Go to opens out of it (`PaletteController.place`).
struct GoToField: View {
    @State private var hovering = false

    static let height: CGFloat = 24
    /// From the top bar's top to the field's.
    static var inset: CGFloat { (Look.Height.topBar - height) / 2 }

    var body: some View {
        Button {
            NSApp.sendAction(#selector(MainWindowController.goTo(_:)), to: nil, from: nil)
        } label: {
            HStack(spacing: Look.Space.s) {
                Image(systemName: "magnifyingglass")
                    .font(Look.smallIcon.weight(.medium))
                    .foregroundStyle(Color.ink3)
                Text(String(localized: "Go to a workspace, tab or file", comment: "Top bar: the search field's placeholder"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ink3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Look.Space.m)
                KeyCap(text: "⌘P")
            }
            .padding(.leading, Look.Space.m + 2)
            .padding(.trailing, Look.Space.xs)
            .frame(height: Self.height)
        }
        .buttonStyle(FieldButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .help(String(localized: "Go to a workspace, tab, Claude or file (⌘P)"))
        .accessibilityLabel(String(localized: "Go to…"))
    }
}

/// The search field's look: the content's colour inset in the chrome, its line darker on hover, a
/// pressed shade while the click lasts; each change eases at `Look.Motion.quick`, as every control's in
/// the bars does.
private struct FieldButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Look.Radius.control).fill(Color.content))
            .overlay(RoundedRectangle(cornerRadius: Look.Radius.control).fill(configuration.isPressed ? Look.Fill.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: Look.Radius.control).strokeBorder(hovering || configuration.isPressed ? Color.lineStrong : Color.line))
            .animation(Look.Motion.animation(Look.Motion.quick), value: hovering)
            .animation(Look.Motion.animation(Look.Motion.quick), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// A key shown as a small cap ("⌘P"), as menus and Cursor's field show keys.
struct KeyCap: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Color.ink3)
            .padding(.horizontal, Look.Space.xs + 1)
            .frame(height: 16)
            .background(RoundedRectangle(cornerRadius: Look.Radius.small).fill(Look.Fill.hover))
            .accessibilityHidden(true)
    }
}

/// A 28 × 26 pt icon button, as every button in the bars is (`barButton`). It is named after its symbol
/// ("bar.house").
struct ChromeButton: View {
    let symbol: String
    let help: String
    let label: String
    var selected = false
    let action: () -> Void

    var body: some View {
        ChromeIcon(symbol: symbol, active: selected)
            .barButton("bar.\(symbol)", label: label, help: help, selected: selected, action: action)
    }
}

/// The icon of a chrome button: one size and weight for every symbol in the bars.
struct ChromeIcon: View {
    let symbol: String
    var active = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Image(systemName: symbol)
            .font(Look.icon)
            .foregroundStyle(active ? Color.ink : Color.ink2)
            .opacity(enabled ? 1 : 0.4)
            .frame(width: Look.Height.iconButton, height: Look.Height.control)
    }
}

/// "+": New Tab, New Workspace, Open Folder…, New Worktree…, each as in the File menu.
private struct NewMenuButton: View {
    var body: some View {
        ChromeIcon(symbol: "plus")
            .barMenu("bar.new", label: String(localized: "New"), help: String(localized: "New Tab, Workspace or Worktree"), menu: Self.menu)
    }

    static func menu() -> NSMenu {
        let menu = NSMenu()
        for (title, action, key, modifiers) in [
            (String(localized: "New Tab"), #selector(MainWindowController.newTab(_:)), "t", NSEvent.ModifierFlags.command),
            (String(localized: "New Workspace"), #selector(MainWindowController.newWorkspace(_:)), "n", [.command]),
            (String(localized: "Open Folder…"), #selector(MainWindowController.openFolder(_:)), "o", [.command]),
            (String(localized: "New Worktree…"), #selector(MainWindowController.newWorktree(_:)), "n", [.command, .shift]),
        ] {
            if action == #selector(MainWindowController.newWorktree(_:)) { menu.addItem(.separator()) }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
        }
        return menu
    }
}

/// Shows or hides the side panel (Files and Changes); counts the workspace's changed files. Dimmed on
/// Home, which has no folder of its own.
struct PanelButton: View {
    let workbench: Workbench

    var body: some View {
        let shown = workbench.selectedWorkspace.map { workbench.files.panel($0.id).shown } ?? false
        let count = workbench.selectedRepository?.status?.changeCount ?? 0
        ChromeIcon(symbol: "sidebar.right", active: shown)
            .overlay(alignment: .topTrailing) {
                if count > 0, !shown {
                    Text(verbatim: count > 99 ? "99+" : "\(count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 3.5)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.content))
                        .overlay(Capsule().strokeBorder(Color.lineStrong))
                        // Inside the button's own 28 pt: past it, the count crowded Settings beside it.
                        .offset(x: 1, y: -1)
                }
            }
            .barButton("bar.panel", label: shown ? String(localized: "Hide Files and Changes") : String(localized: "Show Files and Changes"),
                       help: shown ? String(localized: "Hide Files and Changes") : count > 0 ? String(localized: "Show Files and Changes: \(count) changed files") : String(localized: "Show Files and Changes"),
                       value: count > 0 ? String(localized: "\(count) changed files") : nil, selected: shown, enabled: !workbench.isHome) {
                workbench.setPanelShown(!shown)
            }
    }
}

/// An empty stretch of the window's bars (the top bar's, and the tab row's under it): it moves the
/// window, and a double-click does what a title bar's does, following Desktop & Dock's setting (zoom
/// unless set otherwise). It never opens anything: new tabs come from "+", ⌘T and the menus.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else { return window.performDrag(with: event) }
            switch TitleBarDoubleClick() {
            case .zoom: window.performZoom(nil)
            case .minimize: window.performMiniaturize(nil)
            case .nothing: break
            }
        }

        override var mouseDownCanMoveWindow: Bool { true }

        /// As a title bar: a window that is not the key one moves (or zooms) at the first click.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

/// The top bar's hosting view, which lies in the title bar's band. A hosting view says the window may move
/// wherever it is pressed (as any view that is not opaque does), and in that band the window server acts on
/// it before the app hears of the press: a control SwiftUI draws there (Go to's field) would move the window
/// instead. Here only the bar's empty stretches say so (`WindowDragArea`), as a title bar's do.
final class TitleBarHostingView<Content: View>: BarHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}
