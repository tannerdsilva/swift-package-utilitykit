import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParserDiagnostics
import SwiftParser

/// find and replace literal text in a Swift source file (every occurrence).
///
/// text-only by design: the AST symbol rename that used to be a second mode of
/// this verb is now `edit rename` — one verb, one behavior. the edit contract
/// is the group's: the result is re-parsed and a write that would not parse is
/// withheld unless `--force`; `--dry-run` previews the diff without writing.
struct ReplaceCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "replace",
        abstract: "Find and replace text in a file (every occurrence)."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .long, help: "Text to find.")
    var old: String?

    @Option(name: .long, help: "Replacement text.")
    var new: String?

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

    @Flag(name: .customLong("literal-content"), help: "Take content arguments literally: skip the \\n and \\\\ escape expansion.")
    var literalContent = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .long, help: "Output format: json, compact, short, csv, jsonl.")
    var outputFormat: OutputFormat?

    mutating func run() throws {
        if printSchemaIfRequested() { return }
        guard let old, let new else {
            throw ValidationError("--old and --new are both required")
        }
        try runTextReplace(old: old, new: new)
    }

    private func runTextReplace(old: String, new: String) throws {
        let processedNew = FileEditor.content(new, literal: literalContent)
        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            guard source.contains(old) else { return FileEditor.noOccurrenceOf(old) }
            source = source.replacingOccurrences(of: old, with: processedNew)
            return nil
        }

        try emitEditResult(result)
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