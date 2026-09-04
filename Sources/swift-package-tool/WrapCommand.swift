import Foundation
import ArgumentParser

/// wrap selected lines in a syntactic container (do-catch, if-let, guard-let, do).
struct WrapCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "wrap",
        abstract: "Wrap selected lines in a container (do-catch, if-let, guard-let)."
    )

    @Argument(help: "File to edit.")
    var file: String

    @Option(name: .customLong("lines"), help: "Line range to wrap (e.g. '10-20').")
    var lineRange: String

    @Option(name: .customLong("in"), help: "Container type: do-catch, if-let, guard-let, do.")
    var container: String

    @Option(name: .customLong("variable"), help: "Variable name for if-let/guard-let.")
    var variable: String?

    @Option(name: .customLong("else"), help: "Else body for guard-let.")
    var elseBody: String?

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
        let parts = lineRange.split(separator: "-")
        guard parts.count == 2, let startLine = Int(parts[0]), let endLine = Int(parts[1]) else {
            throw ValidationError("invalid line range '\(lineRange)'; use format '10-20'")
        }

        guard ["do-catch", "if-let", "guard-let", "do"].contains(container) else {
            throw ValidationError("unsupported container '\(container)'; use do-catch, if-let, guard-let, or do")
        }

        if (container == "if-let" || container == "guard-let") && variable == nil {
            throw ValidationError("--variable is required for \(container)")
        }

        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            let lines = source.components(separatedBy: "\n")
            let startIdx = max(0, startLine - 1)
            let endIdx = min(lines.count, endLine)

            guard startIdx < endIdx else { return source }

            let wrappedLines = Array(lines[startIdx..<endIdx])
            let baseIndent = FileEditor.detectIndent(lines[startIdx])
            let innerIndent = baseIndent + "    "

            // Re-indent wrapped lines
            let indentedBody = wrappedLines.map { line in
                line.isEmpty ? "" : innerIndent + line.drop(while: { $0 == " " || $0 == "\t" })
            }.joined(separator: "\n")

            let wrapper: String
            switch container {
            case "do-catch":
                wrapper = "\(baseIndent)do {\n\(indentedBody)\n\(baseIndent)} catch {\n\(baseIndent)    <#handle error#>\n\(baseIndent)}"
            case "if-let":
                wrapper = "\(baseIndent)if let \(variable!) {\n\(indentedBody)\n\(baseIndent)}"
            case "guard-let":
                let elseBlock = elseBody.map { "\n\(baseIndent)    \($0)" } ?? ""
                wrapper = "\(baseIndent)guard let \(variable!) else {\(elseBlock)\n\(baseIndent)}"
            case "do":
                wrapper = "\(baseIndent)do {\n\(indentedBody)\n\(baseIndent)}"
            default:
                wrapper = ""
            }

            var newLines = lines
            newLines.replaceSubrange(startIdx..<endIdx, with: wrapper.components(separatedBy: "\n"))
            source = newLines.joined(separator: "\n")
            return ""
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        print(String(data: data, encoding: .utf8)!)
    }
}
