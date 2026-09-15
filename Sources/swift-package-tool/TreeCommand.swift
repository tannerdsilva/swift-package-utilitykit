import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// show a hierarchical symbol tree for Swift source files, formatted as
/// indented Swift-like declarations for token-efficient agent consumption.
///
/// walks only type member blocks (struct/class/enum/protocol/extension),
/// skipping local variables inside function bodies and import statements.
struct TreeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tree",
        abstract: "Show a hierarchical symbol tree for Swift source files."
    )

    @Argument(help: "Files or directories to scan.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Option(name: .long, help: "Output format: tree (default), json, compact.")
    var outputFormat: OutputFormat?

    @Option(name: .long, help: "Maximum number of top-level declarations per file.")
    var limit: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(TreeFile.jsonSchema)
            return
        }
        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        try validateInputPathsExist(paths)

        var perFile: [TreeFile] = []

        for filePath in files.sorted() {
            guard let source = readSwiftSource(filePath) else { continue }
            let tree = Parser.parse(source: source)
            var roots = collectTopDeclarations(from: tree, source: source)
            if let limit = limit, roots.count > limit {
                roots = Array(roots.prefix(limit))
            }
            perFile.append(TreeFile(file: filePath, nodes: roots.map { TreeNode(node: $0) }))
        }

        // text mode is the historical default (indented Swift-like declarations)
        if outputFormat == nil || outputFormat == .short || outputFormat == .csv {
            var output = ""
            for (i, tf) in perFile.enumerated() {
                if i > 0 { output += "\n" }
                output += "// \(tf.file)\n"
                output += formatTreeNodes(perFileNodes(tf), depth: 0)
            }
            try writeOutput(output, to: outputPath)
            return
        }

        let fmt: OutputFormat = outputFormat ?? .compact
        let outputStr = try formatOutput(perFile, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }

    /// rebuild the raw node tree (used by the text renderer) from the
    /// codable mirror — same structure, so both modes stay in lockstep.
    private func perFileNodes(_ tf: TreeFile) -> [SymbolTreeNode] {
        func inflate(_ n: TreeNode) -> SymbolTreeNode {
            let node = SymbolTreeNode(label: n.label)
            node.children = n.children.map(inflate)
            return node
        }
        return tf.nodes.map(inflate)
    }
}

/// a per-file tree, codable so `tree --output-format json` mirrors the text.
struct TreeFile: Codable, Sendable {
    let file: String
    let nodes: [TreeNode]

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "TreeFile",
      "type": "object",
      "properties": {
        "file":  { "type": "string", "description": "Source file path" },
        "nodes": { "type": "array", "items": { "$ref": "#/definitions/TreeNode" } }
      },
      "required": ["file", "nodes"],
      "definitions": {
        "TreeNode": {
          "type": "object",
          "properties": {
            "label":    { "type": "string", "description": "Swift-like declaration label" },
            "children": { "type": "array", "items": { "$ref": "#/definitions/TreeNode" } }
          },
          "required": ["label", "children"]
        }
      }
    }
    """
}

/// codable mirror of SymbolTreeNode for JSON tree output.
struct TreeNode: Codable, Sendable {
    let label: String
    let children: [TreeNode]

    init(node: SymbolTreeNode) {
        self.label = node.label
        self.children = node.children.map(TreeNode.init)
    }
}

// MARK: - tree node

/// a single node in the symbol tree, holding its formatted label and mutable
/// children array.
final class SymbolTreeNode: @unchecked Sendable {
    let label: String
    var children: [SymbolTreeNode] = []

    init(label: String) {
        self.label = label
    }
}

// MARK: - tree construction (manual walk, no SyntaxVisitor)

/// collect top-level declarations from a source file, skipping imports.
private func collectTopDeclarations(from sourceFile: SourceFileSyntax, source: String) -> [SymbolTreeNode] {
    var roots: [SymbolTreeNode] = []
    for statement in sourceFile.statements {
        guard let decl = statement.item.as(DeclSyntax.self) else { continue }
        // skip import declarations — noise for a symbol tree
        if decl.is(ImportDeclSyntax.self) { continue }
        if let node = buildNode(from: decl, source: source) {
            roots.append(node)
        }
    }
    return roots
}

/// build a single tree node from a declaration, recursing into member blocks
/// for type-like declarations.
private func buildNode(from decl: DeclSyntax, source: String) -> SymbolTreeNode? {
    // skip imports at any level
    if decl.is(ImportDeclSyntax.self) { return nil }

    // enum cases: one node per element (a single EnumCaseDeclSyntax can have
    // multiple elements like `case foo, bar`)
    if let caseDecl = decl.as(EnumCaseDeclSyntax.self) {
        let parent = SymbolTreeNode(label: "") // transient container
        for element in caseDecl.elements {
            let label = makeEnumCaseLabel(element)
            parent.children.append(SymbolTreeNode(label: label))
        }
        // if there's only one element, return it directly; otherwise return
        // the container (which formatTreeNodes will skip for empty-label nodes)
        if parent.children.count == 1 {
            return parent.children[0]
        }
        return parent
    }

    let label = makeLabel(from: decl, source: source)
    let node = SymbolTreeNode(label: label)

    // recurse into member blocks for type-like declarations
    if let members = memberBlock(of: decl) {
        for member in members.members {
            if let child = buildNode(from: member.decl, source: source) {
                node.children.append(child)
            }
        }
    }

    return node
}

/// extract the member block from a type-like declaration, if any.
private func memberBlock(of decl: DeclSyntax) -> MemberBlockSyntax? {
    if let s = decl.as(StructDeclSyntax.self) { return s.memberBlock }
    if let c = decl.as(ClassDeclSyntax.self) { return c.memberBlock }
    if let e = decl.as(EnumDeclSyntax.self) { return e.memberBlock }
    if let p = decl.as(ProtocolDeclSyntax.self) { return p.memberBlock }
    if let ext = decl.as(ExtensionDeclSyntax.self) { return ext.memberBlock }
    return nil
}

/// produce a one-line Swift-like label for any declaration.
private func makeLabel(from decl: DeclSyntax, source: String) -> String {
    // use the existing signatureString helper which already produces
    // keyword-first output like "struct Foo: Proto" or "var x: Int"
    if let node = decl.as(ProtocolDeclSyntax.self) {
        let sig = signatureString(for: node)
        let mods = modifierNames(from: node)
        return mods.isEmpty ? sig : "\(mods.joined(separator: " ")) \(sig)"
    }
    if let node = decl.as(StructDeclSyntax.self) {
        let sig = signatureString(for: node)
        let mods = modifierNames(from: node)
        return mods.isEmpty ? sig : "\(mods.joined(separator: " ")) \(sig)"
    }
    if let node = decl.as(ClassDeclSyntax.self) {
        let sig = signatureString(for: node)
        let mods = modifierNames(from: node)
        return mods.isEmpty ? sig : "\(mods.joined(separator: " ")) \(sig)"
    }
    if let node = decl.as(EnumDeclSyntax.self) {
        let sig = signatureString(for: node)
        let mods = modifierNames(from: node)
        return mods.isEmpty ? sig : "\(mods.joined(separator: " ")) \(sig)"
    }
    if let node = decl.as(ExtensionDeclSyntax.self) {
        return signatureString(for: node)
    }
    if let node = decl.as(FunctionDeclSyntax.self) {
        let sig = signatureString(for: node)
        let mods = modifierNames(from: node)
        return mods.isEmpty ? sig : "\(mods.joined(separator: " ")) \(sig)"
    }
    if let node = decl.as(VariableDeclSyntax.self) {
        let sig = signatureString(for: node)
        let mods = modifierNames(from: node)
        return mods.isEmpty ? sig : "\(mods.joined(separator: " ")) \(sig)"
    }
    if let node = decl.as(InitializerDeclSyntax.self) {
        let sig = signatureString(for: node)
        let mods = modifierNames(from: node)
        return mods.isEmpty ? sig : "\(mods.joined(separator: " ")) \(sig)"
    }
    if let node = decl.as(DeinitializerDeclSyntax.self) {
        return signatureString(for: node)
    }
    if let node = decl.as(SubscriptDeclSyntax.self) {
        let sig = signatureString(for: node)
        let mods = modifierNames(from: node)
        return mods.isEmpty ? sig : "\(mods.joined(separator: " ")) \(sig)"
    }
    if let node = decl.as(TypeAliasDeclSyntax.self) {
        return signatureString(for: node)
    }
    if let node = decl.as(AssociatedTypeDeclSyntax.self) {
        return signatureString(for: node)
    }
    if let node = decl.as(OperatorDeclSyntax.self) {
        return signatureString(for: node)
    }
    if let node = decl.as(PrecedenceGroupDeclSyntax.self) {
        return signatureString(for: node)
    }
    if let node = decl.as(MacroDeclSyntax.self) {
        let sig = signatureString(for: node)
        let mods = modifierNames(from: node)
        return mods.isEmpty ? sig : "\(mods.joined(separator: " ")) \(sig)"
    }
    if let node = decl.as(MacroExpansionDeclSyntax.self) {
        return signatureString(for: node)
    }

    // fallback: raw first line
    return decl.description.trimmingCharacters(in: .whitespaces)
        .components(separatedBy: "\n").first ?? ""
}

/// format a single enum case element.
private func makeEnumCaseLabel(_ element: EnumCaseElementSyntax) -> String {
    let params = element.parameterClause.map { clause in
        let items = clause.parameters.map { param -> String in
            let name = param.firstName?.text ?? ""
            let type = param.type.description.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? "\(type)" : "\(name): \(type)"
        }
        return "(\(items.joined(separator: ", ")))"
    } ?? ""
    return "case \(element.name.text)\(params)"
}

// MARK: - output formatting

/// format a list of tree nodes as indented Swift-like text.
/// nodes with an empty label are treated as transparent containers — their
/// children are rendered at the current depth instead of creating a new level.
private func formatTreeNodes(_ nodes: [SymbolTreeNode], depth: Int) -> String {
    guard !nodes.isEmpty else { return "" }
    let indent = String(repeating: "  ", count: depth)
    return nodes.map { node in
        // transparent container: render children at same depth
        if node.label.isEmpty {
            return formatTreeNodes(node.children, depth: depth)
        }
        let children = formatTreeNodes(node.children, depth: depth + 1)
        if children.isEmpty {
            return "\(indent)\(node.label)"
        }
        return "\(indent)\(node.label) {\n\(children)\n\(indent)}"
    }.joined(separator: "\n")
}
