import Foundation
import SwiftTerm

/// SwiftTerm 1.99.1 keeps a view's `Terminal` and its `SelectionService` internal, though both are public
/// types with public methods: the command marks (`semanticRowKind`), the buffer's lines and setting a
/// selection are all there, but the view offers no way to them. This finds the two stored properties by
/// reflection, once per terminal, so command jumps, selecting a command's output and the word under a
/// right click can use SwiftTerm's own state rather than a copy of their own.
///
/// Kept to this one type on purpose. Should a SwiftTerm update rename the properties, nothing is found:
/// the features that need them turn off (their menu items dim) and nothing else changes. Everything read
/// or set through it is done while holding the terminal's lock, as SwiftTerm itself does.
@MainActor
struct TerminalReach {
    let terminal: Terminal
    let selection: SelectionService

    init?(_ view: TerminalView) {
        var terminal: Terminal?
        var selection: SelectionService?
        var mirror: Mirror? = Mirror(reflecting: view)
        while let current = mirror, terminal == nil || selection == nil {
            for child in current.children {
                switch child.label {
                case "terminal": terminal = terminal ?? child.value as? Terminal
                case "selection": selection = selection ?? child.value as? SelectionService
                default: break
                }
            }
            mirror = current.superclassMirror
        }
        guard let terminal, let selection else { return nil }
        self.terminal = terminal
        self.selection = selection
    }

    /// Runs `body` holding the terminal's lock.
    func locked<T>(_ body: (Terminal, SelectionService) -> T) -> T {
        terminal.terminalLock.withLock { body(terminal, selection) }
    }
}

extension TerminalSurface {
    /// SwiftTerm's terminal and selection (`TerminalReach`), found the first time they are asked for.
    var reach: TerminalReach? {
        if let cached = reachCache { return cached }
        let found = TerminalReach(self)
        reachCache = .some(found)
        return found
    }
}
