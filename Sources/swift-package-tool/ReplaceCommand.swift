import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParserDiagnostics
import SwiftParser

/// find and replace text in a Swift source file, or rename a symbol.
///
/// two modes:
///   --old / --new    simple text replacement (like sed, but with safety)
///   --symbol / --rename    AST-aware rename of a declaration and all its
///                          references in the same file
struct ReplaceCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "replace",
        abstract: "Find and replace text, or rename a symbol in a file."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .long, help: "Text to find (text mode).")
    var old: String?

    @Option(name: .long, help: "Replacement text (text mode).")
    var new: String?

    @Option(name: .long, help: "Symbol name to rename (AST mode).")
    var symbol: String?

    @Option(name: .long, help: "New name for the symbol (AST mode).")
    var rename: String?

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
        // Validate modes
        let hasTextMode = old != nil || new != nil
        let hasSymbolMode = symbol != nil || rename != nil
        guard hasTextMode || hasSymbolMode else {
            throw ValidationError("specify --old/--new (text mode) or --symbol/--rename (AST mode)")
        }
        guard !(hasTextMode && hasSymbolMode) else {
            throw ValidationError("use either --old/--new or --symbol/--rename, not both")
        }

        if hasTextMode {
            guard let o = old, let n = new else {
                throw ValidationError("--old and --new are both required in text mode")
            }
            try runTextReplace(old: o, new: n)
        } else {
            guard let s = symbol, let r = rename else {
                throw ValidationError("--symbol and --rename are both required in AST mode")
            }
            try runSymbolRename(oldName: s, newName: r)
        }
    }

    private func runTextReplace(old: String, new: String) throws {
        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath
        ) { source in
            source = source.replacingOccurrences(of: old, with: new)
            return ""
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }

    private func runSymbolRename(oldName: String, newName: String) throws {
        let resolved = NSString(string: file).standardizingPath
        let source = try String(contentsOfFile: resolved, encoding: .utf8)
        let tree = Parser.parse(source: source)

        // Use SyntaxRewriter to rename all matching identifiers
        let rewriter = SymbolRenameRewriter(oldName: oldName, newName: newName)
        let modifiedTree = rewriter.rewrite(tree)

        guard rewriter.renameCount > 0 else {
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: "no references to '\(oldName)' found")
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

/// SyntaxRewriter that renames all occurrences of a symbol in a file.
class SymbolRenameRewriter: SyntaxRewriter {
    let oldName: String
    let newName: String
    var renameCount = 0

    init(oldName: String, newName: String) {
        self.oldName = oldName
        self.newName = newName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: TokenSyntax) -> TokenSyntax {
        guard case .identifier = node.tokenKind, node.text == oldName else {
            return node
        }
        renameCount += 1
        return node.with(\.tokenKind, .identifier(newName))
    }
}

/// Collect all token positions matching a given name.
class SymbolReferenceCollector: SyntaxVisitor {
    let targetName: String
    var positions: [AbsolutePosition] = []

    init(targetName: String) {
        self.targetName = targetName
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: TokenSyntax) -> SyntaxVisitorContinueKind {
        if node.tokenKind == .identifier(node.parent?.description ?? "") {
            // Check if this token's text matches
        }
        if node.text == targetName {
            positions.append(node.position)
        }
        return .visitChildren
    }
}
