import Foundation
import MeadowFile
import WhiskrMeadow

/// What My Meadows and the import sheet say (docs/DESIGN.md, "Words"): a meadow's contents in a line ("214 things
/// · paths and lawn"), who made it, the notes a file from a newer Whiskr gets, and why a file cannot be opened, in
/// plain words that say what to do. Never an id, a path or an error code.
enum MeadowFileWords {
    /// "214 things · paths and lawn", "Nothing placed yet".
    static func contents(things: Int, paints: [String]) -> String {
        let count = things == 1 ? String(localized: "1 thing", comment: "My Meadows: how many things a meadow holds (one)")
                                : String(localized: "\(things) things", comment: "My Meadows: how many things a meadow holds")
        let ground = paints.compactMap(paintName)
        if things == 0 && ground.isEmpty { return String(localized: "Nothing placed yet", comment: "My Meadows: an empty meadow") }
        guard !ground.isEmpty else { return count }
        return "\(count) · \(ListFormatter.localizedString(byJoining: ground))"
    }

    /// A paint as the contents line names it ("paths").
    static func paintName(_ id: String) -> String? {
        switch id {
        case "ground.path": String(localized: "paths", comment: "My Meadows: what a meadow's ground is painted with (worn earth)")
        case "ground.lawn": String(localized: "lawn", comment: "My Meadows: what a meadow's ground is painted with (grass mown short)")
        case "ground.soil": String(localized: "soil", comment: "My Meadows: what a meadow's ground is painted with (beds of bare earth)")
        default: nil
        }
    }

    /// "by Hana · Made with Whiskr 1.8.2", or less when the file says less; nil when it says nothing.
    static func byline(author: String, writtenBy: String?) -> String? {
        var parts: [String] = []
        if !author.isEmpty { parts.append(String(localized: "by \(author)", comment: "Import sheet: who made a meadow (the name its file gives)")) }
        if let writtenBy { parts.append(String(localized: "Made with Whiskr \(writtenBy)", comment: "Import sheet: the Whiskr that saved a meadow")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Notes on a file from a newer Whiskr

    /// Things this Whiskr cannot draw: kept, counted, back once it is updated.
    static func undrawn(_ count: Int) -> String {
        count == 1 ? String(localized: "Made with a newer Whiskr: 1 thing can't be shown here. It's kept, and comes back when you update.",
                            comment: "A meadow note: one thing this Whiskr cannot draw")
                   : String(localized: "Made with a newer Whiskr: \(count) things can't be shown here. They're kept, and come back when you update.",
                            comment: "A meadow note: things this Whiskr cannot draw")
    }

    /// A newer way of writing meadows, read in part.
    static var newerFormat: String {
        String(localized: "Saved by a newer Whiskr. Everything this one knows is shown; the rest is kept untouched and saved back as it was.",
               comment: "Import sheet: a meadow file of a newer minor format")
    }

    /// Things outside the meadow, left out.
    static func leftOutside(_ count: Int) -> String {
        count == 1 ? String(localized: "1 thing outside the meadow was left out.", comment: "Import sheet: a thing out of the meadow's bounds")
                   : String(localized: "\(count) things outside the meadow were left out.", comment: "Import sheet: things out of the meadow's bounds")
    }

    /// The name an import takes when one of yours has its own.
    static func renamed(_ name: String, as taken: String) -> String {
        String(localized: "You have a meadow called “\(name)”, so this one is added as “\(taken)”.",
               comment: "Import sheet: a meadow of the same name is in My Meadows already")
    }

    // MARK: Files that cannot be opened

    /// The title over why a file cannot be opened: "“Orchard Study” needs a newer Whiskr", "“picnic” can't be opened".
    static func refusalTitle(_ error: Error, name: String) -> String {
        if case MeadowFileError.needsNewerWhiskr = error {
            return String(localized: "“\(name)” needs a newer Whiskr", comment: "Import: a meadow file of a newer format, refused")
        }
        return String(localized: "“\(name)” can't be opened", comment: "Import: a file that is not a meadow this Whiskr can read")
    }

    /// Why, and what to do: plain and specific to what was found.
    static func refusal(_ error: Error) -> String {
        guard let error = error as? MeadowFileError else {
            return String(localized: "It couldn't be read. It may have been moved, or Whiskr may not be allowed to read it.",
                          comment: "Import: the file could not be read at all")
        }
        switch error {
        case .tooLarge:
            let most = ByteCountFormatter.string(fromByteCount: Int64(MeadowFormat.maxBytes), countStyle: .memory)
            return String(localized: "It's too large to be a meadow: a meadow file is at most \(most).", comment: "Import: a file over the size limit")
        case .notJSON(.truncated):
            return String(localized: "It's damaged: it ends part way through, as a download that stopped early does. Ask for it again.",
                          comment: "Import: a meadow file cut short")
        case .notJSON(.tooDeep), .notJSON(.tooManyValues):
            return String(localized: "It holds more than a meadow file can, so it isn't read.", comment: "Import: a file over the parser's limits")
        case .notJSON:
            return String(localized: "It's damaged: it isn't written the way a meadow file is, so nothing in it can be read.",
                          comment: "Import: a file that is not valid JSON")
        case .notAMeadow:
            return String(localized: "It isn't a Whiskr meadow.", comment: "Import: JSON that is not a meadow file")
        case .needsNewerWhiskr(let writtenBy):
            if let writtenBy {
                return String(localized: "It was made with Whiskr \(writtenBy), which saves meadows in a way this version can't read. Update Whiskr to open it.",
                              comment: "Import: a meadow file of a newer major format, and the Whiskr that wrote it")
            }
            return String(localized: "It was made with a newer Whiskr, which saves meadows in a way this version can't read. Update Whiskr to open it.",
                          comment: "Import: a meadow file of a newer major format")
        case .invalid(let at, _):
            return String(localized: "It's damaged: something in it isn't what a meadow file holds (at \(at)).", comment: "Import: a field of the wrong kind; where")
        case .textTooLong(let field):
            switch field {
            case .name: return String(localized: "Its name is longer than a meadow's name may be (\(field.limit) characters).", comment: "Import: the name is too long")
            case .author: return String(localized: "Its author is longer than a meadow file allows (\(field.limit) characters).", comment: "Import: the author is too long")
            case .description: return String(localized: "Its description is longer than a meadow file allows (\(field.limit) characters).",
                                              comment: "Import: the description is too long")
            }
        case .tooManyThings(let count):
            return String(localized: "This meadow has more things than Whiskr can show (\(count) of \(MeadowFormat.maxItems)).", comment: "Import: too many things")
        case .tooManyOfKind(let cap, let count):
            return String(localized: "This meadow has more \(capName(cap)) than a meadow can hold (\(count) of \(cap.limit)).", comment: "Import: too many of one kind")
        case .tooManyNewerThings(let count):
            return String(localized: "This meadow has more things from a newer Whiskr than this one can keep (\(count) of \(MeadowFormat.maxNewerItems)).",
                          comment: "Import: too many unknown things")
        case .thingTooLarge(let at):
            return String(localized: "It's damaged: one thing in it is far larger than a thing can be (at \(at)).", comment: "Import: one item over its size limit")
        }
    }

    /// A kind with a cap, as "more trees than a meadow can hold" names it.
    static func capName(_ cap: MeadowCatalog.Cap) -> String {
        switch cap {
        case .trees: String(localized: "trees", comment: "Import: a kind of thing with a cap")
        case .tall: String(localized: "tall things", comment: "Import: a kind of thing with a cap")
        case .lamps: String(localized: "lamps", comment: "Import: a kind of thing with a cap")
        case .fencePosts: String(localized: "fence posts", comment: "Import: a kind of thing with a cap")
        case .madeThings: String(localized: "made things", comment: "Import: a kind of thing with a cap")
        }
    }

    // MARK: Things from a newer Whiskr, in the editor

    /// A parcel's name ("Thing from a newer Whiskr") and what it is, for the pointer's note and VoiceOver.
    static var parcelName: String { String(localized: "Thing from a newer Whiskr", comment: "Meadow editor: a thing this Whiskr cannot draw, shown as a parcel") }
    static var parcelDetail: String {
        String(localized: "Kept whole: move it, or take it away.",
               comment: "Meadow editor: what a parcel is (a thing this Whiskr cannot draw)")
    }
}
