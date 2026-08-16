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

    mutating func run() throws {
        let resolved = NSString(string: file).standardizingPath
        let source = try String(contentsOfFile: resolved, encoding: .utf8)
        let tree = Parser.parse(source: source)

        // Find the type's member block
        let finder = TypeMemberFinder(targetName: typeName)
        finder.walk(tree)

        guard let memberBlock = finder.foundMemberBlock else {
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: "no type '\(typeName)' found")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
            return
        }

        // Get the member block's source range
        let blockStart = memberBlock.position.utf8Offset
        let blockEnd = memberBlock.endPosition.utf8Offset

        // Extract member declarations
        let members = memberBlock.members
        guard members.count > 1 else {
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: "only one member; nothing to sort")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
            return
        }

        // Collect member info
        struct MemberInfo {
            let decl: MemberBlockItemSyntax
            let name: String
            let kind: String
            let source: String
        }

        var memberInfos: [MemberInfo] = []
        for member in members {
            let decl = member.decl
            let name = extractName(from: decl)
            let kind = extractKind(from: decl)
            let memberSource = member.description
            memberInfos.append(MemberInfo(decl: member, name: name, kind: kind, source: memberSource))
        }

        // Sort
        switch sortBy {
        case "kind":
            memberInfos.sort { a, b in
                if a.kind != b.kind { return a.kind < b.kind }
                return a.name < b.name
            }
        default:
            memberInfos.sort { a, b in
                if a.kind != b.kind {
                    let order = ["property", "method", "initializer", "deinitializer", "subscript", "typealias", "associatedtype", "enumcase", "nestedtype"]
                    let aOrder = order.firstIndex(of: a.kind) ?? 99
                    let bOrder = order.firstIndex(of: b.kind) ?? 99
                    if aOrder != bOrder { return aOrder < bOrder }
                }
                return a.name < b.name
            }
        }

        // Build sorted member block
        let sortedSource = memberInfos.map { $0.source }.joined()

        // Replace the member block content
        let startIdx = source.index(source.startIndex, offsetBy: blockStart)
        let endIdx = source.index(source.startIndex, offsetBy: blockEnd)

        // Find the opening brace position
        let blockText = String(source[startIdx..<endIdx])
        let braceIdx = blockText.firstIndex(of: "{")!
        let afterBrace = blockText[blockText.index(after: braceIdx)...]

        // Find the closing brace (relative to blockText, not afterBrace)
        let closeBraceInBlock = blockText.lastIndex(of: "}")!
        let contentStart = blockText.index(after: braceIdx)
        let contentEnd = closeBraceInBlock

        var modified = source
        let rangeStart = source.index(startIdx, offsetBy: blockText.distance(from: blockText.startIndex, to: contentStart))
        let rangeEnd = source.index(startIdx, offsetBy: blockText.distance(from: blockText.startIndex, to: contentEnd))
        modified.replaceSubrange(rangeStart..<rangeEnd, with: "\n" + sortedSource + "\n")

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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
            return
        }

        if backup {
            try FileManager.default.copyItem(atPath: resolved, toPath: resolved + ".bak")
        }

        let target = outputPath.isEmpty ? resolved : outputPath
        try modified.write(toFile: target, atomically: true, encoding: .utf8)

        let result = EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: warning)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
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
