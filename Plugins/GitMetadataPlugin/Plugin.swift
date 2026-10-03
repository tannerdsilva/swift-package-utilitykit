import Foundation
import PackagePlugin

/// generates `GitProvenance.swift` — the commit, branch, tag, and dirty state
/// of the package's git checkout — for the target that opts in.
///
/// design notes, for anyone copying this:
///   - the plugin is a thin adapter: all logic (probe, render, write-if-
///     changed) lives in `GitMetadataCore`, which is unit-testable, so the
///     plugin itself stays a declaration of build inputs and outputs.
///   - the command is a `.buildCommand`, not a `.prebuildCommand`: prebuild
///     commands cannot depend on a tool built from this package's sources.
///   - inputs are the git state files a commit/checkout/stage touches *plus
///     the target's own sources*, so editing a source refreshes `isDirty`;
///     outputs are the generated file, so a no-op build neither re-runs git
///     nor recompiles the target.
///   - no git (tarball, bare container) is not an error: the tool renders nil
///     fields and the build proceeds.
@main
struct GitMetadataPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = try context.tool(named: "git-metadata-tool")
        let generated = context.pluginWorkDirectoryURL.appendingPathComponent("GitProvenance.swift")
        let packageDirectory = context.package.directoryURL

        let gitState = gitStateFiles(in: packageDirectory)
        let sources = target.sourceModule.map { $0.sourceFiles.map(\.url) } ?? []

        return [
            .buildCommand(
                displayName: "Generating \(generated.lastPathComponent)",
                executable: tool.url,
                arguments: ["--repo", packageDirectory.path, "--output", generated.path],
                inputFiles: gitState + sources,
                outputFiles: [generated]
            )
        ]
    }

    /// the `.git` files that change when a commit lands, a branch moves, or the
    /// index is touched — the cache-key half of "did the provenance change".
    /// absent files are simply not declared.
    private func gitStateFiles(in packageDirectory: URL) -> [URL] {
        let fileManager = FileManager.default
        let gitDirectory = packageDirectory.appendingPathComponent(".git")

        var candidates = [".git/HEAD", ".git/packed-refs", ".git/index", ".git/logs/HEAD"]
            .map { packageDirectory.appendingPathComponent($0) }

        // a symbolic HEAD names the branch ref whose value actually changes on
        // each commit; declare it so commits re-trigger generation
        if let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8),
           head.hasPrefix("ref: ") {
            let ref = head.dropFirst("ref: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !ref.isEmpty {
                candidates.append(gitDirectory.appendingPathComponent(ref))
            }
        }

        return candidates.filter { fileManager.fileExists(atPath: $0.path) }
    }
}