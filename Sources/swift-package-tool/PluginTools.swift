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

@MCPCommand(
    description: "extract the public API surface of a Swift package or source directory (declarations + conformances, compact JSON). read-only.",
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
        return try PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "build a Swift package (or one target) and return the authoritative structured result: pass/fail, warning/error counts, exit status.",
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
        var argv = ["build", try requiredAbsolutePath(path)]
        if let target, !target.isEmpty { argv += ["--target", target] }
        if warnings_only { argv.append("--warnings-only") }
        if errors_only { argv.append("--errors-only") }
        if let timeout_seconds { argv += ["--timeout", String(timeout_seconds)] }
        return try PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "run a Swift package's test suite and return the authoritative structured pass/fail result.",
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
        var argv = ["build", try requiredAbsolutePath(path), "--test"]
        if let filter, !filter.isEmpty { argv += ["--filter", filter] }
        if let timeout_seconds { argv += ["--timeout", String(timeout_seconds)] }
        return try PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "delete a package's build artifacts (cached dependencies are preserved unless purge_all is set).",
    name: "pkg_clean"
)
struct PkgClean {
    @Argument(description: "absolute path to the Swift package directory to clean")
    var path: String = ""

    @Flag(description: "DESTRUCTIVE: also delete all cached dependencies (re-fetched on the next build)")
    var purge_all: Bool = false

    func run() async throws -> String {
        var argv = ["clean", try requiredAbsolutePath(path)]
        if purge_all { argv.append("--purge-all") }
        return try PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "validate docc symbol references in Swift sources and return warnings with locations. read-only.",
    name: "pkg_docc_check"
)
struct PkgDoccCheck {
    @Argument(description: "absolute path to the package directory or source files to check")
    var path: String = ""

    @Option(description: "maximum number of warnings to return")
    var limit: Int? = nil

    func run() async throws -> String {
        var argv = ["docc-check", try requiredAbsolutePath(path)]
        if let limit { argv += ["--limit", String(limit)] }
        return try PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "find force-unwrap `!` usage in Swift sources, classified by subkind. read-only.",
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
        return try PluginToolRunner.run(argv)
    }
}

@MCPCommand(
    description: "shallow syntax validation of Swift sources via SwiftParser diagnostics; exits non-zero when errors exist (a pass/fail gate). read-only.",
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
        return try PluginToolRunner.run(argv)
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
    version: "1.0.0",
    description: "Swift package inspection and audit tools (swift-package-tool) served over the plugin stdin/JSON protocol.",
    interface: .oneShot
)
struct SwiftPackageUtilityKitPlugin {
    @Tool var api = PkgApi()
    @Tool var build = PkgBuild()
    @Tool var test = PkgTest()
    @Tool var clean = PkgClean()
    @Tool var doccCheck = PkgDoccCheck()
    @Tool var forceUnwraps = PkgForceUnwraps()
    @Tool var validate = PkgValidate()
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
enum PluginToolRunner {
    static func run(_ argv: [String]) throws -> String {
        guard let executable = MCPManifestContext.resolveExecutablePath() else {
            throw PluginToolError("cannot locate this binary's own path")
        }
        // stdout/stderr are captured through temp files (never pipes — a
        // large undrained pipe deadlocks).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-package-tool-plugin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outURL = dir.appendingPathComponent("stdout")
        let errURL = dir.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = argv
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()
        process.waitUntilExit()
        try outHandle.close()
        try errHandle.close()

        let outData = (try? Data(contentsOf: outURL)) ?? Data()
        let errData = (try? Data(contentsOf: errURL)) ?? Data()
        return composeResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
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