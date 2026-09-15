import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParserDiagnostics
import SwiftParser

/// sort members of a type declaration alphabetically or by kind.
struct SortCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "sort",
        abstract: "Sort members of a type."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .customLong("type"), help: "Type name to sort members of.")
    var typeName: String

    @Option(name: .customLong("by"), help: "Sort key: name (default) or kind.")
    var sortBy: String = "name"

    @Flag(name: .long, help: "Show diff without modifying.")
    var dryRun = false

    @Flag(name: .long, help: "Save original as .bak before editing.")
    var backup = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Re-parse to verify syntactic validity.")
    var verify = true

    @Flag(name: .long, help: "Show unified diff of changes.")
    var showDiff = false

    @Option(name: .customLong("output"), help: "Write to a different file instead of in-place.")
    var outputPath: String = ""

    @Flag(name: .long, help: "Write even if verification fails.")
    var force = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .long, help: "Output format: json, compact, short, csv, jsonl.")
    var outputFormat: OutputFormat?

    mutating func run() throws {
        if printSchemaIfRequested() { return }
        let resolved = NSString(string: file).standardizingPath
        let source = try String(contentsOfFile: resolved, encoding: .utf8)
        let tree = Parser.parse(source: source)

        // Use SyntaxRewriter to sort members
        let rewriter = MemberSortRewriter(targetName: typeName, sortBy: sortBy)
        let modifiedTree = rewriter.rewrite(tree)

        guard rewriter.didModify else {
            let warning = rewriter.notFound
                ? "no type '\(typeName)' found"
                : "only one member; nothing to sort"
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: warning)
            try emitEditResult(result)
            return
        }

        let modified = modifiedTree.description

        let original = source
        var warning: String? = nil
        var verified = true
        if verify {
            let verifyTree = Parser.parse(source: modified)
            let diags = ParseDiagnosticsGenerator.diagnostics(for: verifyTree)
            let errors = diags.filter { $0.diagMessage.severity == .error }
            if !errors.isEmpty {
                verified = false
                warning = "edit introduced \(errors.count) syntax error(s); use --force to write anyway"
            }
        }

        let diff: String? = (showDiff || dryRun) ? FileEditor.makeDiff(original: original, modified: modified) : nil

        if dryRun {
            let result = EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: warning)
            try emitEditResult(result)
            return
        }

        // block the write when verification fails unless --force is set
        guard verified || force else {
            let result = EditResult(file: resolved, modified: false, diff: diff, verified: false, warning: warning)
            try emitEditResult(result)
            return
        }

        if backup {
            try FileManager.default.copyItem(atPath: resolved, toPath: resolved + ".bak")
        }

        let target = outputPath.isEmpty ? resolved : outputPath
        try modified.write(toFile: target, atomically: true, encoding: .utf8)

        let result = EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: warning)
        try emitEditResult(result)
    }
}

/// SyntaxRewriter that sorts members of a type declaration.
class MemberSortRewriter: SyntaxRewriter {
    let targetName: String
    let sortBy: String
    var didModify = false
    var notFound = true

    init(targetName: String, sortBy: String) {
        self.targetName = targetName
        self.sortBy = sortBy
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        guard node.name.text == targetName else { return DeclSyntax(node) }
        notFound = false
        return DeclSyntax(sortMembers(of: node))
    }

    override func visit(_ node: ClassDeclSyntax) -> DeclSyntax {
        guard node.name.text == targetName else { return DeclSyntax(node) }
        notFound = false
        return DeclSyntax(sortMembers(of: node))
    }

    override func visit(_ node: EnumDeclSyntax) -> DeclSyntax {
        guard node.name.text == targetName else { return DeclSyntax(node) }
        notFound = false
        return DeclSyntax(sortMembers(of: node))
    }

    override func visit(_ node: ProtocolDeclSyntax) -> DeclSyntax {
        guard node.name.text == targetName else { return DeclSyntax(node) }
        notFound = false
        return DeclSyntax(sortMembers(of: node))
    }

    override func visit(_ node: ExtensionDeclSyntax) -> DeclSyntax {
        let extName = node.extendedType.description.trimmingCharacters(in: .whitespaces)
        guard extName == targetName else { return DeclSyntax(node) }
        notFound = false
        return DeclSyntax(sortMembers(of: node))
    }

    private func sortMembers<T: DeclGroupSyntax>(of node: T) -> T {
        let members = node.memberBlock.members
        guard members.count > 1 else { return node }

        var infos: [MemberSortInfo] = []
        for member in members {
            let name = extractName(from: member.decl)
            let kind = extractKind(from: member.decl)
            infos.append(MemberSortInfo(item: member, name: name, kind: kind))
        }

        switch sortBy {
        case "kind":
            infos.sort { a, b in
                if a.kind != b.kind { return a.kind < b.kind }
                return a.name < b.name
            }
        default:
            infos.sort { a, b in
                if a.kind != b.kind {
                    let order = ["property", "method", "initializer", "deinitializer", "subscript", "typealias", "associatedtype", "enumcase", "nestedtype"]
                    let aOrder = order.firstIndex(of: a.kind) ?? 99
                    let bOrder = order.firstIndex(of: b.kind) ?? 99
                    if aOrder != bOrder { return aOrder < bOrder }
                }
                return a.name < b.name
            }
        }

        let sortedList = MemberBlockItemListSyntax(infos.map { $0.item })
        didModify = true
        return node.with(\.memberBlock.members, sortedList)
    }
}

private func extractName(from decl: DeclSyntax) -> String {
    if let s = decl.as(StructDeclSyntax.self) { return s.name.text }
    if let c = decl.as(ClassDeclSyntax.self) { return c.name.text }
    if let e = decl.as(EnumDeclSyntax.self) { return e.name.text }
    if let p = decl.as(ProtocolDeclSyntax.self) { return p.name.text }
    if let f = decl.as(FunctionDeclSyntax.self) { return f.name.text }
    if let i = decl.as(InitializerDeclSyntax.self) { return "init" }
    if let d = decl.as(DeinitializerDeclSyntax.self) { return "deinit" }
    if let s = decl.as(SubscriptDeclSyntax.self) { return "subscript" }
    if let t = decl.as(TypeAliasDeclSyntax.self) { return t.name.text }
    if let a = decl.as(AssociatedTypeDeclSyntax.self) { return a.name.text }
    if let v = decl.as(VariableDeclSyntax.self) {
        if let binding = v.bindings.first, let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
            return pattern.identifier.text
        }
    }
    if let ec = decl.as(EnumCaseDeclSyntax.self) {
        if let element = ec.elements.first {
            return element.name.text
        }
    }
    return ""
}

private func extractKind(from decl: DeclSyntax) -> String {
    if decl.is(StructDeclSyntax.self) { return "nestedtype" }
    if decl.is(ClassDeclSyntax.self) { return "nestedtype" }
    if decl.is(EnumDeclSyntax.self) { return "nestedtype" }
    if decl.is(ProtocolDeclSyntax.self) { return "nestedtype" }
    if decl.is(FunctionDeclSyntax.self) { return "method" }
    if decl.is(InitializerDeclSyntax.self) { return "initializer" }
    if decl.is(DeinitializerDeclSyntax.self) { return "deinitializer" }
    if decl.is(SubscriptDeclSyntax.self) { return "subscript" }
    if decl.is(TypeAliasDeclSyntax.self) { return "typealias" }
    if decl.is(AssociatedTypeDeclSyntax.self) { return "associatedtype" }
    if decl.is(VariableDeclSyntax.self) { return "property" }
    if decl.is(EnumCaseDeclSyntax.self) { return "enumcase" }
    return "other"
}

/// Information about a member for sorting.
struct MemberSortInfo {
    let item: MemberBlockItemSyntax
    let name: String
    let kind: String
}
