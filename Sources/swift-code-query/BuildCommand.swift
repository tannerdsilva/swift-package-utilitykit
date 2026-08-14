import Foundation
import ArgumentParser

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
struct BuildCommand: ParsableCommand {
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

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .long, help: "Output format: json, compact.")
    var outputFormat: OutputFormat?

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(BuildResult.jsonSchema)
            return
        }

        let startTime = Date()

        // build the command line
        var args: [String] = ["swift"]
        if test {
            args.append("test")
            if let f = testFilter {
                args += ["--filter", f]
            }
        } else {
            args.append("build")
        }
        if let t = buildTarget {
            args += ["--target", t]
        }
        if let extra = extraArgs {
            // split on whitespace, respecting quoted strings
            args += splitArgs(extra)
        }

        // run the subprocess
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: path)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // use a Sendable box to safely collect output across threads
        final class OutputBox: @unchecked Sendable {
            var stdoutData = Data()
            var stderrData = Data()
        }
        let box = OutputBox()

        try process.run()

        // read output with timeout
        let group = DispatchGroup()

        DispatchQueue.global().async(group: group) {
            box.stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: group) {
            box.stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let timeoutResult = group.wait(timeout: .now() + .seconds(timeout))

        if timeoutResult == .timedOut {
            process.terminate()
            let duration = Date().timeIntervalSince(startTime)
            let result = BuildResult(
                ok: true,
                succeeded: false,
                exitCode: nil,
                duration: duration,
                phases: [],
                diagnostics: BuildDiagnostics(
                    errorCount: 0, warningCount: 0, noteCount: 0,
                    errors: [], warnings: [], notes: []
                ),
                summary: "build timed out after \(timeout)s",
                rawLog: ""
            )
            try emit(result)
            return
        }

        process.waitUntilExit()

        let duration = Date().timeIntervalSince(startTime)
        let stdout = String(data: box.stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: box.stderrData, encoding: .utf8) ?? ""
        let combined = stdout + "\n" + stderr

        // parse the output
        let parsed = parseBuildOutput(combined)
        let succeeded = process.terminationStatus == 0

        let result = BuildResult(
            ok: true,
            succeeded: succeeded,
            exitCode: Int(process.terminationStatus),
            duration: duration,
            phases: parsed.phases,
            diagnostics: parsed.diagnostics,
            summary: makeSummary(succeeded: succeeded, exitCode: Int(process.terminationStatus),
                                 diagnostics: parsed.diagnostics, duration: duration),
            rawLog: String(combined.suffix(5000))
        )

        try emit(result)
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
        let outputStr = try formatOutput([result], format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }

    // MARK: - parsing

    struct ParsedOutput {
        var phases: [BuildPhase] = []
        var diagnostics = BuildDiagnostics(
            errorCount: 0, warningCount: 0, noteCount: 0,
            errors: [], warnings: [], notes: []
        )
    }

    func parseBuildOutput(_ text: String) -> ParsedOutput {
        var parsed = ParsedOutput()
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // phase line: [N/M] Action File
            if let phase = parsePhase(line) {
                parsed.phases.append(phase)
                i += 1
                continue
            }

            // diagnostic line: file:line:col: level: message
            if let diag = parseDiagnosticLine(line) {
                // collect context lines (source snippet + caret)
                var context: [String] = [line]
                i += 1
                while i < lines.count {
                    let next = lines[i]
                    // context lines are indented (source) or start with spaces+^ (caret)
                    // or are continuation lines (no colon-number pattern)
                    if next.hasPrefix(" ") || next.hasPrefix("\t") || next.hasPrefix("^") {
                        context.append(next)
                        i += 1
                    } else {
                        break
                    }
                }
                let fullMessage = context.joined(separator: "\n")

                switch diag.level {
                case "error":
                    parsed.diagnostics.errorCount += 1
                    if parsed.diagnostics.errors.count < 20 {
                        parsed.diagnostics.errors.append(DiagnosticItem(
                            file: diag.file, line: diag.line, column: diag.column,
                            message: diag.message, context: fullMessage
                        ))
                    }
                case "warning":
                    parsed.diagnostics.warningCount += 1
                    if parsed.diagnostics.warnings.count < 20 {
                        parsed.diagnostics.warnings.append(DiagnosticItem(
                            file: diag.file, line: diag.line, column: diag.column,
                            message: diag.message, context: fullMessage
                        ))
                    }
                case "note":
                    parsed.diagnostics.noteCount += 1
                    if parsed.diagnostics.notes.count < 20 {
                        parsed.diagnostics.notes.append(DiagnosticItem(
                            file: diag.file, line: diag.line, column: diag.column,
                            message: diag.message, context: fullMessage
                        ))
                    }
                default:
                    break
                }
                continue
            }

            i += 1
        }

        return parsed
    }

    /// parse a phase line like `[1/10] Compiling SomeFile.swift`
    func parsePhase(_ line: String) -> BuildPhase? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let bracketEnd = trimmed.firstIndex(of: "]") else {
            return nil
        }

        let bracketContent = trimmed[trimmed.index(after: trimmed.startIndex)..<bracketEnd]
        let parts = bracketContent.split(separator: "/")
        guard parts.count == 2,
              let current = Int(parts[0]),
              let total = Int(parts[1]) else {
            return nil
        }

        let rest = trimmed[trimmed.index(after: bracketEnd)...].trimmingCharacters(in: .whitespaces)
        // split into action and file
        if let spaceIdx = rest.firstIndex(of: " ") {
            let action = String(rest[..<spaceIdx])
            let file = String(rest[rest.index(after: spaceIdx)...])
            return BuildPhase(
                current: current, total: total,
                action: action, file: file.isEmpty ? nil : file
            )
        }

        return BuildPhase(current: current, total: total, action: rest, file: nil)
    }

    /// parse a diagnostic line: `file:line:col: level: message`
    func parseDiagnosticLine(_ line: String) -> (file: String, line: Int, column: Int, level: String, message: String)? {
        // pattern: /path/file.swift:42:13: error: message
        // or: /path/file.swift:42:13: warning: message
        // or: /path/file.swift:42:13: note: message

        // find the third colon after the file path
        guard let firstColon = line.firstIndex(of: ":") else { return nil }
        let afterFirst = line[line.index(after: firstColon)...]

        guard let secondColon = afterFirst.firstIndex(of: ":") else { return nil }
        let lineStr = String(afterFirst[..<secondColon])
        guard let lineNum = Int(lineStr.trimmingCharacters(in: .whitespaces)) else { return nil }

        let afterSecond = afterFirst[afterFirst.index(after: secondColon)...]
        guard let thirdColon = afterSecond.firstIndex(of: ":") else { return nil }
        let colStr = String(afterSecond[..<thirdColon])
        guard let colNum = Int(colStr.trimmingCharacters(in: .whitespaces)) else { return nil }

        let afterThird = afterSecond[afterSecond.index(after: thirdColon)...].trimmingCharacters(in: .whitespaces)
        // after third colon: "error: message" or "warning: message" or "note: message"
        guard let levelColon = afterThird.firstIndex(of: ":") else { return nil }
        let level = String(afterThird[..<levelColon]).trimmingCharacters(in: .whitespaces)
        let message = String(afterThird[afterThird.index(after: levelColon)...]).trimmingCharacters(in: .whitespaces)

        let file = String(line[..<firstColon])

        guard ["error", "warning", "note"].contains(level) else { return nil }

        return (file, lineNum, colNum, level, message)
    }

    func makeSummary(succeeded: Bool, exitCode: Int, diagnostics: BuildDiagnostics, duration: TimeInterval) -> String {
        let status = succeeded ? "succeeded" : "failed"
        return "build \(status) (exit \(exitCode)); " +
               "\(diagnostics.errorCount) error(s), " +
               "\(diagnostics.warningCount) warning(s), " +
               "\(diagnostics.noteCount) note(s) " +
               "in \(String(format: "%.2f", duration))s"
    }

    /// simple argument splitter that respects quoted strings.
    private func splitArgs(_ input: String) -> [String] {
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
        "rawLog":      { "type": "string", "description": "Last 5000 chars of raw output for debugging" }
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

struct BuildPhase: Codable, Sendable {
    let current: Int
    let total: Int
    let action: String
    let file: String?
}

struct BuildDiagnostics: Codable, Sendable {
    var errorCount: Int
    var warningCount: Int
    var noteCount: Int
    var errors: [DiagnosticItem]
    var warnings: [DiagnosticItem]
    var notes: [DiagnosticItem]
}

struct DiagnosticItem: Codable, Sendable {
    let file: String
    let line: Int
    let column: Int
    let message: String
    let context: String
}
