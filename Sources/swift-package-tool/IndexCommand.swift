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

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output (overrides --output-format).")
    var prettyPrint = false

    @Option(name: .long, help: "Write index to this file instead of stdout.")
    var output: String?

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(ProjectIndex.jsonSchema)
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
        } else {
            try writeOutput(outputStr, to: "")
        }
    }
}

struct ProjectIndex: Codable, Sendable {
    let generated: String
    let fileCount: Int
    let totalDeclarations: Int
    let totalImports: Int
    let files: [FileIndex]

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "ProjectIndex",
      "type": "object",
      "properties": {
        "generated":          { "type": "string", "description": "ISO 8601 generation timestamp" },
        "fileCount":          { "type": "integer", "description": "Number of source files indexed" },
        "totalDeclarations":  { "type": "integer", "description": "Total declarations across all files" },
        "totalImports":       { "type": "integer", "description": "Total import statements across all files" },
        "files": {
          "type": "array",
          "items": { "$ref": "#/definitions/FileIndex" },
          "description": "Per-file index entries"
        }
      },
      "required": ["generated", "fileCount", "totalDeclarations", "totalImports", "files"],
      "definitions": {
        "FileIndex": {
          "type": "object",
          "properties": {
            "file":         { "type": "string", "description": "Source file path" },
            "lineCount":    { "type": "integer", "description": "Number of lines" },
            "declarations": { "type": "array", "items": { "type": "object" }, "description": "Declaration info objects" },
            "imports":      { "type": "array", "items": { "type": "object" }, "description": "Import info objects" }
          },
          "required": ["file", "lineCount", "declarations", "imports"]
        }
      }
    }
    """
}

struct FileIndex: Codable, Sendable {
    let file: String
    let lineCount: Int
    let declarations: [DeclarationInfo]
    let imports: [ImportInfo]
}
