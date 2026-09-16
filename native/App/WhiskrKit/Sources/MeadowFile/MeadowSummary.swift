import Foundation

/// What a meadow file holds and how it was written, as the import sheet and the library's cards tell it
/// ("214 things · paths and lawn", "Made with Whiskr 1.4"), with what this Whiskr should say about it: things
/// it cannot draw, a newer format it reads in part, things outside the meadow left out. The same verdicts
/// anywhere a meadow file is looked at, so a gallery's checks can say what the app says.
public struct MeadowSummary: Equatable, Sendable {
    /// Every thing it holds, those from a newer Whiskr among them.
    public var things: Int
    /// The paints its ground shows (cells painted with each), known ones only, in the catalog's order.
    public var paints: [String]
    /// The Whiskr that last saved it (`writtenBy`), when it named a well-formed version.
    public var writtenBy: String?
    /// Things from a newer Whiskr: kept whole, not drawn ("6 things can't be shown here").
    public var newerThings: Int
    /// It was made with a newer catalog than this Whiskr's and uses something of it (`needsCatalog`):
    /// what this Whiskr cannot show comes back once it is updated.
    public var needsNewerCatalog: Bool
    /// Its format is a newer minor one (`formatMinor`): read, what this Whiskr does not know of it kept and
    /// written back untouched.
    public var newerFormat: Bool
    /// Anything kept only because a newer Whiskr wrote it (things, details of things, sections, paints).
    public var keepsNewerContent: Bool
    /// Things outside the meadow, left out as it was read.
    public var leftOutside: Int

    public init(things: Int, paints: [String], writtenBy: String?, newerThings: Int, needsNewerCatalog: Bool, newerFormat: Bool,
                keepsNewerContent: Bool, leftOutside: Int) {
        self.things = things
        self.paints = paints
        self.writtenBy = writtenBy
        self.newerThings = newerThings
        self.needsNewerCatalog = needsNewerCatalog
        self.newerFormat = newerFormat
        self.keepsNewerContent = keepsNewerContent
        self.leftOutside = leftOutside
    }
}

extension MeadowReading {
    /// The file as people are told of it, against this Whiskr's catalog.
    public func summary(_ catalog: MeadowCatalog = .current) -> MeadowSummary {
        let from = document.readFrom
        return MeadowSummary(things: document.entries.count, paints: document.paintsShown(catalog), writtenBy: from?.writtenBy,
                             newerThings: newerThings, needsNewerCatalog: (from?.needsCatalog ?? 1) > catalog.number,
                             newerFormat: (from?.formatMinor ?? 0) > MeadowFormat.minor, keepsNewerContent: keepsNewerContent,
                             leftOutside: leftOutside)
    }
}

extension MeadowDocument {
    /// The paints its ground shows: those this Whiskr knows with at least one cell painted, in the catalog's
    /// order.
    public func paintsShown(_ catalog: MeadowCatalog = .current) -> [String] {
        guard let ground else { return [] }
        var used = Set<UInt8>()
        for cell in ground.cells where cell != 0 { used.insert(cell) }
        let shown = Set(used.compactMap { ground.drawnPaint($0, catalog) })
        return catalog.assets.filter { $0.nature == .paint && shown.contains($0.id) }.map(\.id)
    }
}
