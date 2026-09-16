import AppKit
import SwiftUI

/// The controls of the window's bars (the top bar, the tab row, the status bar): drawn by SwiftUI, clicked
/// through AppKit, as the tabs are (`TabMouseView`).
///
/// SwiftUI's hosting view takes a click on anything SwiftUI draws there, and does nothing with it unless a
/// gesture of SwiftUI's own is under it. A menu button drawn over an AppKit view that pops the menu was
/// therefore dead: the click went to the hosting view, never to the view under the drawing. And in the
/// title bar's band (the top bar) a hosting view says the window may move wherever it is pressed, so a
/// real window's server drags the window there. So each control here is an AppKit view under its drawing,
/// which lets every click through (`allowsHitTesting(false)`): the view takes the first click even in a
/// window behind others, says the window must not move where it is, follows the pointer for the hover fill,
/// shows the pressed fill while the button is down or its menu is open, pops its menu the moment the
/// button goes down (as a pop-up button does) or acts when it comes up over it (as a push button does),
/// and carries the tooltip. SwiftUI keeps what it does well: the drawing, the fills, and the keyboard and
/// VoiceOver, through a button (unreachable by the pointer) that does what a click does.
extension View {
    /// This drawing as a button of the bars: `action` runs when a click comes up over it, or when the
    /// keyboard or VoiceOver presses it. `id` names the control (`NSView.identifier`).
    func barButton(_ id: String, label: String, help: String, value: String? = nil, selected: Bool = false, enabled: Bool = true,
                   radius: CGFloat = Look.Radius.control, action: @escaping () -> Void) -> some View {
        modifier(BarControlModifier(id: id, label: label, help: help, value: value, hint: nil, selected: selected, enabled: enabled,
                                    radius: radius, kind: .button(action), onDoubleClick: nil))
    }

    /// This drawing as a pop-up button of the bars: its menu (made afresh each time) opens under it, aligned
    /// to it, the moment the button goes down, or when the keyboard or VoiceOver presses it. A second click
    /// of a double-click calls `onDoubleClick` instead.
    func barMenu(_ id: String, label: String, help: String, value: String? = nil, hint: String? = nil, radius: CGFloat = Look.Radius.control,
                 onDoubleClick: (() -> Void)? = nil, menu: @escaping () -> NSMenu) -> some View {
        modifier(BarControlModifier(id: id, label: label, help: help, value: value, hint: hint, selected: false, enabled: true,
                                    radius: radius, kind: .menu(menu), onDoubleClick: onDoubleClick))
    }
}

private struct BarControlModifier: ViewModifier {
    let id: String
    let label: String
    let help: String
    let value: String?
    let hint: String?
    let selected: Bool
    let enabled: Bool
    let radius: CGFloat
    let kind: BarControlView.Kind
    let onDoubleClick: (() -> Void)?
    @State private var handle = BarControlHandle()
    @State private var hovering = false
    @State private var pressed = false

    func body(content: Content) -> some View {
        // The keyboard's and VoiceOver's way in: the pointer never reaches this button, the view under it does.
        Button { handle.view?.activate() } label: {
            content.background(RoundedRectangle(cornerRadius: radius).fill(fill))
        }
        .buttonStyle(DrawingOnly())
        .disabled(!enabled)
        .allowsHitTesting(false)
        .background(BarControl(id: id, help: help, kind: kind, enabled: enabled, onDoubleClick: onDoubleClick, handle: handle) { hover, press in
            hovering = hover
            pressed = press
        })
        .accessibilityLabel(label)
        .accessibilityValue(value ?? "")
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The same fills as every control of the bars (`ChromeButtonStyle`'s).
    private var fill: Color {
        guard enabled else { return .clear }
        if pressed { return Look.Fill.pressed }
        if selected { return Look.Fill.selected }
        return hovering ? Look.Fill.hover : .clear
    }

    /// The drawing as it is: its fills follow AppKit's pointer, not this button's.
    private struct DrawingOnly: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }
}

/// The view behind a control, reachable from its SwiftUI button.
@MainActor
final class BarControlHandle {
    weak var view: BarControlView?
}

private struct BarControl: NSViewRepresentable {
    let id: String
    let help: String
    let kind: BarControlView.Kind
    let enabled: Bool
    let onDoubleClick: (() -> Void)?
    let handle: BarControlHandle
    let look: (_ hovering: Bool, _ pressed: Bool) -> Void

    func makeNSView(context: Context) -> BarControlView { BarControlView() }

    func updateNSView(_ view: BarControlView, context: Context) {
        handle.view = view
        view.identifier = NSUserInterfaceItemIdentifier(id)
        view.toolTip = help.isEmpty ? nil : help
        view.kind = kind
        view.isEnabled = enabled
        view.onDoubleClick = onDoubleClick
        view.onLook = look
    }
}

/// The pointer on a control of the bars, in AppKit (see `barButton` and `barMenu`).
final class BarControlView: NSView {
    enum Kind {
        /// Acts when a click comes up over the control.
        case button(() -> Void)
        /// Pops this menu under the control when the button goes down.
        case menu(() -> NSMenu)
    }

    var kind: Kind = .button({})
    var onDoubleClick: (() -> Void)?
    var onLook: (_ hovering: Bool, _ pressed: Bool) -> Void = { _, _ in }
    var isEnabled = true {
        didSet {
            guard !isEnabled else { return }
            hovering = false
            pressed = false
        }
    }
    private var hovering = false {
        didSet { if hovering != oldValue { onLook(hovering, pressed) } }
    }
    /// The button is down over the control, or its menu is open.
    private var pressed = false {
        didSet { if pressed != oldValue { onLook(hovering, pressed) } }
    }

    /// Room between the control and the menu it opens.
    static let menuGap = Look.Space.xs

    override var isFlipped: Bool { true }

    /// A control in a window that is not the key one acts at the first click, as the tabs and every
    /// title bar control do: the click is not spent on bringing the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A press here is the control's, never the start of a window drag, in the title bar's band too.
    override var mouseDownCanMoveWindow: Bool { false }

    private var hoverArea: NSTrackingArea?

    /// The pointer, followed over the control's own bounds in every window (key or not, the app active or
    /// not). Not `inVisibleRect`: inside SwiftUI's hosting view a platform view's visible rect is the
    /// whole window, which had every control hovered at once.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = isEnabled }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2, let onDoubleClick { return onDoubleClick() }
        switch kind {
        case .menu: popUpMenu()
        case .button: pressed = true
        }
    }

    /// A push button shows itself pressed only while the pointer is over it, and acts only if released there.
    override func mouseDragged(with event: NSEvent) {
        guard case .button = kind, isEnabled else { return }
        pressed = isOver(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard case .button(let action) = kind, pressed else { return }
        pressed = false
        if isOver(event) { action() }
    }

    /// What a click does, for the keyboard and VoiceOver.
    func activate() {
        guard isEnabled else { return }
        switch kind {
        case .menu: popUpMenu()
        case .button(let action): action()
        }
    }

    /// The menu, under the control and aligned to its leading edge, at least as wide (a pop-up button's).
    /// It is modal: this returns once the menu has closed.
    private func popUpMenu() {
        guard case .menu(let make) = kind else { return }
        let menu = make()
        menu.minimumWidth = bounds.width
        pressed = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + Self.menuGap), in: self)
        pressed = false
        // The second click of a double-click lands while the menu is open and closes it: that is the double-click.
        if let onDoubleClick, let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .leftMouseUp, event.clickCount >= 2,
           let window, window.convertToScreen(convert(bounds, to: nil)).contains(NSEvent.mouseLocation) {
            onDoubleClick()
        }
        hovering = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }

    private func isOver(_ event: NSEvent) -> Bool {
        bounds.contains(convert(event.locationInWindow, from: nil))
    }
}

/// The bars' hosting views (the top bar, the tab row, the status bar). A click goes to the AppKit control
/// under it (`BarControlView`, `TabMouseView`, the window's drag area), whatever SwiftUI has put over that
/// control: SwiftUI hosts some of its drawing in views of its own, laid over the AppKit view a drawing sits
/// on (a button's keyboard focus ring, a picture drawn above a platform view), and those views took the click
/// now and then, depending on what SwiftUI had built at that moment: a press on the Home button, or on a tab
/// right after a drop, went to `_NSGraphicsView` and did nothing (or moved the window); and a press on the
/// status bar's "need you" a frame after a tab opened went to the hosting view itself, which did nothing with
/// it. Where no control of the bars lies under the pointer, the press goes where SwiftUI says (Go to's field
/// is SwiftUI's own button), and a field's text view or a control SwiftUI wraps keeps its clicks.
class BarHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        BarHitTesting.resolve(super.hitTest(point), in: self, at: point)
    }
}

@MainActor
enum BarHitTesting {
    /// `hit`, unless it is SwiftUI's (the hosting view or a view of its own) with a control of the bars under
    /// the point: then that control (the topmost). `point` is in the host's superview's coordinates, as
    /// `hitTest` has it.
    static func resolve(_ hit: NSView?, in host: NSView, at point: NSPoint) -> NSView? {
        if let hit, hit !== host, takesClicks(hit, below: host) { return hit }
        return control(in: host, at: point) ?? hit
    }

    private static func isBarControl(_ view: NSView) -> Bool {
        view is BarControlView || view is TabMouseView || view is WindowDragArea.DragView
    }

    /// A view that does something with a click: a control of the bars, or an AppKit control or text view
    /// SwiftUI wraps (a rename field), or one inside them.
    private static func takesClicks(_ view: NSView, below host: NSView) -> Bool {
        var each: NSView? = view
        while let current = each, current !== host {
            if isBarControl(current) || current is NSControl || current is NSText { return true }
            each = current.superview
        }
        return false
    }

    /// The topmost control of the bars under `point`: the last found, as views later among their siblings
    /// are drawn (and hit) above earlier ones. Not the window's drag area: SwiftUI's own button over an
    /// empty stretch (Go to's field) is SwiftUI's to take.
    private static func control(in host: NSView, at point: NSPoint) -> NSView? {
        var found: NSView?
        func walk(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden {
                if isBarControl(sub) {
                    if !(sub is WindowDragArea.DragView), sub.convert(sub.bounds, to: host.superview).contains(point) { found = sub }
                } else {
                    walk(sub)
                }
            }
        }
        walk(host)
        return found
    }
}
