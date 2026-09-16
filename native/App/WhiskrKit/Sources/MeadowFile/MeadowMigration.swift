import Foundation

/// How a file from an older Whiskr becomes this one's: a chain of pure steps on the file's JSON, in
/// memory, before it is read. Opening never rewrites a file; it is saved in the newest format only when
/// the person changes the meadow, and what it holds from a newer Whiskr is kept through the steps.
///
/// - A **format step** turns a file of format major `n` into major `n + 1` (`v1to2`, `v2to3`, …) and
///   sets `whiskrMeadow` to `n + 1`. Minor changes need none: what is missing takes its default.
/// - A **catalog step** at catalog `n` applies to files written with a catalog before `n`: it maps a
///   thing whose look was replaced in catalog `n` to what keeps its look (rule 4 of `MeadowCatalog`).
///
/// There are none yet: format 1 and catalog 1 are the first.
public struct MeadowMigration: Sendable {
    public typealias Step = @Sendable (MeadowJSON) throws -> MeadowJSON

    /// By the major each step migrates from.
    public let formatSteps: [Int: Step]
    /// By the catalog each step migrates to.
    public let catalogSteps: [Int: Step]

    public init(formatSteps: [Int: Step] = [:], catalogSteps: [Int: Step] = [:]) {
        self.formatSteps = formatSteps
        self.catalogSteps = catalogSteps
    }

    /// The chain this Whiskr reads with.
    public static let current = MeadowMigration()

    /// A step left `whiskrMeadow` at something other than the next major, or a step is missing.
    public struct BrokenChain: Error, Equatable, Sendable {
        public let from: Int
    }

    /// `file` (format major `major`, written with catalog `catalog`) as format major `toMajor` with
    /// every catalog step after its catalog applied, up to `toCatalog`.
    public func migrate(_ file: MeadowJSON, major: Int, catalog: Int, toMajor: Int, toCatalog: Int) throws -> MeadowJSON {
        var file = file
        for from in major..<max(major, toMajor) {
            guard let step = formatSteps[from] else { throw BrokenChain(from: from) }
            file = try step(file)
            guard file.object?["whiskrMeadow"]?.integer == from + 1 else { throw BrokenChain(from: from) }
        }
        for to in (catalog + 1)..<max(catalog + 1, toCatalog + 1) {
            if let step = catalogSteps[to] { file = try step(file) }
        }
        return file
    }
}
