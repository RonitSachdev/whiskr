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
    private var statusHeight: NSLayoutConstraint!
    private var status: NSView!
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
        let top = NSHostingView(rootView: TopBar(workbench: workbench, chrome: chrome))
        let status = NSHostingView(rootView: StatusBar(workbench: workbench))
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
            content.view.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        statusHeight = status.heightAnchor.constraint(equalToConstant: Self.statusBarHeight)
        statusHeight.isActive = true
        self.status = status
        self.view = view
        statusObserver = Observing { [weak self] in self?.updateStatusBar() }
    }

    /// View › Show Status Bar: the bar slides away (or back) and the terminals take the room once, at
    /// the end, as in a live resize.
    private func updateStatusBar() {
        let shown = chrome.showsStatusBar
        let height = shown ? Self.statusBarHeight : 0
        guard statusHeight.constant != height else { return }
        if shown { status.isHidden = false }
        guard view.window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            statusHeight.constant = height
            status.isHidden = !shown
            return
        }
        LiveResize.shared.begin()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            statusHeight.animator().constant = height
            view.layoutSubtreeIfNeeded()
        } completionHandler: {
            MainActor.assumeIsolated {
                if !self.chrome.showsStatusBar { self.status.isHidden = true }
                LiveResize.shared.end()
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

    /// Room for the close, minimise and zoom buttons at the top bar's leading end.
    var leadingInset: CGFloat { fullScreen ? Look.Space.m : 78 }

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
        .overlay(alignment: .bottom) { Color.line.frame(height: 1) }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: chrome.leadingInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Top bar", comment: "Accessibility label of the window's top bar"))
    }
}

/// The middle of the top bar, as Cursor's and Safari's: a field that looks like one (inset in the
/// content's colour, a line round it) and opens Go to, where you find any workspace, tab, Claude or file.
private struct GoToField: View {
    @State private var hovering = false

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
            .frame(height: 24)
        }
        .buttonStyle(FieldButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .help(String(localized: "Go to a workspace, tab, Claude or file (⌘P)"))
        .accessibilityLabel(String(localized: "Go to…"))
    }
}

/// The search field's look: the content's colour inset in the chrome, its line darker on hover, a
/// pressed shade while the click lasts.
private struct FieldButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Look.Radius.control).fill(Color.content))
            .overlay(RoundedRectangle(cornerRadius: Look.Radius.control).fill(configuration.isPressed ? Look.Fill.hover : .clear))
            .overlay(RoundedRectangle(cornerRadius: Look.Radius.control).strokeBorder(hovering || configuration.isPressed ? Color.lineStrong : Color.line))
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

/// A 28 × 26 pt icon button, as every button in the bars is.
struct ChromeButton: View {
    let symbol: String
    let help: String
    let label: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChromeIcon(symbol: symbol, active: selected)
        }
        .buttonStyle(ChromeButtonStyle(selected: selected))
        .help(help)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
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
            .contentShape(Rectangle())
    }
}

/// "+": New Tab, New Workspace, Open Folder…, New Worktree…, each as in the File menu.
private struct NewMenuButton: View {
    @State private var hovering = false

    var body: some View {
        ChromeIcon(symbol: "plus")
            .background(RoundedRectangle(cornerRadius: Look.Radius.control).fill(hovering ? Look.Fill.hover : .clear))
            .background(MenuAnchor(menu: Self.menu))
            .onHover { hovering = $0 }
            .help(String(localized: "New Tab, Workspace or Worktree"))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "New"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { Self.menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
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
        Button { workbench.setPanelShown(!shown) } label: {
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
                            .offset(x: 4, y: -2)
                    }
                }
        }
        .buttonStyle(ChromeButtonStyle(selected: shown))
        .disabled(workbench.isHome)
        .help(shown ? String(localized: "Hide Files and Changes") : count > 0 ? String(localized: "Show Files and Changes: \(count) changed files") : String(localized: "Show Files and Changes"))
        .accessibilityLabel(shown ? String(localized: "Hide Files and Changes") : String(localized: "Show Files and Changes"))
        .accessibilityValue(count > 0 ? String(localized: "\(count) changed files") : "")
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
