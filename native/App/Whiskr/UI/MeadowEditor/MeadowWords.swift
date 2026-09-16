import Foundation
import MeadowFile
import WhiskrMeadow

/// What the meadow's editor says, in the app's words (docs/DESIGN.md, "Words"): the names of the things a
/// meadow holds, why an edit was not made, and each step's name in Edit › Undo ("Undo Move Oak").
enum MeadowWords {
    /// A thing's name, as a label ("Oak").
    static func name(_ id: String) -> String {
        switch id {
        case "tree.oak": String(localized: "Oak", comment: "Meadow editor: a thing's name")
        case "tree.birch": String(localized: "Birch", comment: "Meadow editor: a thing's name")
        case "tree.cherry": String(localized: "Cherry tree", comment: "Meadow editor: a thing's name")
        case "tree.young": String(localized: "Young tree", comment: "Meadow editor: a thing's name")
        case "flower.daisy": String(localized: "Daisy", comment: "Meadow editor: a thing's name")
        case "flower.buttercup": String(localized: "Buttercup", comment: "Meadow editor: a thing's name")
        case "flower.lupin": String(localized: "Lupin", comment: "Meadow editor: a thing's name")
        case "flower.poppy": String(localized: "Poppy", comment: "Meadow editor: a thing's name")
        case "fungus.flyAgaric": String(localized: "Fly agaric", comment: "Meadow editor: a thing's name")
        case "stone.stone": String(localized: "Stone", comment: "Meadow editor: a thing's name")
        case "stone.mossy": String(localized: "Mossy stone", comment: "Meadow editor: a thing's name")
        case "wood.fallenLog": String(localized: "Fallen log", comment: "Meadow editor: a thing's name")
        default: String(localized: "Thing", comment: "Meadow editor: a thing with no name of its own")
        }
    }

    /// A clump of one kind, for VoiceOver ("Daisies, 9").
    static func clump(_ id: String, count: Int) -> String {
        let plural: String = switch id {
        case "flower.daisy": String(localized: "Daisies", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "flower.buttercup": String(localized: "Buttercups", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "flower.lupin": String(localized: "Lupins", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "flower.poppy": String(localized: "Poppies", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "fungus.flyAgaric": String(localized: "Fly agarics", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "stone.stone": String(localized: "Stones", comment: "Meadow editor: a clump of them, for VoiceOver")
        case "stone.mossy": String(localized: "Mossy stones", comment: "Meadow editor: a clump of them, for VoiceOver")
        default: name(id)
        }
        return String(localized: "\(plural), \(count)", comment: "VoiceOver: a clump of one kind of plant or stone, and how many")
    }

    /// The things an edit is about, in a step's name: one by its name, several by how many.
    static func things(_ ids: [String]) -> String {
        if ids.count == 1, let id = ids.first { return name(id) }
        return String(localized: "\(ids.count) Things", comment: "Meadow editor: several things, in a step's name (Move 3 Things)")
    }

    /// Why an edit was not made, as the badge by the pointer and VoiceOver say it.
    static func refusal(_ refusal: MeadowEditRefusal) -> String {
        switch refusal {
        case .outsideMeadow:
            String(localized: "Outside the meadow", comment: "Meadow editor: why a thing cannot stand there")
        case .keptForWorkspaces:
            String(localized: "Kept clear for your workspaces", comment: "Meadow editor: why a big thing cannot stand on the picnic ground")
        case .tooClose(let id):
            String(localized: "Too close to the \(name(id).lowercased())", comment: "Meadow editor: why a thing cannot stand there (the thing in the way)")
        case .full(.trees, let limit), .full(.tall, let limit):
            String(localized: "The meadow has as many trees as it can hold (\(limit))", comment: "Meadow editor: a cap reached")
        case .full(_, let limit):
            String(localized: "The meadow has as many things as it can hold (\(limit))", comment: "Meadow editor: a cap reached")
        case .noRoom:
            String(localized: "No room nearby", comment: "Meadow editor: copies found no free ground near")
        case .largest:
            String(localized: "As large as it grows", comment: "Meadow editor: a living thing cannot grow more")
        case .smallest:
            String(localized: "As small as it grows", comment: "Meadow editor: a living thing cannot shrink more")
        case .keepsItsSize:
            String(localized: "Only living things change size", comment: "Meadow editor: stones and made things keep their size")
        }
    }

    // Each step's name, as Edit › Undo and the top bar's Undo say it.
    static func move(_ ids: [String]) -> String { String(localized: "Move \(things(ids))", comment: "Meadow editor: a step's name") }
    static func turn(_ ids: [String]) -> String { String(localized: "Turn \(things(ids))", comment: "Meadow editor: a step's name") }
    static func resize(_ ids: [String]) -> String { String(localized: "Resize \(things(ids))", comment: "Meadow editor: a step's name") }
    static func duplicate(_ ids: [String]) -> String { String(localized: "Duplicate \(things(ids))", comment: "Meadow editor: a step's name") }
    static func delete(_ ids: [String]) -> String { String(localized: "Delete \(things(ids))", comment: "Meadow editor: a step's name") }
    static func cut(_ ids: [String]) -> String { String(localized: "Cut \(things(ids))", comment: "Meadow editor: a step's name") }
    static func paste(_ ids: [String]) -> String { String(localized: "Paste \(things(ids))", comment: "Meadow editor: a step's name") }
    static func shuffle(_ ids: [String]) -> String { String(localized: "Shuffle \(things(ids))", comment: "Meadow editor: a step's name") }

    /// Where a thing is, for VoiceOver: "12 units north-west of the picnic ground", or on it.
    static func whereIs(_ at: MeadowPoint) -> String {
        let g = (minX: -20.0, maxX: 20.0, minZ: -3.0, maxZ: 120.0)
        let dx = at.x < g.minX ? at.x - g.minX : at.x > g.maxX ? at.x - g.maxX : 0
        let dz = at.z < g.minZ ? at.z - g.minZ : at.z > g.maxZ ? at.z - g.maxZ : 0
        let far = Int(hypot(dx, dz).rounded())
        guard far > 0 else { return String(localized: "on the picnic ground", comment: "VoiceOver: where a thing stands in the meadow") }
        // North is away along the meadow (−z), east to the right (+x).
        let angle = atan2(dx, -dz) * 180 / .pi
        let names = [String(localized: "north", comment: "VoiceOver: a direction in the meadow"), String(localized: "north-east", comment: "VoiceOver: a direction in the meadow"),
                     String(localized: "east", comment: "VoiceOver: a direction in the meadow"), String(localized: "south-east", comment: "VoiceOver: a direction in the meadow"),
                     String(localized: "south", comment: "VoiceOver: a direction in the meadow"), String(localized: "south-west", comment: "VoiceOver: a direction in the meadow"),
                     String(localized: "west", comment: "VoiceOver: a direction in the meadow"), String(localized: "north-west", comment: "VoiceOver: a direction in the meadow")]
        let direction = names[(Int(((angle + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45)) % 8]
        return String(localized: "\(far) units \(direction) of the picnic ground", comment: "VoiceOver: how far and which way a thing stands from the picnic ground")
    }
}
