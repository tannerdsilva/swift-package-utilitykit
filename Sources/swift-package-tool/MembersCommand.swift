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

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
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

        try validateInputPathsExist(paths)

        // search for the type across all files
        for filePath in files {
            guard let source = readSwiftSource(filePath) else { continue }
            let tree = Parser.parse(source: source)
            let finder = TypeFinder(targetName: type, filePath: filePath, source: source)
            finder.walk(tree)

            if let typeNode = finder.found {
                // collect direct members from the type's member block
                let collector = MemberCollector(filePath: filePath, source: source)
                collector.collectMembers(from: typeNode)
                let fmt: OutputFormat = prettyPrint ? .json : outputFormat
                let outputStr = try formatOutput(collector.members, format: fmt)
                try writeOutput(outputStr, to: outputPath)
                return
            }
        }

        throw ValidationError("type '\(type)' not found in the given paths")
    }
}

/// finds a type declaration by name and returns the raw syntax node.
class TypeFinder: SyntaxVisitor {
    let targetName: String
    let filePath: String
    let source: String
    var found: (any DeclSyntaxProtocol)?

    init(targetName: String, filePath: String, source: String) {
        self.targetName = targetName
        self.filePath = filePath
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    private func check(_ node: some DeclSyntaxProtocol) {
        guard let name = declarationName(from: node), name == targetName else { return }
        found = node
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return found != nil ? .skipChildren : .visitChildren
    }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return found != nil ? .skipChildren : .visitChildren
    }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return found != nil ? .skipChildren : .visitChildren
    }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return found != nil ? .skipChildren : .visitChildren
    }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return found != nil ? .skipChildren : .visitChildren
    }
    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return found != nil ? .skipChildren : .visitChildren
    }
}

/// collects only direct members of a type by inspecting individual declaration nodes.
class MemberCollector {
    let filePath: String
    let source: String
    var members: [MemberItem] = []

    init(filePath: String, source: String) {
        self.filePath = filePath
        self.source = source
    }

    /// examine a single declaration node and add it as a member if it is one.
    func collect(_ decl: DeclSyntax) {
        if let node = decl.as(FunctionDeclSyntax.self) {
            add(node, kind: "function")
        } else if let node = decl.as(VariableDeclSyntax.self) {
            add(node, kind: "variable")
        } else if let node = decl.as(InitializerDeclSyntax.self) {
            add(node, kind: "initializer")
        } else if let node = decl.as(DeinitializerDeclSyntax.self) {
            add(node, kind: "deinitializer")
        } else if let node = decl.as(SubscriptDeclSyntax.self) {
            add(node, kind: "subscript")
        } else if let node = decl.as(StructDeclSyntax.self) {
            add(node, kind: "struct")
        } else if let node = decl.as(ClassDeclSyntax.self) {
            add(node, kind: "class")
        } else if let node = decl.as(EnumDeclSyntax.self) {
            add(node, kind: "enum")
        } else if let node = decl.as(ProtocolDeclSyntax.self) {
            add(node, kind: "protocol")
        } else if let node = decl.as(TypeAliasDeclSyntax.self) {
            add(node, kind: "typealias")
        } else if let node = decl.as(EnumCaseDeclSyntax.self) {
            // enum case decl can have multiple elements
            for element in node.elements {
                addCase(element)
            }
        }
    }

    /// extract members from a type declaration's member block.
    func collectMembers(from typeNode: some DeclSyntaxProtocol) {
        let memberBlock: MemberBlockSyntax? = {
            if let s = typeNode as? StructDeclSyntax { return s.memberBlock }
            if let c = typeNode as? ClassDeclSyntax { return c.memberBlock }
            if let e = typeNode as? EnumDeclSyntax { return e.memberBlock }
            if let p = typeNode as? ProtocolDeclSyntax { return p.memberBlock }
            if let ext = typeNode as? ExtensionDeclSyntax { return ext.memberBlock }
            return nil
        }()
        guard let block = memberBlock else { return }
        for member in block.members {
            collect(member.decl)
        }
    }

    private func add(_ node: some DeclSyntaxProtocol, kind: String) {
        guard let name = declarationName(from: node) else { return }
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let sig = signatureString(for: node)
        let mods = modifierNames(from: node)
        members.append(MemberItem(
            name: name, kind: kind, file: filePath,
            line: line, column: col,
            signature: sig, modifiers: mods
        ))
    }

    private func addCase(_ node: EnumCaseElementSyntax) {
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let sig = node.parameterClause.map { "(\($0.parameters.map { "\($0.firstName?.text ?? ""): \($0.type)" }.joined(separator: ", ")))" } ?? ""
        members.append(MemberItem(
            name: node.name.text, kind: "enum_case", file: filePath,
            line: line, column: col,
            signature: sig, modifiers: []
        ))
    }
}

struct MemberItem: Codable, Sendable, CustomStringConvertible {
    let name: String
    let kind: String
    let file: String
    let line: Int
    let column: Int
    let signature: String
    let modifiers: [String]

    var description: String {
        let mods = modifiers.isEmpty ? "" : "\(modifiers.joined(separator: " ")) "
        return "\(file):\(line):\(column)  [\(kind)]  \(mods)\(signature)"
    }

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
