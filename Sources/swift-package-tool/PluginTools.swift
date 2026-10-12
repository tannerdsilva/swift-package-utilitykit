//===----------------------------------------------------------------------===//
//
// swift-package-utilitykit
//
// Copyright (c) 2024 and the swift-package-utilitykit project authors
// Licensed under the MIT License
//
// See LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import Foundation
import MCP
import SubprocessCore

// MARK: - Tool errors + argument validation

/// Argument problems are model-actionable, so they become `Error: …` result
/// text (the plugin dialect maps thrown errors into the harness envelope)
/// rather than CLI diagnostics.
struct PluginToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The required absolute-path argument (expands `~`; rejects relative paths,
/// because harnesses run plugin tools from the plugin directory).
func requiredAbsolutePath(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw PluginToolError(
            "'path' is required — pass the absolute path to the Swift package or source directory")
    }
    let expanded = (trimmed as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else {
        throw PluginToolError(
            "'path' must be an absolute path (got '\(raw)') — plugin tools run from the plugin directory")
    }
    return expanded
}

// MARK: - The tool set
//
// One `@MCPCommand` per agent-facing tool. The declarations generate the JSON
// Schema, the typed dispatch, and the `{"tool","args"}` ⇄ `{"result"}`
// envelope (via the host's plugin dialect); each `run()` maps its typed
// parameters onto the CLI subcommand that implements it — the CLI stays the
// contract, and no analysis logic is duplicated here.
//
// The surface is ONE vocabulary with the CLI: the eleven read-only/audit tools
// (`pkg_overview`, `pkg_security_scan`, `pkg_targets`, `pkg_dependencies`,
// `pkg_doc_coverage`, `pkg_force_unwraps`, `pkg_validate`, `pkg_public_api`,
// plus `pkg_build`/`pkg_test`/`pkg_clean`), plus the twelve `pkg_edit_*` tools
// (see `PluginEditTools.swift`). Every name carries the words the request will
// use: "give me an overview" → `pkg_overview`, "scan for security problems" →
// `pkg_security_scan`, "documentation coverage" → `pkg_doc_coverage`, "the
// public API" → `pkg_public_api`. The rename set is pinned by the surface test
// and was validated against small models before shipping (see
// `.hermes/plans/*-v3-clarity.md`).
//
// Build/test/clean are the audit-safe faces of their subcommands: `pkg_build`
// and `pkg_test` run isolated (fresh ephemeral scratch, the package's real
// `.build` untouched) and `pkg_clean` sweeps only audit residue — an agent can
// never destroy a consumer's build products through this surface.

@MCPCommand(
    description: "build a Swift package (or one target) and return a structured verdict: pass/fail, error/warning counts with diagnostics, exit status. a real cold compile in an isolated scratch dir - the slowest tool, seconds to minutes. a failed build reports through the MCP isError flag; the package's real .build is never touched.",
    name: "pkg_build"
)
struct PkgBuild {
    @Argument(description: "absolute path to the Swift package directory to build")
    var path: String = ""

    @Option(description: "build only this target (faster than a full build)")
    var target: String? = nil

    @Flag(description: "output only diagnostics, summary, and exit status")
    var warnings_only: Bool = false

    @Flag(description: "output only errors, summary, and exit status")
    var errors_only: Bool = false

    @Option(description: "build timeout in seconds")
    var timeout_seconds: Int? = nil

    func run() async throws -> String {
        var argv = ["build", try requiredAbsolutePath(path), "--isolated"]
        if let target, !target.isEmpty { argv += ["--target", target] }
        if warnings_only { argv.append("--warnings-only") }
        if errors_only { argv.append("--errors-only") }
        if let timeout_seconds { argv += ["--timeout", String(timeout_seconds)] }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "scan a Swift package's source code for security problems and risky patterns: unsafe pointers, force unwraps, process safety, and hardcoded secrets. returns findings with severity counts, grouped by category. use compact=true for a quick triage. read-only; answers in seconds.",
    name: "pkg_security_scan"
)
struct PkgSecurityScan {
    @Argument(description: "absolute path to the Swift package directory or source files to scan")
    var path: String = ""

    @Option(
        description: "scan categories to run. default: all.",
        enumValues: ["unsafe_pointers", "force_unwraps", "process_safety", "secrets", "all"]
    )
    var categories: [String]? = nil

    @Flag(description: "return counts and top-5 findings only per category")
    var compact: Bool = false

    func run() async throws -> String {
        var argv = ["security-scan", try requiredAbsolutePath(path)]
        if let categories, !categories.isEmpty {
            argv += ["--categories", categories.joined(separator: ",")]
        }
        if compact { argv.append("--compact") }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "list a Swift package's dependencies (the external packages it requires) with requirement kinds and pinned versions. use compact=true for name, kind, and version only. read-only; answers in seconds.",
    name: "pkg_dependencies"
)
struct PkgDependencies {
    @Argument(description: "absolute path to the Swift package directory or Package.swift")
    var path: String = ""

    @Flag(description: "return name, requirement kind, and pinned version only")
    var compact: Bool = false

    func run() async throws -> String {
        var argv = ["package-dependencies", try requiredAbsolutePath(path)]
        if compact { argv.append("--compact") }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "list a Swift package's targets (its modules), with resolved source paths, file counts, line counts, and symbol heatmaps. use compact=true for names, types, files, and lines only. read-only; answers in seconds.",
    name: "pkg_targets"
)
struct PkgTargets {
    @Argument(description: "absolute path to the Swift package directory or Package.swift")
    var path: String = ""

    @Flag(description: "return name, type, file count, and line count only")
    var compact: Bool = false

    func run() async throws -> String {
        var argv = ["targets", try requiredAbsolutePath(path)]
        if compact { argv.append("--compact") }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "run a Swift package's test suite and return a structured verdict: pass/fail, executed/failed test counts, exit status. a real cold compile-and-run in an isolated scratch dir, minutes. a failed run reports through the MCP isError flag; the package's real .build is never touched.",
    name: "pkg_test"
)
struct PkgTest {
    @Argument(description: "absolute path to the Swift package directory to test")
    var path: String = ""

    @Option(description: "test filter (passed to swift test --filter)")
    var filter: String? = nil

    @Option(description: "test timeout in seconds")
    var timeout_seconds: Int? = nil

    func run() async throws -> String {
        var argv = ["test", try requiredAbsolutePath(path), "--isolated"]
        if let filter, !filter.isEmpty { argv += ["--filter", filter] }
        if let timeout_seconds { argv += ["--timeout", String(timeout_seconds)] }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "delete a Swift package's stale audit scratch: temporary build folders left behind by crashed runs (older than 1h) plus legacy residue. non-destructive: the package's real build products and sources are never touched. answers in seconds.",
    name: "pkg_clean"
)
struct PkgClean {
    @Argument(description: "absolute path to the Swift package directory to sweep")
    var path: String = ""

    func run() async throws -> String {
        let argv = ["clean", try requiredAbsolutePath(path), "--audit"]
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "measure how much of a Swift package is documented: /// doc-comment coverage over its declarations, the uncovered-symbol list, and an inventory of its DocC catalogs. read-only; answers in seconds.",
    name: "pkg_doc_coverage"
)
struct PkgDocCoverage {
    @Argument(description: "absolute path to the package directory or source files to check")
    var path: String = ""

    @Option(description: "maximum number of uncovered symbols to list (the count is always the full total)")
    var limit: Int? = nil

    func run() async throws -> String {
        var argv = ["doc-coverage", try requiredAbsolutePath(path)]
        if let limit { argv += ["--limit", String(limit)] }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "get a complete overview of a Swift package in one call: targets, dependencies, security findings, build result, test result, documentation coverage, README, and git state, plus a one-line summary. use when starting work on an unfamiliar package, or when you need the big picture and do not yet know which specific check matters. slow: performs a real build and test run. use compact=true for the summary only.",
    name: "pkg_overview"
)
struct PkgOverview {
    @Argument(description: "absolute path to the Swift package directory to inspect")
    var path: String = ""

    @Flag(description: "return the orientation summary only (counts + verdicts)")
    var compact: Bool = false

    func run() async throws -> String {
        var argv = ["overview", try requiredAbsolutePath(path)]
        if compact { argv.append("--compact") }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "extract the public API surface of a Swift package or source directory: declarations plus their conformances. set include_internal=true to also include internal declarations. read-only; answers in seconds.",
    name: "pkg_public_api"
)
struct PkgPublicApi {
    @Argument(description: "absolute path to the Swift package directory or source files to analyze")
    var path: String = ""

    @Flag(description: "include internal declarations (default: public only)")
    var include_internal: Bool = false

    @Option(description: "maximum number of declarations to return")
    var limit: Int? = nil

    func run() async throws -> String {
        var argv = ["public-api", try requiredAbsolutePath(path)]
        if include_internal { argv.append("--include-internal") }
        if let limit { argv += ["--limit", String(limit)] }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "find force-unwrap `!` usage in Swift source files, classified by subkind. read-only; answers in seconds.",
    name: "pkg_force_unwraps"
)
struct PkgForceUnwraps {
    @Argument(description: "absolute path to the package directory or source files to scan")
    var path: String = ""

    @Option(description: "maximum number of findings to return")
    var limit: Int? = nil

    func run() async throws -> String {
        var argv = ["force-unwraps", try requiredAbsolutePath(path)]
        if let limit { argv += ["--limit", String(limit)] }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "syntax check: parse Swift source files and report parser diagnostics as a pass/fail gate. errors present is a failure, reported through the MCP isError flag. read-only; answers in seconds.",
    name: "pkg_validate"
)
struct PkgValidate {
    @Argument(description: "absolute path to the package directory or source files to validate")
    var path: String = ""

    @Flag(description: "include warnings in addition to errors")
    var warnings: Bool = false

    func run() async throws -> String {
        var argv = ["validate", try requiredAbsolutePath(path)]
        if warnings { argv.append("--warnings") }
        return try await PluginToolRunner.run(argv)
    }
}

// MARK: - The one-shot host

/// The compiled harness surface: one `@MCPCommand` per agent-facing tool.
///
/// The declaration is here for the typed ``MCPToolDispatcher`` it generates;
/// its own generated `main()` is intentionally unused — process entry is the
/// `plugin` subcommand (`PluginCommand.swift` → `PluginHost.run()`), which
/// constructs the host with the harness invocation prefix so generated
/// manifests keep the `plugin` entry argv.
@MCPApplication(
    name: "swift-package-utilitykit",
    version: "3.0.0",
    description: "Swift package inspection, audit, and source-editing tools (swift-package-tool) served over the plugin stdin/JSON protocol.",
    interface: .oneShot
)
struct SwiftPackageUtilityKitPlugin {
    @Tool var build = PkgBuild()
    @Tool var securityScan = PkgSecurityScan()
    @Tool var dependencies = PkgDependencies()
    @Tool var targets = PkgTargets()
    @Tool var test = PkgTest()
    @Tool var clean = PkgClean()
    @Tool var docCoverage = PkgDocCoverage()
    @Tool var overview = PkgOverview()
    @Tool var publicApi = PkgPublicApi()
    @Tool var forceUnwraps = PkgForceUnwraps()
    @Tool var validate = PkgValidate()
    @Tool var editReplace = PkgEditReplace()
    @Tool var editRename = PkgEditRename()
    @Tool var editInsert = PkgEditInsert()
    @Tool var editDelete = PkgEditDelete()
    @Tool var editPrepend = PkgEditPrepend()
    @Tool var editAppend = PkgEditAppend()
    @Tool var editAddImport = PkgEditAddImport()
    @Tool var editAddConformance = PkgEditAddConformance()
    @Tool var editAddMember = PkgEditAddMember()
    @Tool var editWrap = PkgEditWrap()
    @Tool var editSort = PkgEditSort()
    @Tool var editBatch = PkgEditBatch()
}

/// The one-shot host entry behind `swift-package-tool plugin`.
///
/// `runMain()` maps failures onto the exit contract (exit `1` with a stderr
/// diagnostic; stdout carries results only).
enum PluginHost {
    static func run() async {
        var configuration = MCPStdinHost<SwiftPackageUtilityKitPlugin>.Configuration()
        configuration.manifestInvocationArguments = ["plugin"]
        await MCPStdinHost(
            name: "swift-package-utilitykit",
            version: SwiftCodeQuery.packageVersion,
            description: "Swift package inspection, audit, and source-editing tools (swift-package-tool) served over the plugin stdin/JSON protocol.",
            dispatcher: SwiftPackageUtilityKitPlugin(),
            configuration: configuration
        ).runMain()
    }
}

// MARK: - Subcommand execution

/// Runs the CLI subcommand behind a tool and returns its stdout — the CLI
/// stays the contract, so no analysis logic is duplicated in the tool layer.
///
/// A non-zero subcommand exit is a real failure, not a payload: the runner
/// THROWS, so the host router reports it through the framework's documented
/// `isError` channel (the plugin dialect renders the thrown message as
/// `Error: <payload>`, with the structured payload intact after the prefix).
/// A consumer never has to parse prose to learn a tool failed.
enum PluginToolRunner {
    static func run(_ argv: [String]) async throws -> String {
        guard let executable = MCPManifestContext.resolveExecutablePath() else {
            throw PluginToolError("cannot locate this binary's own path")
        }
        // the spawn layer drains stdout and stderr concurrently, so a large
        // undrained pipe cannot deadlock and no temp files are needed.
        let outcome = try await Subprocess.capture(executable, argv)
        // composeResult is the single source of the payload text: stdout
        // verbatim when non-empty (structured verdicts live there), otherwise
        // stderr with the exit status. Its payload-preserving behaviour is the
        // contract and must not change.
        let result = composeResult(
            status: outcome.exitCode,
            stdout: outcome.stdout,
            stderr: outcome.stderr
        )
        guard outcome.exitCode == 0 else {
            // carry the payload text through the throw so it survives the
            // `Error: ` prefix; `pkg_build`'s succeeded:false rides along.
            throw PluginToolError(result)
        }
        return result
    }

    /// The CLI output IS the tool result: prefer stdout verbatim (structured
    /// payloads carry their own pass/fail), fall back to stderr with the exit
    /// status when stdout is empty (a crash or usage error).
    static func composeResult(status: Int32, stdout: String, stderr: String) -> String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !err.isEmpty { return "Error (exit \(status)): " + String(err.prefix(4_000)) }
        return status == 0
            ? "(no output)"
            : "Error: command exited \(status) with no output"
    }
}