import AppKit
import MeadowFile
import MeadowScene
import Observation
import WhiskrMeadow

/// Pictures of meadows (docs/DESIGN.md, "My Meadows"): each drawn by the scene itself from the meadow's data
/// (`MeadowView.previewImage`), never an image from a file, by one meadow view of their own that is never on
/// screen. Kept in memory for as long as what they show holds: a file's stamp (its size and time), so a meadow
/// changed (by you, a sync tool or the Finder) is drawn again; the Default once. The scene draws no colour of the
/// theme, so one picture is right for every theme; the cards round it are the theme's.
///
/// Drawing one takes a few tens of milliseconds on the main thread (the scene is not thread-safe), so pictures
/// asked for are drawn one at a time, a turn of the main loop apart, and `drawn` counts them so views showing
/// them update.
@MainActor @Observable
final class MeadowPreviews {
    static let shared = MeadowPreviews()

    /// The pictures' sizes, in pixels (16:10, at twice the points shown).
    enum Size: Hashable {
        /// A card in My Meadows.
        case card
        /// The import sheet.
        case sheet
        /// File › Export Meadow Picture….
        case export

        var pixels: (width: Int, height: Int) {
            switch self {
            case .card: (480, 300)
            case .sheet: (960, 600)
            case .export: (2400, 1500)
            }
        }
    }

    /// What a picture shows: a meadow file as its stamp says it is, the Default, or a meadow being imported (by
    /// its bytes' digest).
    struct Key: Hashable {
        var source: String
        var size: Size
    }

    /// How many pictures have been drawn: views read it to show each as it comes.
    private(set) var drawn = 0
    @ObservationIgnored private var pictures: [Key: CGImage] = [:]
    /// What could not be drawn (a meadow that cannot be read): not asked again until what it shows changes.
    @ObservationIgnored private var failed: Set<Key> = []
    @ObservationIgnored private var queue: [(key: Key, document: @MainActor () -> MeadowDocument?)] = []
    @ObservationIgnored private var drawing = false
    @ObservationIgnored private lazy var view = MeadowView(frame: NSRect(x: 0, y: 0, width: 240, height: 150))

    /// The key of a picture of one of your meadows (nil: the Default) as it is on disk now.
    func key(_ file: String?, _ size: Size) -> Key {
        guard let file else { return Key(source: "default", size: size) }
        let stamp = MeadowLibrary.shared.stamps[file]
        return Key(source: "\(file)|\(stamp?.size ?? -1)|\(stamp?.modified.timeIntervalSinceReferenceDate ?? 0)", size: size)
    }

    /// The picture of one of your meadows (nil: the Default), when drawn; asked for, it is drawn soon (`drawn` then
    /// changes). Nil also when the meadow cannot be read.
    func picture(_ file: String?, _ size: Size = .card) -> CGImage? {
        let key = key(file, size)
        if let picture = pictures[key] { return picture }
        if !failed.contains(key) { ask(key) { MeadowLibrary.shared.document(file) } }
        return nil
    }

    /// The picture of a meadow being imported (`digest`: its bytes'), when drawn; asked for as `picture` is.
    func picture(importing document: MeadowDocument, digest: UInt64, _ size: Size = .sheet) -> CGImage? {
        let key = Key(source: "import|\(digest)", size: size)
        if let picture = pictures[key] { return picture }
        if !failed.contains(key) { ask(key) { document } }
        return nil
    }

    /// A picture drawn now, not kept (File › Export Meadow Picture…).
    func pictureNow(of document: MeadowDocument, _ size: Size) -> CGImage? {
        draw(document, size)
    }

    private func ask(_ key: Key, _ document: @escaping @MainActor () -> MeadowDocument?) {
        guard !queue.contains(where: { $0.key == key }) else { return }
        queue.append((key, document))
        drawNext()
    }

    private func drawNext() {
        guard !drawing, !queue.isEmpty else { return }
        drawing = true
        // A turn of the main loop between pictures: whatever else is waiting (typing, a frame) goes first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let (key, document) = self.queue.removeFirst()
            if let document = document(), let picture = self.draw(document, key.size) {
                // Pictures of the same meadow as it was are let go: only what is on disk now is kept.
                let meadow = key.source.split(separator: "|").first.map(String.init)
                self.pictures = self.pictures.filter { old in old.key.size != key.size || old.key.source.split(separator: "|").first.map(String.init) != meadow }
                self.pictures[key] = picture
            } else {
                self.failed.insert(key)
            }
            self.drawn += 1
            self.drawing = false
            self.drawNext()
        }
    }

    private func draw(_ document: MeadowDocument, _ size: Size) -> CGImage? {
        let pixels = size.pixels
        return view.previewImage(of: MeadowScenery(document), width: pixels.width, height: pixels.height)
    }

    /// The picture as a PNG (File › Export Meadow Picture…).
    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    #if DEBUG
    /// Pictures kept now (the library flow checks one is drawn again when its meadow changes).
    var debugKept: Int { pictures.count }
    var debugWaiting: Int { queue.count + (drawing ? 1 : 0) }
    #endif
}
