import AppKit
import SwiftTerm
import WhiskrKit

/// What a terminal on screen tells its pane.
protocol TerminalSurfaceDelegate: AnyObject {
    /// Keys, pastes and the terminal's own answers to the program, to be sent to it.
    func surface(_ surface: TerminalSurface, typed bytes: ArraySlice<UInt8>)
    func surface(_ surface: TerminalSurface, resizedTo size: TerminalSize)
    /// The program in front named its window (OSC 0/2).
    func surface(_ surface: TerminalSurface, titled title: String)
    /// The shell said where it is (OSC 7).
    func surface(_ surface: TerminalSurface, movedTo directory: String?)
    func surface(_ surface: TerminalSurface, programStatus records: [TerminalProgramStatus])
}

/// One terminal on screen: SwiftTerm's view, in the active theme's colours and the chosen font and
/// cursor, following changes to either as they happen. The program it shows runs in the session host;
/// its output is fed in as it arrives (`show`) and what is typed goes out through the delegate.
final class TerminalSurface: TerminalView, TerminalViewDelegate {
    /// Thousands of lines, as herdr keeps; SwiftTerm's own default is 500.
    static let scrollbackLines = 10_000

    weak var surfaceDelegate: TerminalSurfaceDelegate?
    /// Output kept by the host is being drawn again after a relaunch. What the terminal would do in
    /// answer to it was done when it was first printed: its replies to the program, the bell and the
    /// clipboard are held back.
    var replaying = false {
        didSet { if replaying != oldValue { NotificationCenter.default.post(name: Self.replayingChanged, object: self) } }
    }
    /// A terminal began or finished drawing kept output again: its card holds it at the size the output
    /// was printed for meanwhile (a frame that changes underneath would re-lay the output out).
    static let replayingChanged = Notification.Name("Whiskr.TerminalReplayingChanged")

    /// The grid a frame of this size would hold.
    func size(for frame: NSSize) -> TerminalSize {
        let cell = getOptimalFrameSize().size
        let dimensions = terminalDimensions
        guard dimensions.cols > 0, dimensions.rows > 0, cell.width > 0, cell.height > 0 else { return TerminalSize(columns: 0, rows: 0) }
        return TerminalSize(columns: Int(frame.width / (cell.width / CGFloat(dimensions.cols))), rows: Int(frame.height / (cell.height / CGFloat(dimensions.rows))))
    }

    /// The view's size for the terminal's grid as it is now (the size kept output is drawn at).
    var gridFrameSize: NSSize { getOptimalFrameSize().size }

    private var themeObserver: Observing?
    private var appliedCursor: (ThemeStore.CursorShape, Bool)?
    nonisolated private let outputHandler = OutputHandler()

    init() {
        let store = ThemeStore.shared
        var options = TerminalOptions.default
        options.scrollback = Self.scrollbackLines
        options.cursorStyle = Self.cursorStyle(store.cursorShape, blinks: store.cursorBlinks)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: store.font(), options: options)
        terminalDelegate = self
        appliedCursor = (store.cursorShape, store.cursorBlinks)
        scrollerStyle = .overlay
        // SwiftTerm pauses drawing while its window is not visible, but a terminal attached before
        // the window is on screen never resumes (seen with SwiftTerm 1.99.1): output arrives and
        // nothing is drawn. Terminals in tabs not shown are out of the window and draw nothing anyway.
        suspendsRenderingWhenNotVisible = false
        setAccessibilityLabel("Terminal")
        themeObserver = Observing { [weak self] in self?.applySettings() }
    }

    required init?(coder: NSCoder) {
        fatalError("TerminalSurface is created in code")
    }

    // MARK: The program's side

    /// Draws what the program printed. Called on the pane's connection thread, where it is parsed, so
    /// a terminal printing a great deal never holds up the window.
    nonisolated func show(_ bytes: Data) {
        feed(byteArray: [UInt8](bytes)[...])
        outputHandler.call()
    }

    /// Runs after each piece of output has been taken in, on the thread that brought it.
    nonisolated func setOutputHandler(_ handler: (@Sendable () -> Void)?) {
        outputHandler.replace(with: handler)
    }

    /// The size in cells, and in pixels for programs that draw images.
    var size: TerminalSize {
        let dimensions = terminalDimensions
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let cells = getOptimalFrameSize().size
        return TerminalSize(columns: dimensions.cols, rows: dimensions.rows, pixelWidth: Int(cells.width * scale), pixelHeight: Int(cells.height * scale))
    }

    /// Takes the size a terminal has in the host, before its kept output is drawn again: output is laid
    /// out for the size it was printed at.
    func adopt(_ size: TerminalSize) {
        guard size.columns > 0, size.rows > 0 else { return }
        resize(cols: size.columns, rows: size.rows)
    }

    /// Goes back to the size the view itself has room for.
    func followFrame() {
        setFrameSize(frame.size)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard !replaying else { return }
        surfaceDelegate?.surface(self, typed: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        surfaceDelegate?.surface(self, resizedTo: size)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // The same cells are now a different number of pixels.
        if window != nil { surfaceDelegate?.surface(self, resizedTo: size) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        surfaceDelegate?.surface(self, titled: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        surfaceDelegate?.surface(self, movedTo: directory)
    }

    func programStatusChanged(source: TerminalView, records: [TerminalProgramStatus]) {
        guard !replaying else { return }
        surfaceDelegate?.surface(self, programStatus: records)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// ⌘-click on a link or a file path the terminal printed ("src/app.ts:12"): the window decides (a file
    /// opens in the editor at that line); with no one listening, the system opens it.
    var onOpenLink: ((String) -> Void)?

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let onOpenLink { onOpenLink(link) } else { TerminalView.openDefaultLink(link) }
    }

    func bell(source: TerminalView) {
        guard !replaying else { return }
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard !replaying, let text = String(bytes: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([text as NSString])
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    // MARK: Look

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// Everything the theme store decides; runs again whenever any of it changes.
    private func applySettings() {
        let store = ThemeStore.shared
        applyColors()
        let font = store.font()
        if self.font != font { self.font = font }
        if lineSpacing != store.lineHeight { lineSpacing = store.lineHeight }
        let cursor = (store.cursorShape, store.cursorBlinks)
        if appliedCursor.map({ $0 != cursor }) ?? true {
            appliedCursor = cursor
            // DECSCUSR, as a program would send it: the cursor takes the new shape at once.
            feed(text: "\u{1b}[\(Self.decscusr(cursor.0, blinks: cursor.1)) q")
        }
    }

    private func applyColors() {
        let colors = ThemeStore.shared.palette.theme.variant(dark: Palette.isDark(effectiveAppearance)).terminal
        installColors(colors.ansi.map { SwiftTerm.Color(red: UInt16($0.red * 65535), green: UInt16($0.green * 65535), blue: UInt16($0.blue * 65535)) })
        nativeBackgroundColor = Palette.nsColor(colors.background)
        nativeForegroundColor = Palette.nsColor(colors.foreground)
        caretColor = Palette.nsColor(colors.cursor)
        selectedTextBackgroundColor = Palette.nsColor(colors.selection)
    }

    private static func cursorStyle(_ shape: ThemeStore.CursorShape, blinks: Bool) -> CursorStyle {
        switch shape {
        case .block: blinks ? .blinkBlock : .steadyBlock
        case .underline: blinks ? .blinkUnderline : .steadyUnderline
        case .bar: blinks ? .blinkBar : .steadyBar
        }
    }

    private static func decscusr(_ shape: ThemeStore.CursorShape, blinks: Bool) -> Int {
        switch shape {
        case .block: blinks ? 1 : 2
        case .underline: blinks ? 3 : 4
        case .bar: blinks ? 5 : 6
        }
    }
}

/// A callback that can be replaced from the main thread while a connection thread calls it.
nonisolated private final class OutputHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    func replace(with handler: (@Sendable () -> Void)?) { lock.withLock { self.handler = handler } }
    func call() { lock.withLock { handler }?() }
}
