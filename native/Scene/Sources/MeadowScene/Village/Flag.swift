import AppKit
import CoreText

// Port of src/village/Flag.ts: a tab's name flag, the account's colour and a short name on a pill, raised
// above the back of its blanket. Part of the scene, not laid over it, so any cat nearer the camera is
// drawn in front of it. This half measures and fits the name; VillageDrawer paints it.
//
//   ( pin ●  shop-web  ⑂ fix-cart  lantern +5 )    pin (if pinned), colour dot, title, then the branch,
//                                                  quieter; after dark, a drawn lantern and how many more
//                                                  terminals there are than the blanket has room for

struct FlagLabel {
    static let scale: CGFloat = 3                    // canvas pixels per point, so it stays crisp when large
    static let tall: CGFloat = 28 * scale            // canvas height; the width follows the name
    static let shadow: CGFloat = 6 * scale           // room round the pill for its soft shadow
    /// The pill is drawn FLAG_PIXELS points tall on screen: screen points per canvas point.
    static let onScreen = CGFloat(FLAG_PIXELS) / 28
    /// Text reads as 11 pt on screen, as a sidebar's does.
    static let textSize: CGFloat = 11 / onScreen
    static let roomMost: Float = 300                 // the widest a pill gets on screen, in points, before it is cut short
    static let roomLeast: Float = 90
    /// Names longer than this many characters lose their middle; branches likewise.
    static let titleMost = 22
    static let detailMost = 18
    /// Fitting a narrow pill cuts the branch, then the title, down to this many characters before
    /// leaving the branch out altogether.
    static let fewest = 8
    static let fill = Float(tall / (tall + shadow * 2))
    static var font: CTFont { Paint.system(textSize * scale, weight: .semibold) }
    static var detailFont: CTFont { Paint.system(textSize * scale, weight: .regular) }

    // Where things sit along the pill, in canvas points from its left end.
    static let lead: CGFloat = 9                     // before the first mark
    static let pinWide: CGFloat = 8, pinGap: CGFloat = 4
    static let dotWide: CGFloat = 10, dotGap: CGFloat = 7
    static let branchGap: CGFloat = 8, glyphWide: CGFloat = 7, glyphGap: CGFloat = 3.5
    static let lanternGap: CGFloat = 8, lanternWide: CGFloat = 7, lanternTextGap: CGFloat = 2.5
    static let trail: CGFloat = 12.5                 // after the text

    struct Inputs: Equatable {
        var name = "", detail: String? = nil, pinned = false
        var color = MeadowColor(hex: 0x000000)
        var chosen = false, hollow = false, remote = false
        /// Lanterns with no room on the blanket (0 for none), and whether one of them failed.
        var more = 0, moreFailed = false
        var room: Float = roomMost
    }
    private(set) var inputs = Inputs()
    var name: String { inputs.name }
    var color: MeadowColor { inputs.color }
    var chosen: Bool { inputs.chosen }
    var hollow: Bool { inputs.hollow }
    var remote: Bool { inputs.remote }
    var pinned: Bool { inputs.pinned }
    var more: Int { inputs.more }
    var moreFailed: Bool { inputs.moreFailed }

    /// What is shown, cut to fit: the title, and the branch (nil when there is none or no room for it).
    private(set) var shown = ""
    private(set) var shownDetail: String?
    /// Left ends along the pill, in canvas pixels from the pill's left end.
    private(set) var dotX: CGFloat = 0, titleX: CGFloat = 0, glyphX: CGFloat = 0, detailX: CGFloat = 0
    private(set) var lanternX: CGFloat = 0, moreX: CGFloat = 0
    /// "+N" for the lanterns counted here, or nil.
    private(set) var shownMore: String?
    /// The pill's width over its height (without the shadow margin).
    private(set) var aspect: Float = 3
    /// Canvas size in pixels, shadow margin included.
    private(set) var canvas = (width: 1, height: 1)
    /// Bumped whenever the picture changes.
    private(set) var version = 0

    mutating func update(_ given: Inputs) {
        if version > 0 && given == inputs { return }
        inputs = given
        let S = Self.scale
        let bold = Self.font, regular = Self.detailFont
        func width(_ s: String, _ font: CTFont) -> CGFloat { Paint.width(Paint.line(s, font: font, color: CGColor(gray: 0, alpha: 1))) }
        let marks = Self.lead + (given.pinned ? Self.pinWide + Self.pinGap : 0) + Self.dotWide + Self.dotGap
        let branchMarks = (Self.branchGap + Self.glyphWide + Self.glyphGap) * S
        // The lantern count is never cut: the title and branch make room for it.
        let more = given.more > 0 ? "+\(given.more)" : nil
        let moreWide = more.map { (Self.lanternGap + Self.lanternWide + Self.lanternTextGap) * S + width($0, regular) } ?? 0
        // Room for the words: the pill's room on screen, in canvas pixels, less its marks and ends.
        let room = CGFloat(given.room) / Self.onScreen * S - (marks + Self.trail) * S - moreWide
        var title = Self.middle(given.name.isEmpty ? "Untitled" : given.name, Self.titleMost)
        var detail = given.detail.flatMap { $0.isEmpty ? nil : Self.middle($0, Self.detailMost) }
        func needed() -> CGFloat { width(title, bold) + (detail.map { branchMarks + width($0, regular) } ?? 0) }
        // A branch in folders ("feature/checkout") first gives up its folders, "…/checkout", so what is cut
        // short still reads as a word rather than "featur…out".
        var foldersDropped = false
        while needed() > room {
            if !foldersDropped, detail != nil, let full = given.detail, let slash = full.lastIndex(of: "/"), full.index(after: slash) < full.endIndex {
                foldersDropped = true
                detail = Self.middle("…" + full[slash...], Self.detailMost)
            } else if let d = detail, d.count > Self.fewest { detail = Self.middle(d, d.count - 1) }
            else if title.count > Self.fewest { title = Self.middle(title, title.count - 1) }
            else if detail != nil { detail = nil }
            else if title.count > 2 { title = Self.middle(title, title.count - 1) }
            else { break }
        }
        shown = title
        shownDetail = detail
        dotX = (Self.lead + (given.pinned ? Self.pinWide + Self.pinGap : 0)) * S
        titleX = marks * S
        glyphX = titleX + width(title, bold) + Self.branchGap * S
        detailX = glyphX + (Self.glyphWide + Self.glyphGap) * S
        shownMore = more
        lanternX = titleX + needed() + Self.lanternGap * S
        moreX = lanternX + (Self.lanternWide + Self.lanternTextGap) * S
        let wide = ceil(titleX + needed() + moreWide + Self.trail * S)
        canvas = (Int(wide + Self.shadow * 2), Int(Self.tall + Self.shadow * 2))
        aspect = Float(wide / Self.tall)
        version += 1
    }

    /// `text` cut to at most `most` characters by taking out its middle, so both ends still read:
    /// "the-meadow-cats-native-app" → "the-meadow-…native-app".
    static func middle(_ text: String, _ most: Int) -> String {
        guard text.count > most, most > 1 else { return text }
        let keep = most - 1
        let head = String(text.prefix((keep + 1) / 2)).trimmingCharacters(in: .whitespaces)
        let tail = String(text.suffix(keep / 2)).trimmingCharacters(in: .whitespaces)
        return head + "…" + tail
    }
}
