import Foundation
import Synchronization

/// The scopes a token sits in, outermost first ("source.swift", "meta.function.swift",
/// "entity.name.function.swift"), as one small number. Every stack is kept once for the life of the app,
/// so tokens hold four bytes each, two stacks compare as numbers, and a theme works out a stack's style
/// once (`SyntaxTheme`) however many tokens and files share it: changing the theme recolours without
/// tokenising anything again.
public struct ScopeStack: Hashable, Sendable {
    public let id: UInt32

    init(id: UInt32) {
        self.id = id
    }

    /// A stack of one scope.
    public static func root(_ scope: String) -> ScopeStack {
        ScopeTable.shared.stack(parent: 0, scope: scope)
    }

    /// Scopes given outermost first.
    public init?(_ scopes: [String]) {
        guard let first = scopes.first else { return nil }
        var stack = ScopeStack.root(first)
        for scope in scopes.dropFirst() { stack = stack.pushing(scope) }
        self = stack
    }

    /// This stack with `scope` inside it.
    public func pushing(_ scope: String) -> ScopeStack {
        ScopeTable.shared.stack(parent: id, scope: scope)
    }

    /// The innermost scope.
    public var scope: String { ScopeTable.shared.entry(id).scope }

    /// The stack without its innermost scope; nil for a stack of one.
    public var parent: ScopeStack? {
        let parent = ScopeTable.shared.entry(id).parent
        return parent == 0 ? nil : ScopeStack(id: parent)
    }

    /// Every scope, outermost first.
    public var scopes: [String] {
        var result: [String] = []
        var stack: ScopeStack? = self
        while let current = stack {
            result.append(current.scope)
            stack = current.parent
        }
        return result.reversed()
    }
}

extension ScopeStack: CustomStringConvertible {
    public var description: String { scopes.joined(separator: " ") }
}

/// Every scope stack made so far. Stacks are only added, so an id stays valid for good; the table grows
/// with the distinct stacks grammars produce (thousands, not millions: names are fixed in grammars, but
/// for a few made from matched text).
final class ScopeTable: Sendable {
    static let shared = ScopeTable()

    struct Entry {
        var parent: UInt32
        var scope: String
    }

    private struct Key: Hashable {
        var parent: UInt32
        var scope: String
    }

    private struct Table {
        // Index 0 is "no stack", the parent of a root.
        var entries: [Entry] = [Entry(parent: 0, scope: "")]
        var ids: [Key: UInt32] = [:]
    }

    private let table = Mutex(Table())

    func stack(parent: UInt32, scope: String) -> ScopeStack {
        let key = Key(parent: parent, scope: scope)
        return table.withLock { table in
            if let id = table.ids[key] { return ScopeStack(id: id) }
            let id = UInt32(table.entries.count)
            table.entries.append(Entry(parent: parent, scope: scope))
            table.ids[key] = id
            return ScopeStack(id: id)
        }
    }

    func entry(_ id: UInt32) -> Entry {
        table.withLock { $0.entries[Int(id)] }
    }

    var count: Int { table.withLock { $0.entries.count } }
}
