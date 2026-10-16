import Foundation
import ArgumentParser

/// replace the text of lines A-B with new content — no matching.
///
/// the verb the read→edit loop was missing: `read --lines` gives the lines, this
/// names them back, and the file is written once (or, on failure, not at all).
/// `replace` searches for `--old` text and hits every occurrence of it; when that
/// text cannot be made to match, the only route left is `delete` + `insert` —
/// two calls, and the second can fail on its own, leaving the file half-edited.
/// a measured bench case (the `no_edit` class, and the c2 cascade that converted
/// it into destructive partial edits) is exactly that route failing. this verb
/// is one call and one write.
///
/// the line numbers are `read`'s: 1-based, inclusive, and a trailing newline
/// terminates the last line rather than opening an empty one. an end past the
/// file clamps to the last line; a range that selects no lines at all is a miss
/// (exit 1). the replacement takes the indentation of the range's first line,
/// and the content's own relative indentation is preserved (the `insert`
/// precedent).
///
/// empty `--content` is refused: removing lines is `delete`'s job, and a verb
/// that silently meant "delete" for one input would be two verbs wearing one
/// name.
struct ReplaceRangeCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "replace-range",
        abstract: "Replace the text of lines A-B in a file (no matching)."
    )

    @Argument(help: "File to edit.")
    var file: String?

    @Option(name: .long, help: "Line range to replace (e.g. '10-12'); 1-based, inclusive.")
    var lines: String?

    @Option(name: .long, help: "Replacement content. Use \\n for newlines.")
    var content: String? = nil

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
        guard let file else {
            throw ValidationError("Missing expected argument '<file>'")
        }
        guard let lines else {
            throw ValidationError("Missing expected argument '--lines <lines>'")
        }
        guard let content else {
            throw ValidationError("Missing expected argument '--content <content>'")
        }
        guard !content.isEmpty else {
            throw ValidationError("--content is empty; use `edit delete` to remove lines without replacing them")
        }
        let (start, end) = try parseLineRange(lines)
        guard start >= 1, end >= start else {
            throw ValidationError(
                "invalid line range '\(lines)'; start must be at least 1 and end must not precede start")
        }

        // the shell convention: `\n` in the argument becomes a newline. a caller
        // building arguments as data passes --literal-content instead.
        let processedContent = FileEditor.content(content, literal: literalContent)

        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            let current = sourceLines(source)
            let startIdx = start - 1
            let endIdx = min(end, current.count)
            guard startIdx < endIdx else {
                return FileEditor.rangeSelectsNoLines(lines)
            }
            let indent = FileEditor.detectIndent(current[startIdx])
            let replacement = processedContent
                .components(separatedBy: "\n")
                .map { indent + $0 }
            var newLines = current
            newLines.replaceSubrange(startIdx..<endIdx, with: replacement)
            // the file's terminal newline is the file's shape, not a line the
            // range consumed: replacing through the last line keeps it.
            let terminated = source.hasSuffix("\n")
            source = newLines.joined(separator: "\n") + (terminated ? "\n" : "")
            return nil
        }

        try emitEditResult(result)
    }
}