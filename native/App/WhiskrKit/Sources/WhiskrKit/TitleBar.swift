import Foundation

/// What a double-click on the window's bars does: the same as on any Mac title bar, as set in System
/// Settings › Desktop & Dock ("Double-click a window's title bar to"). The app draws its own bars, so it
/// reads that setting itself.
public enum TitleBarDoubleClick: Equatable, Sendable {
    case zoom, minimize, nothing

    /// From the global defaults: `AppleActionOnDoubleClick` ("Fill", "Maximize", "Minimize", "None";
    /// absent on a Mac that never changed it), else the older `AppleMiniaturizeOnDoubleClick`. "Fill"
    /// and "Maximize" both zoom: a window with no size of its own to return to zooms to fill the screen,
    /// and a second double-click puts it back, as the system's own does.
    public init(action: String?, miniaturize: Bool) {
        switch action {
        case "Minimize": self = .minimize
        case "None": self = .nothing
        case "Fill", "Maximize": self = .zoom
        default: self = miniaturize ? .minimize : .zoom
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.init(action: defaults.string(forKey: "AppleActionOnDoubleClick"), miniaturize: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"))
    }
}
