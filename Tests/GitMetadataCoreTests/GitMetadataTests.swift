import Testing
import Foundation
@testable import GitMetadataCore
import SubprocessCore

// MARK: - renderer (no git required)

@Suite("Git metadata renderer")
struct GitMetadataRendererTests {

    @Test("renders one constant per field with stable optional types")
    func rendersStableTypes() {
        let available = GitMetadataRenderer.swiftSource(for: GitMetadata(
            commitHash: "abc123", shortCommitHash: "abc123", branch: "main",
            tag: nil, describe: "abc123", commitDate: "2026-10-02T20:00:00-05:00",
            commitCount: 7, isDirty: false
        ))
        let unavailable = GitMetadataRenderer.swiftSource(for: .unknown)

        // a field's type must not depend on whether its value exists
        for source in [available, unavailable] {
            #expect(source.contains("public static let commitCount: Int? ="))
            #expect(source.contains("public static let commitHash: String? ="))
            #expect(source.contains("public static let isDirty: Bool ="))
        }
        #expect(available.contains("public static let commitCount: Int? = 7"))
        #expect(unavailable.contains("public static let commitCount: Int? = nil"))
        #expect(available.contains("public static let branch: String? = \"main\""))
        #expect(unavailable.contains("public static let branch: String? = nil"))
    }

    @Test("rendering is deterministic")
    func renderingIsDeterministic() {
        let metadata = GitMetadata(commitHash: "abc", shortCommitHash: "abc", branch: "main", isDirty: true)
        #expect(GitMetadataRenderer.swiftSource(for: metadata) == GitMetadataRenderer.swiftSource(for: metadata))
    }

    @Test("escapes quotes, backslashes, and control characters")
    func escapesSurprisingValues() {
        // git ref names may contain quotes; the generated literal must survive
        let metadata = GitMetadata(commitHash: "abc", branch: "we\"ird\\branch")
        let source = GitMetadataRenderer.swiftSource(for: metadata)
        #expect(source.contains(#"public static let branch: String? = "we\"ird\\branch""#))

        let controls = GitMetadataRenderer.swiftSource(for: GitMetadata(commitHash: "abc", branch: "line1\nline2"))
        #expect(controls.contains(#"public static let branch: String? = "line1\nline2""#))
        // and no raw newline leaks into the literal
        #expect(!controls.contains("branch: String? = \"line1\n"))
    }

    @Test("writeIfChanged only writes when the content differs")
    func writeIfChangedIsQuiet() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitmeta-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nested/GitProvenance.swift")

        let wrote = try GitMetadataRenderer.writeIfChanged("first", to: file.path)
        #expect(wrote)
        let rewrote = try GitMetadataRenderer.writeIfChanged("first", to: file.path)
        #expect(!rewrote, "identical content must not be rewritten")
        let changed = try GitMetadataRenderer.writeIfChanged("second", to: file.path)
        #expect(changed)
        #expect(try String(contentsOf: file, encoding: .utf8) == "second")
    }
}

// MARK: - probe (requires git)

/// git is a hard requirement for the probe's own tests; on a machine without
/// it the suite reports skipped rather than failing.
private let gitAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/git")

@Suite("Git metadata probe", .enabled(if: gitAvailable), .serialized)
struct GitMetadataProbeTests {

    /// run git in `directory` under a controlled environment (no system/global
    /// config, no signing) so the tests behave identically on any machine.
    @discardableResult
    private func git(_ arguments: [String], in directory: String) async throws -> (status: Int32, output: String) {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_AUTHOR_NAME"] = "test"
        environment["GIT_AUTHOR_EMAIL"] = "test@example.com"
        environment["GIT_COMMITTER_NAME"] = "test"
        environment["GIT_COMMITTER_EMAIL"] = "test@example.com"
        let outcome = try await Subprocess.capture(
            "/usr/bin/git",
            ["-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"] + arguments,
            workingDirectory: directory,
            environment: environment
        )
        return (outcome.exitCode, outcome.stdout + outcome.stderr)
    }

    /// an initialized repository with one commit and one tracked file.
    private func makeRepository() async throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitmeta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.path
        #expect(FileManager.default.createFile(atPath: "\(path)/file.swift", contents: Data("let a = 1\n".utf8)))
        try await git(["init", "-q"], in: path)
        try await git(["add", "."], in: path)
        try await git(["commit", "-q", "-m", "first"], in: path)
        return path
    }

    @Test("collects commit, branch, and count from a real repository")
    func collectsFromRepository() async throws {
        let path = try await makeRepository()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let head = try await git(["rev-parse", "HEAD"], in: path).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = try await git(["rev-parse", "--short", "HEAD"], in: path).output.trimmingCharacters(in: .whitespacesAndNewlines)

        let metadata = await GitMetadataProbe.collect(at: path)
        #expect(metadata.isAvailable)
        #expect(metadata.commitHash == head)
        #expect(metadata.shortCommitHash == short)
        #expect(metadata.branch == "main")
        #expect(metadata.commitCount == 1)
        #expect(metadata.commitDate != nil)
        #expect(!metadata.isDirty, "a fresh checkout is clean")
        // with no tags, `describe --always` is the abbreviated hash
        #expect(metadata.describe == short)
        #expect(metadata.tag == nil)
    }

    @Test("reports a dirty working tree for tracked and untracked changes")
    func reportsDirtyTree() async throws {
        let path = try await makeRepository()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try "let a = 2\n".write(toFile: "\(path)/file.swift", atomically: true, encoding: .utf8)
        let modified = await GitMetadataProbe.collect(at: path)
        #expect(modified.isDirty, "a modified tracked file is dirty")

        try await git(["checkout", "--", "file.swift"], in: path)
        let restored = await GitMetadataProbe.collect(at: path)
        #expect(!restored.isDirty)

        try "new\n".write(toFile: "\(path)/untracked.swift", atomically: true, encoding: .utf8)
        let untracked = await GitMetadataProbe.collect(at: path)
        #expect(untracked.isDirty, "an untracked file is dirty")
    }

    @Test("reports a tag when one is reachable")
    func reportsTag() async throws {
        let path = try await makeRepository()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await git(["tag", "v9.9.9"], in: path)

        let metadata = await GitMetadataProbe.collect(at: path)
        #expect(metadata.tag == "v9.9.9")
        #expect(metadata.describe == "v9.9.9")
    }

    @Test("degrades to unknown outside a repository")
    func degradesOutsideRepository() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitmeta-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let metadata = await GitMetadataProbe.collect(at: directory.path)
        #expect(metadata == .unknown)
        #expect(!metadata.isAvailable)
    }

    @Test("degrades to unknown when git cannot be resolved")
    func degradesWithoutGit() async throws {
        let metadata = await GitMetadataProbe.collect(at: "/tmp", gitPath: "/nonexistent/git")
        #expect(metadata == .unknown)
    }
}