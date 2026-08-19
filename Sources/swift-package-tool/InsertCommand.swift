import Foundation
import ArgumentParser

/// insert code at a precise location in a Swift source file.
///
/// supports three targeting modes:
///   --after <pattern>   insert after the first line containing the pattern
///   --before <pattern>  insert before the first line containing the pattern
///   --at-line <n>       insert at an absolute line number
struct InsertCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "insert",
        abstract: "Insert code at a precise location in a file."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .long, help: "Content to insert. Use \\n for newlines.")
    var content: String

    @Option(name: .long, help: "Insert after the first line containing this text.")
    var after: String?

    @Option(name: .long, help: "Insert before the first line containing this text.")
    var before: String?

    @Option(name: .customLong("at-line"), help: "Insert at this absolute line number (1-indexed).")
    var atLine: Int?

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
        let modes = [after != nil, before != nil, atLine != nil].filter { $0 }.count
        guard modes == 1 else {
            throw ValidationError("specify exactly one of --after, --before, or --at-line")
        }

        // Process multi-line content: convert literal \n to actual newlines
        let processedContent = FileEditor.processMultilineContent(content)

        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath
        ) { source in
            let lines = source.components(separatedBy: "\n")
            var newLines = lines

            if let pattern = after {
                if let idx = lines.firstIndex(where: { $0.contains(pattern) }) {
                    let indent = FileEditor.detectIndent(lines[idx])
                    let indented = processedContent.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
                    newLines.insert(contentsOf: [indented], at: idx + 1)
                }
            } else if let pattern = before {
                if let idx = lines.firstIndex(where: { $0.contains(pattern) }) {
                    let indent = FileEditor.detectIndent(lines[idx])
                    let indented = processedContent.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
                    newLines.insert(contentsOf: [indented], at: idx)
                }
            } else if let line = atLine {
                let idx = max(0, min(line - 1, lines.count))
                let indent = idx > 0 ? FileEditor.detectIndent(lines[idx - 1]) : ""
                let indented = processedContent.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
                newLines.insert(contentsOf: [indented], at: idx)
            }

            source = newLines.joined(separator: "\n")
            return ""
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }
}
