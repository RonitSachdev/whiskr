import Foundation

/// How the window is arranged: herdr's arrangement with the meadow as the star. The meadow is on the
/// left where herdr's sidebar is, the terminals on the right, both present; by default the meadow takes
/// about 42 % of the window while the terminals keep 90 columns. The divider drags anywhere from a 240 pt
/// sidebar to the meadow taking the whole window; View has three one-key forms (Meadow and Terminals,
/// Terminals Only, Meadow Only). Home (no workspace selected) has the same arrangement, its page in the
/// terminals' place, so entering or leaving it moves nothing.
public struct WindowLayout: Equatable, Sendable, Codable {
    public enum Navigator: String, Codable, Sendable, CaseIterable {
        case meadow, list
    }

    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Meadow and Terminals.
        case split
        case terminalsOnly
        case meadowOnly
    }

    public var navigator: Navigator
    public var mode: Mode
    /// The meadow's width once you have dragged the divider; nil for the default share of the window.
    public var navigatorWidth: Double?
    /// View › Show Status Bar.
    public var showsStatusBar: Bool

    /// The meadow's share of the window by default, and its limits then.
    public static let defaultShare: Double = 0.42
    public static let defaultRange: ClosedRange<Double> = 380...780
    /// The narrowest the meadow is shown (a sidebar holding one column of workspaces).
    public static let navigatorMinimum: Double = 240
    /// The default split hides the meadow rather than make it narrower than its sidebar form.
    public static let sidebarForm: Double = 300
    /// 90 columns of SF Mono 13 (7.8 pt each) with the terminal's padding: what the default split keeps.
    public static let terminalComfort: Double = 718
    /// 80 columns: what the default split still keeps once the meadow has narrowed to its sidebar form
    /// (the pane area's minimum, docs/DESIGN.md). Only below this does the meadow step aside.
    public static let terminalCompact: Double = 640
    /// The narrowest you can drag the terminals to, and the least they keep whatever the meadow asks.
    public static let terminalMinimum: Double = 320
    /// Dragging the divider this close to either edge switches to that region alone.
    public static let snap: Double = 120

    public init(navigator: Navigator = .meadow, mode: Mode = .split, navigatorWidth: Double? = nil, showsStatusBar: Bool = true) {
        self.navigator = navigator
        self.mode = mode
        self.navigatorWidth = navigatorWidth
        self.showsStatusBar = showsStatusBar
    }

    /// What the window shows, `width` points wide.
    public struct Frame: Equatable, Sendable {
        /// The meadow's width: 0 while it is hidden, the window's width when it is alone.
        public var navigator: Double
        public var showsTerminals: Bool

        /// The meadow alone, the window's whole width: Meadow Only, and the meadow while it is edited.
        public static func meadowAlone(window width: Double) -> Frame { Frame(navigator: width, showsTerminals: false) }
    }

    public func frame(window width: Double) -> Frame {
        switch mode {
        case .meadowOnly: return .meadowAlone(window: width)
        case .terminalsOnly: return Frame(navigator: 0, showsTerminals: true)
        case .split: break
        }
        if let navigatorWidth {
            let most = width - Self.terminalMinimum
            guard most >= Self.navigatorMinimum else { return Frame(navigator: 0, showsTerminals: true) }
            return Frame(navigator: min(max(navigatorWidth, Self.navigatorMinimum), most), showsTerminals: true)
        }
        // The default: 42 % (380 to 780), never leaving the terminals under 90 columns. Short of room the
        // meadow keeps its sidebar form (300) while the terminals keep 80 columns, then narrows to the
        // narrowest sidebar (240); only a window too small for even that (under 880) hides it, so your
        // other workspaces stay in sight on a laptop's half screen.
        let share = min(max(width * Self.defaultShare, Self.defaultRange.lowerBound), Self.defaultRange.upperBound)
        let roomy = min(share, width - Self.terminalComfort)
        if roomy >= Self.sidebarForm { return Frame(navigator: roomy, showsTerminals: true) }
        let compact = min(Self.sidebarForm, width - Self.terminalCompact)
        return compact >= Self.navigatorMinimum ? Frame(navigator: compact, showsTerminals: true) : Frame(navigator: 0, showsTerminals: true)
    }

    /// The divider was dragged to `x` in a window `width` wide: near either edge it gives that edge's
    /// region the window; otherwise the meadow keeps the width it was given.
    public mutating func dragDivider(to x: Double, window width: Double) {
        if x < Self.snap {
            mode = .terminalsOnly
        } else if x > width - Self.snap {
            mode = .meadowOnly
        } else {
            mode = .split
            navigatorWidth = max(x, Self.navigatorMinimum)
        }
    }

    /// Double-clicking the divider: the default split.
    public mutating func resetSplit() {
        navigatorWidth = nil
        mode = .split
    }

    /// The meadow is on screen in a window `width` wide: what the meadow button and View › Hide Meadow /
    /// Show Meadow go by, rather than the mode, since the default split hides it in a narrow window.
    public func showsNavigator(window width: Double) -> Bool {
        frame(window: width).navigator > 0
    }

    /// View › Hide Meadow / Show Meadow (⌃⌘S): the terminals alone, or the meadow back beside them.
    public mutating func toggleNavigator(window width: Double) {
        if showsNavigator(window: width) { mode = .terminalsOnly } else { showNavigator(window: width) }
    }

    /// Asked for, the meadow shows at any width the window can have. Where the default split has no room
    /// for it (a window under 880 pt), it takes its narrowest sidebar, as if the divider had been dragged
    /// there: the terminals keep the rest, under their 80 columns but never under their least, so both
    /// stay in sight. Only a window too narrow for even that (none the app allows) gives it the window.
    public mutating func showNavigator(window width: Double) {
        guard !showsNavigator(window: width) else { return }
        mode = .split
        if !showsNavigator(window: width) { navigatorWidth = Self.navigatorMinimum }
        if !showsNavigator(window: width) { mode = .meadowOnly }
    }

    /// View › Reset Layout: every region back, at its usual size. How the workspaces are drawn (meadow or
    /// list) is a preference, not a region, and stays.
    public mutating func reset() {
        self = WindowLayout(navigator: navigator)
    }

    // MARK: Saving

    private enum CodingKeys: String, CodingKey { case navigator, mode, navigatorWidth, showsStatusBar }

    /// Reads what it can: anything missing or unknown keeps its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let value = try? container.decodeIfPresent(Navigator.self, forKey: .navigator) { navigator = value }
        if let value = try? container.decodeIfPresent(Mode.self, forKey: .mode) { mode = value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: .navigatorWidth), value.isFinite, value >= Self.navigatorMinimum {
            navigatorWidth = value
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: .showsStatusBar) { showsStatusBar = value }
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(WindowLayout.self, from: $0) } ?? WindowLayout()
    }
}
