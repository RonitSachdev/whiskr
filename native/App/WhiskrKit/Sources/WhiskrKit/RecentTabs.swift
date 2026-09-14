import Foundation

/// ⌃Tab's order (as VS Code and Safari keep it): a workspace's tabs, the one shown first, then the others
/// from the most recently shown; tabs never shown since launch come last, in the row's order. A tap of
/// ⌃Tab goes to the second; each further Tab while ⌃ is held steps on, ⇧Tab back, wrapping round.
public enum RecentTabs {
    /// `tabs` (in the row's order) by how recently each was shown, newest first; `visited` is newest first
    /// and may hold tabs of other workspaces or tabs since closed.
    public static func order<ID: Hashable>(_ tabs: [ID], visited: [ID], shown: ID?) -> [ID] {
        let present = Set(tabs)
        var seen = Set<ID>()
        var order: [ID] = []
        for id in (shown.map { [$0] } ?? []) + visited + tabs where present.contains(id) && !seen.contains(id) {
            seen.insert(id)
            order.append(id)
        }
        return order
    }

    /// The place `steps` on from `index` in a list of `count`, wrapping round both ways.
    public static func step(_ index: Int, by steps: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + steps) % count + count) % count
    }
}
