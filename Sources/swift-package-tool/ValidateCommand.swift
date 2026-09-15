import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser
import SwiftDiagnostics
import SwiftParserDiagnostics

/// shallow syntax validation using SwiftParser's built-in diagnostics.
/// catches syntax-level errors (missing braces, invalid tokens, etc.)
/// without running the full compiler. does not perform type-checking.
struct ValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Shallow syntax validation using SwiftParser diagnostics."
    )

    @Argument(help: "Files or directories to validate.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: json, compact, short.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Flag(name: .long, help: "Include warnings in addition to errors.")
    var warnings = false

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(ValidateDiagnostic.jsonSchema)
            return
        }
        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        guard !files.isEmpty else {
            throw ValidationError("no matching source files found")
        }

        var allDiagnostics: [ValidateDiagnostic] = []

        for filePath in files.sorted() {
            do {
                let source = try String(contentsOfFile: filePath, encoding: .utf8)
                let tree = Parser.parse(source: source)
                let diags = ParseDiagnosticsGenerator.diagnostics(for: tree)
                let converter = SourceLocationConverter(fileName: filePath, tree: tree)

                for diag in diags {
                    // filter by severity
                    if !warnings && diag.diagMessage.severity != .error { continue }

                    let location = diag.location(converter: converter)
                    allDiagnostics.append(ValidateDiagnostic(
                        file: filePath,
                        line: location.line,
                        column: location.column,
                        severity: "\(diag.diagMessage.severity)",
                        message: diag.message,
                        diagnosticID: "\(diag.diagnosticID)",
                        fixItCount: diag.fixIts.count
                    ))
                }
            } catch {
                allDiagnostics.append(ValidateDiagnostic(
                    file: filePath, line: 1, column: 1,
                    severity: "error",
                    message: "unable to read file: \(error.localizedDescription)",
                    diagnosticID: "read_error",
                    fixItCount: 0
                ))
            }
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput(allDiagnostics, format: fmt)
        try writeOutput(outputStr, to: outputPath)

        // a validator must signal pass/fail on its exit code; exit non-zero
        // when any error-severity diagnostic was found (warnings alone stay 0)
        if allDiagnostics.contains(where: { $0.severity == "error" }) {
            throw ExitCode(1)
        }
    }
}

struct ValidateDiagnostic: Codable, Sendable {
    let file: String
    let line: Int
    let column: Int
    let severity: String
    let message: String
    let diagnosticID: String
    let fixItCount: Int

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "ValidateDiagnostic",
      "type": "object",
      "properties": {
        "file":         { "type": "string", "description": "Source file path" },
        "line":         { "type": "integer", "description": "1-based line number" },
        "column":       { "type": "integer", "description": "1-based column number" },
        "severity":     { "type": "string", "description": "error or warning" },
        "message":      { "type": "string", "description": "Diagnostic message" },
        "diagnosticID": { "type": "string", "description": "Parser diagnostic identifier" },
        "fixItCount":   { "type": "integer", "description": "Number of attached fix-its" }
      },
      "required": ["file", "line", "column", "severity", "message"]
    }
    """
}
