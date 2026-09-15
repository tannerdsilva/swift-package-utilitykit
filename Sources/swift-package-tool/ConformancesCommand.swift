import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// list every type and what it conforms to (protocols, superclasses).
/// essential for agents that need to understand Swift's protocol system
/// before modifying conformances.
struct ConformancesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conformances",
        abstract: "List protocol conformances and inheritance chains."
    )

    @Argument(help: "Files or directories to analyze.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: json, compact, csv, short, jsonl.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include extensions that add conformances.")
    var includeExtensions = false

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .long, help: "Maximum number of results.")
    var limit: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    mutating func run() throws {
        if schema {
            print(ConformanceItem.jsonSchema)
            return
        }

        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        try validateInputPathsExist(paths)

        var items: [ConformanceItem] = []

        for filePath in files {
            guard let source = readSwiftSource(filePath) else { continue }
            let tree = Parser.parse(source: source)
            let collector = ConformanceCollector(
                filePath: filePath, source: source,
                includeExtensions: includeExtensions
            )
            collector.walk(tree)
            items.append(contentsOf: collector.items)
        }

        items.sort { ($0.kind, $0.name) < ($1.kind, $1.name) }

        if let limit = limit, items.count > limit {
            items = Array(items.prefix(limit))
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput(items, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }
}

struct ConformanceItem: Codable, Sendable, CustomStringConvertible {
    let name: String
    let kind: String
    let file: String
    let line: Int
    let inherits: [String]       // superclass/protocol names from declaration
    let source: String           // "declaration" or "extension"

    var description: String {
        let base = inherits.isEmpty ? "" : " : \(inherits.joined(separator: ", "))"
        return "\(file):\(line)  [\(kind) \(source)]  \(name)\(base)"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "ConformanceItem",
      "type": "object",
      "properties": {
        "name":     { "type": "string", "description": "Type name" },
        "kind":     { "type": "string", "description": "struct, class, enum, protocol" },
        "file":     { "type": "string", "description": "Source file path" },
        "line":     { "type": "integer", "description": "1-based line number" },
        "inherits": { "type": "array", "items": { "type": "string" }, "description": "Types/protocols this type inherits from or conforms to" },
        "source":   { "type": "string", "description": "declaration or extension" }
      },
      "required": ["name", "kind", "file", "line", "inherits", "source"]
    }
    """
}

class ConformanceCollector: SyntaxVisitor {
    let filePath: String
    let source: String
    let includeExtensions: Bool
    var items: [ConformanceItem] = []

    init(filePath: String, source: String, includeExtensions: Bool) {
        self.filePath = filePath
        self.source = source
        self.includeExtensions = includeExtensions
        super.init(viewMode: .sourceAccurate)
    }

    private func add(name: String, kind: String, line: Int, inherits: [String], source: String) {
        items.append(ConformanceItem(
            name: name, kind: kind, file: filePath,
            line: line, inherits: inherits, source: source
        ))
    }

    public override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let inherits = extractConformances(from: node)
        if !inherits.isEmpty {
            let pos = node.position.utf8Offset
            let (line, _) = lineColumn(at: pos, in: source)
            add(name: node.name.text, kind: "struct", line: line, inherits: inherits, source: "declaration")
        }
        return .visitChildren
    }

    public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let inherits = extractConformances(from: node)
        if !inherits.isEmpty {
            let pos = node.position.utf8Offset
            let (line, _) = lineColumn(at: pos, in: source)
            add(name: node.name.text, kind: "class", line: line, inherits: inherits, source: "declaration")
        }
        return .visitChildren
    }

    public override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let inherits = extractConformances(from: node)
        if !inherits.isEmpty {
            let pos = node.position.utf8Offset
            let (line, _) = lineColumn(at: pos, in: source)
            add(name: node.name.text, kind: "enum", line: line, inherits: inherits, source: "declaration")
        }
        return .visitChildren
    }

    public override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let inherits = extractConformances(from: node)
        if !inherits.isEmpty {
            let pos = node.position.utf8Offset
            let (line, _) = lineColumn(at: pos, in: source)
            add(name: node.name.text, kind: "protocol", line: line, inherits: inherits, source: "declaration")
        }
        return .visitChildren
    }

    public override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard includeExtensions else { return .visitChildren }
        let inherits = extractConformances(from: node)
        if !inherits.isEmpty {
            let pos = node.position.utf8Offset
            let (line, _) = lineColumn(at: pos, in: source)
            let name = node.extendedType.description.trimmingCharacters(in: CharacterSet.whitespaces)
            add(name: name, kind: "extension", line: line, inherits: inherits, source: "extension")
        }
        return .visitChildren
    }
}
