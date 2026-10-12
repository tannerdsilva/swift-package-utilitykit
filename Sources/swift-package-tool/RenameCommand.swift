import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser
import SwiftParserDiagnostics

/// rename a symbol and every reference to it in one Swift source file.
///
/// the dedicated home of the AST rename that used to be a second mode of
/// `edit replace`: `rename` is a first-class concept on the agent surface
/// (`pkg_edit_rename`), so it is a first-class verb here too. the flags are
/// self-describing (`--old-name` / `--new-name`), and the edit contract is the
/// group's: the result is re-parsed and a write that would not parse is
/// withheld unless `--force`; `--dry-run` previews the diff without writing.
struct RenameCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename a symbol and all of its references in a file (AST-aware)."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .long, help: "The current name of the symbol to rename.")
    var oldName: String?

    @Option(name: .long, help: "The new name for the symbol.")
    var newName: String?

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
        guard let oldName, let newName else {
            throw ValidationError("--old-name and --new-name are both required")
        }
        try runSymbolRename(oldName: oldName, newName: newName)
    }

    private func runSymbolRename(oldName: String, newName: String) throws {
        let resolved = NSString(string: file).standardizingPath
        let source = try String(contentsOfFile: resolved, encoding: .utf8)
        let tree = Parser.parse(source: source)

        // Use SyntaxRewriter to rename all matching identifiers
        let rewriter = SymbolRenameRewriter(oldName: oldName, newName: newName)
        let modifiedTree = rewriter.rewrite(tree)

        guard rewriter.renameCount > 0 else {
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: "no references to '\(oldName)' found", status: .missed)
            try emitEditResult(result)
            return
        }

        let modified = modifiedTree.description

        let original = source
        if modified == original {
            // a rename to the same name reproduces the file byte-for-byte
            let result = EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: "rename produced no change", status: .alreadyCurrent)
            try emitEditResult(result)
            return
        }
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
            let result = EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: warning, status: verified ? .applied : .blocked)
            try emitEditResult(result)
            return
        }

        // block the write when verification fails unless --force is set
        guard verified || force else {
            let result = EditResult(file: resolved, modified: false, diff: diff, verified: false, warning: warning, status: .blocked)
            try emitEditResult(result)
            return
        }

        if backup {
            try FileEditor.backupFile(resolved)
        }

        let target = outputPath.isEmpty ? resolved : outputPath
        try modified.write(toFile: target, atomically: true, encoding: .utf8)

        let result = EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: warning, status: .applied)
        try emitEditResult(result)
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