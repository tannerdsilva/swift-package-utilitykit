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
    var paths: [String] = []

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

    @Flag(name: .customLong("include-timestamp"), help: "Include a generation timestamp in the output (off by default so runs are byte-stable).")
    var includeTimestamp = false

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

        try validateInputPathsExist(paths.isEmpty ? ["."] : paths)

        var fileIndex: [FileIndex] = []

        for file in files {
            guard let source = readSwiftSource(file) else { continue }
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
        }

        let index = ProjectIndex(
            generated: includeTimestamp ? ISO8601DateFormatter().string(from: Date()) : nil,
            fileCount: fileIndex.count,
            totalDeclarations: fileIndex.reduce(0) { $0 + $1.declarations.count },
            totalImports: fileIndex.reduce(0) { $0 + $1.imports.count },
            files: fileIndex
        )

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat

        if fmt == .jsonl {
            // jsonl = one index object per line (streaming shape), not a single
            // minified object — matches every other command's jsonl contract
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let lines = try index.files.map { file -> String in
                let row = ProjectIndex(
                    generated: index.generated,
                    fileCount: index.fileCount,
                    totalDeclarations: index.totalDeclarations,
                    totalImports: index.totalImports,
                    files: [file]
                )
                return String(data: try enc.encode(row), encoding: .utf8) ?? "{}"
            }
            let outputStr = lines.joined(separator: "\n")
            if let outputPath = output {
                try outputStr.write(toFile: outputPath, atomically: true, encoding: .utf8)
            } else {
                print(outputStr)
            }
            return
        }

        // index is a single document object, not an array — encode it directly
        let encoder = JSONEncoder()
        if fmt == .json {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        let outputStr = String(data: try encoder.encode(index), encoding: .utf8) ?? "{}"
        if let outputPath = output {
            try outputStr.write(toFile: outputPath, atomically: true, encoding: .utf8)
        } else {
            print(outputStr)
        }
    }
}

struct ProjectIndex: Codable, Sendable {
    let generated: String?   // nil unless --include-timestamp
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
        "generated":          { "type": ["string", "null"], "description": "ISO 8601 generation timestamp (--include-timestamp)" },
        "fileCount":          { "type": "integer", "description": "Number of source files indexed" },
        "totalDeclarations":  { "type": "integer", "description": "Total declarations across all files" },
        "totalImports":       { "type": "integer", "description": "Total import statements across all files" },
        "files": {
          "type": "array",
          "items": { "$ref": "#/definitions/FileIndex" },
          "description": "Per-file index entries"
        }
      },
      "required": ["fileCount", "totalDeclarations", "totalImports", "files"],
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
