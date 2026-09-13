import Foundation

/// GitHub's heading anchors, so a link to "#getting-started" scrolls the preview to its heading:
/// the heading's text (its Markdown read), lowercased, punctuation dropped, spaces as hyphens.
public enum MarkdownSlug {
    public static func make(_ text: String) -> String {
        let plain = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? text
        return String(plain.lowercased().compactMap { character -> Character? in
            if character.isLetter || character.isNumber || character == "-" || character == "_" { return character }
            return character == " " ? "-" : nil
        })
    }
}

extension SyntaxLanguage {
    /// A code fence's info string ("swift", "ts", "sh", "py") as a language.
    public static func named(_ name: String?) -> SyntaxLanguage {
        guard let name = name?.lowercased(), !name.isEmpty else { return .plain }
        if let exact = SyntaxLanguage(rawValue: name) { return exact }
        let aliases: [String: SyntaxLanguage] = ["ts": .typescript, "tsx": .typescript, "js": .javascript, "jsx": .javascript, "py": .python,
                                                  "sh": .shell, "bash": .shell, "zsh": .shell, "console": .shell, "rs": .rust, "golang": .go,
                                                  "c++": .cpp, "objc": .cpp, "kt": .kotlin, "rb": .ruby, "yml": .yaml, "md": .markdown, "docker": .dockerfile,
                                                  "htm": .html, "jsonc": .json, "scss": .css, "less": .css]
        return aliases[name] ?? SyntaxLanguage.detect(fileName: "file.\(name)", firstLine: nil)
    }
}
