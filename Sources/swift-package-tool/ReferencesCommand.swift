import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// find all references to a symbol across source files.
struct ReferencesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "references",
        abstract: "Find all references to a symbol across source files."
    )

    @Argument(help: "Symbol name to find references for.")
    var symbol: String

    @Argument(help: "Files or directories to search.")
    var paths: [String]

    @Option(name: .long, help: "Output format: json, compact, csv, short.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output (overrides --output-format).")
    var prettyPrint = false

    @Option(name: .long, help: "Only search files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Option(name: .long, help: "Maximum number of references to return.")
    var limit: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(SymbolReference.jsonSchema)
            return
        }
        let files = collectSwiftFiles(
            from: paths.isEmpty ? ["."] : paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        try validateInputPathsExist(paths)

        var allRefs: [SymbolReference] = []
        for file in files {
            guard let source = readSwiftSource(file) else { continue }
            let tree = Parser.parse(source: source)
            let finder = ReferenceFinder(targetName: symbol, filePath: file, source: source)
            finder.walk(tree)
            allRefs.append(contentsOf: finder.references)
        }

        if let limit = limit, allRefs.count > limit {
            allRefs = Array(allRefs.prefix(limit))
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput(allRefs, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }
}
