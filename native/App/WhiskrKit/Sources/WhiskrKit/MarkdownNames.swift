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
