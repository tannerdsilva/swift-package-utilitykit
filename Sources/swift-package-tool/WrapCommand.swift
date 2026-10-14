import Foundation
import ArgumentParser

/// wrap selected lines in a syntactic container (do-catch, if-let, guard-let, do).
struct WrapCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "wrap",
        abstract: "Wrap selected lines in a container (do-catch, if-let, guard-let)."
    )

    @Argument(help: "File to edit.")
    var file: String?

    @Option(name: .customLong("lines"), help: "Line range to wrap (e.g. '10-20').")
    var lineRange: String? = nil

    @Option(name: .customLong("in"), help: "Container type: do-catch, if-let, guard-let, do.")
    var container: String? = nil

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

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .long, help: "Output format: json, compact, short, csv, jsonl.")
    var outputFormat: OutputFormat?

    mutating func run() throws {
        if printSchemaIfRequested() { return }
        guard let file else {
            throw ValidationError("Missing expected argument '<file>'")
        }
        guard let lineRange else {
            throw ValidationError("Missing expected argument '--lines <lines>'")
        }
        guard let container else {
            throw ValidationError("Missing expected argument '--in <in>'")
        }
        let (startLine, endLine) = try parseLineRange(lineRange)

        guard ["do-catch", "if-let", "guard-let", "do"].contains(container) else {
            throw ValidationError("unsupported container '\(container)'; use do-catch, if-let, guard-let, or do")
        }

        if (container == "if-let" || container == "guard-let") && variable == nil {
            throw ValidationError("--variable is required for \(container)")
        }

        // a guard's else block must exit its scope, so `guard let x else {}`
        // is not a legal wrapping. the syntax re-parse cannot catch that (an
        // empty else block parses), so it is refused here rather than written
        // as code that will not compile.
        if container == "guard-let" && (elseBody?.isEmpty ?? true) {
            throw ValidationError("--else is required for guard-let (its else block must exit scope)")
        }

        let result = try FileEditor.edit(
            file: file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            let lines = source.components(separatedBy: "\n")
            let startIdx = max(0, startLine - 1)
            let endIdx = min(lines.count, endLine)

            guard startIdx < endIdx else { return FileEditor.rangeSelectsNoLines(lineRange) }

            let wrappedLines = Array(lines[startIdx..<endIdx])
            let baseIndent = FileEditor.detectIndent(lines[startIdx])
            let innerIndent = baseIndent + "    "

            // Re-indent wrapped lines
            let indentedBody = wrappedLines.map { line in
                line.isEmpty ? "" : innerIndent + line.drop(while: { $0 == " " || $0 == "\t" })
            }.joined(separator: "\n")

            var newLines = lines

            if container == "guard-let" {
                // a guard conditions the code that FOLLOWS it: the selected
                // lines stay where they are and the guard goes above them.
                // replacing them (every other container's shape) silently
                // deletes the very code the guard protects.
                var guardLines = ["\(baseIndent)guard let \(variable!) else {"]
                guardLines += (elseBody ?? "").components(separatedBy: "\n").map { "\(innerIndent)\($0)" }
                guardLines.append("\(baseIndent)}")
                newLines.insert(contentsOf: guardLines, at: startIdx)
            } else {
                let wrapper: String
                switch container {
                case "do-catch":
                    // the catch body must be COMPILABLE source. an editor
                    // placeholder (<#handle error#>) is not — it fails the
                    // syntax re-parse, so every do-catch wrap was blocked.
                    wrapper = "\(baseIndent)do {\n\(indentedBody)\n\(baseIndent)} catch {\n\(innerIndent)// handle the error\n\(baseIndent)}"
                case "if-let":
                    wrapper = "\(baseIndent)if let \(variable!) {\n\(indentedBody)\n\(baseIndent)}"
                case "do":
                    wrapper = "\(baseIndent)do {\n\(indentedBody)\n\(baseIndent)}"
                default:
                    wrapper = ""
                }
                newLines.replaceSubrange(startIdx..<endIdx, with: wrapper.components(separatedBy: "\n"))
            }

            source = newLines.joined(separator: "\n")
            return nil
        }

        try emitEditResult(result)
    }
}
