import Foundation

/// A glob pattern over a file's name or path, as VS Code matches `filenamePatterns` ("Dockerfile.*",
/// "tsconfig.*.json", "**/.git/config"): `*` and `?` within one path segment, `**` across any number of
/// segments, `{a,b}` alternatives and `[a-z]` / `[!a-z]` ranges, ignoring case.
///
/// The translation to a regular expression is ported from `parseRegExp` and `starsToRegExp` in
/// microsoft/vscode `src/vs/base/common/glob.ts` (MIT), which VS Code's own shortcuts for common patterns
/// agree with.
struct PathGlob: @unchecked Sendable {
    let pattern: String
    private let expression: NSRegularExpression

    init?(_ pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let expression = try? NSRegularExpression(pattern: "^" + Self.regularExpression(trimmed) + "$", options: [.caseInsensitive])
        else { return nil }
        self.pattern = pattern
        self.expression = expression
    }

    func matches(_ path: String) -> Bool {
        expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    private static let globstar = "**"
    private static let pathSeparator = "[/\\\\]"
    private static let notPathSeparator = "[^/\\\\]"

    private static func stars(_ count: Int, isLast: Bool) -> String {
        switch count {
        case 0: return ""
        case 1: return "\(notPathSeparator)*?"
        default:
            let last = isLast ? "|\(pathSeparator)\(notPathSeparator)+" : ""
            return "(?:\(pathSeparator)|\(notPathSeparator)+\(pathSeparator)\(last))*?"
        }
    }

    /// Splits on `separator` outside `{…}` and `[…]`.
    private static func split(_ pattern: String, on separator: Character) -> [String] {
        var segments: [String] = []
        var inBraces = false
        var inBrackets = false
        var current = ""
        for character in pattern {
            if character == separator, !inBraces, !inBrackets {
                segments.append(current)
                current = ""
                continue
            }
            switch character {
            case "{": inBraces = true
            case "}": inBraces = false
            case "[": inBrackets = true
            case "]": inBrackets = false
            default: break
            }
            current.append(character)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func escaped(_ character: Character) -> String {
        "\\{}*+?|^$.[]()".contains(character) ? "\\" + String(character) : String(character)
    }

    static func regularExpression(_ pattern: String) -> String {
        guard !pattern.isEmpty else { return "" }
        let segments = split(pattern, on: "/")
        if segments.allSatisfy({ $0 == globstar }) { return ".*" }
        var result = ""
        var previousWasGlobstar = false
        for (index, segment) in segments.enumerated() {
            defer { previousWasGlobstar = segment == globstar }
            if segment == globstar {
                if !previousWasGlobstar { result += stars(2, isLast: index == segments.count - 1) }
                continue
            }
            var inBraces = false
            var braces = ""
            var inBrackets = false
            var brackets = ""
            for character in segment {
                if character != "}", inBraces {
                    braces.append(character)
                    continue
                }
                // "]" is only literal as a range's first character.
                if inBrackets, character != "]" || brackets.isEmpty {
                    if character == "-" {
                        brackets += "-"
                    } else if (character == "^" || character == "!") && brackets.isEmpty {
                        brackets += "^"
                    } else if character == "/" {
                        continue
                    } else {
                        brackets += escaped(character)
                    }
                    continue
                }
                switch character {
                case "{":
                    inBraces = true
                case "[":
                    inBrackets = true
                case "}":
                    result += "(?:" + split(braces, on: ",").map(regularExpression).joined(separator: "|") + ")"
                    inBraces = false
                    braces = ""
                case "]":
                    result += "[" + brackets + "]"
                    inBrackets = false
                    brackets = ""
                case "?":
                    result += notPathSeparator
                case "*":
                    result += stars(1, isLast: false)
                default:
                    result += escaped(character)
                }
            }
            // The separator before the next segment, unless what follows is a final "**".
            if index < segments.count - 1, segments[index + 1] != globstar || index + 2 < segments.count {
                result += pathSeparator
            }
        }
        return result
    }
}
