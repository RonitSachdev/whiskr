import AppKit
import SwiftUI
import WhiskrKit

/// A Markdown file drawn as it reads (no web view): headings, paragraphs, lists and task lists, tables,
/// code in the editor's colours, quotes, rules and pictures beside the file. It follows the text as you
/// type or as Claude writes it, and beside the editor it keeps to the editor's scroll.
struct MarkdownPreview: View {
    let document: FileDocument
    /// The editor's first visible line, when the preview sits beside it.
    var followLine: Int?
    var openLink: (URL) -> Void

    @State private var parsed = MarkdownDocument(blocks: [])
    @State private var parsedVersion = -1

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(parsed.blocks.enumerated()), id: \.offset) { index, block in
                        MarkdownBlockView(block: block, base: document.url.deletingLastPathComponent(), first: index == 0)
                            .id(block.lines.lowerBound)
                    }
                }
                .frame(maxWidth: 780, alignment: .leading)
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
            }
            .onChange(of: followLine) { _, line in
                guard let line, let target = parsed.blocks.last(where: { $0.lines.lowerBound <= line })?.lines.lowerBound else { return }
                reader.scrollTo(target, anchor: .top)
            }
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == nil || url.isFileURL, let fragment = url.fragment, url.path.isEmpty || url.path == document.url.path {
                    if let heading = parsed.blocks.first(where: { block in
                        if case .heading(_, let text) = block.kind { return MarkdownSlug.make(text) == fragment.lowercased() }
                        return false
                    }) { withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(heading.lines.lowerBound, anchor: .top) } }
                    return .handled
                }
                openLink(url)
                return .handled
            })
        }
        .background(Color(nsColor: Colors.terminalBackground))
        .task(id: document.version) {
            // Typing is gathered for a moment; the parse runs off the main thread.
            if parsedVersion >= 0 { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            let text = document.storage.string
            let version = document.version
            let result = await Task.detached(priority: .userInitiated) { MarkdownDocument.parse(text) }.value
            guard !Task.isCancelled else { return }
            parsed = result
            parsedVersion = version
        }
        .accessibilityLabel(String(localized: "Preview of \(document.name)", comment: "Accessibility: the Markdown preview"))
    }
}

/// One block, and the blocks inside it.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let base: URL
    var first = false

    var body: some View {
        content
            .padding(.top, first ? 0 : topSpace)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var topSpace: CGFloat {
        switch block.kind {
        case .heading(let level, _): level <= 2 ? 26 : 20
        case .rule: 18
        default: 12
        }
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 8) {
                Text(MarkdownInline.render(text, size: Self.headingSize(level)))
                    .font(.system(size: Self.headingSize(level), weight: level <= 2 ? .semibold : .semibold))
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                if level <= 2 { Color.line.frame(height: 1) }
            }
        case .paragraph(let text):
            MarkdownParagraph(text: text, base: base)
        case .list(let list):
            MarkdownListView(list: list, base: base)
        case .code(let language, let code):
            MarkdownCode(language: language, code: code)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.lineStrong).frame(width: 3)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, inner in
                        MarkdownBlockView(block: inner, base: base, first: index == 0)
                    }
                }
                .foregroundStyle(Color.ink2)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Color.lineStrong.frame(height: 1).padding(.vertical, 4)
        case .html(let html):
            MarkdownHTMLView(html: html, base: base)
        case .frontMatter(let yaml):
            MarkdownCode(language: "yaml", code: yaml)
        }
    }

    static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 26
        case 2: 21
        case 3: 17
        case 4: 15
        default: 13.5
        }
    }
}

/// Inline Markdown (emphasis, code, links, strikethrough) through Foundation, in the preview's colours.
enum MarkdownInline {
    static let bodySize: CGFloat = 14

    /// Soft line breaks read as spaces, as GitHub shows them; a line ending in two spaces or "\" breaks.
    static func joined(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var result = ""
        for (index, line) in lines.enumerated() {
            if index == lines.count - 1 {
                result += line
            } else if line.hasSuffix("  ") || line.hasSuffix("\\") {
                result += line.trimmingCharacters(in: CharacterSet(charactersIn: " \\")) + "\n"
            } else {
                result += line + " "
            }
        }
        return result
    }

    static func render(_ text: String, size: CGFloat = bodySize) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        var string = (try? AttributedString(markdown: joined(text), options: options)) ?? AttributedString(text)
        for run in string.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                string[run.range].font = .system(size: size * 0.9, design: .monospaced)
                string[run.range].backgroundColor = Color.well
            }
            if run.link != nil {
                string[run.range].foregroundColor = Color.accent
            }
        }
        return string
    }

    /// The pictures a paragraph holds (`![alt](src)`), in order.
    static func images(in text: String) -> [(source: String, alt: String)] {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let string = try? AttributedString(markdown: text, options: options) else { return [] }
        return string.runs.compactMap { run in run.imageURL.map { ($0.relativeString, String(string[run.range].characters)) } }
    }

    /// Whether a paragraph is nothing but pictures (and the links round them, as badges are).
    static func onlyImages(_ text: String) -> Bool {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let string = try? AttributedString(markdown: text, options: options) else { return false }
        var any = false
        for run in string.runs {
            if run.imageURL != nil { any = true; continue }
            if !String(string[run.range].characters).allSatisfy(\.isWhitespace) { return false }
        }
        return any
    }
}

private struct MarkdownParagraph: View {
    let text: String
    let base: URL

    var body: some View {
        if MarkdownInline.onlyImages(text) {
            FlowLayout(spacing: 6) {
                ForEach(Array(MarkdownInline.images(in: text).enumerated()), id: \.offset) { _, image in
                    MarkdownImage(source: image.source, alt: image.alt, base: base, width: nil)
                }
            }
        } else {
            Text(MarkdownInline.render(text))
                .font(.system(size: MarkdownInline.bodySize))
                .lineSpacing(3.5)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MarkdownListView: View {
    let list: MarkdownList
    let base: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(index: index, item: item)
                        .frame(minWidth: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(item.blocks.enumerated()), id: \.offset) { blockIndex, inner in
                            MarkdownBlockView(block: inner, base: base, first: blockIndex == 0)
                        }
                    }
                    .opacity(item.task == true ? 0.6 : 1)
                }
            }
        }
        .padding(.leading, 4)
    }

    @ViewBuilder private func marker(index: Int, item: MarkdownListItem) -> some View {
        if let done = item.task {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(done ? Color.accent : Color.ink3)
                .accessibilityLabel(done ? String(localized: "Done") : String(localized: "To do"))
        } else if list.ordered {
            Text(verbatim: "\(list.start + index).")
                .font(.system(size: MarkdownInline.bodySize).monospacedDigit())
                .foregroundStyle(Color.ink2)
        } else {
            Text(verbatim: "•")
                .font(.system(size: MarkdownInline.bodySize, weight: .bold))
                .foregroundStyle(Color.ink3)
        }
    }
}

/// A fenced code block in the editor's colours, its language in the corner; long lines scroll sideways.
private struct MarkdownCode: View {
    let language: String?
    let code: String
    /// The code's tokens, worked out off the main thread; plain until they come.
    @State private var tokens: SyntaxText.Tokens?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(tokens.map(SyntaxText.attributed) ?? AttributedString(code))
                .font(SyntaxText.font)
                .lineSpacing(3)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.well))
        .task(id: SyntaxText.Request(code: code, language: language)) {
            tokens = await SyntaxText.tokens(code, fence: language)
        }
        .overlay(alignment: .topTrailing) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.ink3)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
            }
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                        self.cell(cell, column: column).font(.system(size: 13, weight: .semibold))
                    }
                }
                .background(Look.Fill.hover)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                            self.cell(cell, column: column).font(.system(size: 13))
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.line))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .fixedSize()
        }
    }

    private func cell(_ text: String, column: Int) -> some View {
        let alignment: Alignment = switch table.alignments.indices.contains(column) ? table.alignments[column] : .none {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
        return Text(MarkdownInline.render(text, size: 13))
            .foregroundStyle(Color.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minWidth: 60, maxWidth: 420, alignment: alignment)
            .gridColumnAlignment(alignment.horizontal)
    }
}

/// An HTML block: its pictures (a README's centred logo) and its text.
private struct MarkdownHTMLView: View {
    let html: String
    let base: URL

    var body: some View {
        let images = MarkdownHTML.images(in: html)
        let text = MarkdownHTML.text(in: html)
        VStack(alignment: html.contains("center") ? .center : .leading, spacing: 8) {
            if !images.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        MarkdownImage(source: image.source, alt: image.alt ?? "", base: base, width: image.width)
                    }
                }
            }
            if !text.isEmpty {
                Text(text).font(.system(size: MarkdownInline.bodySize)).foregroundStyle(Color.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: html.contains("center") ? .center : .leading)
    }
}

/// A picture: a file beside the Markdown (read once and kept), or from the web.
private struct MarkdownImage: View {
    let source: String
    let alt: String
    let base: URL
    let width: Double?

    var body: some View {
        if let url = URL(string: source), let scheme = url.scheme, scheme == "http" || scheme == "https" {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    sized(image.resizable().aspectRatio(contentMode: .fit))
                } else if phase.error != nil {
                    placeholder
                } else {
                    Color.clear.frame(width: 24, height: 20)
                }
            }
        } else if let image = ImageCache.shared.image(source, relativeTo: base) {
            sized(Image(nsImage: image).resizable().aspectRatio(contentMode: .fit), natural: image.size)
        } else {
            placeholder
        }
    }

    private func sized(_ image: some View, natural: CGSize? = nil) -> some View {
        image
            .frame(maxWidth: width.map { CGFloat($0) } ?? min(natural?.width ?? 700, 700))
            .accessibilityLabel(alt)
    }

    private var placeholder: some View {
        Label(alt.isEmpty ? source : alt, systemImage: "photo")
            .font(.system(size: 12))
            .foregroundStyle(Color.ink3)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.line))
    }
}

/// Pictures beside the Markdown, read once per path.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func image(_ source: String, relativeTo base: URL) -> NSImage? {
        let decoded = source.removingPercentEncoding ?? source
        let url = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded) : base.appendingPathComponent(decoded)
        let key = url.standardizedFileURL.path
        if let image = images[key] { return image }
        guard !missing.contains(key) else { return nil }
        guard let image = NSImage(contentsOf: url) else {
            missing.insert(key)
            return nil
        }
        images[key] = image
        return image
    }
}

/// Lays its children out in rows, wrapping (a README's badges).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += row + spacing
                x = 0
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += row + spacing
                x = bounds.minX
                row = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// Code as coloured text, for the preview's code blocks: tokenized off the main thread in the fence's
/// language (each line's state carried to the next), then coloured from the theme's scope rules as the
/// editor is.
enum SyntaxText {
    struct Request: Equatable {
        var code: String
        var language: String?
    }

    struct Tokens: Equatable {
        var lines: [String]
        var tokens: [[SyntaxToken]]
    }

    static let font = Font.system(size: 12.5, design: .monospaced)

    /// The tokens of `code` in the language a fence's info string names; nil for plain text.
    nonisolated static func tokens(_ code: String, fence: String?) async -> Tokens? {
        guard let fence, let language = LanguageRegistry.shared.language(forFence: fence),
              let tokenizer = await GrammarStore.shared.tokenizer(for: language) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let lines = code.components(separatedBy: "\n")
            var state: StateStack?
            var tokens: [[SyntaxToken]] = []
            for line in lines {
                let result = tokenizer.tokenize(line, state: state)
                state = result.end
                tokens.append(result.tokens)
            }
            return Tokens(lines: lines, tokens: tokens)
        }.value
    }

    /// The lines in their tokens' colours and styles, in the current theme.
    static func attributed(_ code: Tokens) -> AttributedString {
        let style = EditorStyle.shared
        style.refresh()
        let dark = Palette.isDark(NSApp.effectiveAppearance)
        var result = AttributedString()
        for (index, line) in code.lines.enumerated() {
            let utf16 = Array(line.utf16)
            var position = 0
            for token in code.tokens[index] where token.range.lowerBound >= position && token.range.upperBound <= utf16.count {
                if token.range.lowerBound > position { result += AttributedString(String(decoding: utf16[position..<token.range.lowerBound], as: UTF16.self)) }
                var piece = AttributedString(String(decoding: utf16[token.range], as: UTF16.self))
                let look = style.look(token.scopes)
                if let color = look.color { piece.foregroundColor = Color(nsColor: color) }
                if let background = look.background { piece.backgroundColor = Color(nsColor: background) }
                let fontStyle = look.fontStyle(dark: dark)
                if fontStyle.contains(.bold) || fontStyle.contains(.italic) {
                    var font = Self.font
                    if fontStyle.contains(.bold) { font = font.bold() }
                    if fontStyle.contains(.italic) { font = font.italic() }
                    piece.font = font
                }
                if fontStyle.contains(.underline) { piece.underlineStyle = .single }
                if fontStyle.contains(.strikethrough) { piece.strikethroughStyle = .single }
                result += piece
                position = token.range.upperBound
            }
            if position < utf16.count { result += AttributedString(String(decoding: utf16[position...], as: UTF16.self)) }
            if index < code.lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }
}
