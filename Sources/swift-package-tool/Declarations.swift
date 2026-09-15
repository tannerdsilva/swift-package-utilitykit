import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

// MARK: - declaration info model

/// structured information about a single declaration, serializable as JSON
/// for agent consumption.
public struct DeclarationInfo: Codable, Sendable {
    public let name: String
    public let kind: String
    public let file: String
    public let line: Int
    public let column: Int
    public let offset: Int
    public let signature: String
    public let docComment: String
    public let modifiers: [String]

    public init(
        name: String, kind: String, file: String,
        line: Int, column: Int, offset: Int,
        signature: String, docComment: String,
        modifiers: [String]
    ) {
        self.name = name
        self.kind = kind
        self.file = file
        self.line = line
        self.column = column
        self.offset = offset
        self.signature = signature
        self.docComment = docComment
        self.modifiers = modifiers
    }

    public static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "DeclarationInfo",
      "type": "object",
      "properties": {
        "name":       { "type": "string", "description": "Declaration name" },
        "kind":       { "type": "string", "description": "Declaration kind: function, struct, class, enum, protocol, etc." },
        "file":       { "type": "string", "description": "Source file path" },
        "line":       { "type": "integer", "description": "1-based line number" },
        "column":     { "type": "integer", "description": "1-based column number" },
        "offset":     { "type": "integer", "description": "UTF-8 byte offset" },
        "signature":  { "type": "string", "description": "One-line declaration signature" },
        "docComment": { "type": "string", "description": "Documentation comment text" },
        "modifiers":  { "type": "array", "items": { "type": "string" }, "description": "Declaration modifiers" }
      },
      "required": ["name", "kind", "file", "line", "column", "offset", "signature", "docComment", "modifiers"]
    }
    """
}

/// detailed symbol information for the inspect command.
public struct SymbolDetail: Codable, Sendable {
    public let name: String
    public let kind: String
    public let file: String
    public let line: Int
    public let column: Int
    public let offset: Int
    public let signature: String
    public let docComment: String
    public let modifiers: [String]
    public let sourceText: String
    public let children: [DeclarationInfo]

    public init(
        name: String, kind: String, file: String,
        line: Int, column: Int, offset: Int,
        signature: String, docComment: String,
        modifiers: [String], sourceText: String,
        children: [DeclarationInfo]
    ) {
        self.name = name
        self.kind = kind
        self.file = file
        self.line = line
        self.column = column
        self.offset = offset
        self.signature = signature
        self.docComment = docComment
        self.modifiers = modifiers
        self.sourceText = sourceText
        self.children = children
    }

    public static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "SymbolDetail",
      "type": "object",
      "properties": {
        "name":        { "type": "string", "description": "Symbol name" },
        "kind":        { "type": "string", "description": "Declaration kind" },
        "file":        { "type": "string", "description": "Source file path" },
        "line":        { "type": "integer", "description": "1-based line number" },
        "column":      { "type": "integer", "description": "1-based column number" },
        "offset":      { "type": "integer", "description": "UTF-8 byte offset in the source" },
        "signature":   { "type": "string", "description": "One-line declaration signature" },
        "docComment":  { "type": "string", "description": "Documentation comment text" },
        "modifiers":   { "type": "array", "items": { "type": "string" }, "description": "Declaration modifiers" },
        "sourceText":  { "type": "string", "description": "Full source text of the declaration" },
        "children":    { "type": "array", "description": "Immediate child members" }
      },
      "required": ["name", "kind", "file", "line", "column", "signature"]
    }
    """
}

// MARK: - trivia helpers
// MARK: - symbol finder

/// finds a single declaration by name and returns its detail.
public class SymbolFinder: SyntaxVisitor {
    public let targetName: String
    public let filePath: String
    public let source: String
    public private(set) var found: SymbolDetail?

    public init(targetName: String, filePath: String, source: String) {
        self.targetName = targetName
        self.filePath = filePath
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    private func check(_ node: some DeclSyntaxProtocol) {
        guard let name = declarationName(from: node), name == targetName else { return }
        let kind = kindString(for: node)
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let sig = signatureString(for: node)
        let doc = extractDocComment(from: node.leadingTrivia)
        let mods = modifierNames(from: node)
        let src = sourceText(for: node, in: source)

        // collect immediate children
        let childCollector = DeclarationCollector(filePath: filePath, source: source)
        childCollector.walk(node)
        let children = childCollector.declarations

        found = SymbolDetail(
            name: name, kind: kind, file: filePath,
            line: line, column: col, offset: pos,
            signature: sig, docComment: doc,
            modifiers: mods, sourceText: src,
            children: children
        )
    }

    public override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: PrecedenceGroupDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
    public override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        check(node); return .visitChildren
    }
}

