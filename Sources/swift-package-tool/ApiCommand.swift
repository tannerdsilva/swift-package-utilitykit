import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// extract the public API surface of a project: public/internal declarations
/// with signatures and protocol conformances.  gives a small model the
/// interface without the implementation.
struct ApiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "api",
        abstract: "Extract the public API surface of a project."
    )

    @Argument(help: "Files or directories to analyze.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: json, compact, csv, short, jsonl.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include internal declarations (default: public only).")
    var includeInternal = false

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .long, help: "Maximum number of declarations.")
    var limit: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    mutating func run() throws {
        if schema {
            print(ApiItem.jsonSchema)
            return
        }

        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        try validateInputPathsExist(paths)

        var items: [ApiItem] = []

        for filePath in files {
            guard let source = readSwiftSource(filePath) else { continue }
            let tree = Parser.parse(source: source)
            let collector = ApiCollector(filePath: filePath, source: source, includeInternal: includeInternal)
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

struct ApiItem: Codable, Sendable, CustomStringConvertible {
    let name: String
    let kind: String
    let access: String
    let file: String
    let line: Int
    let column: Int
    let signature: String
    let conformsTo: [String]
    let docComment: String

    var description: String {
        let mods = access.isEmpty ? "" : "\(access) "
        return "\(file):\(line):\(column)  [\(kind)]  \(mods)\(signature)"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "ApiItem",
      "type": "object",
      "properties": {
        "name":        { "type": "string", "description": "Declaration name" },
        "kind":        { "type": "string", "description": "Declaration kind: function, struct, class, enum, protocol, typealias, variable, initializer, subscript" },
        "access":      { "type": "string", "description": "Access level: public, internal, package" },
        "file":        { "type": "string", "description": "Source file path" },
        "line":        { "type": "integer", "description": "1-based line number" },
        "column":      { "type": "integer", "description": "1-based column number" },
        "signature":   { "type": "string", "description": "One-line declaration signature" },
        "conformsTo":  { "type": "array", "items": { "type": "string" }, "description": "Protocols/types this type conforms to or inherits from" },
        "docComment":  { "type": "string", "description": "Documentation comment" }
      },
      "required": ["name", "kind", "access", "file", "line", "column", "signature", "conformsTo", "docComment"]
    }
    """
}

class ApiCollector: SyntaxVisitor {
    let filePath: String
    let source: String
    let includeInternal: Bool
    var items: [ApiItem] = []

    init(filePath: String, source: String, includeInternal: Bool) {
        self.filePath = filePath
        self.source = source
        self.includeInternal = includeInternal
        super.init(viewMode: .sourceAccurate)
    }

    private func add(_ node: some DeclSyntaxProtocol) {
        let mods = modifierNames(from: node)
        let access = accessLevel(from: mods)
        if access == "private" || access == "fileprivate" { return }
        if access == "internal" && !includeInternal { return }
        guard let name = declarationName(from: node) else { return }
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let sig = signatureString(for: node)
        let doc = extractDocComment(from: node.leadingTrivia)
        let conforms = extractConformances(from: node)
        items.append(ApiItem(
            name: name, kind: kindString(for: node),
            access: access, file: filePath,
            line: line, column: col,
            signature: sig, conformsTo: conforms,
            docComment: doc
        ))
    }

    public override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
}

/// extract access level from modifier names.
func accessLevel(from modifiers: [String]) -> String {
    if modifiers.contains("public") { return "public" }
    if modifiers.contains("package") { return "package" }
    if modifiers.contains("internal") { return "internal" }
    if modifiers.contains("private") { return "private" }
    if modifiers.contains("fileprivate") { return "fileprivate" }
    return "internal" // default in Swift
}

/// extract protocol/type names from an inheritance clause.
func extractConformances(from node: some DeclSyntaxProtocol) -> [String] {
    // swift-syntax exposes inheritanceClause as a typed property on each
    // declaration node, but the generic DeclSyntaxProtocol doesn't have it.
    // we check each concrete type.
    let clause: InheritanceClauseSyntax? = {
        if let s = node as? StructDeclSyntax      { return s.inheritanceClause }
        if let c = node as? ClassDeclSyntax       { return c.inheritanceClause }
        if let e = node as? EnumDeclSyntax        { return e.inheritanceClause }
        if let p = node as? ProtocolDeclSyntax    { return p.inheritanceClause }
        if let e = node as? ExtensionDeclSyntax   { return e.inheritanceClause }
        return nil
    }()
    guard let inherited = clause else { return [] }
    return inherited.inheritedTypes.map {
        $0.type.description.trimmingCharacters(in: CharacterSet.whitespaces)
    }
}
