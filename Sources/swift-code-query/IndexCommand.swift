import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// build a comprehensive index of all symbols, imports, and file metadata.
struct IndexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Build a comprehensive project index (declarations + imports + files)."
    )

    @Argument(help: "Files or directories to index.")
    var paths: [String]

    @Option(name: .long, help: "Output format: json, compact, csv, jsonl.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, help: "Pretty-print JSON output (overrides --output-format).")
    var prettyPrint = false

    @Option(name: .long, help: "Write index to this file instead of stdout.")
    var output: String?

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    mutating func run() throws {
        let files = collectSwiftFiles(
            from: paths.isEmpty ? ["."] : paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        guard !files.isEmpty else {
            throw ValidationError("no matching source files found")
        }

        var fileIndex: [FileIndex] = []

        for file in files {
            do {
                let source = try String(contentsOfFile: file, encoding: .utf8)
                let tree = Parser.parse(source: source)

                // collect declarations
                let declCollector = DeclarationCollector(filePath: file, source: source)
                declCollector.walk(tree)

                // collect imports
                let importCollector = ImportCollector(filePath: file, source: source)
                importCollector.walk(tree)

                // line count
                let lineCount = source.components(separatedBy: "\n").count

                fileIndex.append(FileIndex(
                    file: file,
                    lineCount: lineCount,
                    declarations: declCollector.declarations,
                    imports: importCollector.imports
                ))
            } catch {
                continue
            }
        }

        let index = ProjectIndex(
            generated: ISO8601DateFormatter().string(from: Date()),
            fileCount: fileIndex.count,
            totalDeclarations: fileIndex.reduce(0) { $0 + $1.declarations.count },
            totalImports: fileIndex.reduce(0) { $0 + $1.imports.count },
            files: fileIndex
        )

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput([index], format: fmt)

        if let outputPath = output {
            try outputStr.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("index written to \(outputPath)")
        } else {
            print(outputStr)
        }
    }
}

struct ProjectIndex: Codable, Sendable {
    let generated: String
    let fileCount: Int
    let totalDeclarations: Int
    let totalImports: Int
    let files: [FileIndex]
}

struct FileIndex: Codable, Sendable {
    let file: String
    let lineCount: Int
    let declarations: [DeclarationInfo]
    let imports: [ImportInfo]
}
