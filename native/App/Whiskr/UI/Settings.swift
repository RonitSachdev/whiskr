import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskrKit

/// The settings window (⌘,), as Mac settings windows are: a pane per subject, chosen in the toolbar, each
/// change applied at once (docs/DESIGN.md). General: restoring Claude, where new tabs open,
/// asking before quitting. Terminal: the theme (with previews, editing and importing) and the font and
/// cursor. Alerts: notifications and the Dock badge. Meadow: time of day, real weather, picnic things,
/// flag size (and the map, once there is a second to choose).
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
            importThemes(panel.urls, over: window)
            then()
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Where languages added with Add Theme… or File › Import are kept (`LanguageRegistry.install`).
    static var languagesFolder: URL { Workbench.supportFolder.appendingPathComponent("Languages", isDirectory: true) }

    /// Imports themes and languages (a VS Code extension may hold both; a TextMate grammar is a language),
    /// keeps one line saying what was added for Settings to show (`ThemeStore.importSummary`), and reports
    /// anything that could not be read.
    static func importThemes(_ urls: [URL], over window: NSWindow?) {
        var problems: [String] = []
        var added: [String] = []
        var languages = 0
        for url in urls {
            let name = url.lastPathComponent.lowercased()
            let isGrammar = name.hasSuffix(".tmlanguage.json") || name.hasSuffix(".tmlanguage") || url.pathExtension.lowercased() == "plist"
            let isExtension = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true || url.pathExtension.lowercased() == "vsix"
            do {
                let themes = isGrammar ? [] : try ThemeStore.shared.importThemes(at: url)
                added += themes.map(\.name)
                if isGrammar || isExtension {
                    do {
                        languages += try LanguageRegistry.shared.install(from: url, into: languagesFolder).count
                    } catch LanguageInstallError.nothingToInstall where !themes.isEmpty {
                        // An extension of themes only.
                    }
                } else if themes.isEmpty {
                    throw ThemeImportError.unreadable(String(localized: "There are no colour themes in it."))
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
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
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
    @Environment(\.colorScheme) private var colorScheme

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
                        ThemeCard(theme: theme, dark: colorScheme == .dark, selected: theme.id == store.themeID)
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

/// A theme in the picker: its preview for the current appearance, its name and which versions it has.
struct ThemeCard: View {
    let theme: Theme
    let dark: Bool
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThemePreview(variant: theme.variant(dark: dark))
                .frame(height: 104)
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
        .help(theme.credit ?? theme.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(selected ? String(localized: "\(theme.name) theme, selected") : String(localized: "\(theme.name) theme"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A miniature of a theme: a strip of the app's chrome with its state marks, a line, and a terminal.
struct ThemePreview: View {
    let variant: ThemeVariant

    private func color(_ value: WhiskrKit.RGBColor) -> SwiftUI.Color { SwiftUI.Color(nsColor: Palette.nsColor(value)) }
    private func app(_ key: AppColorKey) -> SwiftUI.Color { color(variant.app[key]) }
    private func ansi(_ index: Int) -> SwiftUI.Color { color(variant.terminal.ansi[index]) }

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
            .frame(width: 58)
            .background(app(.chrome))
            Rectangle().fill(app(.line)).frame(width: 1)
            VStack(alignment: .leading, spacing: 1.5) {
                Text("$ ").foregroundColor(ansi(2)) + Text("npm test").foregroundColor(color(variant.terminal.foreground))
                Text("✓ 13 passing").foregroundColor(ansi(2))
                Text("✗ 1 failing").foregroundColor(ansi(1))
                Text("warn ").foregroundColor(ansi(3)) + Text("src/cart.ts").foregroundColor(ansi(4))
                Text("~/shop ").foregroundColor(ansi(6)) + Text("main").foregroundColor(ansi(5))
                (Text("> ").foregroundColor(color(variant.terminal.foreground)) + Text("█").foregroundColor(color(variant.terminal.cursor)))
            }
            .font(.system(size: 8.5, design: .monospaced))
            .padding(7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(color(variant.terminal.background))
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
        _dark = State(initialValue: original.light == nil || (original.dark != nil && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
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
            ThemePreview(variant: variant)
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

/// Settings › Alerts (§10): the three sounds with a Play button each, how loud, notifications while you
/// are in another app, the Dock icon, and Pause Alerts.
struct AlertSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section {
                SoundRow(title: String(localized: "Sound when Claude needs you"), isOn: $preferences.soundRequests, sounds: [.request, .error])
                SoundRow(title: String(localized: "Sound when Claude finishes"), isOn: $preferences.soundFinished, sounds: [.finished])
                LabeledContent(String(localized: "Volume")) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                        Slider(value: $preferences.soundVolume, in: 0...1)
                            .frame(maxWidth: 200)
                            .accessibilityLabel(String(localized: "Volume"))
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                    }
                }
            } footer: {
                Text(String(localized: "Only while you are in Whiskr and not typing in that Claude's terminal. A request plays two rising notes, an error two low ones, a finish one soft knock."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle(String(localized: "Notify when Claude needs you"), isOn: $preferences.notifyRequests)
                Toggle(String(localized: "Notify when Claude finishes a long turn"), isOn: $preferences.notifyFinished)
            } footer: {
                Text(String(localized: "Only while you are in another app. A request's notification has Allow and Deny; a finish is announced quietly, and only after a turn of 30 seconds or more."))
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
    }
}

/// A sound's switch with a Play button for each of its sounds.
private struct SoundRow: View {
    let title: String
    @Binding var isOn: Bool
    let sounds: [AlertSound]

    var body: some View {
        HStack {
            Toggle(title, isOn: $isOn)
            Spacer()
            ForEach(sounds, id: \.self) { sound in
                Button {
                    AlertCenter.shared.play(sound)
                } label: {
                    Label(sounds.count > 1 ? sound.name : String(localized: "Play"), systemImage: "play.fill")
                }
                .controlSize(.small)
                .help(String(localized: "Play the \(sound.name.lowercased()) sound", comment: "Settings: a Play button's tooltip"))
            }
        }
    }
}

extension AlertSound {
    /// The sound's name, as the Play buttons show it.
    var name: String {
        switch self {
        case .request: String(localized: "Request", comment: "Alert sound")
        case .error: String(localized: "Error", comment: "Alert sound")
        case .finished: String(localized: "Finished", comment: "Alert sound")
        }
    }
}
