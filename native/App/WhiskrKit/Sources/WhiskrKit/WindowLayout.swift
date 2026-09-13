import Foundation

/// How the window is arranged: herdr's arrangement with the meadow as the star. The meadow is on the
/// left where herdr's sidebar is, the terminals on the right, both present; by default the meadow takes
/// about 42 % of the window while the terminals keep 90 columns. The divider drags anywhere from a 240 pt
/// sidebar to the meadow taking the whole window; View has three one-key forms (Meadow and Terminals,
/// Terminals Only, Meadow Only). With no terminal open the meadow fills the window: it is the welcome.
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
    /// The narrowest you can drag the terminals to.
    public static let terminalMinimum: Double = 320
    /// Dragging the divider this close to either edge switches to that region alone.
    public static let snap: Double = 120

    public init(navigator: Navigator = .meadow, mode: Mode = .split, navigatorWidth: Double? = nil) {
        self.navigator = navigator
        self.mode = mode
        self.navigatorWidth = navigatorWidth
    }

    /// What the window shows, `width` points wide, while terminals are open or not.
    public struct Frame: Equatable, Sendable {
        /// The meadow's width: 0 while it is hidden, the window's width when it is alone.
        public var navigator: Double
        public var showsTerminals: Bool
    }

    public func frame(window width: Double, hasTerminals: Bool) -> Frame {
        // Nothing open: the meadow is the welcome.
        guard hasTerminals else { return Frame(navigator: width, showsTerminals: false) }
        switch mode {
        case .meadowOnly: return Frame(navigator: width, showsTerminals: false)
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

    /// View › Hide Meadow / Show Meadow (⌃⌘S): the terminals alone, or back to both.
    public mutating func toggleNavigator() {
        mode = mode == .terminalsOnly ? .split : .terminalsOnly
    }

    // MARK: Saving

    private enum CodingKeys: String, CodingKey { case navigator, mode, navigatorWidth }

    /// Reads what it can: anything missing or unknown keeps its default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        if let value = try? container.decodeIfPresent(Navigator.self, forKey: .navigator) { navigator = value }
        if let value = try? container.decodeIfPresent(Mode.self, forKey: .mode) { mode = value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: .navigatorWidth), value.isFinite, value >= Self.navigatorMinimum {
            navigatorWidth = value
        }
    }

    public var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public init(data: Data?) {
        self = data.flatMap { try? JSONDecoder().decode(WindowLayout.self, from: $0) } ?? WindowLayout()
    }
}
