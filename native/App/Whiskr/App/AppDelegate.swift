import AppKit
import UniformTypeIdentifiers
import WhiskrKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    private let workbench: Workbench
    private var windowController: MainWindowController?
    private var quitting = false
    /// The unsaved files were saved or let go, for the Quit that asked about them.
    private var editedFilesSettled = false
    private var terminationSignal: DispatchSourceSignal?
    /// Folders handed over before the workbench was ready (opened from the Finder or the Dock at launch).
    private var pendingFolders: [String] = []
    private var launched = false
    /// Keeps the Dock's count of requests in step with the model (`updateDockBadge`).
    private var dockBadgeWatch: Observing?

    override init() {
        workbench = Workbench()
        super.init()
    }

    static func main() {
        #if DEBUG
        // Before anything reads settings or the support folder.
        DebugScenario.prepareProcess()
        #endif
        // Before anything reads them too: a Workers Factory's settings and files become Whiskr's, once.
        if !AppPlaces.isIsolated { AppMigration.run() }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // NSApplication holds its delegate weakly; this keeps it for the life of the app.
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SwiftTerm's shaders, compiled off the main thread now so the first terminal does not wait for them.
        TerminalShaderWarmup.start()
        NSApp.mainMenu = MainMenu.build()
        MainMenu.openRecent.delegate = self
        _ = ThemeStore.shared
        // Languages added in Settings, before any file is opened (a few small index files).
        LanguageRegistry.shared.loadInstalled(from: SettingsWindowController.languagesFolder)
        SecureKeyboard.shared.update()
        handleTerminationSignal()
        WorldStore.shared.start()
        let controller = MainWindowController(workbench: workbench)
        windowController = controller
        // The Dock counts the requests waiting, as the model has them now: one answered, a Claude gone, its
        // tab closed, the setting turned off. (Set only as Claudes changed, a closed tab's request stayed on it.)
        dockBadgeWatch = Observing { [weak self] in self?.updateDockBadge() }
        #if DEBUG
        if DebugScenario.keepsInBackground { DebugScript.keepOutOfSight() }
        #endif
        // The window comes once the workspaces are back, drawn as it will stay: Home with every blanket,
        // rather than an empty Home that fills in a moment later. A slow start (the session host's first
        // launch) shows it after a second regardless.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.present(controller) }
        // AppKit sets up its text-cursor helper (a hidden window of its own: 18–30 ms on the main thread) the
        // first time a text view's caret is placed. Done now, while launch waits on the session host, rather
        // than in the frames of the first file opened, where it held the main thread past two frames.
        DispatchQueue.main.async { NSTextView().inputContext?.invalidateCharacterCoordinates() }
        Task {
            await workbench.launch()
            // Every launch lands on Home; a folder opened with the app (from the Finder or the Dock) is shown.
            for folder in pendingFolders { workbench.open(folder: folder) }
            pendingFolders = []
            launched = true
            controller.workbenchDidLaunch()
            present(controller)
            if !AppPlaces.isIsolated { workbench.launchNotice = HostNotice(terminals: workbench.host.strangers, withheld: workbench.resumesWithheld) }
            #if DEBUG
            DebugScenario.run(workbench: workbench, window: controller)
            #endif
        }
    }

    private var presented = false

    /// Puts the window on screen, once.
    private func present(_ controller: MainWindowController) {
        guard !presented else { return }
        presented = true
        #if DEBUG
        if DebugScenario.keepsInBackground {
            // Shown, but behind every other window, and the app never activates itself (nor goes full screen).
            // Invisible and click-through as well: nobody at this Mac can see or catch it by accident
            // (snapshots draw the views themselves).
            controller.window?.orderBack(nil)
            return
        }
        #endif
        controller.showWindow(nil)
    }

    /// A SIGTERM (logout, `kill`) quits as ⌘Q does: the layout is saved and the terminals keep running
    /// in the session host (at logout the system ends that too, and it ends its terminals in turn).
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.quitting = true
                self.windowController?.saveState()
                self.workbench.shutDown(stoppingSessions: self.stopsSessions)
                // Everything is saved; leave even if a sheet or panel would hold up terminate.
                exit(0)
            }
        }
        source.resume()
        terminationSignal = source
    }

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    /// File › Import Themes and Languages…: what Settings › Terminal's Add Theme… takes, chosen in an
    /// open panel; Settings then opens on the themes, with what was added.
    @objc func importThemes(_ sender: Any?) {
        SettingsWindowController.chooseImports(over: NSApp.mainWindow) { SettingsWindowController.shared.showThemes() }
    }

    /// Whiskr › Secure Keyboard Entry (`SecureKeyboard`): checked while on.
    @objc func toggleSecureKeyboardEntry(_ sender: Any?) {
        SecureKeyboard.shared.isOn.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSecureKeyboardEntry(_:)) { item.state = SecureKeyboard.shared.isOn ? .on : .off }
        return true
    }

    /// Folders dropped on the Dock icon or opened with the app (`open -a "Whiskr" ~/code/shop`)
    /// become workspaces; theme files are imported.
    func application(_ application: NSApplication, open urls: [URL]) {
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        if launched {
            folders.forEach { workbench.open(folder: $0.path) }
        } else {
            pendingFolders += folders.map(\.path)
        }
        let themes = urls.filter { (Theme.fileExtensions + ["itermcolors"]).contains($0.pathExtension.lowercased()) }
        guard !themes.isEmpty else { return }
        SettingsWindowController.shared.show()
        SettingsWindowController.importThemes(themes, over: SettingsWindowController.shared.window)
    }

    @objc func showMainWindow(_ sender: Any?) {
        windowController?.showWindow(nil)
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Open Recent

    /// File › Open Recent: the same folders as Home's Recent, by name, with where each is.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === MainMenu.openRecent else { return }
        menu.removeAllItems()
        let folders = workbench.recentFolders
        for folder in folders {
            let item = closureMenuItem(title: URL(fileURLWithPath: folder.path).lastPathComponent) { [weak self] in self?.workbench.open(folder: folder.path) }
            item.subtitle = abbreviatingHome(folder.path)
            item.image = NSWorkspace.shared.icon(for: .folder)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if !folders.isEmpty { menu.addItem(.separator()) }
        let clear = closureMenuItem(title: String(localized: "Clear Menu")) { [weak self] in self?.workbench.clearRecentFolders() }
        clear.isEnabled = !folders.isEmpty
        menu.autoenablesItems = false
        menu.addItem(clear)
    }

    // MARK: Dock

    private func updateDockBadge() {
        let count = workbench.needsYouCount
        let label = count > 0 && Preferences.shared.dockBadge ? "\(count)" : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// The Dock menu (§6.1): who is waiting, oldest first ("shop-web: Wants to run npm test"), then New
    /// Workspace (Home) and Pause Alerts. Choosing one is yours to do, so it brings the window forward.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let waiting = workbench.agentRows.filter { $0.status == .blocked || $0.status == .done }
            .sorted { ($0.status.rawValue, $0.since) < ($1.status.rawValue, $1.since) }
        for row in waiting.prefix(10) {
            let failed = workbench.panes[row.id].flatMap(workbench.session(of:))?.failed ?? false
            let what = row.status == .done ? String(localized: "Finished") : failed ? String(localized: "Stopped on an error")
                : row.line.isEmpty ? String(localized: "Claude needs you") : row.line
            let item = closureMenuItem(title: String(localized: "\(row.workspaceName): \(what)", comment: "Dock menu: a workspace and what waits there")) { [weak self] in
                self?.showMainWindow(nil)
                self?.workbench.focus(pane: row.id)
            }
            menu.addItem(item)
        }
        if !waiting.isEmpty { menu.addItem(.separator()) }
        menu.addItem(closureMenuItem(title: String(localized: "New Workspace")) { [weak self] in
            self?.showMainWindow(nil)
            self?.workbench.goHome()
        })
        let pause = NSMenuItem(title: String(localized: "Pause Alerts"), action: nil, keyEquivalent: "")
        pause.submenu = AlertCenter.pauseMenu()
        menu.addItem(pause)
        return menu
    }

    // MARK: Quitting

    /// Whether quitting also ends every terminal: after Quit and Stop All Terminals, and at the end of
    /// a test run, which must leave nothing behind.
    private var stopsSessions = AppDelegate.isolatedRunStopsSessions

    private static var isolatedRunStopsSessions: Bool {
        #if DEBUG
        AppPlaces.isIsolated && !DebugScenario.leavesHost
        #else
        false
        #endif
    }

    /// Quit (⌘Q) closes the app and nothing else: every terminal keeps running in the session host
    /// and is back as it was at the next launch, so nothing is asked (§5.3).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        // Files with unsaved changes are asked about first (Save / Don't Save / Cancel); once settled, Quit
        // goes on as it always does.
        let edited = workbench.files.editedDocuments
        // (A background test run cannot answer, and quits as asked.)
        if !edited.isEmpty, !editedFilesSettled, !DebugPlaces.isBackground {
            windowController?.showWindow(nil)
            workbench.confirmClosing(edited, cancelled: { NSApp.reply(toApplicationShouldTerminate: false) }) { [weak self] in
                self?.editedFilesSettled = true
                NSApp.reply(toApplicationShouldTerminate: false)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return .terminateLater
        }
        windowController?.saveState()
        quitting = true
        workbench.shutDown(stoppingSessions: stopsSessions)
        return .terminateNow
    }

    /// Quit and Stop All Terminals (⌥⌘Q, Quit with Option held): ends everything in every terminal,
    /// then quits. Asks first only when Claude or another program is running; idle shells just end.
    @objc func quitAndStopAllTerminals(_ sender: Any?) {
        let busy = workbench.busyPanes
        if !busy.isEmpty && !AppPlaces.isIsolated {
            let claudes = busy.filter(\.agentRunning).count
            let commands = busy.count - claudes
            let alert = NSAlert()
            alert.messageText = String(localized: "Stop all terminals and quit?")
            // Only what is running is named ("2 Claudes are running", not "and 0 commands").
            alert.informativeText = claudes == 0
                ? String(localized: "\(commands) commands are running. They will stop.",
                         comment: "Quit and Stop All Terminals alert body: programs other than Claude are running")
                : commands == 0
                ? String(localized: "\(claudes) Claudes are running. They will stop; their conversations reopen where you left them.",
                         comment: "Quit and Stop All Terminals alert body: only Claudes are running")
                : String(localized: "\(claudes) Claudes and \(commands) commands are running. They will stop. Claude conversations reopen where you left them.",
                         comment: "Quit and Stop All Terminals alert body: how many Claudes and other programs are running")
            alert.addButton(withTitle: String(localized: "Stop All and Quit"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        stopsSessions = true
        NSApp.terminate(nil)
    }
}
