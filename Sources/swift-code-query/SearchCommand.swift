import Foundation
import ArgumentParser

/// full-text search across Swift source files.
struct SearchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Full-text search across source files."
    )

    @Argument(help: "Search pattern (plain text or regex).")
    var pattern: String

    @Argument(help: "Files or directories to search.")
    var paths: [String]

    @Flag(name: .long, inversion: .prefixedNo, help: "Interpret pattern as regex.")
    var regex = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Case-insensitive search.")
    var ignoreCase = false

    @Option(name: .long, help: "Number of context lines around each match.")
    var context: Int = 0

    @Option(name: .long, help: "Output format: json, compact, csv, short.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output (overrides --output-format).")
    var prettyPrint = false

    @Option(name: .long, help: "Only search files with these extensions (comma-separated, e.g. 'swift,h').")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .long, help: "Maximum number of matches to return.")
    var limit: Int?

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    mutating func run() throws {
        let files = collectSwiftFiles(
            from: paths.isEmpty ? ["."] : paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        guard !files.isEmpty else {
            throw ValidationError("no matching source files found")
        }

        var allMatches: [SearchMatch] = []
        for file in files {
            do {
                let matches = try searchFile(
                    file,
                    pattern: pattern,
                    isRegex: regex,
                    ignoreCase: ignoreCase,
                    context: context
                )
                allMatches.append(contentsOf: matches)
                if let limit = limit, allMatches.count >= limit {
                    allMatches = Array(allMatches.prefix(limit))
                    break
                }
            } catch {
                // skip files that can't be read
                continue
            }
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput(allMatches, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }
}
