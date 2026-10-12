import Foundation
import ArgumentParser
import SubprocessCore
import BuildOutputParsing

/// run a package's test suite (`swift test`) and return the structured JSON
/// verdict.
///
/// the standalone home of the test verdict the agent surface names `pkg_test`
/// — the CLI had only `build --test`. the execution path is the same
/// ``BuildRunner``, with the same isolated scratch, so a test verdict means the
/// same thing wherever it is produced (here, in `overview`, or over MCP).
///
/// with `--isolated` the whole run happens in a fresh ephemeral
/// scratch dir under `<pkg>/.build/swift-package-audit/` that the call removes
/// when it finishes: no persistent build state, and the package's real
/// `.build` products are never touched.
struct TestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test",
        abstract: "Run swift test and return structured JSON."
    )

    @Argument(help: "Package directory to test.")
    var path: String = "."

    @Option(name: .customLong("filter"), help: "Test filter (passed to swift test --filter).")
    var testFilter: String?

    @Option(name: .long, help: "Timeout in seconds.")
    var timeout: Int = 600

    @Flag(name: .customLong("isolated"), help: "Test in a fresh ephemeral scratch under <pkg>/.build/swift-package-audit (no persistent build state; the real .build is untouched).")
    var isolated = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .long, help: "Output format: json, compact.")
    var outputFormat: OutputFormat?

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    func run() async throws {
        if schema {
            print(BuildResult.jsonSchema)
            return
        }

        let request = BuildRequest(
            path: path.isEmpty ? "." : path,
            test: true,
            filter: testFilter,
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
                summary: "test run timed out after \(timeout)s",
                rawLog: "",
                testsTotal: nil,
                testsFailed: nil
            )
            try emit(timedOut)
            throw ExitCode(1)
        }

        try emit(result)

        // a failed test run is a tool failure — never report success through
        // the process exit code. the structured result on stdout still carries
        // the specifics (summary, testsTotal/testsFailed, diagnostics).
        guard result.succeeded else {
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