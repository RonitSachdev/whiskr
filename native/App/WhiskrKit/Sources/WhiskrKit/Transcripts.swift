import Foundation

/// Reads the parts of Claude Code's own files that hooks do not carry, ported from the web prototype's
/// `server/lineage.ts`. These are Claude Code's internal formats, so anything unexpected just means
/// "not known" and the caller falls back. Plain blocking reads: call them off the main thread.
public enum Transcripts {
    static let tail = 256 * 1024

    /// The chat's name and the model of its latest reply, from the end of the transcript. Claude Code
    /// rewrites the name into the transcript as the chat goes on: a name the user chose
    /// (`custom-title`) wins over the generated one (`ai-title`).
    public static func facts(transcriptPath: String) -> TranscriptFacts {
        guard transcriptPath.hasSuffix(".jsonl"), let handle = FileHandle(forReadingAtPath: transcriptPath) else { return TranscriptFacts() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return TranscriptFacts() }
        let length = min(size, UInt64(tail))
        guard (try? handle.seek(toOffset: size - length)) != nil, let data = try? handle.read(upToCount: Int(length)) else { return TranscriptFacts() }
        var chosen: String?, generated: String?, model: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            let text = String(decoding: line, as: UTF8.self)
            let titled = text.contains("-title\"")
            guard titled || text.contains("\"type\":\"assistant\"") else { continue }
            // The first line of the tail is usually cut off mid-record; it fails to parse and is skipped.
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            switch entry["type"].text {
            case "custom-title":
                chosen = nonEmpty(entry["customTitle"].text) ?? nonEmpty(entry["title"].text) ?? chosen
            case "ai-title":
                generated = nonEmpty(entry["aiTitle"].text) ?? generated
            case "assistant":
                // Claude Code writes some replies itself, under a made-up model such as "<synthetic>".
                let wrote = entry["message"]["model"].text
                if !wrote.isEmpty, !wrote.hasPrefix("<") { model = wrote }
            default:
                break
            }
        }
        return TranscriptFacts(title: chosen ?? generated, model: model)
    }

    /// The meta file Claude Code writes beside a helper's transcript, naming the tool call that launched
    /// it: the only exact link from a helper back to its parent. nil when it is not there (yet).
    public static func spawnMeta(transcriptPath: String, agentID: String) -> SpawnMeta? {
        guard let path = helperFile(transcriptPath: transcriptPath, agentID: agentID, ending: ".meta.json"),
              let data = FileManager.default.contents(atPath: path),
              let meta = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = meta else { return nil }
        return SpawnMeta(toolUseID: nonEmpty(meta["toolUseId"].text), description: nonEmpty(meta["description"].text), agentType: nonEmpty(meta["agentType"].text))
    }

    /// Where a helper's own files live: `<session>/subagents/agent-<id>` beside the session's transcript.
    /// Agent ids arrive in hook payloads, so a path is only ever built from one that is plainly an id;
    /// anything else (a slash, dots, an empty string) gets no path at all.
    static func helperFile(transcriptPath: String, agentID: String, ending: String) -> String? {
        guard isPlainID(agentID), transcriptPath.hasSuffix(".jsonl") else { return nil }
        let transcript = URL(fileURLWithPath: transcriptPath)
        let folder = transcript.deletingLastPathComponent().lastPathComponent == "subagents"
            ? transcript.deletingLastPathComponent()
            : transcript.deletingPathExtension().appendingPathComponent("subagents")
        return folder.appendingPathComponent("agent-\(agentID)\(ending)").path
    }

    static func isPlainID(_ id: String) -> Bool {
        (1...128).contains(id.count) && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    private static func nonEmpty(_ value: String) -> String? { value.isEmpty ? nil : value }
}
