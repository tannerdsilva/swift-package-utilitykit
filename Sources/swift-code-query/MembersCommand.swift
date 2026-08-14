import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// list the direct members of a type (enum cases, properties, methods, etc.).
struct MembersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "members",
        abstract: "List direct members of a type (properties, methods, enum cases)."
    )

    @Argument(help: "Files or directories to search.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Type name to list members for.")
    var type: String = ""

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .long, help: "Output format: json, compact, csv, short.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .long, help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Flag(name: .long, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(MemberItem.jsonSchema)
            return
        }
        guard !type.isEmpty else {
            throw ValidationError("type name is required")
        }

        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        guard !files.isEmpty else {
            throw ValidationError("no matching source files found")
        }

        // search for the type across all files
        for filePath in files {
            do {
                let source = try String(contentsOfFile: filePath, encoding: .utf8)
                let tree = Parser.parse(source: source)
                let finder = SymbolFinder(targetName: type, filePath: filePath, source: source)
                finder.walk(tree)

                if let detail = finder.found {
                    let fmt: OutputFormat = prettyPrint ? .json : outputFormat
                    let outputStr = try formatOutput(detail.children, format: fmt)
                    try writeOutput(outputStr, to: outputPath)
                    return
                }
            } catch {
                continue
            }
        }

        throw ValidationError("type '\(type)' not found in the given paths")
    }
}

struct MemberItem: Codable, Sendable {
    let name: String
    let kind: String
    let file: String
    let line: Int
    let column: Int
    let signature: String
    let modifiers: [String]

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "MemberItem",
      "type": "object",
      "properties": {
        "name":      { "type": "string", "description": "Member name" },
        "kind":      { "type": "string", "description": "Member kind: function, variable, enum_case, subscript, initializer" },
        "file":      { "type": "string", "description": "Source file path" },
        "line":      { "type": "integer", "description": "1-based line number" },
        "column":    { "type": "integer", "description": "1-based column number" },
        "signature": { "type": "string", "description": "One-line declaration signature" },
        "modifiers": { "type": "array", "items": { "type": "string" }, "description": "Declaration modifiers (public, static, etc.)" }
      },
      "required": ["name", "kind", "file", "line", "column", "signature", "modifiers"]
    }
    """
}
