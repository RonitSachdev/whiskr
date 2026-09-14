import CoreGraphics
import Foundation

/// How a tab's panes are arranged: a pane, or a split of two arrangements side by side or one above
/// the other. Splitting a pane replaces it with a split holding it and the new pane.
public indirect enum PaneTree: Sendable, Equatable, Codable {
    case pane(UUID)
    case split(Split)

    public enum Axis: String, Sendable, Codable {
        /// Side by side: the first on the left.
        case horizontal
        /// One above the other: the first on top.
        case vertical
    }

    public struct Split: Sendable, Equatable, Codable {
        public var axis: Axis
        /// The first part's share of the space, between `PaneTree.minRatio` and `PaneTree.maxRatio`.
        public var ratio: Double
        public var first: PaneTree
        public var second: PaneTree

        public init(axis: Axis, ratio: Double, first: PaneTree, second: PaneTree) {
            self.axis = axis
            self.ratio = PaneTree.clamp(ratio)
            self.first = first
            self.second = second
        }
    }

    public enum Direction: Sendable, CaseIterable {
        case left, right, up, down
    }

    public static let minRatio = 0.05
    public static let maxRatio = 0.95

    static func clamp(_ ratio: Double) -> Double {
        ratio.isFinite ? min(max(ratio, minRatio), maxRatio) : 0.5
    }

    /// Every pane, in reading order (left to right, top to bottom).
    public var panes: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(let split): split.first.panes + split.second.panes
        }
    }

    public func contains(_ id: UUID) -> Bool { panes.contains(id) }

    /// This arrangement with `target` split in two, `new` placed after it (right of it or below it).
    public func splitting(_ target: UUID, axis: Axis, new: UUID) -> PaneTree {
        switch self {
        case .pane(let id):
            return id == target ? .split(Split(axis: axis, ratio: 0.5, first: self, second: .pane(new))) : self
        case .split(var split):
            split.first = split.first.splitting(target, axis: axis, new: new)
            split.second = split.second.splitting(target, axis: axis, new: new)
            return .split(split)
        }
    }

    /// This arrangement with `tree` (another tab's panes) put beside `target`, taking the half of it on
    /// `side`: a tab dragged to a pane's edge.
    public func inserting(_ tree: PaneTree, beside target: UUID, on side: Direction) -> PaneTree {
        switch self {
        case .pane(let id):
            guard id == target else { return self }
            let axis: Axis = side == .left || side == .right ? .horizontal : .vertical
            let before = side == .left || side == .up
            return .split(Split(axis: axis, ratio: 0.5, first: before ? tree : self, second: before ? self : tree))
        case .split(var split):
            split.first = split.first.inserting(tree, beside: target, on: side)
            split.second = split.second.inserting(tree, beside: target, on: side)
            return .split(split)
        }
    }

    /// Where a tab dropped at `point` in a pane's `frame` goes (VS Code's rule): within the outer tenth of
    /// a side, beside the pane on that side (the nearest side, when in a corner); nil in the middle,
    /// where it goes into the pane's tab instead. `frame` and `point` share a coordinate space whose y
    /// grows downward.
    public static func dropSide(at point: CGPoint, in frame: CGRect, edge: Double = 0.1) -> Direction? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let x = (point.x - frame.minX) / frame.width, y = (point.y - frame.minY) / frame.height
        let distances: [(Direction, Double)] = [(.left, x), (.right, 1 - x), (.up, y), (.down, 1 - y)]
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < edge else { return nil }
        return nearest.0
    }

    /// The part of a pane's `frame` a tab dropped on `side` will take (the whole of it for the middle).
    public static func dropPreview(_ side: Direction?, in frame: CGRect) -> CGRect {
        switch side {
        case .left?: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right?: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .up?: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .down?: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        case nil: frame
        }
    }

    /// This arrangement without `target`; its neighbour takes the space. nil when nothing is left.
    public func removing(_ target: UUID) -> PaneTree? {
        switch self {
        case .pane(let id):
            return id == target ? nil : self
        case .split(var split):
            let first = split.first.removing(target)
            let second = split.second.removing(target)
            guard let first else { return second }
            guard let second else { return first }
            split.first = first
            split.second = second
            return .split(split)
        }
    }

    /// This arrangement with two panes trading places.
    public func swapping(_ a: UUID, _ b: UUID) -> PaneTree {
        switch self {
        case .pane(let id):
            return id == a ? .pane(b) : id == b ? .pane(a) : self
        case .split(var split):
            split.first = split.first.swapping(a, b)
            split.second = split.second.swapping(a, b)
            return .split(split)
        }
    }

    /// This arrangement with one pane's place given to another (a page turning into a terminal).
    public func replacing(_ old: UUID, with new: UUID) -> PaneTree {
        switch self {
        case .pane(let id):
            return id == old ? .pane(new) : self
        case .split(var split):
            split.first = split.first.replacing(old, with: new)
            split.second = split.second.replacing(old, with: new)
            return .split(split)
        }
    }

    /// The least room the arrangement needs for every pane to get at least `pane`, with `gap` between
    /// neighbours. A tab given less shows only its focused pane.
    public func minimumSize(pane: CGSize, gap: CGFloat) -> CGSize {
        switch self {
        case .pane:
            return pane
        case .split(let split):
            let a = split.first.minimumSize(pane: pane, gap: gap)
            let b = split.second.minimumSize(pane: pane, gap: gap)
            switch split.axis {
            case .horizontal: return CGSize(width: a.width + gap + b.width, height: max(a.height, b.height))
            case .vertical: return CGSize(width: max(a.width, b.width), height: a.height + gap + b.height)
            }
        }
    }

    /// This arrangement with a new ratio for the split reached by following `path` from the top
    /// (0 = into the first part, 1 = into the second); the empty path is the top split itself.
    public func settingRatio(_ ratio: Double, at path: [Int]) -> PaneTree {
        guard case .split(var split) = self else { return self }
        guard let step = path.first else {
            split.ratio = Self.clamp(ratio)
            return .split(split)
        }
        if step == 0 {
            split.first = split.first.settingRatio(ratio, at: Array(path.dropFirst()))
        } else {
            split.second = split.second.settingRatio(ratio, at: Array(path.dropFirst()))
        }
        return .split(split)
    }

    /// Where each pane sits inside `rect`, from the ratios alone.
    public func frames(in rect: CGRect) -> [UUID: CGRect] {
        switch self {
        case .pane(let id):
            return [id: rect]
        case .split(let split):
            let (a, b): (CGRect, CGRect)
            switch split.axis {
            case .horizontal:
                let width = rect.width * split.ratio
                a = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
                b = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
            case .vertical:
                // Top-left origin: the first part is on top.
                let height = rect.height * split.ratio
                a = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
                b = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height)
            }
            return split.first.frames(in: a).merging(split.second.frames(in: b)) { first, _ in first }
        }
    }

    /// The pane next to `from` in `direction`: of the panes that lie that way and share some of its
    /// span, the nearest; among equally near ones, the one used most recently (`recency`, latest last).
    public func neighbor(of from: UUID, toward direction: Direction, recency: [UUID] = []) -> UUID? {
        let frames = frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let origin = frames[from] else { return nil }
        let epsilon = 1e-9
        let candidates = frames.compactMap { id, frame -> (UUID, CGFloat)? in
            guard id != from else { return nil }
            let distance: CGFloat
            let overlaps: Bool
            switch direction {
            case .left:
                distance = origin.minX - frame.maxX
                overlaps = frame.minY < origin.maxY - epsilon && frame.maxY > origin.minY + epsilon
            case .right:
                distance = frame.minX - origin.maxX
                overlaps = frame.minY < origin.maxY - epsilon && frame.maxY > origin.minY + epsilon
            case .up:
                distance = origin.minY - frame.maxY
                overlaps = frame.minX < origin.maxX - epsilon && frame.maxX > origin.minX + epsilon
            case .down:
                distance = frame.minY - origin.maxY
                overlaps = frame.minX < origin.maxX - epsilon && frame.maxX > origin.minX + epsilon
            }
            return overlaps && distance > -epsilon ? (id, distance) : nil
        }
        guard let nearest = candidates.map(\.1).min() else { return nil }
        // Among equally near panes: the most recently used, then the top-most, then the left-most.
        let rank = { (id: UUID) in -(recency.lastIndex(of: id) ?? -1) }
        return candidates.filter { $0.1 - nearest < epsilon }.map(\.0).min { a, b in
            (rank(a), frames[a]!.minY, frames[a]!.minX) < (rank(b), frames[b]!.minY, frames[b]!.minX)
        }
    }
}
