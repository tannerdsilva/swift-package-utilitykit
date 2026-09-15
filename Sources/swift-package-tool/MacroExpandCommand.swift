import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// find and report macro expansion sites in Swift source files.
///
/// this command identifies where macros are used (both declaration-level
/// and expression-level expansions) and reports their locations, names,
/// and arguments. it does NOT expand the macros — that requires running
/// the Swift compiler with the macro implementations loaded as plugins.
///
/// to see expanded macro output, run `swift build` first — the compiler
/// expands macros during compilation. the expansions are not saved to
/// disk by default, but you can use compiler flags like
/// `-Xswiftc -Xfrontend -Xswiftc -emit-macro-expansion-source` to
/// capture them (requires the macro implementations to be available).
struct MacroExpandCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macro-expand",
        abstract: "Find macro expansion sites in source files."
    )

    @Argument(help: "Files or directories to scan.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: json, compact, short.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(MacroExpansion.jsonSchema)
            return
        }
        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        try validateInputPathsExist(paths)

        var expansions: [MacroExpansion] = []

        for filePath in files.sorted() {
            guard let source = readSwiftSource(filePath) else { continue }
            let tree = Parser.parse(source: source)
            let collector = MacroExpansionCollector(filePath: filePath, source: source)
            collector.walk(tree)
            expansions.append(contentsOf: collector.expansions)
        }

        expansions.sort { ($0.file, $0.line) < ($1.file, $1.line) }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput(expansions, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }
}

struct MacroExpansion: Codable, Sendable, CustomStringConvertible {
    let file: String
    let line: Int
    let column: Int
    let name: String
    let kind: String  // "declaration" or "expression"
    let arguments: String

    var description: String {
        return "\(file):\(line):\(column)  [\(kind)]  \(name)(\(arguments))"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "MacroExpansion",
      "type": "object",
      "properties": {
        "file":      { "type": "string", "description": "Source file path" },
        "line":      { "type": "integer", "description": "1-based line number" },
        "column":    { "type": "integer", "description": "1-based column number" },
        "name":      { "type": "string", "description": "Macro name" },
        "kind":      { "type": "string", "description": "declaration or expression" },
        "arguments": { "type": "string", "description": "Macro arguments as written" }
      },
      "required": ["file", "line", "column", "name", "kind"]
    }
    """
}

/// walk a syntax tree collecting all macro expansion sites.
class MacroExpansionCollector: SyntaxVisitor {
    let filePath: String
    let source: String
    var expansions: [MacroExpansion] = []

    init(filePath: String, source: String) {
        self.filePath = filePath
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let args = node.arguments.map { arg in
            let label = arg.label?.text ?? ""
            let expr = arg.expression.description.trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? expr : "\(label): \(expr)"
        }.joined(separator: ", ")
        expansions.append(MacroExpansion(
            file: filePath, line: line, column: col,
            name: "#\(node.macroName.text)",
            kind: "declaration",
            arguments: args
        ))
        return .visitChildren
    }

    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let args = node.arguments.map { arg in
            let label = arg.label?.text ?? ""
            let expr = arg.expression.description.trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? expr : "\(label): \(expr)"
        }.joined(separator: ", ")
        expansions.append(MacroExpansion(
            file: filePath, line: line, column: col,
            name: "#\(node.macroName.text)",
            kind: "expression",
            arguments: args
        ))
        return .visitChildren
    }
}
