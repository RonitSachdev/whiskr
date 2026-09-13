import Foundation

/// Plain-language descriptions of what a tool call is and what it asks, ported from the web
/// prototype's `server/describe.ts`. Everything kept is cut to a size: inputs can be megabytes.
enum Describe {
    static func clip(_ value: String, _ max: Int = 70) -> String {
        value.count > max ? String(value.prefix(max - 1)) + "…" : value
    }

    static func firstLine(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? ""
    }

    private static func fileOf(_ input: [String: JSONValue]) -> String {
        let file = input["file_path"].text
        return file.isEmpty ? input["notebook_path"].text : file
    }

    private static func mcpName(_ tool: String) -> String {
        tool.components(separatedBy: "__").dropFirst().joined(separator: " · ")
    }

    /// A few words for the sidebar: which file, which command.
    static func toolDetail(tool: String, input: [String: JSONValue]) -> String {
        let file = fileOf(input)
        if !file.isEmpty { return basename(file) }
        for key in ["description", "command", "pattern", "query", "url"] {
            let said = input[key].text
            if !said.isEmpty { return clip(firstLine(said)) }
        }
        return tool.hasPrefix("mcp__") ? mcpName(tool) : tool
    }

    /// What a permission request asks, in a few words, e.g. "Run a command".
    static func permissionSummary(tool: String, input: [String: JSONValue]) -> String {
        let file = basename(fileOf(input))
        switch tool {
        case "Bash", "PowerShell": return String(localized: "Run a command", bundle: .module, comment: "A permission request: what Claude wants to do")
        case "Write": return String(localized: "Create or overwrite \(file)", bundle: .module, comment: "A permission request: a file's name follows")
        case "Edit", "MultiEdit", "NotebookEdit": return String(localized: "Edit \(file)", bundle: .module, comment: "A permission request: edit the named file")
        case "Read": return String(localized: "Read \(file)", bundle: .module, comment: "A permission request: read the named file")
        case "WebFetch":
            if let host = URL(string: input["url"].text)?.host, !host.isEmpty { return String(localized: "Fetch a page from \(host)", bundle: .module, comment: "A permission request: a web site's name follows") }
            return String(localized: "Fetch a web page", bundle: .module, comment: "A permission request")
        case "WebSearch": return String(localized: "Search the web", bundle: .module, comment: "A permission request")
        case "Agent", "Task": return String(localized: "Launch a helper", bundle: .module, comment: "A permission request: start a subagent")
        case "AskUserQuestion": return String(localized: "Answer a question", bundle: .module, comment: "A permission request")
        case "ExitPlanMode": return String(localized: "Approve the plan", bundle: .module, comment: "A request: Claude waits for its plan to be approved")
        default: return String(localized: "Use \(tool.hasPrefix("mcp__") ? mcpName(tool) : tool)", bundle: .module, comment: "A permission request: use the named tool")
        }
    }
}
