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
// The surface is the package-inspector contract: the eight `pkg_*` tools a
// harness already consumes, plus three read-only extras (`pkg_api`,
// `pkg_force_unwraps`, `pkg_validate`) that the CLI has always offered, plus
// the `pkg_edit_*` family (see `PluginEditTools.swift`) that lets an agent
// EDIT Swift source over the same stdio transport the read-only tools use.
//
// Build/test/clean are the audit-safe faces of their subcommands: `pkg_build`
// and `pkg_test` run isolated (fresh ephemeral scratch, the package's real
// `.build` untouched) and `pkg_clean` sweeps only audit residue — an agent can
// never destroy a consumer's build products through this surface.

@MCPCommand(
    description: "build a Swift package (or one target) in an isolated scratch dir. performs a real cold compile - the slowest tool, seconds to minutes. a failed build reports through the MCP isError flag; the structured verdict (pass/fail, warning/error counts, exit status) is always returned. the package's real .build is never touched.",
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
    description: "scan a Swift package for security and code-quality issues (unsafe pointers, force unwraps, process safety, hardcoded secrets). returns unified findings with severity counts; use compact=true for a quick triage pass. read-only; answers in seconds.",
    name: "pkg_scan"
)
struct PkgScan {
    @Argument(description: "absolute path to the Swift package directory or source files to scan")
    var path: String = ""

    @Option(
        description: "scan categories to run. default: all.",
        enumValues: ["unsafe_ptrs", "force_unwraps", "process_safety", "secrets", "all"]
    )
    var categories: [String]? = nil

    @Flag(description: "return counts and top-5 findings only per category")
    var compact: Bool = false

    func run() async throws -> String {
        var argv = ["scan", try requiredAbsolutePath(path)]
        if let categories, !categories.isEmpty {
            argv += ["--categories", categories.joined(separator: ",")]
        }
        if compact { argv.append("--compact") }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "list a Swift package's resolved dependencies with requirement kinds and pinned versions. use compact=true for name/kind/version only. read-only; answers in seconds.",
    name: "pkg_list_dependencies"
)
struct PkgListDependencies {
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
    description: "list a Swift package's targets with resolved source paths, file counts, line counts and symbol heatmaps. use compact=true for name/type/files/lines only. read-only; answers in seconds.",
    name: "pkg_list_targets"
)
struct PkgListTargets {
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
    description: "run a Swift package's test suite in an isolated scratch dir - a real cold compile-and-run, seconds to minutes. a failed test run reports through the MCP isError flag; the structured verdict (pass/fail, executed/failed test counts, exit status) is always returned. the package's real .build is never touched.",
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
        var argv = ["build", try requiredAbsolutePath(path), "--test", "--isolated"]
        if let filter, !filter.isEmpty { argv += ["--filter", filter] }
        if let timeout_seconds { argv += ["--timeout", String(timeout_seconds)] }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "sweep a Swift package's stale audit build scratch (crashed-run leftovers older than 1h and legacy .build-audit residue). non-destructive: the package's real build products and sources are never touched. answers in seconds.",
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
    description: "inventory a Swift package's DocC catalogs and measure /// doc-comment coverage, with the uncovered-symbol list. read-only; answers in seconds.",
    name: "pkg_docc_check"
)
struct PkgDoccCheck {
    @Argument(description: "absolute path to the package directory or source files to check")
    var path: String = ""

    @Option(description: "maximum number of uncovered symbols to list (the count is always the full total)")
    var uncovered_limit: Int? = nil

    func run() async throws -> String {
        var argv = ["doc-coverage", try requiredAbsolutePath(path)]
        if let uncovered_limit { argv += ["--limit", String(uncovered_limit)] }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "one-call orientation on a Swift package: targets, dependencies, security findings, build and test verdicts, doc coverage, README intent, AGENTS.md and git state, plus a one-line summary. the first tool to reach for on an unfamiliar package: one round-trip returns the broad picture, but it also runs a real build+test, so reach for a granular pkg_* tool when you can stop early (fat-call vs thin-call trade-off, see the README). use compact=true for the summary only.",
    name: "pkg_inspector"
)
struct PkgInspector {
    @Argument(description: "absolute path to the Swift package directory to inspect")
    var path: String = ""

    @Flag(description: "return the orientation summary only (counts + verdicts)")
    var compact: Bool = false

    func run() async throws -> String {
        var argv = ["inspector", try requiredAbsolutePath(path)]
        if compact { argv.append("--compact") }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "extract the public API surface of a Swift package or source directory (declarations + conformances, compact JSON). read-only; answers in seconds.",
    name: "pkg_api"
)
struct PkgApi {
    @Argument(description: "absolute path to the Swift package directory or source files to analyze")
    var path: String = ""

    @Flag(description: "include internal declarations (default: public only)")
    var include_internal: Bool = false

    @Option(description: "maximum number of declarations to return")
    var limit: Int? = nil

    func run() async throws -> String {
        var argv = ["api", try requiredAbsolutePath(path)]
        if include_internal { argv.append("--include-internal") }
        if let limit { argv += ["--limit", String(limit)] }
        return try await PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "find force-unwrap `!` usage in Swift sources, classified by subkind. read-only; answers in seconds.",
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
    description: "shallow syntax validation of Swift sources via SwiftParser diagnostics - a pass/fail gate. read-only; answers in seconds. a failed validation (errors present) reports through the MCP isError flag.",
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
    version: "2.1.0",
    description: "Swift package inspection and audit tools (swift-package-tool) served over the plugin stdin/JSON protocol.",
    interface: .oneShot
)
struct SwiftPackageUtilityKitPlugin {
    @Tool var build = PkgBuild()
    @Tool var scan = PkgScan()
    @Tool var listDependencies = PkgListDependencies()
    @Tool var listTargets = PkgListTargets()
    @Tool var test = PkgTest()
    @Tool var clean = PkgClean()
    @Tool var doccCheck = PkgDoccCheck()
    @Tool var inspector = PkgInspector()
    @Tool var api = PkgApi()
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
            description: "Swift package inspection and audit tools (swift-package-tool) served over the plugin stdin/JSON protocol.",
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