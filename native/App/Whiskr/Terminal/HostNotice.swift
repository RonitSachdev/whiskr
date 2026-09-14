import Foundation

/// Says, once at launch, that terminals started by another version of the app (or by it under its
/// earlier name) are still running where this version cannot show them, and, when some Claudes were
/// therefore not resumed, why. Nothing is stopped: an update never ends work in progress. It is a quiet
/// bar on Home (`HomePage`), never a dialog: nobody asked for it, and nothing needs deciding.
struct HostNotice: Equatable {
    /// Terminals the other version's session host holds.
    let terminals: Int
    /// Claudes not resumed here because they may still run there.
    let withheld: Int

    init?(terminals: Int, withheld: Int) {
        guard terminals > 0 else { return nil }
        self.terminals = terminals
        self.withheld = withheld
    }

    /// The bar's one line.
    var summary: String {
        var text = String(localized: "\(terminals) terminals from another version of Whiskr are still running.",
                          comment: "Home note at launch: how many terminals an incompatible session host holds")
        if withheld > 0 {
            text += " " + String(localized: "\(withheld) Claudes were not resumed here, so none runs twice.",
                                 comment: "Home note at launch: Claude conversations not resumed because the other version may still run them")
        }
        return text
    }

    /// What Details says.
    var details: String {
        String(localized: "This version cannot show them. They keep running until their programs end; open that version to see them again. Nothing was stopped.",
               comment: "Home note's details: terminals of another version")
    }
}
