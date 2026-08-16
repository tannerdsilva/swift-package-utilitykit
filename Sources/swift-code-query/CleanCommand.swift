import Foundation
import ArgumentParser

/// run `swift package clean` as a subprocess and return structured JSON.
///
/// this removes build artifacts (`.build/` object files, modules, binaries)
/// but preserves the dependency cache (`.build/checkouts/`), so the next
/// `swift build` recompiles without re-fetching dependencies.
struct CleanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Delete build artifacts without removing dependencies."
    )

    @Argument(help: "Package directory to clean (default: current directory).")
    var path: String = "."

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Flag(name: .long, help: "Full reset — removes dependencies too (re-fetched on next build).")
    var reset = false

    mutating func run() throws {
        let resolvedPath = NSString(string: path).standardizingPath
        guard FileManager.default.fileExists(atPath: resolvedPath + "/Package.swift") else {
            throw ValidationError("no Package.swift found at \(resolvedPath)")
        }

        let command = reset ? "swift package reset" : "swift package clean"
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

        let result = CleanResult(
            success: process.terminationStatus == 0,
            mode: reset ? "reset" : "clean",
            directory: resolvedPath,
            output: (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let encoder = JSONEncoder()
        if prettyPrint {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        let jsonData = try encoder.encode(result)
        print(String(data: jsonData, encoding: .utf8)!)
    }
}

struct CleanResult: Codable, Sendable {
    let success: Bool
    let mode: String
    let directory: String
    let output: String
}
