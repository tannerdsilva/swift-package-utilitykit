import Foundation
import ArgumentParser
import SubprocessCore
import BuildOutputParsing

/// run `swift build` (or `swift test`) as a subprocess and reshape the
/// chaotic stdout/stderr stream into structured, LLM-friendly JSON.
///
/// the parser recognises:
///   - phase lines: `[N/M] Compiling|Emitting|Linking|...`
///   - diagnostics: `file:line:col: error|warning|note: message`
///   - multi-line diagnostic context (source snippet + caret)
///   - final summary: `Build complete!` or `Build failed`
///
/// everything else is collected as raw log lines so no information is lost.
///
/// with `--isolated` the whole run happens in a fresh ephemeral scratch dir
/// under `<pkg>/.build/swift-package-audit/` that the call removes when it
/// finishes (see ``AuditScratch``) — no persistent build state, and the
/// package's real `.build` products are never touched.
struct BuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Run swift build/test and return structured JSON."
    )

    @Argument(help: "Package directory to build.")
    var path: String = "."

    @Flag(name: .long, inversion: .prefixedNo, help: "Run tests instead of build.")
    var test = false

    @Option(name: .customLong("filter"), help: "Test filter (passed to swift test --filter).")
    var testFilter: String?

    @Option(name: .customLong("target"), help: "Build only this target.")
    var buildTarget: String?

    @Option(name: .long, help: "Extra args to pass to swift build/test.")
    var extraArgs: String?

    @Option(name: .long, help: "Timeout in seconds.")
    var timeout: Int = 600

    @Flag(name: .customLong("isolated"), help: "Build in a fresh ephemeral scratch under <pkg>/.build/swift-package-audit (no persistent build state; the real .build is untouched).")
    var isolated = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .long, help: "Output format: json, compact.")
    var outputFormat: OutputFormat?

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Flag(name: .customLong("warnings-only"), help: "Suppress phases and raw log — output only diagnostics, summary, and exit status.")
    var warningsOnly = false

    @Flag(name: .customLong("errors-only"), help: "Suppress phases, raw log, and warnings — output only errors, summary, and exit status.")
    var errorsOnly = false

    func run() async throws {
        if schema {
            print(BuildResult.jsonSchema)
            return
        }

        let request = BuildRequest(
            path: path.isEmpty ? "." : path,
            test: test,
            filter: testFilter,
            target: buildTarget,
            extraArgs: extraArgs,
            timeout: timeout,
            isolated: isolated
        )

        let result: BuildResult
        do {
            result = try await BuildRunner.execute(request)
        } catch SubprocessError.timedOut {
            let timedOut = BuildResult(
                ok: true,
                succeeded: false,
                exitCode: nil,
                duration: TimeInterval(timeout),
                phases: [],
                diagnostics: BuildDiagnostics(
                    errorCount: 0, warningCount: 0, noteCount: 0,
                    errors: [], warnings: [], notes: []
                ),
                summary: "build timed out after \(timeout)s",
                rawLog: "",
                testsTotal: nil,
                testsFailed: nil
            )
            try emit(timedOut)
            throw ExitCode(1)
        }

        var output = result
        if warningsOnly || errorsOnly {
            var diagnostics = result.diagnostics
            if errorsOnly {
                diagnostics = BuildDiagnostics(
                    errorCount: diagnostics.errorCount,
                    warningCount: 0,
                    noteCount: 0,
                    errors: diagnostics.errors,
                    warnings: [],
                    notes: []
                )
            }
            output = BuildResult(
                ok: result.ok,
                succeeded: result.succeeded,
                exitCode: result.exitCode,
                duration: result.duration,
                phases: [],
                diagnostics: diagnostics,
                summary: result.summary,
                rawLog: "",
                testsTotal: result.testsTotal,
                testsFailed: result.testsFailed
            )
        }

        try emit(output)

        // a build that failed or timed out is a tool failure — never report
        // success through the process exit code. the structured result on
        // stdout still carries the specifics (summary, diagnostics, exitCode).
        guard output.succeeded else {
            throw ExitCode(1)
        }
    }

    // MARK: - output

    private func emit(_ result: BuildResult) throws {
        let fmt: OutputFormat
        if prettyPrint {
            fmt = .json
        } else if let f = outputFormat {
            fmt = f
        } else {
            fmt = .compact
        }
        try writeOutput(try formatOutput([result], format: fmt), to: outputPath)
    }
}

// MARK: - the runner

/// one build/test invocation.
struct BuildRequest: Sendable {
    var path: String
    var test = false
    var filter: String?
    var target: String?
    var extraArgs: String?
    var timeout: Int = 600
    var isolated = false
}

/// the single home for build/test execution: spawn `swift build`/`swift test`,
/// parse the output, and (when isolated) own the ephemeral scratch.  shared by
/// the `build` subcommand and the inspector, so a verdict means the same thing
/// wherever it is produced.
enum BuildRunner {
    static func execute(_ request: BuildRequest) async throws -> BuildResult {
        let startTime = Date()
        let workingDirectory: String
        var scratch: String?
        if request.isolated {
            let resolved = try resolveExistingPath(request.path)
            let package = packageFileURL(for: resolved)
            guard FileManager.default.fileExists(atPath: package.path) else {
                throw ValidationError("no Package.swift found at \(package.path)")
            }
            let packageDir = package.deletingLastPathComponent().path
            workingDirectory = packageDir
            scratch = try AuditScratch.create(packageDir: packageDir)
        } else {
            workingDirectory = request.path
        }
        defer {
            if let scratch {
                AuditScratch.remove(runDirectory: scratch, packageDir: workingDirectory)
            }
        }

        // build the command line
        var args: [String] = ["swift"]
        if request.test {
            args.append("test")
            if let f = request.filter {
                args += ["--filter", f]
            }
        } else {
            args.append("build")
        }
        if let t = request.target {
            args += ["--target", t]
        }
        if let extra = request.extraArgs {
            args += splitBuildArgs(extra)
        }
        if let scratch {
            args += ["--scratch-path", scratch]
        }

        // run the subprocess through the package's one spawn path. the timeout
        // signals and reaps the child before throwing, so a timed-out build
        // never leaves a compiler running.
        let outcome = try await Subprocess.capture(
            "/usr/bin/env",
            args,
            workingDirectory: workingDirectory,
            timeout: .seconds(request.timeout)
        )

        let duration = Date().timeIntervalSince(startTime)
        let combined = outcome.stdout + "\n" + outcome.stderr

        // strip escape sequences once, up front: both the diagnostic parser and
        // rawLog consume the same cleaned text, so no escape byte can reach a
        // model and the parser is colour-blind (6.4.0 emits colour even when
        // both streams are pipes).
        let clean = BuildOutputParser.stripEscapeSequences(combined)
        let parsed = BuildOutputParser.parseBuildOutput(clean)
        let succeeded = outcome.exitCode == 0

        var testsTotal: Int?
        var testsFailed: Int?
        if request.test {
            (testsTotal, testsFailed) = BuildOutputParser.parseTestCounts(clean)
        }

        return BuildResult(
            ok: true,
            succeeded: succeeded,
            exitCode: Int(outcome.exitCode),
            duration: duration,
            phases: parsed.phases,
            diagnostics: parsed.diagnostics,
            summary: makeSummary(
                succeeded: succeeded, exitCode: Int(outcome.exitCode),
                diagnostics: parsed.diagnostics, duration: duration
            ),
            rawLog: String(clean.suffix(5000)),
            testsTotal: testsTotal,
            testsFailed: testsFailed
        )
    }

    static func makeSummary(succeeded: Bool, exitCode: Int, diagnostics: BuildDiagnostics, duration: TimeInterval) -> String {
        let status = succeeded ? "succeeded" : "failed"
        return "build \(status) (exit \(exitCode)); " +
               "\(diagnostics.errorCount) error(s), " +
               "\(diagnostics.warningCount) warning(s), " +
               "\(diagnostics.noteCount) note(s) " +
               "in \(String(format: "%.2f", duration))s"
    }

    /// simple argument splitter that respects quoted strings.
    private static func splitBuildArgs(_ input: String) -> [String] {
        var args: [String] = []
        var current = ""
        var inQuote = false
        for ch in input {
            if ch == "\"" {
                inQuote.toggle()
            } else if ch == " " && !inQuote {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }
}

// MARK: - output types

struct BuildResult: Codable, Sendable {
    let ok: Bool
    let succeeded: Bool
    let exitCode: Int?
    let duration: TimeInterval
    let phases: [BuildPhase]
    let diagnostics: BuildDiagnostics
    let summary: String
    let rawLog: String
    let testsTotal: Int?
    let testsFailed: Int?

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "BuildResult",
      "type": "object",
      "properties": {
        "ok":          { "type": "boolean", "description": "Tool ran without internal errors" },
        "succeeded":   { "type": "boolean", "description": "Build/test succeeded (exit code 0)" },
        "exitCode":    { "type": ["integer", "null"], "description": "Process exit code, or null on timeout" },
        "duration":    { "type": "number", "description": "Wall-clock duration in seconds" },
        "phases":      { "type": "array", "items": { "$ref": "#/definitions/BuildPhase" }, "description": "Build phases (compiling, linking, etc.)" },
        "diagnostics": { "$ref": "#/definitions/BuildDiagnostics" },
        "summary":     { "type": "string", "description": "Human-readable one-line summary" },
        "rawLog":      { "type": "string", "description": "Last 5000 chars of raw output for debugging" },
        "testsTotal":  { "type": ["integer", "null"], "description": "Executed test count (swift test runs only)" },
        "testsFailed": { "type": ["integer", "null"], "description": "Failed test count (swift test runs only)" }
      },
      "definitions": {
        "BuildPhase": {
          "type": "object",
          "properties": {
            "current": { "type": "integer" },
            "total":   { "type": "integer" },
            "action":  { "type": "string" },
            "file":    { "type": ["string", "null"] }
          }
        },
        "BuildDiagnostics": {
          "type": "object",
          "properties": {
            "errorCount":   { "type": "integer" },
            "warningCount": { "type": "integer" },
            "noteCount":    { "type": "integer" },
            "errors":       { "type": "array", "items": { "$ref": "#/definitions/DiagnosticItem" } },
            "warnings":     { "type": "array", "items": { "$ref": "#/definitions/DiagnosticItem" } },
            "notes":        { "type": "array", "items": { "$ref": "#/definitions/DiagnosticItem" } }
          }
        },
        "DiagnosticItem": {
          "type": "object",
          "properties": {
            "file":    { "type": "string" },
            "line":    { "type": "integer" },
            "column":  { "type": "integer" },
            "message": { "type": "string" },
            "context": { "type": "string" }
          }
        }
      },
      "required": ["ok", "succeeded", "exitCode", "duration", "phases", "diagnostics", "summary", "rawLog"]
    }
    """
}
