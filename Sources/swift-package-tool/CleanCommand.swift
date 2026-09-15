import Foundation
import ArgumentParser

/// run `swift package clean` as a subprocess and return structured JSON.
///
/// by default this removes **only build artifacts** (`.build/` object files,
/// modules, binaries). the dependency cache (`.build/checkouts/`) is
/// preserved — the next `swift build` recompiles without re-fetching.
///
/// to also destroy cached dependencies, pass `--purge-all`. this is a
/// destructive operation: every dependency is deleted and must be re-fetched
/// from scratch on the next build. only use this when you are certain you
/// want to wipe the entire cache.
struct CleanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Delete build artifacts. Dependencies are preserved unless --purge-all is passed."
    )

    @Argument(help: "Package directory to clean (default: current directory).")
    var path: String = "."

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .long, help: "Output format: json, compact, csv, short.")
    var outputFormat: OutputFormat = .json

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Flag(
        name: [.customLong("purge-all"), .customLong("destroy-dependencies")],
        help: """
        ⚠️  DESTRUCTIVE: Delete ALL cached dependencies in addition to build artifacts. \
        Every dependency is removed from .build/checkouts/ and must be re-fetched from \
        scratch on the next build. Only use this when you are certain you want to wipe \
        the entire dependency cache.
        """
    )
    var purgeAll = false

    mutating func run() throws {
        if schema {
            print(CleanResult.jsonSchema)
            return
        }
        let resolvedPath = NSString(string: path).standardizingPath
        guard FileManager.default.fileExists(atPath: resolvedPath + "/Package.swift") else {
            throw ValidationError("no Package.swift found at \(resolvedPath)")
        }

        let command = purgeAll ? "swift package reset" : "swift package clean"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: resolvedPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        let modeLabel = purgeAll ? "purge-all (dependencies DESTROYED)" : "clean (dependencies preserved)"
        let result = CleanResult(
            success: process.terminationStatus == 0,
            mode: modeLabel,
            directory: resolvedPath,
            output: (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput([result], format: fmt)
        print(outputStr)
    }
}

struct CleanResult: Codable, Sendable, CustomStringConvertible {
    let success: Bool
    let mode: String
    let directory: String
    let output: String

    var description: String {
        "\(directory): \(mode) — success=\(success)"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "CleanResult",
      "type": "object",
      "properties": {
        "success":   { "type": "boolean", "description": "Whether the clean command exited 0" },
        "mode":      { "type": "string", "description": "clean (dependencies preserved) or purge-all (dependencies DESTROYED)" },
        "directory": { "type": "string", "description": "Package directory cleaned" },
        "output":    { "type": "string", "description": "Raw clean command output" }
      },
      "required": ["success", "mode", "directory"]
    }
    """
}
