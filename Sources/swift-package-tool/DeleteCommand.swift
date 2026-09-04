import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParserDiagnostics
import SwiftParser

/// remove code from a Swift source file by line range, symbol name, or pattern.
///
/// three modes:
///   --lines <start>-<end>    remove a range of lines
///   --symbol <name>          remove a declaration (AST-aware, removes docc comment too)
///   --matching <pattern>     remove every line containing the pattern
struct DeleteCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Remove code by line range, symbol, or pattern."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .long, help: "Line range to remove (e.g. '10-20').")
    var lines: String?

    @Option(name: .long, help: "Symbol name to remove (AST-aware).")
    var symbol: String?

    @Option(name: .long, help: "Remove every line containing this text.")
    var matching: String?

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
        let modes = [lines != nil, symbol != nil, matching != nil].filter { $0 }.count
        guard modes == 1 else {
            throw ValidationError("specify exactly one of --lines, --symbol, or --matching")
        }

        if let s = symbol {
            try runSymbolDelete(name: s)
            return
        }

        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            let lines = source.components(separatedBy: "\n")

            if let range = self.lines {
                let parts = range.split(separator: "-")
                guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]) else {
                    return ""
                }
                let startIdx = max(0, start - 1)
                let endIdx = min(lines.count, end)
                guard startIdx < endIdx else { return "" }
                var newLines = lines
                newLines.removeSubrange(startIdx..<endIdx)
                source = newLines.joined(separator: "\n")
                return ""
            }

            if let pattern = self.matching {
                source = lines.filter { !$0.contains(pattern) }.joined(separator: "\n")
                return ""
            }

            return ""
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }

    private func runSymbolDelete(name: String) throws {
        let resolved = NSString(string: file).standardizingPath
        let source = try String(contentsOfFile: resolved, encoding: .utf8)
        let tree = Parser.parse(source: source)

        // Use SyntaxRewriter to remove the declaration
        let rewriter = DeclarationDeleteRewriter(targetName: name)
        let modifiedTree = rewriter.rewrite(tree)

        guard rewriter.didDelete else {
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: "no declaration '\(name)' found")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
            return
        }

        // block the write when verification fails unless --force is set
        guard verified || force else {
            let result = EditResult(file: resolved, modified: false, diff: diff, verified: false, warning: warning)
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

/// SyntaxRewriter that removes a declaration by name.
///
/// filtering is done at the item-list level (top-level `CodeBlockItemListSyntax`
/// and member `MemberBlockItemListSyntax`) — returning `nil` from `visitAny`
/// is not reliable on this swift-syntax version because the generated typed
/// visit methods take precedence for declaration nodes.
class DeclarationDeleteRewriter: SyntaxRewriter {
    let targetName: String
    var didDelete = false

    init(targetName: String) {
        self.targetName = targetName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: CodeBlockItemListSyntax) -> CodeBlockItemListSyntax {
        let kept: [CodeBlockItemSyntax] = node.compactMap { item in
            if let decl = item.item.as(DeclSyntax.self), matchesTarget(decl) {
                didDelete = true
                return nil
            }
            return item
        }
        return CodeBlockItemListSyntax(kept)
    }

    override func visit(_ node: MemberBlockItemListSyntax) -> MemberBlockItemListSyntax {
        let kept: [MemberBlockItemSyntax] = node.compactMap { item in
            if matchesTarget(item.decl) {
                didDelete = true
                return nil
            }
            return item
        }
        return MemberBlockItemListSyntax(kept)
    }

    private func matchesTarget(_ decl: DeclSyntax) -> Bool {
        if let s = decl.as(StructDeclSyntax.self) { return s.name.text == targetName }
        if let c = decl.as(ClassDeclSyntax.self) { return c.name.text == targetName }
        if let e = decl.as(EnumDeclSyntax.self) { return e.name.text == targetName }
        if let p = decl.as(ProtocolDeclSyntax.self) { return p.name.text == targetName }
        if let f = decl.as(FunctionDeclSyntax.self) { return f.name.text == targetName }
        if let v = decl.as(VariableDeclSyntax.self) {
            for binding in v.bindings {
                if let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                   pattern.identifier.text == targetName {
                    return true
                }
            }
        }
        if let t = decl.as(TypeAliasDeclSyntax.self) { return t.name.text == targetName }
        if let a = decl.as(AssociatedTypeDeclSyntax.self) { return a.name.text == targetName }
        if let i = decl.as(InitializerDeclSyntax.self) { return targetName == "init" }
        if let d = decl.as(DeinitializerDeclSyntax.self) { return targetName == "deinit" }
        if let s = decl.as(SubscriptDeclSyntax.self) { return targetName == "subscript" }
        return false
    }
}

/// Find a declaration by name in the syntax tree.
class DeclarationFinder: SyntaxVisitor {
    let targetName: String
    var foundDeclaration: DeclSyntax?

    init(targetName: String) {
        self.targetName = targetName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundDeclaration = DeclSyntax(node); return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundDeclaration = DeclSyntax(node); return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundDeclaration = DeclSyntax(node); return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundDeclaration = DeclSyntax(node); return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundDeclaration = DeclSyntax(node); return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
               pattern.identifier.text == targetName {
                foundDeclaration = DeclSyntax(node)
                return .skipChildren
            }
        }
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundDeclaration = DeclSyntax(node); return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName { foundDeclaration = DeclSyntax(node); return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
        if node.name.text == targetName {
            // Walk up to find the parent EnumCaseDeclSyntax
            foundDeclaration = DeclSyntax(node)
            return .skipChildren
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if "init" == targetName { foundDeclaration = DeclSyntax(node); return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if "deinit" == targetName { foundDeclaration = DeclSyntax(node); return .skipChildren }
        return .visitChildren
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if "subscript" == targetName { foundDeclaration = DeclSyntax(node); return .skipChildren }
        return .visitChildren
    }
}
