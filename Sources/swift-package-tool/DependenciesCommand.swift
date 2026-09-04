import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// list all import statements across source files.
struct DependenciesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dependencies",
        abstract: "List all imports across source files."
    )

    @Argument(help: "Files or directories to analyze.")
    var paths: [String] = []

    @Option(name: .long, help: "Output format: json, compact, csv, short.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output (overrides --output-format).")
    var prettyPrint = false

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Group imports by file.")
    var grouped = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(ImportInfo.jsonSchema)
            return
        }
        let files = collectSwiftFiles(
            from: paths.isEmpty ? ["."] : paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        guard !files.isEmpty else {
            throw ValidationError("no matching source files found")
        }

        var allImports: [ImportInfo] = []
        for file in files {
            do {
                let source = try String(contentsOfFile: file, encoding: .utf8)
                let tree = Parser.parse(source: source)
                let collector = ImportCollector(filePath: file, source: source)
                collector.walk(tree)
                allImports.append(contentsOf: collector.imports)
            } catch {
                continue
            }
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat

        if grouped {
            // group by file
            let grouped = Dictionary(grouping: allImports) { $0.file }
                .sorted { $0.key < $1.key }
            let outputStr = try formatOutput(
                grouped.map { (file, imports) in
                    GroupedImports(file: file, imports: imports)
                },
                format: fmt
            )
            try writeOutput(outputStr, to: outputPath)
        } else {
            let outputStr = try formatOutput(allImports, format: fmt)
            try writeOutput(outputStr, to: outputPath)
        }
    }
}

struct GroupedImports: Codable, Sendable {
    let file: String
    let imports: [ImportInfo]
}
