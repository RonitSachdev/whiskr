import Foundation
import Testing
@testable import WhiskrKit

/// A theme's preview in Settings draws the theme as it will look once chosen: the version the app will be in
/// then (whatever the chosen theme holds the app in now), with the very colours the terminal and the window
/// get. Each colour is compared with the theme's own, read by hand from the version that applies, so a
/// preview that took the other version, a wrong index or another theme's colour fails here.
@Suite("Theme previews")
struct ThemePreviewTests {
    /// The version the app shows `theme` in on a Mac that is dark or not, read by hand: a theme with one
    /// version is always in it.
    static func applied(_ theme: Theme, macDark: Bool) -> ThemeVariant {
        switch (theme.light, theme.dark) {
        case (let light?, let dark?): macDark ? dark : light
        case (let light?, nil): light
        case (nil, let dark?): dark
        default: fatalError("a theme has a version")
        }
    }

    /// Every swatch and sample of `preview` against `variant`'s own colours.
    static func expectDraws(_ preview: ThemePreviewColors, _ variant: ThemeVariant, increasedContrast: Bool, _ what: String) {
        #expect(preview.isDark == variant.isDark, "\(what): the preview's version is \(preview.isDark ? "dark" : "light"), the theme's is not")
        #expect(preview.terminal.background == variant.terminal.background, "\(what): background")
        #expect(preview.terminal.foreground == variant.terminal.foreground, "\(what): text")
        #expect(preview.terminal.cursor == variant.terminal.cursor, "\(what): cursor")
        #expect(preview.terminal.selection == variant.terminal.selection, "\(what): selection")
        #expect(preview.terminal.ansi.count == 16, "\(what): sixteen colours")
        for index in 0..<16 {
            #expect(preview.terminal.ansi[index] == variant.terminal.ansi[index], "\(what): \(TerminalColors.ansiNames[index])")
        }
        // Black, white and their bright forms, where a mix-up shows most: in the rows the preview draws.
        #expect(preview.ansiRows[0][0] == variant.terminal.ansi[0] && preview.ansiRows[0][7] == variant.terminal.ansi[7], "\(what): black and white")
        #expect(preview.ansiRows[1][0] == variant.terminal.ansi[8] && preview.ansiRows[1][7] == variant.terminal.ansi[15], "\(what): bright black and bright white")
        // The window's colours, with Increase Contrast's steps written out.
        let raised: [AppColorKey: AppColorKey] = increasedContrast
            ? [.line: .textTertiary, .lineStrong: .textTertiary, .textSecondary: .text, .textTertiary: .textSecondary] : [:]
        for key in AppColorKey.allCases {
            #expect(preview[key] == variant.app[raised[key] ?? key], "\(what): \(key.rawValue)")
        }
    }

    @Test("every built-in theme's preview is the version and the colours it will have once chosen, on a light and a dark Mac")
    func builtIn() {
        for theme in BuiltInThemes.all {
            for macDark in [false, true] {
                for increasedContrast in [false, true] {
                    let preview = ThemePreviewColors(theme: theme, followedDark: macDark, increasedContrast: increasedContrast)
                    Self.expectDraws(preview, Self.applied(theme, macDark: macDark), increasedContrast: increasedContrast,
                                     "\(theme.name) on a \(macDark ? "dark" : "light") Mac\(increasedContrast ? ", Increase Contrast" : "")")
                    // The app is in the version the preview shows once the theme is chosen.
                    #expect(preview.isDark == theme.isDark(following: macDark))
                }
            }
        }
    }

    @Test("Nord, dark only, previews its own dark colours on a light Mac, black, white and their bright forms as published")
    func nord() {
        let nord = BuiltInThemes.theme(id: "nord")!
        let preview = ThemePreviewColors(theme: nord, followedDark: false)
        #expect(preview.isDark)
        #expect(preview.terminal.background == RGBColor(0x2e3440) && preview.terminal.foreground == RGBColor(0xd8dee9))
        #expect(preview.terminal.ansi[0] == RGBColor(0x3b4252) && preview.terminal.ansi[7] == RGBColor(0xe5e9f0))
        #expect(preview.terminal.ansi[8] == RGBColor(0x4c566a) && preview.terminal.ansi[15] == RGBColor(0xeceff4))
    }

    @Test("a theme with both versions previews the light one on a light Mac, whichever theme holds the app dark now")
    func bothVersions() {
        // The preview is made from the theme and the Mac's appearance only: Nord, chosen, holds the app dark,
        // yet choosing Whiskr on a light Mac makes it light, and its card shows that.
        let whiskr = BuiltInThemes.theme(id: BuiltInThemes.defaultID)!
        #expect(!ThemePreviewColors(theme: whiskr, followedDark: false).isDark)
        #expect(ThemePreviewColors(theme: whiskr, followedDark: false).terminal.background == RGBColor(0xfdfdfc))
        #expect(ThemePreviewColors(theme: whiskr, followedDark: true).terminal.background == RGBColor(0x161618))
    }

    @Test("imported themes preview the colours as imported, after the guarantees the import applies")
    func imported() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-theme-previews-\(UUID().uuidString)", isDirectory: true)
        let originals = folder.appendingPathComponent("Originals", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func write(_ name: String, _ text: String) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }
        // A VS Code theme whose text is too faint for its background (the import raises it), with its own
        // black and white.
        let faintFile = ##"{ "name": "Faint Night", "type": "dark", "colors": { "editor.background": "#20242c", "terminal.background": "#20242c", "terminal.foreground": "#3a404c", "terminal.ansiBlack": "#101318", "terminal.ansiWhite": "#c8ccd4", "terminal.ansiBrightBlack": "#5c6370", "terminal.ansiBrightWhite": "#ffffff" } }"##
        let faint = try #require(try ThemeImport.themes(at: write("faint-color-theme.json", faintFile), originals: originals).first)
        // An iTerm2 light scheme.
        var plist = #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>"#
        let ansi: [UInt32] = [0x000000, 0xc91b00, 0x00a600, 0xa0a000, 0x0225c7, 0xc930c7, 0x00a5b2, 0xc7c7c7,
                              0x686868, 0xff6e67, 0x5ffa68, 0xc0c000, 0x6871ff, 0xff77ff, 0x60fdff, 0xffffff]
        let entries = [("Background Color", UInt32(0xfafaf8)), ("Foreground Color", 0x2a2a2a)] + ansi.enumerated().map { ("Ansi \($0.offset) Color", $0.element) }
        for (key, value) in entries {
            let part = { (shift: UInt32) in Double((value >> shift) & 0xff) / 255 }
            plist += "<key>\(key)</key><dict><key>Red Component</key><real>\(part(16))</real><key>Green Component</key><real>\(part(8))</real><key>Blue Component</key><real>\(part(0))</real></dict>"
        }
        plist += "</dict></plist>"
        let paper = try #require(try ThemeImport.themes(at: write("Paper.itermcolors", plist), originals: originals).first)
        // VS Code's own Dark+ and Light+, from the fixtures (each a theme of one version).
        let fixtures = VSCodeThemeTests.fixtures
        var vsCode: [Theme] = []
        for name in ["dark_plus.json", "light_plus.json"] {
            let copy = folder.appendingPathComponent(name)
            for file in ["dark_plus.json", "dark_vs.json", "light_plus.json", "light_vs.json"] where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) {
                try FileManager.default.copyItem(at: fixtures.appendingPathComponent(file), to: folder.appendingPathComponent(file))
            }
            vsCode += try ThemeImport.themes(at: copy, originals: originals)
        }

        for theme in [faint, paper] + vsCode {
            for macDark in [false, true] {
                let variant = Self.applied(theme, macDark: macDark)
                Self.expectDraws(ThemePreviewColors(theme: theme, followedDark: macDark), variant, increasedContrast: false, "\(theme.name) on a \(macDark ? "dark" : "light") Mac")
                // What is previewed already meets the guarantees: the terminal is given the same.
                #expect(variant.meetingGuarantees().repairs.isEmpty, "\(theme.name): \(variant.meetingGuarantees().repairs)")
            }
        }
        // The faint text is previewed raised, as the terminal shows it; black and white as the file gives them.
        let night = ThemePreviewColors(theme: faint, followedDark: false)
        #expect(night.isDark && night.terminal.foreground != RGBColor(0x3a404c) && night.terminal.foreground.contrast(with: night.terminal.background) >= 4.5)
        #expect(night.terminal.ansi[0] == RGBColor(0x101318) && night.terminal.ansi[7] == RGBColor(0xc8ccd4))
        #expect(night.terminal.ansi[8] == RGBColor(0x5c6370) && night.terminal.ansi[15] == RGBColor(0xffffff))
        // The iTerm2 scheme, light only, previews light on a dark Mac.
        let light = ThemePreviewColors(theme: paper, followedDark: true)
        #expect(!light.isDark && light.terminal.background == RGBColor(0xfafaf8) && light.terminal.ansi[15] == RGBColor(0xffffff))
    }
}
