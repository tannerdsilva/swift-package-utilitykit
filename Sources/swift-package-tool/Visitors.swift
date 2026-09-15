import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

// MARK: - visitor base

/// collects declarations from a syntax tree, optionally filtering by kind.
public class DeclarationCollector: SyntaxVisitor {
    public private(set) var declarations: [DeclarationInfo] = []
    public let filePath: String
    public let source: String
    public let kinds: Set<String>?

    public init(filePath: String, source: String, kinds: Set<String>? = nil) {
        self.filePath = filePath
        self.source = source
        self.kinds = kinds
        super.init(viewMode: .sourceAccurate)
    }

    private func add(_ node: some DeclSyntaxProtocol) {
        let kind = kindString(for: node)
        if let filter = kinds, !filter.contains(kind) { return }
        guard let name = declarationName(from: node) else { return }
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let sig = signatureString(for: node)
        let doc = extractDocComment(from: node.leadingTrivia)
        let mods = modifierNames(from: node)
        declarations.append(DeclarationInfo(
            name: name, kind: kind, file: filePath,
            line: line, column: col, offset: pos,
            signature: sig, docComment: doc,
            modifiers: mods
        ))
    }

    // MARK: visit methods

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
    public override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: PrecedenceGroupDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
    public override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        add(node); return .visitChildren
    }
}

// MARK: - symbol finder
// MARK: - search

/// a single match from a text search.
public struct SearchMatch: Codable, Sendable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let column: Int
    public let lineContent: String
    public let contextBefore: [String]
    public let contextAfter: [String]

    public var description: String {
        "\(file):\(line):\(column):  \(lineContent)"
    }

    public static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "SearchMatch",
      "type": "object",
      "properties": {
        "file":          { "type": "string", "description": "Source file path" },
        "line":          { "type": "integer", "description": "1-based line number" },
        "column":        { "type": "integer", "description": "1-based column number" },
        "lineContent":   { "type": "string", "description": "Text of the matching line" },
        "contextBefore": { "type": "array", "items": { "type": "string" }, "description": "Lines before the match" },
        "contextAfter":  { "type": "array", "items": { "type": "string" }, "description": "Lines after the match" }
      },
      "required": ["file", "line", "column", "lineContent"]
    }
    """
}

/// search a single file for a pattern. returns all matches.
public func searchFile(
    _ path: String,
    pattern: String,
    isRegex: Bool,
    ignoreCase: Bool,
    context: Int
) throws -> [SearchMatch] {
    let source: String? = readSwiftSource(path)
    guard let source else { return [] }
    let lines = source.components(separatedBy: "\n")
    var matches: [SearchMatch] = []

    let searchPattern: String
    if isRegex {
        searchPattern = pattern
    } else {
        // escape literal string for regex
        searchPattern = NSRegularExpression.escapedPattern(for: pattern)
    }

    let regexOptions: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
    guard let regex = try? NSRegularExpression(pattern: searchPattern, options: regexOptions) else {
        throw UsageError("invalid search pattern: \(pattern)")
    }

    for (i, line) in lines.enumerated() {
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        let lineMatches = regex.matches(in: line, options: [], range: nsRange)
        for m in lineMatches {
            let col = line.distance(from: line.startIndex, to: line.utf16.index(line.utf16.startIndex, offsetBy: m.range.location)) + 1
            let before = context > 0 ? Array(lines[max(0, i-context)..<i]) : []
            let after = context > 0 ? Array(lines[i+1..<min(lines.count, i+1+context)]) : []
            matches.append(SearchMatch(
                file: path,
                line: i + 1,
                column: col,
                lineContent: line,
                contextBefore: before,
                contextAfter: after
            ))
        }
    }

    return matches
}

// MARK: - references

/// a single reference to a symbol found in the AST.
public struct SymbolReference: Codable, Sendable, CustomStringConvertible {
    public let symbol: String
    public let file: String
    public let line: Int
    public let column: Int
    public let context: String
    public let role: String   // "declaration", "call", "access", "type_ref"

    public var description: String {
        "\(file):\(line):\(column) [\(role)] \(context)"
    }

    public static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "SymbolReference",
      "type": "object",
      "properties": {
        "symbol":  { "type": "string", "description": "Referenced symbol name" },
        "file":    { "type": "string", "description": "Source file path" },
        "line":    { "type": "integer", "description": "1-based line number" },
        "column":  { "type": "integer", "description": "1-based column number" },
        "context": { "type": "string", "description": "Surrounding source text" },
        "role":    { "type": "string", "description": "declaration, call, access, or type_ref" }
      },
      "required": ["symbol", "file", "line", "column", "role"]
    }
    """
}

/// finds all references to a given symbol name in a syntax tree.
public class ReferenceFinder: SyntaxVisitor {
    public let targetName: String
    public let filePath: String
    public let source: String
    public private(set) var references: [SymbolReference] = []

    public init(targetName: String, filePath: String, source: String) {
        self.targetName = targetName
        self.filePath = filePath
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    private func addRef(_ node: some SyntaxProtocol, role: String) {
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let ctx = sourceText(for: node, in: source).prefix(80).trimmingCharacters(in: CharacterSet.whitespaces)
        references.append(SymbolReference(
            symbol: targetName,
            file: filePath,
            line: line,
            column: col,
            context: String(ctx),
            role: role
        ))
    }

    // identifier expressions (variable/function references)
    public override func visit(_ node: IdentifierExprSyntax) -> SyntaxVisitorContinueKind {
        if node.identifier.text == targetName {
            addRef(node, role: "call")
        }
        return .visitChildren
    }

    // member access (foo.bar)
    public override func visit(_ node: MemberAccessExprSyntax) -> SyntaxVisitorContinueKind {
        if node.declName.baseName.text == targetName {
            addRef(node, role: "access")
        }
        return .visitChildren
    }

    // declarations (catches the definition itself)
    public override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { addRef(node, role: "declaration") }
        return .visitChildren
    }
    public override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { addRef(node, role: "declaration") }
        return .visitChildren
    }
    public override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { addRef(node, role: "declaration") }
        return .visitChildren
    }
    public override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { addRef(node, role: "declaration") }
        return .visitChildren
    }
    public override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { addRef(node, role: "declaration") }
        return .visitChildren
    }
    public override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { addRef(node, role: "declaration") }
        return .visitChildren
    }
    public override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
               pattern.identifier.text == targetName {
                addRef(node, role: "declaration")
            }
        }
        return .visitChildren
    }
}

// MARK: - imports

/// information about a single import statement.
public struct ImportInfo: Codable, Sendable, CustomStringConvertible {
    public let module: String
    public let kind: String       // "module", "struct", "func", etc.
    public let file: String
    public let line: Int
    public let column: Int

    public var description: String {
        "\(file):\(line):\(column)  \(kind) import \(module)"
    }

    public static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "ImportInfo",
      "type": "object",
      "properties": {
        "module": { "type": "string", "description": "Imported module name" },
        "kind":   { "type": "string", "description": "Import kind: module, struct, func, etc." },
        "file":   { "type": "string", "description": "Source file path" },
        "line":   { "type": "integer", "description": "1-based line number" },
        "column": { "type": "integer", "description": "1-based column number" }
      },
      "required": ["module", "kind", "file", "line", "column"]
    }
    """
}

/// collects all import declarations from a syntax tree.
public class ImportCollector: SyntaxVisitor {
    public let filePath: String
    public let source: String
    public private(set) var imports: [ImportInfo] = []

    public init(filePath: String, source: String) {
        self.filePath = filePath
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    public override func visit(_ node: ImportDeclSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let path = node.path.map { $0.name.text }.joined(separator: ".")
        let kind: String
        switch node.importKindSpecifier?.text {
        case "typealias": kind = "typealias"
        case "struct":    kind = "struct"
        case "class":     kind = "class"
        case "enum":      kind = "enum"
        case "protocol":  kind = "protocol"
        case "var":       kind = "var"
        case "func":      kind = "func"
        case "let":       kind = "let"
        default:          kind = "module"
        }
        imports.append(ImportInfo(module: path, kind: kind, file: filePath, line: line, column: col))
        return .visitChildren
    }
}

