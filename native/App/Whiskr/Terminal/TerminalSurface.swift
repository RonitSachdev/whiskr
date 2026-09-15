import AppKit
import Metal
import SwiftTerm
import WhiskrKit

/// What a terminal on screen tells its pane.
protocol TerminalSurfaceDelegate: AnyObject {
    /// Keys, pastes and the terminal's own answers to the program, to be sent to it.
    func surface(_ surface: TerminalSurface, typed bytes: ArraySlice<UInt8>)
    func surface(_ surface: TerminalSurface, resizedTo size: TerminalSize)
    /// The view is shown again (back in the window, or no longer hidden): sizes taken while it was not are
    /// told now.
    func surfaceShown(_ surface: TerminalSurface)
    /// The program in front named its window (OSC 0/2).
    func surface(_ surface: TerminalSurface, titled title: String)
    /// The shell said where it is (OSC 7).
    func surface(_ surface: TerminalSurface, movedTo directory: String?)
    func surface(_ surface: TerminalSurface, programStatus records: [TerminalProgramStatus])
    /// The program rang the terminal's bell (BEL).
    func surfaceRang(_ surface: TerminalSurface)
    /// The shell marked a command (OSC 133): one started, or one ended with its exit status.
    func surface(_ surface: TerminalSurface, command: TerminalCommandMark)
}

/// What a shell's command marks (OSC 133) say happened, as the app needs it.
nonisolated enum TerminalCommandMark: Equatable, Sendable {
    /// "C": a command typed at the prompt is running.
    case started
    /// "D": it ended, with its exit status (nil when the shell did not say).
    case finished(status: Int32?)

    /// Reads one OSC 133 payload ("C", "D;1", "A;k=i"); nil for the marks the app does not act on.
    static func parse(_ payload: [UInt8]) -> TerminalCommandMark? {
        guard let action = payload.first else { return nil }
        switch action {
        case UInt8(ascii: "C"): return .started
        case UInt8(ascii: "D"):
            let fields = payload.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
            return .finished(status: fields.count > 1 ? Int32(String(decoding: fields[1], as: UTF8.self)) : nil)
        default: return nil
        }
    }
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

    /// Terminals draw with SwiftTerm's Metal renderer, on a render thread of their own: the main thread
    /// only says that a frame is due. (Its Core Graphics renderer, SwiftTerm's default, draws every frame
    /// on the main thread, beside the meadow, typing and the window's own work.) Debug builds can keep
    /// Core Graphics for comparison: `--cg-terminals`.
    static let drawsWithMetal: Bool = {
        #if DEBUG
        !ProcessInfo.processInfo.arguments.contains("--cg-terminals")
        #else
        true
        #endif
    }()
    /// Metal has been turned on once (or failed, and the terminal stays on Core Graphics).
    private var metalTried = false
    /// The renderer was given back while the terminal was out of the window (`restMetal`).
    private var metalRested = false
    private var metalRest: Task<Void, Never>?

    private var themeObserver: Observing?
    private var appliedCursor: (ThemeStore.CursorShape, Bool)?
    /// What the terminal last told programs it is: light or dark (`applyColors`).
    private var appliedScheme: TerminalColorScheme?
    nonisolated private let outputHandler = OutputHandler()
    /// Command marks, read off SwiftTerm's own queue (`observeOscEvents`) and brought to the main thread.
    private var commandMarks: TerminalOscObservation?
    /// Find (⌘F), and the link under the pointer while ⌘ is held: made the first time they are needed.
    var findBar: TerminalFindBar?
    var linkUnderline: LinkUnderlineView?
    /// What reflection found of SwiftTerm's internals (`TerminalReach`), looked up once.
    var reachCache: TerminalReach??
    /// The prompt of the command whose output ⇧⌘↑ / ⇧⌘↓ selected last.
    var selectedCommandPrompt: Int?
    /// A ⌘-click opened a link: its release is not SwiftTerm's.
    var swallowsMouseUp = false
    /// The click that brought the window forward (`acceptsFirstMouse`): it chooses the pane and nothing more.
    var activatingClick: Int?
    /// A link the terminal printed, to be opened, shown in Files or copied (`PaneCard` resolves it).
    var onLink: ((TerminalLink, TerminalLinkAction) -> Void)?
    /// Whether a link names something there is (a path that exists, or any web link): only those are
    /// underlined and opened, so `console.log` or `and/or` stay text.
    var linkResolves: ((TerminalLink) -> Bool)?

    init() {
        let store = ThemeStore.shared
        var options = TerminalOptions.default
        options.scrollback = Self.scrollbackLines
        options.cursorStyle = Self.cursorStyle(store.cursorShape, blinks: store.cursorBlinks)
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: store.font(), options: options)
        terminalDelegate = self
        appliedCursor = (store.cursorShape, store.cursorBlinks)
        scrollerStyle = .overlay
        // Links: the app finds paths and web links itself (`TerminalLink`, ⌘ held), so SwiftTerm keeps to
        // those a program marks (OSC 8). Unfocused terminals show a hollow cursor.
        linkReporting = .explicit
        caretViewTracksFocus = true
        // SwiftTerm pauses drawing while its window is not visible, but a terminal attached before
        // the window is on screen never resumes (seen with SwiftTerm 1.99.1): output arrives and
        // nothing is drawn. Terminals in tabs not shown are out of the window and draw nothing anyway.
        suspendsRenderingWhenNotVisible = false
        setAccessibilityLabel("Terminal")
        themeObserver = Observing { [weak self] in self?.applySettings() }
        // A handful of marks per command, so each one is simply handed over; the payloads are copies.
        commandMarks = observeOscEvents { [weak self] event in
            guard event.code == 133, let mark = TerminalCommandMark.parse(event.payload) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.heard(mark) } }
        }
    }

    private func heard(_ mark: TerminalCommandMark) {
        guard !replaying else { return }
        surfaceDelegate?.surface(self, command: mark)
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

    /// Metal is turned on in the first window the view joins (it needs one); a device or shader that fails
    /// leaves the terminal on Core Graphics. Out of the window for a while (its tab not shown), the terminal
    /// gives its renderer back, and takes a new one as it returns.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { surfaceDelegate?.surfaceShown(self) }
        guard Self.drawsWithMetal else { return }
        if window == nil { restMetal() } else { wakeMetal() }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if window != nil { surfaceDelegate?.surfaceShown(self) }
    }

    private func wakeMetal() {
        metalRest?.cancel()
        metalRest = nil
        guard !metalTried || metalRested else { return }
        let returning = metalRested
        metalTried = true
        metalRested = false
        do {
            try setUseMetal(true)
            keepFramesUnscaled()
            // A new renderer's layer is empty until its first frame: drawn now, before the window shows it,
            // the terminal never flashes blank.
            if returning { drawMetalFrameNow() }
        } catch {
            NSLog("Whiskr: terminals draw without Metal: \(error)")
        }
    }

    /// SwiftTerm hands a size change made during a live resize to the renderer's next frame instead of resizing
    /// the grid, and that frame applies it even after a later, immediate change: after a divider's drag the grid
    /// went back to its size from before the drag, the program never told the new one (`make perf`'s sizes
    /// check, about one run in two). The app holds each terminal's size through a live resize itself
    /// (`LiveResize`, `PaneCard`), so to SwiftTerm the view is never in one and every change is applied at once.
    override var inLiveResize: Bool { false }

    /// The renderer's frames are drawn on its own thread and reach the screen a frame after the view's new
    /// size does (a drag's end, a split, the window resized). Meanwhile the layer would stretch the frame it
    /// has to the new size, the text swelling or squashing for a moment; pinned at the top left instead, the
    /// text stays where it is and the new room shows the terminal's background until the next frame.
    private func keepFramesUnscaled() {
        for view in subviews where view.layer is CAMetalLayer {
            view.layerContentsPlacement = .topLeft
        }
    }

    /// A renderer keeps its drawables (the layer's frames at the pane's size in pixels: 10 MB each for a
    /// full-width pane on a Retina display), glyph atlases and buffers while its terminal is out of the
    /// window; SwiftTerm only stops drawing. Twenty tabs held 770 MB, against 200 MB once given back.
    /// Taking a new one costs the main thread 3–15 ms as the tab is shown again (its shaders are compiled
    /// already, `TerminalShaderWarmup`), so a tab gone back and forth between is left as it is.
    private func restMetal() {
        guard isUsingMetalRenderer, metalRest == nil else { return }
        metalRest = Task { [weak self] in
            try? await Task.sleep(for: Self.metalRestDelay)
            guard let self, !Task.isCancelled, window == nil else { return }
            metalRest = nil
            // A frame still in flight keeps the renderer; the next time the tab is hidden tries again.
            guard (try? setUseMetal(false)) != nil else { return }
            metalRested = true
        }
    }

    /// How long a terminal stays out of the window before it gives its renderer back. Debug builds can
    /// change it, to measure: `--metal-rest-after <seconds>`.
    static let metalRestDelay: Duration = {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--metal-rest-after"), arguments.indices.contains(index + 1),
           let seconds = Double(arguments[index + 1]) {
            return .milliseconds(Int(seconds * 1000))
        }
        #endif
        return .seconds(30)
    }()

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

    /// A link underlined under the pointer no longer lines up once the text has moved.
    func scrolled(source: TerminalView, position: Double) {
        if linkUnderline?.isHidden == false { linkUnderline?.isHidden = true }
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// ⌘-click on a link a program marked (OSC 8): the window decides (a file opens in the editor at its
    /// line); with no one listening, the system opens it. Links the app finds itself go to `onLink`.
    var onOpenLink: ((String) -> Void)?

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let onOpenLink { onOpenLink(link) } else { TerminalView.openDefaultLink(link) }
    }

    /// The pane decides whether to sound it, or mark its tab (`Pane`).
    func bell(source: TerminalView) {
        guard !replaying else { return }
        surfaceDelegate?.surfaceRang(self)
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard !replaying, let text = String(bytes: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([text as NSString])
    }

    /// A program never reads the clipboard (OSC 52 "?"): anything that only prints, a `cat` of a file or
    /// a remote host, could otherwise take a password and have it typed back. Writes (tmux, an editor's
    /// yank) still reach it. Refused on both of SwiftTerm's paths, as this answer is what both ask.
    func clipboardRead(source: TerminalView) -> Data? { nil }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        validateOwnItem(item) ?? super.validateUserInterfaceItem(item)
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
        // A program that asks whether the terminal is light or dark (`CSI ? 996 n`, or told as it changes after
        // `CSI ? 2031 h`) picks its colours for that background: SwiftTerm says dark until told.
        let scheme: TerminalColorScheme = colors.isDark ? .dark : .light
        if appliedScheme != scheme {
            appliedScheme = scheme
            updateColorScheme(scheme)
        }
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

/// SwiftTerm compiles its Metal shaders from source, and builds six pipelines from them, for each terminal's
/// renderer, on the main thread, in the turn the terminal is first shown (`setUseMetal`). Metal keeps what
/// it compiled for each copy of the app, so later terminals take about 2 ms; but the first one after an
/// install, an update or a macOS update waits for the compiler: 75–180 ms measured, in the turn of ⌘T.
/// Compiling the same source once at launch, off the main thread, takes that wait out of every terminal's way.
///
/// The source is SwiftTerm's own `Shaders.metal`, which its package leaves out of its target (it embeds the
/// same text in its code, less the last line break); a build step copies it into the app (`project.yml`).
/// Should the two ever differ, nothing breaks: the warm-up only stops helping.
enum TerminalShaderWarmup {
    /// At launch, before any terminal is shown.
    static func start() {
        guard TerminalSurface.drawsWithMetal,
              let url = Bundle.main.url(forResource: "SwiftTermShaders", withExtension: "metal") else { return }
        Task.detached(priority: .utility) { compile(url) }
    }

    /// The pipelines SwiftTerm's renderer builds, as it describes them: its text pipelines blend
    /// premultiplied colour, its colour pipelines straight alpha, into its layer's pixel format.
    nonisolated private static let pipelines: [(vertex: String, fragment: String, source: MTLBlendFactor)] = [
        ("terminal_text_vertex", "terminal_text_fragment", .one),
        ("terminal_text_vertex", "terminal_text_fragment_gray", .one),
        ("terminal_cell_text_vertex", "terminal_text_fragment", .one),
        ("terminal_cell_text_vertex", "terminal_text_fragment_gray", .one),
        ("terminal_color_vertex", "terminal_color_fragment", .sourceAlpha),
        ("terminal_cell_color_vertex", "terminal_color_fragment", .sourceAlpha),
    ]

    nonisolated private static func compile(_ url: URL) {
        guard let file = try? String(contentsOf: url, encoding: .utf8), let device = MTLCreateSystemDefaultDevice(),
              let library = try? device.makeLibrary(source: file.hasSuffix("\n") ? String(file.dropLast()) : file, options: nil) else { return }
        for pipeline in pipelines {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: pipeline.vertex)
            descriptor.fragmentFunction = library.makeFunction(name: pipeline.fragment)
            guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil, let attachment = descriptor.colorAttachments[0] else { return }
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = pipeline.source
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            _ = try? device.makeRenderPipelineState(descriptor: descriptor)
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
