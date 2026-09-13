import Foundation

/// One Claude Code account: a config folder in the home folder. `~/.claude` is the default one;
/// `~/.claude-<name>` are others, chosen for a process by setting `CLAUDE_CONFIG_DIR`.
public struct ClaudeAccount: Sendable, Equatable, Hashable, Identifiable {
    public let name: String          // "default" for ~/.claude, else the part after "-"
    public let configDir: String     // absolute path of the folder
    public let email: String?        // the signed-in address, when the account file says so

    public var id: String { configDir }
    public var isDefault: Bool { name == Self.defaultName }

    public static let defaultName = "default"

    /// What `CLAUDE_CONFIG_DIR` must be for this account: nothing for the default one.
    public var configDirEnvironment: String? { isDefault ? nil : configDir }

    public init(name: String, configDir: String, email: String?) {
        self.name = name
        self.configDir = configDir
        self.email = email
    }
}

/// A folder Claude Code has been used in, and when.
public struct RecentFolder: Sendable, Equatable, Identifiable {
    public let path: String
    public let lastUsed: Date
    public var id: String { path }

    public init(path: String, lastUsed: Date) {
        self.path = path
        self.lastUsed = lastUsed
    }
}

public enum FolderProblem: Error, Sendable, Equatable {
    case empty, notAbsolute, missing, notAFolder, notReadable

    public var message: String {
        switch self {
        case .empty: "Choose a folder."
        case .notAbsolute: "Type a full path, starting with / or ~."
        case .missing: "There is no such folder."
        case .notAFolder: "That is a file, not a folder."
        case .notReadable: "You do not have permission to open that folder."
        }
    }
}

public enum Discovery {
    /// Every Claude Code account under `home`, default first, then by name. Only folders count:
    /// `~/.claude.json` is the default account's file, not an account.
    public static func accounts(home: URL) -> [ClaudeAccount] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let accounts = names.compactMap { entry -> ClaudeAccount? in
            let name: String
            if entry == ".claude" {
                name = ClaudeAccount.defaultName
            } else if entry.hasPrefix(".claude-"), entry.count > ".claude-".count {
                name = String(entry.dropFirst(".claude-".count))
            } else {
                return nil
            }
            let folder = home.appendingPathComponent(entry)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else { return nil }
            // The default account keeps its file beside the folder; the others keep theirs inside it.
            let file = name == ClaudeAccount.defaultName ? home.appendingPathComponent(".claude.json") : folder.appendingPathComponent(".claude.json")
            return ClaudeAccount(name: name, configDir: folder.path, email: email(in: file))
        }
        return accounts.sorted { ($0.isDefault ? 0 : 1, $0.name) < ($1.isDefault ? 0 : 1, $1.name) }
    }

    /// The signed-in address from an account file. Only that one field is read.
    static func email(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        let email = json["oauthAccount"]["emailAddress"].text
        return email.isEmpty ? nil : email
    }

    /// Folders Claude Code was used in under these accounts, newest first. Each account keeps a folder
    /// per project under `projects/`, named by a lossy encoding of the path, so the real path is read
    /// from the `cwd` field of the newest transcript inside it. Only the accounts' own records are
    /// read: the folders themselves are not looked at (many are in ~/Desktop or ~/Documents, which
    /// macOS guards with a permission prompt) until you pick one and it is checked.
    public static func recentFolders(accounts: [ClaudeAccount], limit: Int = 30) -> [RecentFolder] {
        var newest: [String: Date] = [:]
        let files = FileManager.default
        for account in accounts {
            let projects = URL(fileURLWithPath: account.configDir).appendingPathComponent("projects")
            guard let folders = try? files.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil) else { continue }
            for folder in folders {
                guard let transcripts = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                let dated = transcripts.filter { $0.pathExtension == "jsonl" }.compactMap { url -> (URL, Date)? in
                    guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                    return (url, date)
                }
                guard let (latest, date) = dated.max(by: { $0.1 < $1.1 }), let cwd = workingFolder(transcript: latest) else { continue }
                if date > newest[cwd] ?? .distantPast { newest[cwd] = date }
            }
        }
        return newest
            .map { RecentFolder(path: $0.key, lastUsed: $0.value) }
            .sorted { ($0.lastUsed, $1.path) > ($1.lastUsed, $0.path) }
            .prefix(limit)
            .map { $0 }
    }

    /// Joins folder lists, newest use of each path winning, newest first.
    public static func merge(_ lists: [RecentFolder]..., limit: Int = 30) -> [RecentFolder] {
        var newest: [String: Date] = [:]
        for folder in lists.joined() where folder.lastUsed > newest[folder.path] ?? .distantPast {
            newest[folder.path] = folder.lastUsed
        }
        return newest.map { RecentFolder(path: $0.key, lastUsed: $0.value) }
            .sorted { ($0.lastUsed, $1.path) > ($1.lastUsed, $0.path) }
            .prefix(limit)
            .map { $0 }
    }

    /// The `cwd` recorded near the start of a transcript.
    static func workingFolder(transcript: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")) where line.count < 64 * 1024 {
            guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line)) else { continue }
            let cwd = entry["cwd"].text
            if cwd.hasPrefix("/") { return cwd }
        }
        return nil
    }

    /// Checks a folder typed by hand and returns it as an absolute, standardised path.
    public static func validateFolder(_ typed: String, home: URL) -> Result<String, FolderProblem> {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let expanded: String
        if trimmed == "~" {
            expanded = home.path
        } else if trimmed.hasPrefix("~/") {
            expanded = home.appendingPathComponent(String(trimmed.dropFirst(2))).path
        } else {
            expanded = trimmed
        }
        guard expanded.hasPrefix("/") else { return .failure(.notAbsolute) }
        let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &folder) else { return .failure(.missing) }
        guard folder.boolValue else { return .failure(.notAFolder) }
        guard access(path, R_OK | X_OK) == 0 else { return .failure(.notReadable) }
        return .success(path)
    }
}
