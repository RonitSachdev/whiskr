import AppKit
import SwiftUI
import WhiskrKit

/// Help's pages on making the meadow yours (docs/DESIGN.md, "Editing the meadow" and "My Meadows"): what the
/// editor is, its tools with their keys, placing, fences, colours, lamps, what cats do with what is placed, My
/// Meadows and meadow files (from newer Whiskrs too), the limits, and every key of the editor, read from
/// `KeyTable` so the table can never fall behind the keys.
struct HelpMeadowEditorSections: View {
    var body: some View {
        HelpSection(title: HelpTopic.editing.title) {
            Text(String(localized: "The meadow's trees, flowers, stones, paths and garden are yours to arrange. View › Edit Meadow (⌃⌘E), Edit Meadow… in the grass's right-click menu or in Settings › Meadow opens the editor: the terminals step aside, the meadow fills the window, and the tray of tools and things rises along its bottom edge. Every change is saved as you make it; Done (⌘↩) or Esc brings everything back as it was. Terminals, Claudes and alerts carry on meanwhile.",
                        comment: "Help page: what editing the meadow is"))
            HelpKey(keys: "V", text: String(localized: "Select: click a thing to choose it, ⇧-click to add, drag on the grass to choose what is inside. Drag to move (⌥-drag copies). The bar under what is chosen turns, sizes, colours, duplicates and deletes.", comment: "Help page: the Select tool"))
            HelpKey(keys: "B", text: String(localized: "Brush: drag to plant clumps of wildflowers, ferns, clover or mushrooms; ⌥-drag clears them.", comment: "Help page: the Brush"))
            HelpKey(keys: "E", text: String(localized: "Erase: click a thing to take it away; drag to sweep plants and stones (never a tree or anything placed with care).", comment: "Help page: the Eraser"))
            HelpKey(keys: "G", text: String(localized: "Ground: paint paths, lawn and soil. Wild Grass, or ⌥-drag, brings the long grass back.", comment: "Help page: the Ground tool"))
            Text(String(localized: "⌘Z undoes each step, named in Edit › Undo (“Undo Move Oak”). Without a pointer: Tab reaches the tray's shelf, the arrows move a cursor on the ground, and Return places or chooses there.",
                        comment: "Help page: undo and the keyboard in the editor"))
        }
        HelpSection(title: HelpTopic.placing.title) {
            Text(String(localized: "Choose a thing on the tray's shelf and click where it should stand: ⇧-click places more, R turns it, Esc puts it back. A tile can also be dragged onto the meadow, or double-clicked to place it near the middle. Where a thing may not stand, its ring is dashed and the reason shows by the pointer. Trees, sheds, tents, fences and lamps are kept clear of the picnic ground where your workspaces' blankets lie.",
                        comment: "Help page: placing things"))
            Text(String(localized: "Fences are laid in runs: drag to lay one, a post every few steps; ⌥-drag lays it straight, and an end near another fence's joins it. Choose a fence to straighten it or to hang a gate, which cats walk through. Stepping stones dragged are laid in a row, a stride apart.",
                        comment: "Help page: fences and stepping stones"))
            Text(String(localized: "Benches, cushions, pots, the shed's door and other made things come in a few colours: choose one, then Colour (C) in its bar. The next one you place wears the colour chosen last.",
                        comment: "Help page: colours of made things"))
            Text(String(localized: "Garden lamps light at dusk and go out after sunrise. Settings › Meadow can keep them dark.", comment: "Help page: garden lamps"))
            Text(String(localized: "Idle cats use what you place: they nap in beds, boxes and on cushions, sit on stumps, benches and the desk, scratch the post, keep to paths and stepping stones, and pass fences by their gates.",
                        comment: "Help page: what cats do with the meadow's things"))
        }
        HelpSection(title: HelpTopic.meadows.title) {
            Text(String(localized: "My Meadows, in Settings › Meadow and the editor's name menu, holds the Default (built in, it never changes) and your own: the first change you make copies the Default as “My Meadow”. Click a card's picture to show that meadow; its ⋯ menu renames, duplicates, exports, shares and moves it to the Trash. New Meadow starts from the Default or from empty grass.",
                        comment: "Help page: My Meadows"))
            Text(String(localized: "Meadows are .whiskrmeadow files, plain data you can share: Export… or Share… sends one, Export Picture… saves its picture. Open a file someone sent (double-click it, drop it on the meadow or on My Meadows, or File › Import Meadow…) and a sheet shows it first; adding never replaces a meadow you have.",
                        comment: "Help page: sharing and importing meadow files"))
            Text(String(localized: "A meadow made with a newer Whiskr opens as far as this one can: things it cannot draw are kept whole and show as parcels while editing, which you can move or take away, and come back as they were once Whiskr is updated. A file too new to read says so and asks you to update.",
                        comment: "Help page: files from newer versions"))
            Text(String(localized: "A meadow holds up to 5,000 things: 48 trees, 120 tall things and 32 garden lamps among them. The tray says how full it is once it is nearly full, and what cannot be added says why.",
                        comment: "Help page: the meadow's limits"))
        }
        HelpSection(title: HelpTopic.editorKeys.title) {
            ForEach(HelpEditorKeys.rows, id: \.text) { row in
                HelpKey(keys: row.keys, text: row.text, width: 112)
            }
        }
    }
}

/// The editor's keys, as Help lists them: every key `KeyTable` gives the meadow's editor and its tray's shelf, and the
/// Edit and View menus' keys it uses, in the table's order, keys that do the same thing on one line ("← → ↑ ↓").
enum HelpEditorKeys {
    struct Row {
        var keys: String
        var text: String
    }

    /// The menus' commands the editor uses, as Help says them.
    private static let menuCommands: [String: String] = [
        "toggleMeadowEditing:": String(localized: "Edit the meadow, or stop", comment: "Help page: a key of the meadow editor"),
        "toggleEditorTray:": String(localized: "Fold or unfold the tray", comment: "Help page: a key of the meadow editor"),
        "undo:": String(localized: "Undo the last step", comment: "Help page: a key of the meadow editor"),
        "redo:": String(localized: "Redo it", comment: "Help page: a key of the meadow editor"),
        "selectAll:": String(localized: "Choose everything", comment: "Help page: a key of the meadow editor"),
        "copy:": String(localized: "Copy the chosen things", comment: "Help page: a key of the meadow editor"),
        "cut:": String(localized: "Cut the chosen things", comment: "Help page: a key of the meadow editor"),
        "paste:": String(localized: "Paste at the pointer", comment: "Help page: a key of the meadow editor"),
    ]

    /// What each of the editor's own keys does, as Help says it (by `KeyBinding.command`).
    static func text(_ command: String) -> String? {
        if command.hasPrefix("the tray's category ") {
            return String(localized: "A shelf of the tray, in its order", comment: "Help page: a key of the meadow editor (1–7)")
        }
        return switch command {
        case "the Select tool": String(localized: "The Select tool", comment: "Help page: a key of the meadow editor")
        case "the Brush": String(localized: "The Brush", comment: "Help page: a key of the meadow editor")
        case "the Eraser": String(localized: "The Eraser", comment: "Help page: a key of the meadow editor")
        case "the Ground tool": String(localized: "The Ground tool", comment: "Help page: a key of the meadow editor")
        case "the chosen things' colours, in the selection's bar": String(localized: "Show the chosen things' colours", comment: "Help page: a key of the meadow editor")
        case "turn the chosen things, or the thing to place, 15° clockwise": String(localized: "Turn 15° clockwise (⌥: 1°)", comment: "Help page: a key of the meadow editor")
        case "turn the chosen things, or the thing to place, 15° anticlockwise": String(localized: "Turn 15° anticlockwise (⌥: 1°)", comment: "Help page: a key of the meadow editor")
        case "turn the chosen things, or the thing to place, 1° clockwise", "turn the chosen things, or the thing to place, 1° anticlockwise": ""
        case "grow the chosen things, the next thing round the cursor, or a larger Brush, Eraser or Ground brush":
            String(localized: "Larger; with nothing chosen, the next thing round the cursor", comment: "Help page: a key of the meadow editor")
        case "shrink the chosen things, the thing before round the cursor, or a smaller Brush, Eraser or Ground brush":
            String(localized: "Smaller; with nothing chosen, the thing before", comment: "Help page: a key of the meadow editor")
        case "nudge the chosen things, or move the cursor (and the thing to place)":
            String(localized: "Nudge the chosen things, or move the cursor", comment: "Help page: a key of the meadow editor")
        case "nudge further": String(localized: "Nudge further", comment: "Help page: a key of the meadow editor")
        case "place the thing at the cursor, a dab of the Brush, the Eraser or the Ground tool there, or choose the thing nearest it":
            String(localized: "Place, brush, erase or paint at the cursor, or choose the thing nearest it", comment: "Help page: a key of the meadow editor")
        case "delete the chosen things": String(localized: "Delete the chosen things", comment: "Help page: a key of the meadow editor")
        case "step back: the gesture, the thing to place, the Brush, Eraser or Ground tool, the choice, then editing":
            String(localized: "Step back: the drag, the thing to place, the tool, the choice, then editing", comment: "Help page: a key of the meadow editor")
        case "turn the view 45° left": String(localized: "Turn the view 45° left", comment: "Help page: a key of the meadow editor")
        case "turn the view 45° right": String(localized: "Turn the view 45° right", comment: "Help page: a key of the meadow editor")
        case "frame the picnic ground again": String(localized: "Frame the picnic ground again", comment: "Help page: a key of the meadow editor")
        case "held: a drag slides the view": String(localized: "Held: a drag slides the view", comment: "Help page: a key of the meadow editor")
        case "to the selection's bar, or the tray's shelf": String(localized: "To the selection's bar, or the tray's shelf", comment: "Help page: a key of the meadow editor")
        case "to the tray's shelf": String(localized: "To the tray's shelf", comment: "Help page: a key of the meadow editor")
        case "duplicate the chosen things": String(localized: "Duplicate the chosen things", comment: "Help page: a key of the meadow editor")
        case "the tray's filter field": String(localized: "Find a thing on the shelf by name", comment: "Help page: a key of the meadow editor")
        case "the thing before": String(localized: "On the shelf: the thing before", comment: "Help page: a key of the meadow editor's shelf")
        case "the next thing": String(localized: "On the shelf: the next thing", comment: "Help page: a key of the meadow editor's shelf")
        case "choose it (a thing to place waits at the cursor)": String(localized: "On the shelf: choose it", comment: "Help page: a key of the meadow editor's shelf")
        case "back to the meadow": String(localized: "On the shelf: back to the meadow", comment: "Help page: a key of the meadow editor's shelf")
        case "done editing": String(localized: "Done", comment: "Help page: a key of the meadow editor")
        default: nil
        }
    }

    /// The editor's bindings with no words for Help (a key added to `KeyTable` and not yet here): the editor flow
    /// checks there are none.
    static var unsaid: [KeyBinding] {
        bindings.filter { text($0.command) == nil && menuCommands[$0.command] == nil }
    }

    private static var bindings: [KeyBinding] {
        KeyTable.bindings.filter { [.meadowEditor, .editorTray].contains($0.context) || ($0.context == .menu && menuCommands[$0.command] != nil) }
    }

    static var rows: [Row] {
        var rows: [Row] = []
        for binding in bindings {
            let text = menuCommands[binding.command] ?? text(binding.command) ?? binding.command
            guard !text.isEmpty else { continue }
            if let at = rows.firstIndex(where: { $0.text == text }) {
                rows[at].keys += " " + binding.chord.description
            } else {
                rows.append(Row(keys: binding.chord.description, text: text))
            }
        }
        return rows
    }
}

/// Help's topics, as its sections title them and the Help menu's search finds them.
nonisolated enum HelpTopic: String, CaseIterable {
    case editing, placing, meadows, editorKeys

    var title: String {
        switch self {
        case .editing: String(localized: "Making the meadow yours", comment: "Help page heading: editing the meadow")
        case .placing: String(localized: "Placing, fences, colours and lamps", comment: "Help page heading")
        case .meadows: String(localized: "My Meadows and meadow files", comment: "Help page heading")
        case .editorKeys: String(localized: "Keys while editing the meadow", comment: "Help page heading")
        }
    }

    /// Other words the Help menu's search finds the topic by.
    var words: String {
        switch self {
        case .editing: String(localized: "edit meadow, tools, select, brush, erase, eraser, ground, path, lawn, soil, undo", comment: "Help search: words for the topic on editing the meadow, comma-separated")
        case .placing: String(localized: "place, tree, flower, fence, gate, stepping stones, colour, color, lamp, light, night, cats", comment: "Help search: words for the topic on placing things, comma-separated")
        case .meadows: String(localized: "my meadows, file, share, export, import, picture, newer, parcel, update, limits, default", comment: "Help search: words for the topic on My Meadows, comma-separated")
        case .editorKeys: String(localized: "keys, keyboard, shortcuts", comment: "Help search: words for the topic listing the editor's keys, comma-separated")
        }
    }
}

/// The Help menu's search field finds Help's meadow topics, as it finds menu items: a found topic opens Whiskr Help
/// at it (`NSUserInterfaceItemSearching`).
@MainActor final class HelpSearch: NSObject, NSUserInterfaceItemSearching {
    static let shared = HelpSearch()

    nonisolated func searchForItems(withSearch searchString: String, resultLimit: Int, matchedItemHandler handleMatchedItems: @escaping ([Any]) -> Void) {
        let words = searchString.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let found = words.isEmpty ? [] : HelpTopic.allCases.filter { topic in
            words.allSatisfy { topic.title.localizedStandardContains($0) || topic.words.localizedStandardContains($0) }
        }
        handleMatchedItems(Array(found.prefix(resultLimit).map(\.rawValue)))
    }

    nonisolated func localizedTitles(forItem item: Any) -> [String] {
        (item as? String).flatMap(HelpTopic.init(rawValue:)).map { [$0.title] } ?? []
    }

    nonisolated func performAction(forItem item: Any) {
        guard let topic = (item as? String).flatMap(HelpTopic.init(rawValue:)) else { return }
        MainActor.assumeIsolated { HelpWindowController.shared.show(topic) }
    }

    nonisolated func showAllHelpTopics(forSearch searchString: String) {
        MainActor.assumeIsolated { HelpWindowController.shared.showHelp(nil) }
    }
}
