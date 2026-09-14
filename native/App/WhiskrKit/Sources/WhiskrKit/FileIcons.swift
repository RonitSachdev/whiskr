import Foundation

/// File icons by name, as VS Code gives them: Seti's icons, VS Code's default file icon theme, taken as data
/// (`FileIcons/seti.json` and the font `FileIcons/seti.woff`, rebuilt by `Scripts/update-file-icons.py`). The
/// app draws the glyphs in the theme's text colour; Seti's own colours are left out, as colour in the chrome
/// means state.
///
/// Which icon a file gets follows VS Code's file icon themes (`getIconClasses.ts` and the selectors
/// `fileIconThemeData.ts` writes, whose CSS specificity decides; the order is ported here): the file's whole
/// name, then its extensions longest first (`a.test.ts` tries `test.ts`, then `ts`), then its language, then
/// the plain file icon. Names compare lower-cased. Everything after the first dot is an extension, so
/// `.gitignore` has the extension `gitignore`. Theme keys naming a parent folder (`src/index.ts`) are not
/// supported: Seti has none.
public struct FileIconTheme: Sendable {
    /// One of the theme's icons: its name in the theme ("swift", "c") and the character that draws it in
    /// the theme's font.
    public struct Icon: Hashable, Sendable {
        public let name: String
        public let character: Character
    }

    /// Icons by name.
    let icons: [String: Icon]
    /// Lower-cased file names, extensions without their leading dot, and VS Code language ids, each naming an
    /// icon.
    let fileNames: [String: String]
    let fileExtensions: [String: String]
    let languageIDs: [String: String]
    /// A file nothing else matches.
    let file: Icon

    /// The Seti theme bundled with the Kit.
    public static let seti: FileIconTheme = {
        do {
            return try FileIconTheme(data: Data(contentsOf: resource("seti.json")))
        } catch {
            preconditionFailure("The bundled file icons do not load: \(error)")
        }
    }()

    /// The font Seti's icons are drawn from (WOFF, which Core Text reads as it is).
    public static let setiFont: URL = resource("seti.woff")

    private static func resource(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "FileIcons") else {
            preconditionFailure("FileIcons/\(name) is missing from the Kit's resources")
        }
        return url
    }

    /// Reads a theme in the shape `Scripts/update-file-icons.py` writes: `icons` (name → the glyph's
    /// character as hexadecimal), `fileNames`, `fileExtensions` and `languageIds` (key → icon name), and `file`.
    public init(data: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: data)
        var icons: [String: Icon] = [:]
        for (name, hex) in document.icons {
            guard let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else {
                throw LoadError.badCharacter(icon: name, hex)
            }
            icons[name] = Icon(name: name, character: Character(scalar))
        }
        for name in [document.file] + document.fileNames.values + document.fileExtensions.values + document.languageIds.values where icons[name] == nil {
            throw LoadError.unknownIcon(name)
        }
        self.icons = icons
        file = icons[document.file]!
        fileNames = document.fileNames
        fileExtensions = document.fileExtensions
        languageIDs = document.languageIds
    }

    /// The icon of a file called `fileName` (a name, not a path), in the language `languageID` (a VS Code
    /// language id, such as "typescript"), when known.
    public func icon(forFileName fileName: String, languageID: String? = nil) -> Icon {
        let name = fileName.lowercased()
        if let icon = fileNames[name] { return icons[icon]! }
        // VS Code stops combining extensions past 255 characters, which no file system allows anyway.
        if name.utf16.count <= 255 {
            var rest = name[...]
            while let dot = rest.firstIndex(of: ".") {
                rest = rest[rest.index(after: dot)...]
                if let icon = fileExtensions[String(rest)] { return icons[icon]! }
            }
        }
        if let languageID, let icon = languageIDs[languageID] { return icons[icon]! }
        return file
    }

    public enum LoadError: Error, Equatable {
        case badCharacter(icon: String, String)
        case unknownIcon(String)
    }

    private struct Document: Decodable {
        let file: String
        let icons: [String: String]
        let fileNames: [String: String]
        let fileExtensions: [String: String]
        let languageIds: [String: String]
    }
}
