import Foundation

/// The languages the editor colours, found from a file's name (and, for a file without a telling name,
/// its first line). Anything else is plain text.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift, typescript, javascript, python, rust, go, c, cpp, java, kotlin, ruby, php, html, xml, css, json, yaml, toml, markdown, shell, sql, dockerfile, plain

    /// The language a file is written in: by its whole name ("Dockerfile", "Gemfile", ".zshrc"), then its
    /// extension, then a shebang or an XML or HTML declaration on its first line.
    public static func detect(fileName: String, firstLine: String?) -> SyntaxLanguage {
        let name = (fileName as NSString).lastPathComponent.lowercased()
        if let known = names[name] { return known }
        if name.hasPrefix("dockerfile.") || name.hasPrefix("containerfile.") { return .dockerfile }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let known = extensions[ext] { return known }
        if let line = firstLine { return detect(firstLine: line) }
        return .plain
    }

    /// A shebang ("#!/usr/bin/env python3"), `<?xml` or `<!DOCTYPE html`.
    static func detect(firstLine: String) -> SyntaxLanguage {
        let line = firstLine.trimmingCharacters(in: .whitespaces).lowercased()
        if line.hasPrefix("#!") {
            let words = line.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "/" })
            // "/usr/bin/env -S node" names the program after env and its options.
            let program = words.last { !$0.hasPrefix("-") && $0 != "env" && $0 != "usr" && $0 != "bin" && $0 != "local" }.map(String.init) ?? ""
            if program.hasPrefix("python") { return .python }
            if program.hasPrefix("node") || program == "deno" || program == "bun" { return .javascript }
            if program.hasPrefix("ruby") { return .ruby }
            if program == "php" { return .php }
            if ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(program) { return .shell }
            return .plain
        }
        if line.hasPrefix("<?xml") { return .xml }
        if line.hasPrefix("<!doctype html") || line.hasPrefix("<html") { return .html }
        if line.hasPrefix("<?php") { return .php }
        return .plain
    }

    private static let names: [String: SyntaxLanguage] = [
        "dockerfile": .dockerfile, "containerfile": .dockerfile,
        ".zshrc": .shell, ".zshenv": .shell, ".zprofile": .shell, ".bashrc": .shell, ".bash_profile": .shell,
        ".profile": .shell, ".envrc": .shell, "pkgbuild": .shell,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "fastfile": .ruby, "brewfile": .ruby, "vagrantfile": .ruby,
        "package.swift": .swift, ".gitignore": .plain, "makefile": .plain,
    ]

    private static let extensions: [String: SyntaxLanguage] = [
        "swift": .swift,
        "ts": .typescript, "mts": .typescript, "cts": .typescript, "tsx": .typescript,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "py": .python, "pyi": .python, "pyw": .python,
        "rs": .rust, "go": .go,
        "c": .c, "h": .c, "m": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "c++": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp, "mm": .cpp, "ino": .cpp,
        "java": .java, "kt": .kotlin, "kts": .kotlin,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby, "ru": .ruby,
        "php": .php,
        "html": .html, "htm": .html, "xhtml": .html, "vue": .html, "svelte": .html,
        "xml": .xml, "plist": .xml, "svg": .xml, "xib": .xml, "storyboard": .xml, "xsd": .xml, "xsl": .xml, "csproj": .xml, "entitlements": .xml,
        "css": .css, "scss": .css, "less": .css,
        "json": .json, "jsonc": .json, "json5": .json, "geojson": .json, "webmanifest": .json, "xcstrings": .json,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml,
        "md": .markdown, "markdown": .markdown, "mdx": .markdown, "mdown": .markdown,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell, "ksh": .shell, "command": .shell,
        "sql": .sql,
        "dockerfile": .dockerfile, "containerfile": .dockerfile,
    ]

    /// A fenced code block's info string ("swift", "ts", "py", "bash", "Dockerfile") as a language.
    static func detect(fence info: String) -> SyntaxLanguage {
        let word = info.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map { $0.lowercased() } ?? ""
        guard !word.isEmpty else { return .plain }
        if let language = fenceNames[word] { return language }
        if let language = SyntaxLanguage(rawValue: word) { return language }
        return extensions[word] ?? names[word] ?? .plain
    }

    private static let fenceNames: [String: SyntaxLanguage] = [
        "javascript": .javascript, "typescript": .typescript, "node": .javascript, "python3": .python, "python": .python,
        "golang": .go, "c++": .cpp, "objc": .c, "objective-c": .c, "objectivec": .c, "shell": .shell, "console": .shell,
        "shellscript": .shell, "sh-session": .shell, "terminal": .shell, "html": .html, "xml": .xml, "docker": .dockerfile,
        "yml": .yaml, "md": .markdown, "postgres": .sql, "postgresql": .sql, "mysql": .sql, "sqlite": .sql, "plaintext": .plain, "text": .plain,
    ]

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .typescript: "TypeScript"
        case .javascript: "JavaScript"
        case .python: "Python"
        case .rust: "Rust"
        case .go: "Go"
        case .c: "C"
        case .cpp: "C++"
        case .java: "Java"
        case .kotlin: "Kotlin"
        case .ruby: "Ruby"
        case .php: "PHP"
        case .html: "HTML"
        case .xml: "XML"
        case .css: "CSS"
        case .json: "JSON"
        case .yaml: "YAML"
        case .toml: "TOML"
        case .markdown: "Markdown"
        case .shell: "Shell"
        case .sql: "SQL"
        case .dockerfile: "Dockerfile"
        case .plain: "Plain Text"
        }
    }

    /// For Toggle Comment: the line comment marker, nil when the language has none.
    public var lineComment: String? {
        switch self {
        case .swift, .typescript, .javascript, .rust, .go, .c, .cpp, .java, .kotlin, .php, .json: "//"
        case .python, .ruby, .yaml, .toml, .shell, .dockerfile: "#"
        case .sql: "--"
        case .html, .xml, .css, .markdown, .plain: nil
        }
    }

    /// For Toggle Comment when there is no line comment.
    public var blockComment: (open: String, close: String)? {
        switch self {
        case .html, .xml, .markdown: ("<!--", "-->")
        case .css: ("/*", "*/")
        default: nil
        }
    }
}
