import Foundation

/// The rest of the web prototype's `server/describe.ts`: what the journal says about a tool call, what
/// came back from it and what an ask needs to be shown. Payloads come from outside the app, so every
/// field is checked for its type where it is read, and everything kept is cut to a size: a tool's
/// output can be megabytes and is never kept whole.
extension Describe {
    static let detailSize = 2_000
    static let outputSize = 1_000
    static let inputSize = 4_000
    static let titleSize = 120

    /// Tools whose input or output is file contents. Only their paths are kept.
    static let contents: Set = ["Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "NotebookRead"]


    private static func file(_ input: [String: JSONValue]) -> String {
        let file = input["file_path"].text
        return file.isEmpty ? input["notebook_path"].text : file
    }

    private static func mcp(_ tool: String) -> String {
        tool.components(separatedBy: "__").dropFirst().joined(separator: " · ")
    }

    /// The first string that is not empty, or "".
    static func first(_ values: String...) -> String {
        values.first { !$0.isEmpty } ?? ""
    }

    /// A finite JSON number, or nil for anything else.
    static func number(_ value: JSONValue?) -> Double? {
        if case .number(let number) = value, number.isFinite { number } else { nil }
    }

    /// A number as JavaScript prints it: whole numbers without a decimal point.
    static func numberText(_ number: Double) -> String {
        number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
    }

    /// A value as compact JSON, cut short. Keys are sorted, so the same request always reads the same.
    static func json(_ value: JSONValue, _ max: Int) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return clip(String(decoding: data, as: UTF8.self), max)
    }

    /// TaskUpdate's id. Claude Code repairs `id` and `task_id` to `taskId`, but hooks may see either spelling.
    static func taskID(_ input: [String: JSONValue]) -> String {
        first(input["taskId"].text, input["id"].text, input["task_id"].text)
    }

    /// One line for the timeline, e.g. "Ran npm test". `subjectOf` names a task from its id.
    static func toolTitle(tool: String, input: [String: JSONValue], subjectOf: (String) -> String) -> String {
        let name = basename(file(input))
        func line(_ value: JSONValue?) -> String { clip(firstLine(value.text), 80) }
        let said: String
        switch tool {
        case "Read", "NotebookRead": said = String(localized: "step.read", defaultValue: "Read \(name)", bundle: .module, comment: "A step in Claude's story: read the named file (past tense; the same English as the request to read it)")
        case "Write": said = String(localized: "Wrote \(name)", bundle: .module, comment: "A step in Claude's story: wrote the named file")
        case "Edit", "MultiEdit", "NotebookEdit": said = String(localized: "Edited \(name)", bundle: .module, comment: "A step in Claude's story: edited the named file")
        case "Bash", "PowerShell": said = String(localized: "Ran \(line(input["command"]))", bundle: .module, comment: "A step in Claude's story: ran the command shown")
        case "Grep": said = String(localized: "Searched for \(line(input["pattern"]))", bundle: .module, comment: "A step in Claude's story: searched files for the text shown")
        case "Glob": said = String(localized: "Looked for \(line(input["pattern"]))", bundle: .module, comment: "A step in Claude's story: looked for files named like the pattern shown")
        case "WebSearch": said = String(localized: "Searched the web for \(line(input["query"]))", bundle: .module, comment: "A step in Claude's story")
        case "WebFetch": said = String(localized: "Fetched \(line(input["url"]))", bundle: .module, comment: "A step in Claude's story: fetched the web address shown")
        case "Agent", "Task":
            let kind = input["subagent_type"].text
            said = kind.isEmpty ? String(localized: "Launched a helper: \(line(input["description"]))", bundle: .module, comment: "A step in Claude's story: started a helper, then its task") : String(localized: "Launched \(kind): \(line(input["description"]))", bundle: .module, comment: "A step in Claude's story: started a helper of the named kind, then its task")
        case "AskUserQuestion": said = String(localized: "Asked you: \(line(input["questions"].items.first["question"]))", bundle: .module, comment: "A step in Claude's story: the question follows")
        case "ExitPlanMode": said = String(localized: "Asked you to approve a plan", bundle: .module, comment: "A step in Claude's story")
        case "EnterPlanMode": said = String(localized: "Started planning", bundle: .module, comment: "A step in Claude's story")
        case "TaskCreate": said = String(localized: "Added a task: \(line(input["subject"]))", bundle: .module, comment: "A step in Claude's story: the task follows")
        case "TaskUpdate":
            let id = taskID(input)
            let subject = first(line(input["subject"]), subjectOf(id), "#\(id)")
            switch input["status"].text {
            case "in_progress": said = String(localized: "Started a task: \(subject)", bundle: .module, comment: "A step in Claude's story")
            case "completed": said = String(localized: "Finished a task: \(subject)", bundle: .module, comment: "A step in Claude's story")
            case "deleted": said = String(localized: "Removed a task: \(subject)", bundle: .module, comment: "A step in Claude's story")
            case "pending": said = String(localized: "Reopened a task: \(subject)", bundle: .module, comment: "A step in Claude's story")
            default: said = String(localized: "Updated a task: \(subject)", bundle: .module, comment: "A step in Claude's story")
            }
        case "TaskList": said = String(localized: "Checked the task list", bundle: .module, comment: "A step in Claude's story")
        case "TaskGet": said = String(localized: "Looked at a task", bundle: .module, comment: "A step in Claude's story")
        case "TodoWrite": said = String(localized: "Updated the to-do list", bundle: .module, comment: "A step in Claude's story")
        case "Skill": said = String(localized: "Used the \(first(line(input["skill"]), line(input["command"]))) skill", bundle: .module, comment: "A step in Claude's story: used the named skill")
        case "SubagentHandback": said = String(localized: "Handed back its report", bundle: .module, comment: "A step in Claude's story: a helper gave its report to the Claude that started it")
        default: said = tool.hasPrefix("mcp__") ? mcp(tool) : tool
        }
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        return clip(trimmed.isEmpty ? tool : trimmed, titleSize)
    }

    /// The thing itself, in full (within reason): the command, the path, the URL, the helper's instructions.
    static func toolTarget(tool: String, input: [String: JSONValue]) -> String {
        let path = file(input)
        if !path.isEmpty { return clip(path, detailSize) }
        switch tool {
        case "Grep", "Glob":
            let parts = [input["pattern"].text, input["path"].text, input["glob"].text].filter { !$0.isEmpty }
            return clip(parts.joined(separator: "  in  "), detailSize)
        case "Agent", "Task": return clip(input["prompt"].text, detailSize)
        case "ExitPlanMode": return clip(input["plan"].text, detailSize)
        case "TaskCreate", "TaskUpdate": return clip(input["description"].text, detailSize)
        default: break
        }
        let said = first(input["command"].text, input["url"].text, input["query"].text, input["skill"].text)
        if !said.isEmpty { return clip(said, detailSize) }
        if ["TodoWrite", "AskUserQuestion", "SubagentHandback"].contains(tool) || contents.contains(tool) { return "" }
        return input.isEmpty ? "" : json(.object(input), 500)
    }

    /// The text blocks of an MCP or helper result: [{ type: "text", text: "…" }, …].
    private static func blocks(_ value: JSONValue?) -> String {
        value.items.map { $0["text"].text }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// The start of what a successful tool call returned. File contents are never kept.
    static func toolOutput(tool: String, response: JSONValue?) -> String {
        if contents.contains(tool) { return "" }
        if case .string(let said) = response { return clip(said, outputSize) }
        let r = response.fields
        switch tool {
        case "Bash", "PowerShell":
            let said = [r["stdout"].text, r["stderr"].text].filter { !$0.isEmpty }.joined(separator: "\n")
            return clip(r["interrupted"].isTrue ? "(\(String(localized: "interrupted", bundle: .module, comment: "A command's output: it was stopped before it ended")))\n\(said)" : said, outputSize)
        case "Agent", "Task":
            let stats = [
                number(r["totalToolUseCount"]).map { $0 == 1 ? String(localized: "1 tool call", bundle: .module, comment: "A helper's report: it took one step")
                    : String(localized: "\(numberText($0)) tool calls", bundle: .module, comment: "A helper's report: how many steps it took") } ?? "",
                number(r["totalTokens"]).map { String(localized: "\(numberText($0)) tokens in its last request", bundle: .module, comment: "A helper's report: how much text its last request held") } ?? "",
                r["resolvedModel"].text,
            ].filter { !$0.isEmpty }.joined(separator: " · ")
            let report = r["status"].text == "async_launched" ? String(localized: "Running in the background.", bundle: .module, comment: "A helper's report: it was started to run on its own") : blocks(r["content"])
            return clip([report, stats.isEmpty ? "" : "(\(stats))"].filter { !$0.isEmpty }.joined(separator: "\n\n"), outputSize)
        default:
            break
        }
        if case .array(let names) = r["filenames"] { return clip(names.map(\.text).joined(separator: "\n"), outputSize) }
        return clip(first(r["result"].text, r["content"].text, blocks(r["content"]), blocks(response)), outputSize)
    }

    static func errorOutput(_ error: JSONValue?) -> String {
        clip(error.text, outputSize)
    }

    /// The "always allow" choices Claude Code suggests with a permission request.
    private static func suggestion(_ entry: JSONValue) -> String {
        switch entry["type"].text {
        case "addRules", "replaceRules":
            let rules = entry["rules"].items.map { rule in
                rule["ruleContent"].text.isEmpty ? rule["toolName"].text : "\(rule["toolName"].text)(\(rule["ruleContent"].text))"
            }
            return "Always \(first(entry["behavior"].text, "allow")) \(rules.joined(separator: ", "))"
        case "setMode":
            return "Switch to \(entry["mode"].text) mode"
        case "addDirectories":
            return "Allow access to \(entry["directories"].items.map(\.text).joined(separator: ", "))"
        default:
            return entry["type"].text
        }
    }

    /// What an ask needs to be shown, from the hook payload that raised it.
    struct AskText: Equatable {
        var summary: String
        var description = ""
        var target = ""
        var options: [String] = []
        var input: String
        var questionCount = 0
        var multiSelect = false
    }

    static func askText(kind: AskKind, tool: String, payload: JSONValue) -> AskText {
        func options(_ values: [String]) -> [String] {
            values.filter { !$0.isEmpty }.prefix(10).map { clip($0, 200) }
        }
        switch kind {
        case .form:
            // Only what describes the form is shown whole; the rest of the payload is the hook's own.
            let whole = ["message", "mode", "url", "requested_schema"].reduce(into: [String: JSONValue]()) { kept, key in
                if let value = payload[key] { kept[key] = value }
            }
            // A JSON object's order is not kept once read, so the fields are listed by name.
            let fields = payload["requested_schema"]["properties"].fields.sorted { $0.key < $1.key }
            return AskText(
                summary: clip(first(payload["message"].text, String(localized: "An MCP server needs your input", bundle: .module, comment: "A request: a tool's form waits to be filled in")), 200),
                target: clip(payload["url"].text, detailSize),
                options: options(fields.map { first($0.value["title"].text, $0.key) }),
                input: json(.object(whole), inputSize))
        case .question:
            let input = payload["tool_input"].fields
            let questions = input["questions"].items
            let first = questions.first
            let more = questions.count - 1
            return AskText(
                summary: clip(Self.first(first["question"].text, String(localized: "Claude has a question", bundle: .module, comment: "A request: Claude asks something")), 200),
                description: more == 1 ? String(localized: "and 1 more question", bundle: .module, comment: "A request: Claude asks one more question after this one") : more > 1 ? String(localized: "and \(more) more questions", bundle: .module, comment: "A request: Claude asks more questions after this one") : "",
                options: options(first["options"].items.map { $0["label"].text }),
                input: json(.object(input), inputSize),
                questionCount: questions.count,
                multiSelect: first["multiSelect"].isTrue)
        case .plan:
            let input = payload["tool_input"].fields
            return AskText(summary: String(localized: "Approve the plan", bundle: .module, comment: "A request: Claude waits for its plan to be approved"), target: clip(input["plan"].text, detailSize), input: json(.object(input), inputSize))
        case .permission:
            // Shown whole while it waits, as Claude Code's own dialog shows it: for a Write that includes
            // the contents. The ask goes when it is settled; only its path stays, on the timeline.
            let input = payload["tool_input"].fields
            return AskText(
                summary: clip(permissionSummary(tool: tool, input: input), 200),
                description: clip(input["description"].text, 500),
                target: toolTarget(tool: tool, input: input),
                options: options(payload["permission_suggestions"].items.map(suggestion)),
                input: json(.object(input), inputSize))
        }
    }
}
