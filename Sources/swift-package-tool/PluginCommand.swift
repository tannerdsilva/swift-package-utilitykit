import Foundation
import ArgumentParser

// MARK: - plugin mode (agent tool protocol over stdin/stdout)

/// one agent-facing tool: its manifest metadata plus how it maps onto a
/// subcommand invocation of this binary.
struct PluginToolSpec {
    let name: String
    let description: String
    /// JSON Schema for the tool's parameters (the bare object form harnesses
    /// expect — not the OpenAI `{"type": "function", ...}` envelope).
    let schema: [String: Any]
    let makeArgv: ([String: Any]) throws -> [String]
}

/// argument problems are model-actionable, so they become
/// `{"result": "Error: ..."}` text rather than CLI diagnostics.
struct PluginModeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// the agent-facing tool table: name, schema, and the subcommand mapping.
///
/// single source of truth — `--manifest` renders this table into the harness
/// plugin manifest, and the dispatch path executes it. adding a harness-facing
/// capability is one entry here.
///
/// the table is COMPUTED, not stored: each access builds immutable values, so
/// there is no global mutable state for the concurrency checker to police and
/// no `@unchecked Sendable` escape hatch is needed.
enum PluginTools {

    /// required absolute path argument (expands `~`; rejects relative paths,
    /// because harnesses run plugin tools from the plugin directory).
    static func path(_ args: [String: Any], key: String = "path") throws -> String {
        guard let raw = (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw PluginModeError(
                "'\(key)' is required — pass the absolute path to the Swift package or source directory")
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw PluginModeError(
                "'\(key)' must be an absolute path (got '\(raw)') — plugin tools run from the plugin directory")
        }
        return expanded
    }

    static func optionalInt(_ args: [String: Any], key: String) -> Int? {
        (args[key] as? Int) ?? (args[key] as? Double).map { Int($0) }
    }

    static var all: [PluginToolSpec] {
        [api, build, test, clean, doccCheck, forceUnwraps, validate]
    }

    static var api: PluginToolSpec {
        PluginToolSpec(
            name: "pkg_api",
            description: "extract the public API surface of a Swift package or source directory "
                + "(declarations + conformances, compact JSON). read-only.",
            schema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "absolute path to the Swift package directory or source files to analyze"],
                    "include_internal": ["type": "boolean", "description": "include internal declarations (default: public only)"],
                    "limit": ["type": "integer", "description": "maximum number of declarations to return"],
                ],
                "required": ["path"],
            ],
            makeArgv: { args in
                var argv = ["api", try path(args)]
                if args["include_internal"] as? Bool == true { argv.append("--include-internal") }
                if let limit = optionalInt(args, key: "limit") { argv += ["--limit", String(limit)] }
                return argv
            }
        )
    }

    static var build: PluginToolSpec {
        PluginToolSpec(
            name: "pkg_build",
            description: "build a Swift package (or one target) and return the authoritative "
                + "structured result: pass/fail, warning/error counts, exit status.",
            schema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "absolute path to the Swift package directory to build"],
                    "target": ["type": "string", "description": "build only this target (faster than a full build)"],
                    "warnings_only": ["type": "boolean", "description": "output only diagnostics, summary, and exit status"],
                    "errors_only": ["type": "boolean", "description": "output only errors, summary, and exit status"],
                    "timeout_seconds": ["type": "integer", "description": "build timeout in seconds"],
                ],
                "required": ["path"],
            ],
            makeArgv: { args in
                var argv = ["build", try path(args)]
                if let target = args["target"] as? String, !target.isEmpty { argv += ["--target", target] }
                if args["warnings_only"] as? Bool == true { argv.append("--warnings-only") }
                if args["errors_only"] as? Bool == true { argv.append("--errors-only") }
                if let timeout = optionalInt(args, key: "timeout_seconds") { argv += ["--timeout", String(timeout)] }
                return argv
            }
        )
    }

    static var test: PluginToolSpec {
        PluginToolSpec(
            name: "pkg_test",
            description: "run a Swift package's test suite and return the authoritative structured "
                + "pass/fail result.",
            schema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "absolute path to the Swift package directory to test"],
                    "filter": ["type": "string", "description": "test filter (passed to swift test --filter)"],
                    "timeout_seconds": ["type": "integer", "description": "test timeout in seconds"],
                ],
                "required": ["path"],
            ],
            makeArgv: { args in
                var argv = ["build", try path(args), "--test"]
                if let filter = args["filter"] as? String, !filter.isEmpty { argv += ["--filter", filter] }
                if let timeout = optionalInt(args, key: "timeout_seconds") { argv += ["--timeout", String(timeout)] }
                return argv
            }
        )
    }

    static var clean: PluginToolSpec {
        PluginToolSpec(
            name: "pkg_clean",
            description: "delete a package's build artifacts (cached dependencies are preserved "
                + "unless purge_all is set).",
            schema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "absolute path to the Swift package directory to clean"],
                    "purge_all": ["type": "boolean", "description": "DESTRUCTIVE: also delete all cached dependencies (re-fetched on the next build)"],
                ],
                "required": ["path"],
            ],
            makeArgv: { args in
                var argv = ["clean", try path(args)]
                if args["purge_all"] as? Bool == true { argv.append("--purge-all") }
                return argv
            }
        )
    }

    static var doccCheck: PluginToolSpec {
        PluginToolSpec(
            name: "pkg_docc_check",
            description: "validate docc symbol references in Swift sources and return warnings "
                + "with locations. read-only.",
            schema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "absolute path to the package directory or source files to check"],
                    "limit": ["type": "integer", "description": "maximum number of warnings to return"],
                ],
                "required": ["path"],
            ],
            makeArgv: { args in
                var argv = ["docc-check", try path(args)]
                if let limit = optionalInt(args, key: "limit") { argv += ["--limit", String(limit)] }
                return argv
            }
        )
    }

    static var forceUnwraps: PluginToolSpec {
        PluginToolSpec(
            name: "pkg_force_unwraps",
            description: "find force-unwrap `!` usage in Swift sources, classified by subkind. read-only.",
            schema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "absolute path to the package directory or source files to scan"],
                    "limit": ["type": "integer", "description": "maximum number of findings to return"],
                ],
                "required": ["path"],
            ],
            makeArgv: { args in
                var argv = ["force-unwraps", try path(args)]
                if let limit = optionalInt(args, key: "limit") { argv += ["--limit", String(limit)] }
                return argv
            }
        )
    }

    static var validate: PluginToolSpec {
        PluginToolSpec(
            name: "pkg_validate",
            description: "shallow syntax validation of Swift sources via SwiftParser diagnostics; "
                + "exits non-zero when errors exist (a pass/fail gate). read-only.",
            schema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "absolute path to the package directory or source files to validate"],
                    "warnings": ["type": "boolean", "description": "include warnings in addition to errors"],
                ],
                "required": ["path"],
            ],
            makeArgv: { args in
                var argv = ["validate", try path(args)]
                if args["warnings"] as? Bool == true { argv.append("--warnings") }
                return argv
            }
        )
    }
}

/// `swift-package-tool plugin` — serve one agent tool invocation over
/// stdin/stdout (the manifest+executable plugin protocol).
///
/// reads a single JSON request on stdin and writes a single JSON response on
/// stdout, so a harness can drive this binary directly with no interpreter
/// shim in between:
///
///     stdin:  {"tool": "pkg_api", "args": {"path": "/abs/path/to/pkg"}}
///     stdout: {"result": "<the subcommand's output>"}
///
/// a tool executes by re-invoking this same binary with the mapped subcommand
/// argv and capturing its output — the CLI stays the contract, and no
/// analysis logic is duplicated here. `--manifest` renders the same tool
/// table into the harness plugin manifest.
struct PluginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Serve one agent tool invocation over stdin/stdout (plugin protocol).",
        discussion: """
        Reads {"tool": "<name>", "args": {...}} on stdin, runs the mapped \
        subcommand, and writes {"result": "<string>"} on stdout. \
        `--manifest` prints the harness plugin manifest (tools + schemas) for \
        this binary instead — pipe it into \
        <plugins-dir>/swift-package-utilitykit/manifest.json.
        """
    )

    @Flag(name: .customLong("manifest"), help: "Print the harness plugin manifest (tools + schemas) and exit.")
    var manifest = false

    mutating func run() throws {
        if manifest {
            try emitManifest()
            return
        }
        serveOne()
    }

    // MARK: - serving

    private func serveOne() {
        guard let request = Self.readRequest() else {
            Self.emit(["result": "Error: expected one JSON object on stdin: "
                + #"{"tool": "<name>", "args": {...}}"#])
            return
        }
        let tool = (request["tool"] as? String) ?? ""
        let args = (request["args"] as? [String: Any]) ?? [:]

        guard let spec = PluginTools.all.first(where: { $0.name == tool }) else {
            let names = PluginTools.all.map(\.name).joined(separator: ", ")
            Self.emit(["result": "Error: unknown tool '\(tool)'. available: \(names)"])
            return
        }

        let result: String
        do {
            let argv = try spec.makeArgv(args)
            let (status, stdout, stderr) = try Self.runSubcommand(argv)
            result = Self.composeResult(status: status, stdout: stdout, stderr: stderr)
        } catch let error as PluginModeError {
            result = "Error: \(error.description)"
        } catch {
            result = "Error: \(error)"
        }
        Self.emit(["result": result])
    }

    /// the CLI output IS the tool result: prefer stdout verbatim (structured
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

    // MARK: - subprocess capture

    /// run this same binary with `argv`; stdout/stderr are captured through
    /// temp files (never pipes — a large undrained pipe deadlocks).
    static func runSubcommand(_ argv: [String]) throws -> (Int32, String, String) {
        guard let executable = selfExecutablePath() else {
            throw PluginModeError("cannot locate this binary's own path")
        }
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
        return (process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    /// absolute path of the running binary (Bundle first; PATH-resolved
    /// `argv[0]` as fallback for odd invocations).
    static func selfExecutablePath() -> String? {
        if let path = Bundle.main.executablePath, path.hasPrefix("/") { return path }
        guard let argv0 = CommandLine.arguments.first, !argv0.isEmpty else { return nil }
        if argv0.hasPrefix("/") { return argv0 }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for dir in searchPath.split(separator: ":") {
            let candidate = "\(dir)/\(argv0)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - manifest

    /// render the arc harness plugin manifest (the format `~/.arc/plugins/
    /// <name>/manifest.json` expects) from the tool table, addressed to the
    /// running binary.
    private func emitManifest() throws {
        guard let executable = Self.selfExecutablePath() else {
            throw ValidationError("cannot locate this binary's own path for the manifest")
        }
        let tools: [[String: Any]] = PluginTools.all.map { spec in
            [
                "name": spec.name,
                "description": spec.description,
                "command": executable,
                "args": ["plugin"],
                "toolset": "swift-package-utilitykit",
                "schema": spec.schema,
            ]
        }
        let manifest: [String: Any] = [
            "name": "swift-package-utilitykit",
            "version": SwiftCodeQuery.packageVersion,
            "description": "Swift package inspection and audit tools (swift-package-tool) "
                + "served over the plugin stdin/JSON protocol.",
            "tools": tools,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    // MARK: - stdin / stdout

    static func readRequest() -> [String: Any]? {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func emit(_ payload: [String: Any]) {
        if let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]) {
            FileHandle.standardOutput.write(data)
        } else {
            FileHandle.standardOutput.write(Data(#"{"result": "Error: failed to encode plugin response"}"#.utf8))
        }
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}