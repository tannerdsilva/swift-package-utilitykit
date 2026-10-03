import Foundation

/// the git provenance of a working tree.
///
/// every field is optional: a source tarball, a machine without `git`, or a
/// repository with no commits all render as `nil` fields, and consumers fall
/// back to the plain release version instead of failing the build.
public struct GitMetadata: Equatable, Sendable {
    /// full commit hash (40 hex characters).
    public let commitHash: String?
    /// abbreviated commit hash.
    public let shortCommitHash: String?
    /// current branch, or `nil` on a detached HEAD.
    public let branch: String?
    /// nearest reachable tag, or `nil` when the commit is untagged.
    public let tag: String?
    /// `git describe --tags --always` — tag plus distance and hash, or the
    /// bare hash when no tag is reachable.
    public let describe: String?
    /// committer date of HEAD in ISO-8601.
    public let commitDate: String?
    /// number of commits reachable from HEAD.
    public let commitCount: Int?
    /// true when the working tree has staged, unstaged, or untracked changes.
    public let isDirty: Bool

    public init(
        commitHash: String? = nil,
        shortCommitHash: String? = nil,
        branch: String? = nil,
        tag: String? = nil,
        describe: String? = nil,
        commitDate: String? = nil,
        commitCount: Int? = nil,
        isDirty: Bool = false
    ) {
        self.commitHash = commitHash
        self.shortCommitHash = shortCommitHash
        self.branch = branch
        self.tag = tag
        self.describe = describe
        self.commitDate = commitDate
        self.commitCount = commitCount
        self.isDirty = isDirty
    }

    /// no git information available — no repository, or no `git` executable.
    public static let unknown = GitMetadata()

    /// true when a commit was identified, the minimum needed for provenance.
    public var isAvailable: Bool { commitHash != nil }
}

/// collects git provenance with `git` plumbing commands.
///
/// collection never throws: a missing executable, a missing repository, or a
/// failing command all degrade to `.unknown` fields, because a build must not
/// fail over metadata. `--print` on the tool surfaces what was and was not
/// available.
public enum GitMetadataProbe {
    /// the conventional git location, tried before falling back to `PATH`.
    public static let defaultGitPath = "/usr/bin/git"

    /// environment every probe runs under: no system config, no terminal
    /// prompts, no index locks (a metadata read must never write to the repo),
    /// and stable (locale-independent) output.
    static let probeEnvironment = [
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0",
        "LC_ALL": "C",
    ]

    /// resolve the git command to run: an explicit path, else the conventional
    /// `/usr/bin/git`, else `git` on `PATH` (via `/usr/bin/env`). nil when git
    /// cannot be found at all.
    static func resolveCommand(explicit: String?) -> (executable: String, leadingArguments: [String])? {
        let fileManager = FileManager.default
        if let explicit {
            return fileManager.isExecutableFile(atPath: explicit) ? (explicit, []) : nil
        }
        if fileManager.isExecutableFile(atPath: defaultGitPath) { return (defaultGitPath, []) }
        let env = "/usr/bin/env"
        if fileManager.isExecutableFile(atPath: env) { return (env, ["git"]) }
        return nil
    }

    public static func collect(
        at directory: String,
        gitPath: String? = nil
    ) -> GitMetadata {
        guard let command = resolveCommand(explicit: gitPath) else { return .unknown }

        let directory = NSString(string: directory).standardizingPath

        // every command targets the repository explicitly; safe.directory
        // covers repositories owned by another user (containers, CI mounts)
        func git(_ arguments: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.leadingArguments
                + ["-c", "safe.directory=\(directory)", "-C", directory] + arguments
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in probeEnvironment { environment[key] = value }
            process.environment = environment

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return nil
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }

        // the branch is independent of HEAD resolving to a commit, so an empty
        // repository still reports where it is checked out
        let branch = git(["symbolic-ref", "--short", "-q", "HEAD"])
        guard let commitHash = git(["rev-parse", "HEAD"]) else {
            return GitMetadata(branch: branch)
        }

        return GitMetadata(
            commitHash: commitHash,
            shortCommitHash: git(["rev-parse", "--short", "HEAD"]),
            branch: branch,
            tag: git(["describe", "--tags", "--abbrev=0"]),
            describe: git(["describe", "--tags", "--always"]),
            commitDate: git(["log", "-1", "--format=%cI"]),
            commitCount: git(["rev-list", "--count", "HEAD"]).flatMap(Int.init),
            isDirty: git(["status", "--porcelain"]) != nil
        )
    }
}