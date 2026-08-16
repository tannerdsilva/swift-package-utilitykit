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
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath
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

        // Find the declaration to delete
        let finder = DeclarationFinder(targetName: name)
        finder.walk(tree)

        guard let decl = finder.foundDeclaration else {
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: "no declaration '\(name)' found")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            print(String(data: data, encoding: .utf8)!)
            return
        }

        // Calculate the range from leading trivia start to end of node
        let startOffset = decl.position.utf8Offset
        let endOffset = decl.endPosition.utf8Offset
        let startIdx = source.index(source.startIndex, offsetBy: startOffset)
        let endIdx = source.index(source.startIndex, offsetBy: endOffset)

        var modified = source
        modified.removeSubrange(startIdx..<endIdx)

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
