import Foundation

// The `.whiskrmeadow` file: UTF-8 JSON, data only. It can never run code, name a path, open a URL or
// reach the network. Same meadow, same bytes (`MeadowJSON.fileText`).
//
//     {
//       "author": "",
//       "base": "meadow",
//       "catalog": 1,
//       "description": "",
//       "formatMinor": 0,
//       "ground": {
//         "cells": 512,
//         "paints": ["ground.path"],
//         "reach": 150,
//         "runs": [0, 120000, 1, 14, 0, 142130]
//       },
//       "items": [
//         { "at": [12.5, -30.25], "id": "tree.apple", "seed": 3141592653, "size": [1.04, 0.97, 1], "turn": 1.5708 },
//         { "id": "garden.fence", "params": { "gate": 1 }, "points": [[30, 5], [32.5, 5]] }
//       ],
//       "name": "Orchard Study",
//       "needsCatalog": 1,
//       "whiskrMeadow": 1,
//       "writtenBy": "1.4.0"
//     }
//
// Versions, each with one job:
// - `whiskrMeadow`, the format major and the file's magic key: bumped only for a change an older Whiskr
//   could misread. A newer major is refused, nothing changed.
// - `formatMinor`: additive changes (a new optional field, a new section). Older readers keep what they
//   do not know and write it back.
// - `catalog`: the newest catalog the writing Whiskr knew. `needsCatalog`: the oldest catalog holding
//   everything the file uses (`MeadowDocument.needsCatalog`).
// - `writtenBy`: the Whiskr version that last saved it; for people, never for decisions.

/// The file's constants and limits.
public enum MeadowFormat {
    public static let fileExtension = "whiskrmeadow"
    /// Exported by the app; conforms to `public.json`.
    public static let typeIdentifier = "app.whiskr.meadow"

    /// The format this Whiskr reads and writes.
    public static let major = 1
    public static let minor = 0

    /// The only world so far. A file on another is from a newer Whiskr.
    public static let meadowBase = "meadow"

    /// Larger files are refused before they are parsed (a full meadow of 5,000 things is about 400 KB).
    public static let maxBytes = 4 * 1024 * 1024
    /// Nesting and value counts the parser stops at.
    public static let limits = MeadowJSON.Limits(depth: 16, values: 200_000)

    /// The editable disc's radius around the meadow's middle, in units. Things outside it are left out.
    public static let reach = 150.0
    /// Things in all, including those from a newer Whiskr.
    public static let maxItems = 5_000
    /// Things from a newer Whiskr.
    public static let maxNewerItems = 1_000
    /// The longest one thing may be, written on one line (`MeadowJSON.inlineText`), in UTF-8 bytes.
    public static let maxItemBytes = 4_096
    /// Points in one run (a fence).
    public static let runPoints = 2...64
    /// The longest variant number read (a variant this Whiskr lacks is kept, up to this).
    public static let maxVariant = 255

    /// Whether `version` is shaped as a version a Whiskr writes ("1.4.0", "2.0.0-beta.1"): at most 32
    /// letters, digits, dots, hyphens and pluses, starting with a digit.
    public static func isWellFormedVersion(_ version: String) -> Bool {
        guard let first = version.utf8.first, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first), version.utf8.count <= 32 else { return false }
        return version.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "+")
        }
    }
}

/// Why a meadow file could not be read, or a meadow not written. Each is a verdict the app and `paw`
/// put in their own words; nothing here is shown as it is.
public enum MeadowFileError: Error, Equatable, Sendable {
    /// Over `MeadowFormat.maxBytes`.
    case tooLarge(bytes: Int)
    /// Not JSON this reader accepts (or over its nesting or value limits).
    case notJSON(MeadowJSONError)
    /// JSON, but not a meadow: no `whiskrMeadow` number.
    case notAMeadow
    /// Written by a newer Whiskr in a way this one cannot read (a newer format major, or a world this
    /// one does not have). `writtenBy` is that Whiskr's version when the file names a well-formed one.
    case needsNewerWhiskr(writtenBy: String?)
    /// A field this Whiskr knows is not what the format says. `at` is where, as `items[12].size`.
    case invalid(at: String, MeadowProblem)
    /// The name, author or description is longer than its limit.
    case textTooLong(MeadowText.Field)
    /// More things than `MeadowFormat.maxItems`.
    case tooManyThings(count: Int)
    /// More things of one kind than its cap.
    case tooManyOfKind(MeadowCatalog.Cap, count: Int)
    /// More things from a newer Whiskr than `MeadowFormat.maxNewerItems`.
    case tooManyNewerThings(count: Int)
    /// One thing longer than `MeadowFormat.maxItemBytes`, at `items[n]`.
    case thingTooLarge(at: String)
}

/// What is wrong with one field.
public enum MeadowProblem: Equatable, Sendable {
    case missing
    case wrongType
    /// A number too large to be a number (`1e999`).
    case notFinite
    /// A number outside what the field allows (where the format refuses rather than clamps).
    case outOfRange
    /// Not an asset id (`MeadowCatalog.isWellFormed`).
    case malformedId
    /// A paint listed as a thing.
    case notAThing
    /// A thing, or the eraser (which is never stored), listed as a paint.
    case notAPaint
    case duplicatePaint
    /// A run with fewer or more points than `MeadowFormat.runPoints`.
    case pointCount
    case runs(GroundGrid.RunsProblem)
}

/// A meadow read from a file, with what the person should be told about it.
public struct MeadowReading: Equatable, Sendable {
    public var document: MeadowDocument
    /// Things outside the meadow that were left out ("3 things outside the meadow were left out").
    public var leftOutside: Int
    /// Things from a newer Whiskr: kept, and not drawn ("6 things can't be shown here").
    public var newerThings: Int { document.parcels.count }
    /// Anything kept only because a newer Whiskr wrote it (things, or details of known things).
    public var keepsNewerContent: Bool
}
