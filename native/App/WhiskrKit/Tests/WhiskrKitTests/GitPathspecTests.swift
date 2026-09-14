import Foundation
import Testing
@testable import WhiskrKit

/// Paths handed to git (`GitRunner.run(_:paths:in:)`) mean those files only, in a throwaway repository
/// whose names are git patterns, as a Next.js or SvelteKit app's are.
@Suite("git: a path means that file, never a pattern")
struct GitPathspecTests {
    let repository: URL
    let git = GitRunner()
    let files = ["[id].txt", "i.txt", "d.txt", "app/[id]/page.tsx", "app/i/page.tsx", "*.md", "notes.md"]

    init() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("whiskr-pathspecs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        // git reports real paths (/private/var/…, not /var/…).
        repository = made.resolvingSymlinksInPath()
        try git.run(["init", "--quiet", "--initial-branch=main"], in: repository.path)
        for file in files { try write("first", to: file) }
        try git.run(["add", "-A"], in: repository.path)
        try git.run(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "first"],
                    in: repository.path)
        for file in files { try write("changed", to: file) }
    }

    func write(_ text: String, to file: String) throws {
        let url = repository.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// The files with unstaged changes.
    func changed() throws -> Set<String> {
        let status = try git.run(["status", "--porcelain=v2", "-z", "--untracked-files=all"], in: repository.path)
        return Set(GitStatus.parse(Data(status.utf8)).entries.filter { $0.worktree == .modified }.map(\.path))
    }

    @Test("restoring [id].txt and app/[id]/page.tsx leaves i.txt, d.txt and app/i/page.tsx changed")
    func restoresOnlyThoseFiles() throws {
        defer { try? FileManager.default.removeItem(at: repository) }
        try git.run(["restore", "--worktree"], paths: ["[id].txt", "app/[id]/page.tsx", "*.md"], in: repository.path)
        #expect(try changed() == ["i.txt", "d.txt", "app/i/page.tsx", "notes.md"])
        // A folder still means everything in it.
        try git.run(["restore", "--worktree"], paths: ["app"], in: repository.path)
        #expect(try changed() == ["i.txt", "d.txt", "notes.md"])
    }

    @Test("staging a name that is a pattern stages that file alone; a pattern that names no file is refused")
    func stagesOnlyThatFile() throws {
        defer { try? FileManager.default.removeItem(at: repository) }
        try git.run(["add", "-A"], paths: ["[id].txt"], in: repository.path)
        let staged = try git.run(["diff", "--cached", "--name-only", "-z"], in: repository.path).split(separator: "\0").map(String.init)
        #expect(staged == ["[id].txt"])
        #expect(throws: GitError.self) { try git.run(["add", "-A"], paths: ["*.txt"], in: repository.path) }
        #expect(throws: GitError.self) { try git.run(["add", "-A"], paths: [":(glob)*.txt"], in: repository.path) }
    }

    @Test("without it, git reads the same names as patterns: what the literal setting prevents")
    func patternsWithout() throws {
        defer { try? FileManager.default.removeItem(at: repository) }
        try git.run(["restore", "--worktree", "--", "[id].txt"], in: repository.path)
        #expect(try changed().isDisjoint(with: ["[id].txt", "i.txt", "d.txt"]))
    }

    @Test("the literal setting replaces the other global pathspec settings, which git refuses beside it")
    func environment() {
        var environment = ["GIT_GLOB_PATHSPECS": "1", "GIT_ICASE_PATHSPECS": "1", "GIT_NOGLOB_PATHSPECS": "1", "PATH": "/usr/bin"]
        GitRunner.literalPathspecs(&environment)
        #expect(environment == ["GIT_LITERAL_PATHSPECS": "1", "PATH": "/usr/bin"])
    }
}
