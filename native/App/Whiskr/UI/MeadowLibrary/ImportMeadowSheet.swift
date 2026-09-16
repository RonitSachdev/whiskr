import AppKit
import MeadowFile
import SwiftUI
import WhiskrMeadow

/// Importing meadows someone shared (docs/DESIGN.md, "My Meadows" and §8.4): every way a `.whiskrmeadow` comes
/// in (File › Import Meadow…, a double-click in the Finder or Open With, a file dropped on the meadow, on My
/// Meadows or on the Dock icon) goes through here, one file after another, each in the import sheet.
///
/// A file is read only once it is known to be an ordinary file no larger than a meadow (`MeadowLibraryFolder.data`),
/// then with every check a file from anyone gets (`MeadowDocument.read`). It is data only: nothing in it is run,
/// opened or followed. The sheet shows the meadow drawn from its data, its name, who made it, what it holds and
/// what to know (things this Whiskr cannot draw, a newer format, things left outside, a name already taken); a
/// file that cannot be opened says why and what to do. Adding never replaces a meadow: a name taken gets " 2".
@MainActor @Observable
final class MeadowImport {
    static let shared = MeadowImport()

    /// A file read and fit to add.
    struct Candidate {
        let source: URL
        let data: Data
        let reading: MeadowReading
        let summary: MeadowSummary
        /// The name it would take in My Meadows (with " 2" when one of yours has its own).
        let fileName: String
        let digest: UInt64
        /// Things this Whiskr cannot draw (from a newer Whiskr, or of the catalog with no model yet).
        let undrawn: Int

        var name: String { reading.document.name.isEmpty ? MeadowLibraryFolder.name(of: fileName) : reading.document.name }
    }

    /// What the sheet shows now.
    enum Shown {
        case candidate(Candidate)
        case refused(title: String, message: String)
    }

    private(set) var shown: Shown?
    /// What was last done with a file (the library flow checks it): its name in My Meadows, and whether it is shown.
    private(set) var lastAdded: (file: String, used: Bool)?
    @ObservationIgnored private var waiting: [URL] = []
    @ObservationIgnored private var sheet: NSWindow?
    @ObservationIgnored private weak var parent: NSWindow?

    /// Brings `urls` in, one after another, each in the sheet over `window` (the main window when nil).
    func open(_ urls: [URL], over window: NSWindow?) {
        waiting += urls
        if parent == nil || sheet == nil { parent = window ?? NSApp.mainWindow ?? NSApp.windows.first { $0.windowController is MainWindowController } }
        if shown == nil { next() }
    }

    /// File › Import Meadow… and My Meadows' Import…: the open panel, then the sheet for each file chosen.
    func choose(over window: NSWindow?) {
        MeadowPanels.chooseImports(window) { [weak self] urls in
            guard !urls.isEmpty else { return }
            self?.open(urls, over: window)
        }
    }

    private func next() {
        guard !waiting.isEmpty else { return close() }
        let url = waiting.removeFirst()
        shown = Self.judge(url)
        present()
    }

    /// What a file is: fit to add, or why it cannot be opened.
    static func judge(_ url: URL) -> Shown {
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        do {
            let data = try MeadowLibraryFolder.data(at: url)
            let reading = try MeadowDocument.read(data)
            let library = MeadowLibrary.shared
            let undrawn = MeadowEditSession(reading.document).undrawnCount
            return .candidate(Candidate(source: url, data: data, reading: reading, summary: reading.summary(),
                                        fileName: library.folder.importedFileName(reading, fallback: base),
                                        digest: MeadowLibraryFolder.digest(data), undrawn: undrawn))
        } catch {
            return .refused(title: MeadowFileWords.refusalTitle(error, name: base), message: MeadowFileWords.refusal(error))
        }
    }

    private func present() {
        guard let parent else { return }
        if let sheet {
            sheet.contentViewController = NSHostingController(rootView: ImportMeadowSheet(model: self))
            return
        }
        let host = NSHostingController(rootView: ImportMeadowSheet(model: self))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled]
        sheet = window
        parent.beginSheet(window)
    }

    /// Add to My Meadows (and, with `use`, show it): added as it came, under a name of its own.
    func add(use: Bool) {
        guard case .candidate(let candidate) = shown else { return }
        let library = MeadowLibrary.shared
        do {
            let file = try library.add(imported: candidate.data, candidate.reading, fallback: MeadowLibraryFolder.name(of: candidate.fileName))
            if use { library.use(file) }
            lastAdded = (file, use)
            next()
        } catch {
            shown = .refused(title: MeadowFileWords.refusalTitle(error, name: candidate.name),
                             message: String(localized: "It couldn't be added to My Meadows: there was a problem writing it. Try again, or check the disk has room.",
                                             comment: "Import: the meadow could not be written into the library"))
            present()
        }
    }

    /// Cancel, or OK on a file that cannot be opened: on to the next.
    func dismiss() {
        next()
    }

    private func close() {
        shown = nil
        if let sheet, let parent { parent.endSheet(sheet) }
        sheet = nil
        parent = nil
    }

    #if DEBUG
    var debugSheet: NSWindow? { sheet }
    var debugWaiting: Int { waiting.count }
    #endif
}

/// The import sheet (§5.4): the meadow drawn from its data, by day; its name, who made it and a line about it;
/// what it holds; what to know; and Cancel, Add to My Meadows, Add and Use. A file that cannot be opened: why, and OK.
struct ImportMeadowSheet: View {
    let model: MeadowImport
    private let previews = MeadowPreviews.shared

    static let width: CGFloat = 480

    var body: some View {
        Group {
            switch model.shown {
            case .candidate(let candidate): candidateView(candidate)
            case .refused(let title, let message): refusedView(title, message)
            case nil: EmptyView()
            }
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func candidateView(_ candidate: MeadowImport.Candidate) -> some View {
        VStack(alignment: .leading, spacing: Look.Space.l) {
            picture(candidate)
            VStack(alignment: .leading, spacing: Look.Space.xs) {
                Text(verbatim: candidate.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if let byline = MeadowFileWords.byline(author: candidate.reading.document.author, writtenBy: candidate.summary.writtenBy) {
                    Text(verbatim: byline).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if !candidate.reading.document.description.isEmpty {
                    Text(verbatim: "“\(candidate.reading.document.description)”").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: MeadowFileWords.contents(things: candidate.summary.things, paints: candidate.summary.paints))
                    .font(.callout).foregroundStyle(.secondary)
            }
            let notes = notes(candidate)
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: Look.Space.s) {
                    ForEach(notes, id: \.self) { note in
                        Label { Text(verbatim: note).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
                            .font(.callout)
                    }
                }
                .padding(Look.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Look.Radius.control).fill(Color.primary.opacity(0.05)))
            }
            HStack(spacing: Look.Space.m) {
                Spacer()
                Button(String(localized: "Cancel")) { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Add to My Meadows", comment: "Import sheet: adds the meadow without showing it")) { model.add(use: false) }
                Button(String(localized: "Add and Use", comment: "Import sheet: adds the meadow and shows it")) { model.add(use: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Look.Space.xl)
    }

    private func picture(_ candidate: MeadowImport.Candidate) -> some View {
        let _ = previews.drawn
        let image = previews.picture(importing: candidate.reading.document, digest: candidate.digest)
        return ZStack {
            Rectangle().fill(Color.primary.opacity(0.06))
            if let image {
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: (Self.width - 2 * Look.Space.xl) * 10 / 16)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityElement()
        .accessibilityLabel(String(localized: "A picture of the meadow, drawn from its file", comment: "Import sheet: the meadow's picture, for VoiceOver"))
    }

    private func notes(_ candidate: MeadowImport.Candidate) -> [String] {
        var notes: [String] = []
        if candidate.undrawn > 0 { notes.append(MeadowFileWords.undrawn(candidate.undrawn)) }
        if candidate.summary.newerFormat { notes.append(MeadowFileWords.newerFormat) }
        if candidate.summary.leftOutside > 0 { notes.append(MeadowFileWords.leftOutside(candidate.summary.leftOutside)) }
        let taken = MeadowLibraryFolder.name(of: candidate.fileName)
        if taken != candidate.name { notes.append(MeadowFileWords.renamed(candidate.name, as: taken)) }
        return notes
    }

    private func refusedView(_ title: String, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: Look.Space.l) {
            HStack(alignment: .top, spacing: Look.Space.l) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Look.Space.xs) {
                    Text(verbatim: title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button(String(localized: "OK")) { model.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Look.Space.xl)
    }
}
