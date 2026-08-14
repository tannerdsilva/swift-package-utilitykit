import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// semantic diff between two versions of source code.
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Semantic declaration diff between two source files."
    )

    @Argument(help: "First source file (or `-` for stdin).")
    var file1: String

    @Argument(help: "Second source file (or `-` for stdin).")
    var file2: String

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
            print(DiffResult.jsonSchema)
            return
        }

        let source1 = try readSource(file1)
        let source2 = try readSource(file2)

        let tree1 = Parser.parse(source: source1)
        let tree2 = Parser.parse(source: source2)

        let collector1 = DiffDeclarationCollector(source: source1, filePath: label(file1))
        collector1.walk(tree1)
        let collector2 = DiffDeclarationCollector(source: source2, filePath: label(file2))
        collector2.walk(tree2)

        let decls1 = collector1.declarations
        let decls2 = collector2.declarations

        // build lookup by (file, name, kind) to prevent cross-file collisions
        let map1 = Dictionary(grouping: decls1) { "\($0.file):\($0.name):\($0.kind)" }
        let map2 = Dictionary(grouping: decls2) { "\($0.file):\($0.name):\($0.kind)" }

        var added: [DiffDeclaration] = []
        var removed: [DiffDeclaration] = []
        var changed: [DiffChange] = []

        let keys1 = Set(map1.keys)
        let keys2 = Set(map2.keys)

        for key in keys2.subtracting(keys1) {
            added.append(contentsOf: map2[key]!)
        }
        for key in keys1.subtracting(keys2) {
            removed.append(contentsOf: map1[key]!)
        }
        for key in keys1.intersection(keys2) {
            let a = map1[key]!.first!
            let b = map2[key]!.first!
            if a.signature != b.signature {
                changed.append(DiffChange(
                    name: a.name, kind: a.kind,
                    oldSignature: a.signature, newSignature: b.signature,
                    oldLine: a.line, newLine: b.line
                ))
            }
        }

        added.sort { $0.name < $1.name }
        removed.sort { $0.name < $1.name }
        changed.sort { $0.name < $1.name }

        let result = DiffResult(
            file1: label(file1), file2: label(file2),
            addedCount: added.count, removedCount: removed.count, changedCount: changed.count,
            added: added, removed: removed, changed: changed
        )

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput([result], format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }

    private func readSource(_ path: String) throws -> String {
        if isStdinPath(path) {
            return readSourceFromStdin()
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func label(_ path: String) -> String {
        isStdinPath(path) ? "<stdin>" : path
    }
}

struct DiffResult: Codable, Sendable {
    let file1: String
    let file2: String
    let addedCount: Int
    let removedCount: Int
    let changedCount: Int
    let added: [DiffDeclaration]
    let removed: [DiffDeclaration]
    let changed: [DiffChange]

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "DiffResult",
      "type": "object",
      "properties": {
        "file1":         { "type": "string" },
        "file2":         { "type": "string" },
        "addedCount":    { "type": "integer" },
        "removedCount":  { "type": "integer" },
        "changedCount":  { "type": "integer" },
        "added":    { "type": "array", "items": { "$ref": "#/definitions/DiffDeclaration" } },
        "removed":  { "type": "array", "items": { "$ref": "#/definitions/DiffDeclaration" } },
        "changed":  { "type": "array", "items": { "$ref": "#/definitions/DiffChange" } }
      },
      "definitions": {
        "DiffDeclaration": {
          "type": "object",
          "properties": {
            "name":      { "type": "string" },
            "kind":      { "type": "string" },
            "signature": { "type": "string" },
            "line":      { "type": "integer" },
            "column":    { "type": "integer" }
          }
        },
        "DiffChange": {
          "type": "object",
          "properties": {
            "name":         { "type": "string" },
            "kind":         { "type": "string" },
            "oldSignature": { "type": "string" },
            "newSignature": { "type": "string" },
            "oldLine":      { "type": "integer" },
            "newLine":      { "type": "integer" }
          }
        }
      }
    }
    """
}

struct DiffDeclaration: Codable, Sendable {
    let name: String
    let kind: String
    let file: String
    let signature: String
    let line: Int
    let column: Int
}

struct DiffChange: Codable, Sendable {
    let name: String
    let kind: String
    let oldSignature: String
    let newSignature: String
    let oldLine: Int
    let newLine: Int
}

/// collect all declarations from a syntax tree (flat walk, includes nested).
class DiffDeclarationCollector: SyntaxVisitor {
    let source: String
    let filePath: String
    var declarations: [DiffDeclaration] = []

    init(source: String, filePath: String) {
        self.source = source
        self.filePath = filePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position
        let (line, col) = lineColumn(at: pos.utf8Offset, in: source)
        declarations.append(DiffDeclaration(
            name: node.name.text,
            kind: "function",
            file: filePath,
            signature: node.signature.description.trimmingCharacters(in: .whitespaces),
            line: line, column: col
        ))
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position
        let (line, col) = lineColumn(at: pos.utf8Offset, in: source)
        declarations.append(DiffDeclaration(
            name: node.name.text,
            kind: "struct",
            file: filePath,
            signature: node.inheritanceClause?.description.trimmingCharacters(in: .whitespaces) ?? "",
            line: line, column: col
        ))
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position
        let (line, col) = lineColumn(at: pos.utf8Offset, in: source)
        declarations.append(DiffDeclaration(
            name: node.name.text,
            kind: "class",
            file: filePath,
            signature: node.inheritanceClause?.description.trimmingCharacters(in: .whitespaces) ?? "",
            line: line, column: col
        ))
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position
        let (line, col) = lineColumn(at: pos.utf8Offset, in: source)
        declarations.append(DiffDeclaration(
            name: node.name.text,
            kind: "enum",
            file: filePath,
            signature: node.inheritanceClause?.description.trimmingCharacters(in: .whitespaces) ?? "",
            line: line, column: col
        ))
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position
        let (line, col) = lineColumn(at: pos.utf8Offset, in: source)
        declarations.append(DiffDeclaration(
            name: node.name.text,
            kind: "protocol",
            file: filePath,
            signature: node.inheritanceClause?.description.trimmingCharacters(in: .whitespaces) ?? "",
            line: line, column: col
        ))
        return .visitChildren
    }

    override func visit(_ node: TypealiasDeclSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position
        let (line, col) = lineColumn(at: pos.utf8Offset, in: source)
        declarations.append(DiffDeclaration(
            name: node.name.text,
            kind: "typealias",
            file: filePath,
            signature: node.initializer.value.description.trimmingCharacters(in: .whitespaces),
            line: line, column: col
        ))
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position
        let (line, col) = lineColumn(at: pos.utf8Offset, in: source)
        for binding in node.bindings {
            let name = binding.pattern.description
            let sig = binding.initializer?.value.description.trimmingCharacters(in: .whitespaces) ?? ""
            declarations.append(DiffDeclaration(
                name: name,
                kind: "variable",
                file: filePath,
                signature: sig,
                line: line, column: col
            ))
        }
        return .visitChildren
    }

    override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position
        let (line, col) = lineColumn(at: pos.utf8Offset, in: source)
        declarations.append(DiffDeclaration(
            name: node.name.text,
            kind: "enum_case",
            file: filePath,
            signature: node.parameterClause?.description ?? "",
            line: line, column: col
        ))
        return .visitChildren
    }
}
