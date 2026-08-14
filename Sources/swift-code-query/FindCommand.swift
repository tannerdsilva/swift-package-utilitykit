import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// find a symbol by name across all declaration kinds.
///
/// this is the "i know the name but not what it is" command: give it a symbol
/// name and it searches every declaration kind (functions, structs, classes,
/// enums, protocols, variables, typealiases, extensions, etc.) across the
/// specified paths and tells you what it found.
struct FindCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "find",
        abstract: "Find a symbol by name across all declaration kinds."
    )

    @Argument(help: "Symbol name to find (substring match by default).")
    var symbol: String = ""

    @Argument(help: "Files or directories to search.")
    var paths: [String] = ["."]

    @Flag(name: .long, help: "Require exact name match (case-insensitive).")
    var exact = false

    @Flag(name: .long, help: "Case-sensitive search.")
    var caseSensitive = false

    @Option(name: .long, help: "Output format: json, compact, csv, short.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, help: "Pretty-print JSON output (overrides --output-format).")
    var prettyPrint = false

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .long, help: "Maximum number of results.")
    var limit: Int?

    @Flag(name: .long, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(FindResult.jsonSchema)
            return
        }
        guard !symbol.isEmpty else {
            throw ValidationError("symbol is required")
        }
        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        guard !files.isEmpty else {
            throw ValidationError("no matching source files found")
        }

        // search all declaration kinds
        let allKinds: Set<String> = [
            "function", "struct", "class", "enum", "protocol",
            "typealias", "associatedtype", "variable",
            "extension", "initializer", "subscript",
            "operator", "precedencegroup", "macro", "import"
        ]

        var results: [FindResult] = []

        for filePath in files {
            do {
                let url = URL(fileURLWithPath: filePath)
                let source = try String(contentsOf: url, encoding: .utf8)
                let tree = Parser.parse(source: source)
                let collector = DeclarationCollector(filePath: filePath, source: source, kinds: allKinds)
                collector.walk(tree)

                for decl in collector.declarations {
                    let matches: Bool
                    if exact {
                        if caseSensitive {
                            matches = decl.name == symbol
                        } else {
                            matches = decl.name.lowercased() == symbol.lowercased()
                        }
                    } else {
                        if caseSensitive {
                            matches = decl.name.contains(symbol)
                        } else {
                            matches = decl.name.localizedCaseInsensitiveContains(symbol)
                        }
                    }

                    if matches {
                        results.append(FindResult(
                            name: decl.name,
                            kind: decl.kind,
                            file: decl.file,
                            line: decl.line,
                            column: decl.column,
                            signature: decl.signature,
                            docComment: decl.docComment,
                            modifiers: decl.modifiers
                        ))
                    }
                }
            } catch {
                continue
            }
        }

        // sort by kind then name for deterministic output
        results.sort { ($0.kind, $0.name) < ($1.kind, $1.name) }

        // apply limit
        if let limit = limit, results.count > limit {
            results = Array(results.prefix(limit))
        }

        // pretty-print overrides to json
        let fmt: OutputFormat = prettyPrint ? .json : outputFormat

        // format and print
        let outputStr = try formatOutput(results, format: fmt)
        print(outputStr)
    }
}

/// a single find result, with kind prominently included.
struct FindResult: Codable, Sendable, CustomStringConvertible {
    let name: String
    let kind: String
    let file: String
    let line: Int
    let column: Int
    let signature: String
    let docComment: String
    let modifiers: [String]

    var description: String {
        let mods = modifiers.isEmpty ? "" : "\(modifiers.joined(separator: " ")) "
        return "\(file):\(line):\(column)  [\(kind)]  \(mods)\(signature)"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "FindResult",
      "type": "object",
      "properties": {
        "name":       { "type": "string", "description": "Symbol name" },
        "kind":       { "type": "string", "description": "Declaration kind" },
        "file":       { "type": "string", "description": "Source file path" },
        "line":       { "type": "integer", "description": "1-based line number" },
        "column":     { "type": "integer", "description": "1-based column number" },
        "signature":  { "type": "string", "description": "One-line declaration signature" },
        "docComment": { "type": "string", "description": "Documentation comment text" },
        "modifiers":  { "type": "array", "items": { "type": "string" }, "description": "Declaration modifiers" }
      },
      "required": ["name", "kind", "file", "line", "column", "signature", "docComment", "modifiers"]
    }
    """
}
