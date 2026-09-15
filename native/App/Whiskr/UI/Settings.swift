import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskrKit

/// The settings window (⌘,), as Mac settings windows are: a pane per subject, chosen in the toolbar, each
/// change applied at once (docs/DESIGN.md). General: restoring Claude, where new tabs open,
/// asking before quitting. Terminal: the theme (with previews, editing and importing) and the font and
/// cursor. Alerts: each event's sound and notification, the Dock icon. Meadow: time of day, real weather,
/// picnic things, flag size (and the map, once there is a second to choose).
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        // A settings window is not resized or zoomed, and opens on the pane last used (HIG, §10).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.toolbarStyle = .preference
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.pane(String(localized: "General", comment: "Settings pane"), symbol: "gearshape", id: "general",
                                      NSHostingController(rootView: GeneralSettings(preferences: .shared))))
        tabs.addTabViewItem(Self.pane(String(localized: "Terminal", comment: "Settings pane"), symbol: "terminal", id: "terminal",
                                      NSHostingController(rootView: TerminalSettings(store: .shared))))
        tabs.addTabViewItem(Self.pane(String(localized: "Editor", comment: "Settings pane"), symbol: "doc.text", id: "editor",
                                      NSHostingController(rootView: EditorSettings(preferences: .shared, theme: .shared))))
        tabs.addTabViewItem(Self.pane(String(localized: "Alerts", comment: "Settings pane"), symbol: "bell", id: "alerts",
                                      NSHostingController(rootView: AlertSettings(preferences: .shared))))
        tabs.addTabViewItem(Self.pane(String(localized: "Meadow", comment: "Settings pane: the sidebar's scene"), symbol: "leaf", id: "meadow",
                                      NSHostingController(rootView: WorldSettingsView(store: .shared))))
        window.contentViewController = tabs
        tabs.selectRememberedPane()
        window.setContentSize(NSSize(width: 720, height: 640))
        if !AppPlaces.isIsolated { window.setFrameAutosaveName("Settings") }
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    /// A pane, known by `id` (kept as the pane last used; its symbol's name when not given).
    private static func pane(_ label: String, symbol: String, id: String? = nil, _ controller: NSViewController) -> NSTabViewItem {
        controller.preferredContentSize = NSSize(width: 720, height: 640)
        let item = NSTabViewItem(viewController: controller)
        item.identifier = id ?? symbol
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    /// Opens on Terminal, where the themes are.
    func showThemes() {
        show()
        (window?.contentViewController as? SettingsTabs)?.select(pane: "terminal")
    }

    /// Opens on Meadow (Debug: for a look from the command line).
    func showWorld() {
        show()
        (window?.contentViewController as? SettingsTabs)?.select(pane: "meadow")
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is created in code")
    }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// What Add Theme… and File › Import take: the app's own theme files and iTerm2's, VS Code colour
    /// themes (JSON, with comments or without) and TextMate themes, VS Code extensions (a `.vsix` or a
    /// folder), and TextMate grammars.
    static let importTypes: [UTType] = [
        UTType(filenameExtension: Theme.fileExtension) ?? .json,
        UTType(filenameExtension: Theme.legacyFileExtension) ?? .json,
        UTType(filenameExtension: "itermcolors") ?? .propertyList,
        .json,
        UTType(filenameExtension: "jsonc") ?? .json,
        UTType(filenameExtension: "tmTheme") ?? .propertyList,
        UTType(filenameExtension: "vsix") ?? .zip,
        UTType(filenameExtension: "tmLanguage") ?? .propertyList,
        .folder,
    ]

    /// The open panel for Add Theme… and File › Import; `then` runs after an import.
    static func chooseImports(over window: NSWindow?, then: @escaping () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = importTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = String(localized: "Add", comment: "Theme file picker's button")
        panel.message = String(localized: "Choose themes (Whiskr, iTerm2, VS Code or TextMate), VS Code extensions (.vsix or a folder) or TextMate grammars.")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            importThemes(panel.urls, over: window, then: then)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Where languages added with Add Theme… or File › Import are kept (`LanguageRegistry.install`).
    static var languagesFolder: URL { Workbench.supportFolder.appendingPathComponent("Languages", isDirectory: true) }

    /// Imports themes and languages (a VS Code extension may hold both; a TextMate grammar is a language),
    /// keeps one line saying what was added for Settings to show (`ThemeStore.importSummary`), reports
    /// anything that could not be read, then runs `then`. Reading the files, unpacking a `.vsix` (once, for
    /// its themes and its languages) and installing languages happen off the main thread.
    static func importThemes(_ urls: [URL], over window: NSWindow?, then: @escaping () -> Void = {}) {
        Task {
            await performImports(urls, over: window)
            then()
        }
    }

    private static func performImports(_ urls: [URL], over window: NSWindow?) async {
        var problems: [String] = []
        var added: [String] = []
        var languages = 0
        let originals = ThemeStore.originalsFolder, languagesFolder = languagesFolder
        for url in urls {
            let name = url.lastPathComponent.lowercased()
            let isGrammar = name.hasSuffix(".tmlanguage.json") || name.hasSuffix(".tmlanguage") || url.pathExtension.lowercased() == "plist"
            let isExtension = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || url.pathExtension.lowercased() == "vsix"
            do {
                let (read, installed) = try await Task.detached(priority: .userInitiated) { () throws -> ([Theme], Result<Int, any Error>?) in
                    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-vsix-\(UUID().uuidString)", isDirectory: true)
                    defer { try? FileManager.default.removeItem(at: scratch) }
                    let source = url.pathExtension.lowercased() == "vsix" ? try ThemeImport.unpack(vsix: url, into: scratch) : url
                    let themes = isGrammar ? [] : try ThemeImport.themes(at: source, originals: originals)
                    guard isGrammar || isExtension else { return (themes, nil) }
                    return (themes, Result { try LanguageRegistry.shared.install(from: source, into: languagesFolder).count })
                }.value
                let themes = try ThemeStore.shared.add(imported: read)
                added += themes.map(\.name)
                switch installed {
                case .success(let count)?:
                    languages += count
                case .failure(LanguageInstallError.nothingToInstall)? where !themes.isEmpty:
                    // An extension of themes only.
                    break
                case .failure(let error)?:
                    throw error
                case nil:
                    if themes.isEmpty { throw ThemeImportError.unreadable(String(localized: "There are no colour themes in it.")) }
                }
            } catch let error as ThemeImportError {
                problems.append("\(url.lastPathComponent): \(error.message)")
            } catch let error as LanguageInstallError {
                problems.append("\(url.lastPathComponent): \(error.message)")
            } catch {
                problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if languages > 0 {
            FileDocument.languagesChanged()
            added.append(languages == 1 ? String(localized: "1 language") : String(localized: "\(languages) languages"))
        }
        if !added.isEmpty {
            let names = ListFormatter.localizedString(byJoining: added)
            ThemeStore.shared.importSummary = String(localized: "Added \(names).", comment: "Settings › Terminal, after an import: the themes and languages added")
        }
        guard !problems.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = problems.count == 1 ? String(localized: "That theme could not be imported") : String(localized: "Some themes could not be imported")
        alert.informativeText = problems.joined(separator: "\n")
        if let window { alert.beginSheetModal(for: window) { _ in } } else { alert.runModal() }
    }
}

/// The panes, remembering which was last chosen by its identifier, so adding or moving a pane never
/// opens the wrong one.
final class SettingsTabs: NSTabViewController {
    static let paneKey = "settingsPaneID"
    /// Before panes had identifiers, the last one was kept by its place, in this order.
    private static let indexKey = "settingsPane"
    private static let formerOrder = ["general", "terminal", "editor", "alerts", "meadow"]
    private var restoring = false

    func selectRememberedPane() {
        let defaults = AppPlaces.defaults
        if defaults.string(forKey: Self.paneKey) == nil, defaults.object(forKey: Self.indexKey) != nil {
            let index = defaults.integer(forKey: Self.indexKey)
            if Self.formerOrder.indices.contains(index) { defaults.set(Self.formerOrder[index], forKey: Self.paneKey) }
            defaults.removeObject(forKey: Self.indexKey)
        }
        restoring = true
        select(pane: defaults.string(forKey: Self.paneKey) ?? Self.formerOrder[0])
        restoring = false
    }

    func select(pane id: String) {
        guard let index = tabViewItems.firstIndex(where: { ($0.identifier as? String) == id }) else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        // Adding the panes selects the first: only a choice once they are all there is remembered.
        guard !restoring, tabViewItems.count > 1, let id = tabViewItem?.identifier as? String else { return }
        AppPlaces.defaults.set(id, forKey: Self.paneKey)
    }
}

struct TerminalSettings: View {
    @Bindable var store: ThemeStore
    @State private var editing: Theme?
    @State private var dropTargeted = false

    var body: some View {
        Form {
            if let dark = store.theme.fixedDarkness {
                Section {
                    Text(dark ? String(localized: "\(store.theme.name) has a dark version only, so the app stays dark while it is chosen.")
                              : String(localized: "\(store.theme.name) has a light version only, so the app stays light while it is chosen."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 196), spacing: 14)], spacing: 14) {
                    ForEach(store.themes) { theme in
                        // Each as it will look once chosen, not in the appearance the chosen theme holds the app in.
                        ThemeCard(theme: theme, colors: store.previewColors(theme), selected: theme.id == store.themeID)
                            .onTapGesture { store.themeID = theme.id }
                            .contextMenu { cardMenu(theme) }
                    }
                }
                .padding(.vertical, 4)
                HStack {
                    Button("Edit Colors…") { editing = store.theme }
                    Button("Add Theme…") { SettingsWindowController.chooseImports(over: NSApp.keyWindow) }
                    Spacer()
                    Button("Show Themes Folder") { store.showThemesFolder() }
                }
                if let summary = store.importSummary {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Theme")
            } footer: {
                Text("Add a VS Code theme, extension or .vsix, an iTerm2 .itermcolors file or a .whiskrtheme, or drop one here. A theme with a light and a dark version follows your Mac’s appearance; to pair two of yours, right-click one. Your themes are .whiskrtheme files (plain JSON) in the themes folder.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .overlay {
                if dropTargeted { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: importDropped)

            Section("Terminal") {
                Picker("Font", selection: $store.fontFamily) {
                    Text("SF Mono (system)").tag("")
                    Divider()
                    ForEach(ThemeStore.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: $store.fontSize, in: ThemeStore.fontSizes, step: 1) {
                    LabeledContent("Size", value: "\(Int(store.fontSize)) pt")
                }
                LabeledContent("Line height") {
                    HStack {
                        Slider(value: $store.lineHeight, in: ThemeStore.lineHeights, step: 0.05)
                        Text(String(format: "%.2f×", store.lineHeight)).monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                }
                Picker("Cursor", selection: $store.cursorShape) {
                    ForEach(ThemeStore.CursorShape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Blinking cursor", isOn: $store.cursorBlinks)
            }

            Section {
                Picker(String(localized: "Option key acts as Meta"), selection: Bindable(Preferences.shared).optionKey) {
                    Text(String(localized: "Left Option")).tag(Preferences.OptionKey.left)
                    Text(String(localized: "Right Option")).tag(Preferences.OptionKey.right)
                    Text(String(localized: "Both")).tag(Preferences.OptionKey.both)
                    Text(String(localized: "Neither")).tag(Preferences.OptionKey.neither)
                }
            } header: {
                Text(String(localized: "Keyboard"))
            } footer: {
                Text(String(localized: "Claude Code's ⌥P, ⌥T and word moves need Option as Meta; the other Option key still types characters such as é and ©."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { theme in
            ThemeEditor(original: theme, store: store) { editing = nil }
        }
        .onDisappear { store.importSummary = nil }
    }

    @ViewBuilder private func cardMenu(_ theme: Theme) -> some View {
        Button("Use \(theme.name)") { store.themeID = theme.id }
        Button(theme.isBuiltIn ? "Duplicate and Edit…" : "Edit Colors…") { editing = theme }
        // Two of your own, one light and one dark, become one theme that follows the Mac's appearance.
        let candidates = store.pairCandidates(for: theme)
        if !candidates.isEmpty {
            Menu(theme.fixedDarkness == true ? String(localized: "Pair with Light Theme") : String(localized: "Pair with Dark Theme")) {
                ForEach(candidates) { other in
                    Button(other.name) { attempt { try store.pair(theme, with: other) } }
                }
            }
        }
        if !theme.isBuiltIn, theme.fixedDarkness == nil {
            Button(String(localized: "Separate Light and Dark")) { attempt { try store.separate(theme) } }
        }
        if !theme.isBuiltIn {
            Divider()
            Button("Delete \(theme.name)", role: .destructive) { store.remove(userTheme: theme) }
        }
    }

    /// Runs a change to your themes, saying so if it could not be saved.
    private func attempt(_ change: () throws -> Void) {
        do { try change() } catch { NSApp.presentError(error) }
    }

    private func importDropped(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in SettingsWindowController.importThemes([url], over: NSApp.keyWindow) }
            }
        }
        return !providers.isEmpty
    }
}

/// A theme in the picker: its preview as it will look once chosen (`ThemePreviewColors`), its name and
/// which versions it has.
struct ThemeCard: View {
    let theme: Theme
    let colors: ThemePreviewColors
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThemePreview(colors: colors)
                .frame(height: ThemePreview.cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1))
            HStack(spacing: 4) {
                Text(theme.name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(theme.fixedDarkness.map { $0 ? String(localized: "Dark") : String(localized: "Light") } ?? String(localized: "Light & dark"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        #if DEBUG
        .background(DebugThemeSheet.Anchor(id: theme.id))
        #endif
        .help(theme.credit ?? theme.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(selected ? String(localized: "\(theme.name) theme, selected") : String(localized: "\(theme.name) theme"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A miniature of a theme: a strip of the app's chrome with its state marks, a line, and a terminal with
/// its sixteen colours below. Its colours are given whole (`ThemePreviewColors`), never read from the
/// appearance it is drawn in.
struct ThemePreview: View {
    let colors: ThemePreviewColors

    static let cardHeight: CGFloat = 104
    /// The chrome strip's width, and the terminal's inset.
    static let chromeWidth: CGFloat = 58
    static let inset: CGFloat = 7
    /// The sixteen colours: two rows of eight, at the terminal's foot.
    static let swatchHeight: CGFloat = 5
    static let swatchGap: CGFloat = 1

    /// The middle of the swatch of ANSI colour `index` (0…15) in a preview of `size`: where a check looks.
    static func swatchCenter(_ index: Int, in size: CGSize) -> CGPoint {
        let left = chromeWidth + 1 + inset, width = size.width - left - inset
        let swatch = (width - 7 * swatchGap) / 8
        let row = CGFloat(index / 8), column = CGFloat(index % 8)
        let top = size.height - inset - 2 * swatchHeight - swatchGap + row * (swatchHeight + swatchGap)
        return CGPoint(x: left + column * (swatch + swatchGap) + swatch / 2, y: top + swatchHeight / 2)
    }

    /// A point of the terminal's background no text reaches, in a preview of `size`.
    static func backgroundPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width - inset / 2, y: inset + 20)
    }

    private func color(_ value: WhiskrKit.RGBColor) -> SwiftUI.Color { SwiftUI.Color(nsColor: Palette.nsColor(value)) }
    private func app(_ key: AppColorKey) -> SwiftUI.Color { color(colors[key]) }
    private func ansi(_ index: Int) -> SwiftUI.Color { color(colors.terminal.ansi[index]) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                row(mark: AnyView(Capsule().fill(app(.needsYou)).frame(width: 14, height: 6)))
                row(mark: AnyView(Circle().fill(app(.done)).frame(width: 5, height: 5)))
                row(mark: AnyView(Circle().trim(from: 0, to: 0.7).stroke(app(.working), lineWidth: 1.2).frame(width: 6, height: 6)))
                row(mark: AnyView(Circle().strokeBorder(app(.idle), lineWidth: 1).frame(width: 6, height: 6)))
                Spacer()
                Capsule().fill(app(.accent)).frame(width: 28, height: 4)
            }
            .padding(6)
            .frame(width: Self.chromeWidth)
            .background(app(.chrome))
            Rectangle().fill(app(.line)).frame(width: 1)
            VStack(alignment: .leading, spacing: 1.5) {
                Text("$ ").foregroundColor(ansi(2)) + Text("npm test").foregroundColor(color(colors.terminal.foreground))
                Text("✓ 13 passing").foregroundColor(ansi(2))
                Text("✗ 1 failing").foregroundColor(ansi(1))
                Text("warn ").foregroundColor(ansi(3)) + Text("src/cart.ts").foregroundColor(ansi(4))
                HStack(spacing: 0) {
                    Text("~/shop ").foregroundColor(ansi(6))
                    // Selected, as a selection in the terminal shows.
                    Text("main").foregroundColor(ansi(5)).background(color(colors.terminal.selection))
                }
                (Text("> ").foregroundColor(color(colors.terminal.foreground)) + Text("█").foregroundColor(color(colors.terminal.cursor)))
                Spacer(minLength: 0)
                VStack(spacing: Self.swatchGap) {
                    ForEach(colors.ansiRows.indices, id: \.self) { row in
                        HStack(spacing: Self.swatchGap) {
                            ForEach(colors.ansiRows[row].indices, id: \.self) { column in
                                Rectangle().fill(color(colors.ansiRows[row][column])).frame(height: Self.swatchHeight)
                            }
                        }
                    }
                }
            }
            .font(.system(size: 8.5, design: .monospaced))
            .padding(Self.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(color(colors.terminal.background))
        }
        .accessibilityHidden(true)
    }

    private func row(mark: AnyView) -> some View {
        HStack(spacing: 4) {
            mark.frame(width: 14)
            RoundedRectangle(cornerRadius: 1.5).fill(app(.textSecondary)).frame(width: 24, height: 3)
        }
    }
}

/// Changes a theme's colours with the system colour picker and saves the result as one of your
/// themes. A built-in theme is never changed: editing one saves a copy.
struct ThemeEditor: View {
    let original: Theme
    let store: ThemeStore
    let done: () -> Void

    @State private var theme: Theme
    @State private var dark: Bool
    @State private var problem: String?

    init(original: Theme, store: ThemeStore, done: @escaping () -> Void) {
        self.original = original
        self.store = store
        self.done = done
        var copy = original
        if original.isBuiltIn {
            copy.name = "\(original.name) (Custom)"
            copy.credit = original.credit.map { "Based on \(original.name): \($0)" }
        }
        _theme = State(initialValue: copy)
        // The version the app would show it in (not the one the chosen theme holds the app in).
        _dark = State(initialValue: original.isDark(following: store.followedDark))
    }

    private var variant: ThemeVariant { theme.variant(dark: dark) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Name", text: $theme.name).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Spacer()
                if theme.light != nil && theme.dark != nil {
                    Picker("Version", selection: $dark) {
                        Text("Light").tag(false)
                        Text("Dark").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
            ThemePreview(colors: ThemePreviewColors(theme: theme, followedDark: dark, increasedContrast: store.increasedContrast))
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            let warnings = variant.readabilityWarnings
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: Look.Space.xxs) {
                    ForEach(warnings, id: \.what) { warning in
                        Label(warning.message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            Form {
                Section("App") {
                    ForEach(AppColorKey.allCases, id: \.self) { key in
                        ColorPicker(key.label, selection: appBinding(key), supportsOpacity: false)
                    }
                }
                Section("Terminal") {
                    ColorPicker("Background", selection: terminalBinding(\.background), supportsOpacity: false)
                    ColorPicker("Text", selection: terminalBinding(\.foreground), supportsOpacity: false)
                    ColorPicker("Cursor", selection: terminalBinding(\.cursor), supportsOpacity: false)
                    ColorPicker("Selection", selection: terminalBinding(\.selection), supportsOpacity: false)
                    ForEach(0..<16, id: \.self) { index in
                        ColorPicker(TerminalColors.ansiNames[index], selection: ansiBinding(index), supportsOpacity: false)
                    }
                }
            }
            .formStyle(.grouped)
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            HStack {
                Text(original.isBuiltIn ? "Saved as a new theme of your own; \(original.name) stays as it is." : "Saved to your themes folder.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(theme.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 680)
    }

    private func update(_ change: (inout ThemeVariant) -> Void) {
        if dark, theme.dark != nil { change(&theme.dark!) } else if theme.light != nil { change(&theme.light!) } else { change(&theme.dark!) }
    }

    private static func rgb(_ color: SwiftUI.Color) -> WhiskrKit.RGBColor {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return WhiskrKit.RGBColor(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }

    private func swiftColor(_ value: WhiskrKit.RGBColor) -> SwiftUI.Color { SwiftUI.Color(nsColor: Palette.nsColor(value)) }

    private func appBinding(_ key: AppColorKey) -> Binding<SwiftUI.Color> {
        Binding(get: { swiftColor(variant.app[key]) }, set: { color in update { $0.app[key] = Self.rgb(color) } })
    }

    private func terminalBinding(_ path: WritableKeyPath<TerminalColors, WhiskrKit.RGBColor>) -> Binding<SwiftUI.Color> {
        Binding(get: { swiftColor(variant.terminal[keyPath: path]) }, set: { color in update { $0.terminal[keyPath: path] = Self.rgb(color) } })
    }

    private func ansiBinding(_ index: Int) -> Binding<SwiftUI.Color> {
        Binding(get: { swiftColor(variant.terminal.ansi[index]) }, set: { color in update { $0.terminal.ansi[index] = Self.rgb(color) } })
    }

    private func save() {
        var saved = theme
        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
        if original.isBuiltIn || Theme.slug(saved.name) != Theme.slug(original.name) {
            saved.id = store.uniqueID(for: Theme.slug(saved.name))
            if !original.isBuiltIn { store.delete(userTheme: original) }
        }
        do {
            try store.save(userTheme: saved)
            done()
        } catch {
            problem = String(localized: "Could not save the theme: \(error.localizedDescription)")
        }
    }
}

/// Settings › Editor: the font (the terminal's unless chosen), tab width, wrapping, invisibles.
struct EditorSettings: View {
    @Bindable var preferences: EditorPreferences
    let theme: ThemeStore

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Font"), selection: $preferences.fontFamily) {
                    Text(String(localized: "Same as Terminal")).tag("")
                    Divider()
                    ForEach(ThemeStore.monospacedFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper(value: Binding(get: { preferences.fontSize > 0 ? preferences.fontSize : Double(theme.fontSize) },
                                       set: { preferences.fontSize = min(max($0, 9), 28) }), in: 9...28, step: 1) {
                    LabeledContent(String(localized: "Size"), value: String(localized: "\(Int(preferences.fontSize > 0 ? preferences.fontSize : Double(theme.fontSize))) pt"))
                }
                if preferences.fontSize > 0 || !preferences.fontFamily.isEmpty {
                    Button(String(localized: "Use the Terminal’s Font")) {
                        preferences.fontFamily = ""
                        preferences.fontSize = 0
                    }
                }
            } header: {
                Text(String(localized: "Font"))
            } footer: {
                Text(String(localized: "Until you choose one, the editor uses the terminal’s font and size."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker(String(localized: "Indent with"), selection: $preferences.insertSpaces) {
                    Text(String(localized: "Spaces", comment: "Settings › Editor: indent with spaces")).tag(true)
                    Text(String(localized: "Tabs")).tag(false)
                }
                Picker(String(localized: "Tab width"), selection: $preferences.tabWidth) {
                    ForEach(EditorPreferences.tabWidths, id: \.self) { Text(String(localized: "\($0) spaces")).tag($0) }
                }
                Toggle(String(localized: "Wrap long lines"), isOn: $preferences.wrapLines)
                Toggle(String(localized: "Show invisibles"), isOn: $preferences.showInvisibles)
            } header: {
                Text(String(localized: "Text"))
            } footer: {
                Text(String(localized: "Each file keeps its own indentation, encoding and line endings: they are read from it and written back the same way. The indentation and tab width are for files that do not say."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle(String(localized: "Trim trailing whitespace"), isOn: $preferences.trimTrailingWhitespace)
                Toggle(String(localized: "Insert a final newline"), isOn: $preferences.insertFinalNewline)
            } header: {
                Text(String(localized: "When Saving"))
            } footer: {
                Text(String(localized: "A repository’s .editorconfig file decides these, its indentation and its line endings for the files it covers, as in VS Code."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › General.
struct GeneralSettings: View {
    @Bindable var preferences: Preferences
    /// What the last Import Settings applied (`OtherEditorImport`).
    @State private var otherEditorSummary: String?

    /// Settings › General's folder for new worktrees, chosen with the system's folder picker.
    private func chooseWorktreeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.worktreeFolder
        panel.prompt = String(localized: "Choose", comment: "Folder picker's button for the worktrees folder")
        panel.message = String(localized: "New worktrees will be made in this folder.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.worktreeFolderChoice = url.path
    }

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "Resume Claude in restored panes"), isOn: $preferences.resumeClaude)
            } footer: {
                Text(String(localized: "After a restart, a pane that was running Claude runs claude --resume with its conversation, and waits for you."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Picker(String(localized: "New tabs and panes open in"), selection: $preferences.newTerminalFolder) {
                    Text(String(localized: "Current Folder")).tag(Preferences.NewTerminalFolder.current)
                    Text(String(localized: "Home Folder")).tag(Preferences.NewTerminalFolder.home)
                }
            }
            Section {
                LabeledContent(String(localized: "New worktrees go in")) {
                    // One row at any length: the folder gives way in its middle, the buttons stay whole.
                    HStack(spacing: 8) {
                        Text(abbreviatingHome(preferences.worktreeFolder.path))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(preferences.worktreeFolder.path)
                        if preferences.worktreeFolderChoice != nil {
                            Button(String(localized: "Use Default")) { preferences.worktreeFolderChoice = nil }
                                .fixedSize()
                        }
                        Button(String(localized: "Choose…")) { chooseWorktreeFolder() }
                            .fixedSize()
                    }
                }
            } footer: {
                Text(String(localized: "Each worktree is a checkout of another branch, in <folder>/<repository>/<branch>. It opens as a workspace of its own, beside its repository's."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(String(localized: "Language")) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(String(localized: "Follows your Mac's language")).foregroundStyle(.secondary)
                        Button(String(localized: "Open Language & Region…")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
            Section {
                LabeledContent(String(localized: "Settings from VS Code or Cursor")) {
                    Menu(String(localized: "Import Settings")) {
                        ForEach(OtherEditor.allCases, id: \.self) { editor in
                            Button(String(localized: "From \(editor.name)", comment: "Settings › General › Import Settings: the editor to read")) {
                                otherEditorSummary = OtherEditorImport.apply(from: editor)
                            }
                        }
                    }
                    .fixedSize()
                }
                if let otherEditorSummary {
                    Text(otherEditorSummary).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } footer: {
                Text(String(localized: "Reads its settings once, when you choose: fonts and sizes, indentation, wrapping, invisibles, saving, the terminal’s cursor and the colour theme. Nothing is changed there, and nothing is sent anywhere."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings › Alerts (docs/DESIGN.md, Attention): one row per event, each with its sound (the app's own,
/// the Mac's, or one you add) and whether it shows a notification; how loud; whether sounds wait for
/// Whiskr to be in the background; whether macOS lets notifications through; the Dock icon; Pause Alerts.
struct AlertSettings: View {
    @Bindable var preferences: Preferences
    private let access = NotificationAccess.shared
    /// The sounds you added (the Sounds folder), looked at again after each change.
    @State private var customSounds = AlertCenter.customSounds
    /// Why the file last chosen was not taken.
    @State private var refusal: String?

    var body: some View {
        Form {
            Section {
                ForEach(AlertEvent.allCases, id: \.self) { event in
                    AlertEventRow(event: event, setting: setting(event), customSounds: customSounds,
                                  choose: { choose(for: event) }, remove: remove)
                }
                if let refusal {
                    Text(refusal).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "Sounds and Notifications", comment: "Settings › Alerts: the list of events"))
            } footer: {
                Text(String(localized: "A sound plays unless you are typing in that terminal. A notification shows while Whiskr is in the background, for a finished turn only after 30 seconds or more. Point at an event to see where it comes from.", comment: "Settings › Alerts: under the list of events"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(String(localized: "Volume")) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                        Slider(value: $preferences.alerts.volume, in: 0...1) { editing in
                            // Heard at the new volume once let go, as the Mac's own Sound settings do.
                            if !editing { AlertCenter.shared.play(.request) }
                        }
                        .frame(maxWidth: 200)
                        .accessibilityLabel(String(localized: "Volume"))
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
                Toggle(String(localized: "Play sounds only when Whiskr is in the background", comment: "Settings › Alerts"), isOn: $preferences.alerts.soundsOnlyInBackground)
            } footer: {
                Text(String(localized: "The Mac’s alert sound plays at the alert volume set in System Settings › Sound.", comment: "Settings › Alerts: under the volume"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(String(localized: "Notifications", comment: "Settings › Alerts: whether macOS lets Whiskr's notifications through")) {
                    HStack(spacing: 8) {
                        switch access.status {
                        case .allowed:
                            Text(String(localized: "Allowed", comment: "Settings › Alerts: notifications are on in System Settings")).foregroundStyle(.secondary)
                            Button(String(localized: "Notification Settings…")) { access.openSystemSettings() }
                        case .off:
                            Text(String(localized: "Off in System Settings", comment: "Settings › Alerts: notifications are turned off for Whiskr")).foregroundStyle(.secondary)
                            Button(String(localized: "Open System Settings…")) { access.openSystemSettings() }
                        case .notAsked:
                            Text(String(localized: "Not allowed yet", comment: "Settings › Alerts: macOS has not asked about Whiskr's notifications")).foregroundStyle(.secondary)
                            Button(String(localized: "Allow Notifications…")) { Task { await access.request() } }
                        case .unknown:
                            EmptyView()
                        }
                    }
                }
                if access.status == .notAsked, let refusal = access.refusal {
                    Text(String(localized: "macOS did not ask: \(refusal)", comment: "Settings › Alerts: the system refused to ask about notifications, and its reason"))
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            } footer: {
                Text(String(localized: "A permission request’s notification has Allow and Deny. Banners or alerts, and their sound, are set in System Settings › Notifications.", comment: "Settings › Alerts: under the notifications row"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle(String(localized: "Show request count on the Dock icon"), isOn: $preferences.dockBadge)
                Toggle(String(localized: "Bounce the Dock icon for requests"), isOn: $preferences.dockBounce)
            }
            Section {
                LabeledContent(String(localized: "Pause Alerts")) {
                    if let until = preferences.alertsPausedUntil, until > Date() {
                        HStack {
                            Text(String(localized: "Until \(until.formatted(date: .abbreviated, time: .shortened))")).foregroundStyle(.secondary)
                            Button(String(localized: "Resume")) { preferences.alertsPausedUntil = nil }
                        }
                    } else {
                        HStack {
                            Button(String(localized: "For 1 Hour")) { preferences.alertsPausedUntil = Date().addingTimeInterval(3600) }
                            Button(String(localized: "Until Tomorrow")) { preferences.alertsPausedUntil = AlertPause.untilTomorrow(from: Date()) }
                        }
                    }
                }
            } footer: {
                Text(String(localized: "While paused, no sounds and no notifications; the meadow, the tabs and the Dock icon still show who needs you."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await access.refresh() }
    }

    /// One event's setting; turning a notification on asks macOS, if it has not been asked yet.
    private func setting(_ event: AlertEvent) -> Binding<AlertEventSetting> {
        Binding {
            preferences.alerts[event]
        } set: { new in
            if new.notify, !preferences.alerts[event].notify, access.status == .notAsked { Task { await access.request() } }
            preferences.alerts[event] = new
        }
    }

    /// Choose…: a sound file of yours, checked and kept (`CustomSoundFiles`), then played.
    private func choose(for event: AlertEvent) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.prompt = String(localized: "Choose", comment: "Sound file picker's button")
        panel.message = String(localized: "Choose a sound for “\(event.name)”. A short one works best: at most \(Int(CustomSounds.longest)) seconds.", comment: "Settings › Alerts: the sound file picker's message")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            switch CustomSoundFiles.add(url) {
            case .success(let name):
                refusal = nil
                customSounds = AlertCenter.customSounds
                preferences.alerts[event].sound = .custom(name)
                AlertCenter.shared.play(.custom(name), for: event)
            case .failure(let problem):
                refusal = CustomSoundFiles.message(problem, file: url.lastPathComponent)
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    private func remove(_ name: String) {
        CustomSoundFiles.remove(name)
        customSounds = AlertCenter.customSounds
    }
}

/// One event: its name (pointing at it says where it comes from), its sound with Play, and Notify.
private struct AlertEventRow: View {
    let event: AlertEvent
    @Binding var setting: AlertEventSetting
    let customSounds: [String]
    let choose: () -> Void
    let remove: (String) -> Void

    /// What the sound menu holds: a sound, or one of its two commands.
    enum Item: Hashable {
        case sound(AlertSoundChoice)
        case choose
        case remove(String)
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Picker(selection: selection) {
                    Text(String(localized: "None", comment: "Settings › Alerts: no sound")).tag(Item.sound(.none))
                    Section(String(localized: "Whiskr", comment: "Settings › Alerts: the app's own sounds")) {
                        ForEach(AlertSound.allCases, id: \.self) { sound in Text(sound.name).tag(Item.sound(.whiskr(sound))) }
                    }
                    Section(String(localized: "Mac", comment: "Settings › Alerts: the Mac's own sounds")) {
                        Text(String(localized: "Alert Sound", comment: "Settings › Alerts: the alert sound chosen in System Settings › Sound")).tag(Item.sound(.macAlert))
                        ForEach(AlertCenter.systemSounds, id: \.self) { name in Text(name).tag(Item.sound(.system(name))) }
                    }
                    if !customSounds.isEmpty {
                        Section(String(localized: "Yours", comment: "Settings › Alerts: sounds you added")) {
                            ForEach(customSounds, id: \.self) { file in Text(CustomSounds.displayName(file)).tag(Item.sound(.custom(file))) }
                        }
                    }
                    Divider()
                    Text(String(localized: "Choose…", comment: "Settings › Alerts: add a sound file of yours")).tag(Item.choose)
                    if case .custom(let file) = shown {
                        Text(String(localized: "Remove “\(CustomSounds.displayName(file))”", comment: "Settings › Alerts: remove a sound you added")).tag(Item.remove(file))
                    }
                } label: {
                    Text(String(localized: "Sound for \(event.name)", comment: "Settings › Alerts: a sound menu's accessibility label"))
                }
                .labelsHidden()
                // Their chevrons in one column, as in System Settings.
                .frame(width: 170, alignment: .trailing)
                Button {
                    AlertCenter.shared.play(shown, for: event)
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .disabled(shown == .none)
                .help(String(localized: "Play", comment: "Settings › Alerts: a Play button's tooltip"))
                .accessibilityLabel(String(localized: "Play the sound for \(event.name)", comment: "Settings › Alerts: a Play button, for VoiceOver"))
                Toggle(String(localized: "Notify", comment: "Settings › Alerts: show a notification for this event"), isOn: $setting.notify)
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(String(localized: "Notify for \(event.name)", comment: "Settings › Alerts: a Notify checkbox, for VoiceOver"))
            }
        } label: {
            Text(event.name)
                .help(event.explanation)
                .accessibilityHint(event.explanation)
        }
    }

    /// The sound it plays now: a sound of yours that is gone shows (and plays) the default.
    private var shown: AlertSoundChoice {
        if case .custom(let file) = setting.sound, !customSounds.contains(file) { return AlertPreferences.standard[event].sound }
        return setting.sound
    }

    private var selection: Binding<Item> {
        Binding {
            .sound(shown)
        } set: { item in
            switch item {
            case .sound(let sound):
                setting.sound = sound
                // Heard as it is chosen, as the Mac's own Sound settings do.
                AlertCenter.shared.play(sound, for: event)
            case .choose:
                // After the menu has closed.
                DispatchQueue.main.async { choose() }
            case .remove(let file):
                remove(file)
            }
        }
    }
}

extension AlertSound {
    /// The sound's name, in Settings' sound menus.
    var name: String {
        switch self {
        case .request: String(localized: "Rising Notes", comment: "Alert sound: two rising notes")
        case .error: String(localized: "Low Notes", comment: "Alert sound: two low falling notes")
        case .finished: String(localized: "Soft Knock", comment: "Alert sound: one soft wooden knock")
        }
    }
}

extension AlertEvent {
    /// Its name, as Settings › Alerts and Help show it.
    var name: String {
        switch self {
        case .request: String(localized: "Permission request", comment: "Alert event: Claude asks to use a tool")
        case .question: String(localized: "Question", comment: "Alert event: Claude asks a question, a plan waits for approval, or a form waits")
        case .finished: String(localized: "Finished", comment: "Alert event: Claude's turn ended")
        case .error: String(localized: "Error", comment: "Alert event: Claude's turn stopped on an error")
        case .helperFinished: String(localized: "Helper finished", comment: "Alert event: one of Claude's helpers is done")
        case .bell: String(localized: "Bell", comment: "Alert event: a terminal rang its bell")
        }
    }

    /// What it is, and the Claude Code hooks it comes from.
    var explanation: String {
        switch self {
        case .request:
            String(localized: "Claude asks to use a tool. From Claude Code’s PermissionRequest hook, and its Notification hook (permission_prompt).", comment: "Settings › Alerts: where an event comes from")
        case .question:
            String(localized: "Claude asks a question, waits for its plan to be approved, or a tool’s form waits for you. From Claude Code’s PreToolUse hook (AskUserQuestion, ExitPlanMode), its Elicitation hook, and its Notification hook (elicitation_dialog).", comment: "Settings › Alerts: where an event comes from")
        case .finished:
            String(localized: "Claude’s turn ended. From Claude Code’s Stop hook.", comment: "Settings › Alerts: where an event comes from")
        case .error:
            String(localized: "Claude’s turn stopped on an error. From Claude Code’s StopFailure hook.", comment: "Settings › Alerts: where an event comes from")
        case .helperFinished:
            String(localized: "One of Claude’s helpers finished its task. From Claude Code’s SubagentStop hook.", comment: "Settings › Alerts: where an event comes from")
        case .bell:
            String(localized: "A terminal without Claude rang its bell, for example at the end of a long command.", comment: "Settings › Alerts: where an event comes from")
        }
    }
}
