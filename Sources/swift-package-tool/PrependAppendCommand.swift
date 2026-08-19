import Foundation
import ArgumentParser

/// prepend content to the beginning of a Swift source file.
/// with --after-imports, inserts after the last import statement.
struct PrependCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepend",
        abstract: "Add code at the beginning of a file."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .long, help: "Content to prepend. Use \\n for newlines.")
    var content: String

    @Flag(name: .customLong("after-imports"), help: "Insert after the last import statement instead of at line 1.")
    var afterImports = false

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
        let processedContent = FileEditor.processMultilineContent(content)
        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath
        ) { source in
            if afterImports {
                let lines = source.components(separatedBy: "\n")
                if let lastImport = lines.lastIndex(where: { $0.hasPrefix("import ") }) {
                    var newLines = lines
                    newLines.insert("", at: lastImport + 1)
                    newLines.insert(contentsOf: processedContent.components(separatedBy: "\n"), at: lastImport + 2)
                    source = newLines.joined(separator: "\n")
                    return ""
                }
            }
            source = processedContent + "\n" + source
            return ""
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }
}

/// append content to the end of a Swift source file.
struct AppendCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "append",
        abstract: "Add code at the end of a file."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .long, help: "Content to append. Use \\n for newlines.")
    var content: String

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
        let processedContent = FileEditor.processMultilineContent(content)
        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath
        ) { source in
            let trimmed = source.hasSuffix("\n") ? String(source.dropLast()) : source
            source = trimmed + "\n" + processedContent + "\n"
            return ""
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }
}
