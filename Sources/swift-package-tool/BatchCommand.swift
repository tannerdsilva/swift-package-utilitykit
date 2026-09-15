import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser
import SwiftParserDiagnostics

/// Execute multiple edit operations from a JSON plan file.
///
/// Batch mode accepts a JSON file describing an array of operations to apply
/// sequentially. Each operation specifies a command, file, and command-specific
/// arguments. Operations are applied in order; if one fails, the remaining
/// operations are still attempted unless `--fail-fast` is set.
///
/// ## JSON Format
///
/// ```json
/// {
///   "operations": [
///     {
///       "command": "add-import",
///       "file": "Sources/Foo.swift",
///       "module": "Logging"
///     },
///     {
///       "command": "insert",
///       "file": "Sources/Foo.swift",
///       "after": "private let store",
///       "content": "private let logger = Logger(label: \"com.example\")\\n"
///     },
///     {
///       "command": "replace",
///       "file": "Sources/Foo.swift",
///       "old": "print(\"hello\")",
///       "new": "logger.info(\"hello\")"
///     }
///   ]
/// }
/// ```
///
/// Supported commands: `add-import`, `insert`, `replace`, `append`, `prepend`,
/// `delete`, `add-member`, `add-conformance`.
struct BatchCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Execute multiple edit operations from a JSON plan file."
    )

    @Argument(help: "Path to JSON plan file.")
    var plan: String

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

    @Flag(name: .customLong("fail-fast"), help: "Stop on first operation failure.")
    var failFast = false

    mutating func run() throws {
        if printSchemaIfRequested() { return }
        let resolved = NSString(string: plan).standardizingPath
        let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
        do {
            let decoded = try JSONDecoder().decode(BatchPlan.self, from: data)
            try executePlan(decoded)
        } catch let error as DecodingError {
            // a malformed plan must be a readable validation error, not a raw
            // Swift DecodingError dump on stderr
            throw ValidationError("invalid batch plan: \(batchDecodingMessage(error))")
        }
    }

    private func executePlan(_ planData: BatchPlan) throws {
        var results: [EditResult] = []

        for (index, op) in planData.operations.enumerated() {
            do {
                let result = try executeOperation(op)
                results.append(result)
                if failFast, !result.verified, let warning = result.warning {
                    // Record a synthetic failure result and stop
                    results.append(EditResult(
                        file: op.file,
                        modified: false,
                        diff: nil,
                        verified: false,
                        warning: "batch stopped at operation \(index + 1): \(warning)"
                    ))
                    break
                }
            } catch {
                results.append(EditResult(
                    file: op.file,
                    modified: false,
                    diff: nil,
                    verified: false,
                    warning: "operation \(index + 1) failed: \(error.localizedDescription)"
                ))
                if failFast { break }
            }
        }

        let output = BatchResult(results: results)
        try emitBatchResult(output, format: outputFormat ?? .json)
    }

    private func executeOperation(_ op: BatchOperation) throws -> EditResult {
        switch op.command {
        case "add-import":
            return try executeAddImport(op)
        case "insert":
            return try executeInsert(op)
        case "replace":
            return try executeReplace(op)
        case "append":
            return try executeAppend(op)
        case "prepend":
            return try executePrepend(op)
        case "delete":
            return try executeDelete(op)
        case "add-member":
            return try executeAddMember(op)
        case "add-conformance":
            return try executeAddConformance(op)
        default:
            throw ValidationError("unknown command: '\(op.command)'")
        }
    }

    private func executeAddImport(_ op: BatchOperation) throws -> EditResult {
        guard let module = op.module else {
            throw ValidationError("add-import requires --module")
        }
        return try FileEditor.edit(
            file: op.file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            let lines = source.components(separatedBy: "\n")
            let importLine = "import \(module)"

            if lines.contains(where: { $0 == importLine || $0.hasPrefix(importLine + " ") }) {
                return ""
            }

            let importLines = lines.enumerated().filter { $0.element.hasPrefix("import ") }

            if importLines.isEmpty {
                var insertIdx = 0
                for (i, line) in lines.enumerated() {
                    if line.hasPrefix("//") || line.isEmpty {
                        insertIdx = i + 1
                    } else {
                        break
                    }
                }
                var newLines = lines
                newLines.insert("", at: insertIdx)
                newLines.insert(importLine, at: insertIdx)
                source = newLines.joined(separator: "\n")
                return ""
            }

            var insertIdx = lines.count
            for (i, line) in importLines {
                let existing = line.trimmingCharacters(in: .whitespaces)
                if existing > importLine {
                    insertIdx = i
                    break
                }
                insertIdx = i + 1
            }

            var newLines = lines
            newLines.insert(importLine, at: insertIdx)
            source = newLines.joined(separator: "\n")
            return ""
        }
    }

    private func executeInsert(_ op: BatchOperation) throws -> EditResult {
        guard let content = op.content else {
            throw ValidationError("insert requires --content")
        }
        let processedContent = FileEditor.processMultilineContent(content)

        return try FileEditor.edit(
            file: op.file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            let lines = source.components(separatedBy: "\n")
            var newLines = lines

            if let pattern = op.after {
                if let idx = lines.firstIndex(where: { $0.contains(pattern) }) {
                    let indent = FileEditor.detectIndent(lines[idx])
                    let indented = processedContent.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
                    newLines.insert(contentsOf: [indented], at: idx + 1)
                }
            } else if let pattern = op.before {
                if let idx = lines.firstIndex(where: { $0.contains(pattern) }) {
                    let indent = FileEditor.detectIndent(lines[idx])
                    let indented = processedContent.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
                    newLines.insert(contentsOf: [indented], at: idx)
                }
            } else if let line = op.atLine {
                let idx = max(0, min(line - 1, lines.count))
                let indent = idx > 0 ? FileEditor.detectIndent(lines[idx - 1]) : ""
                let indented = processedContent.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
                newLines.insert(contentsOf: [indented], at: idx)
            }

            source = newLines.joined(separator: "\n")
            return ""
        }
    }

    private func executeReplace(_ op: BatchOperation) throws -> EditResult {
        guard let old = op.old, let new = op.new else {
            throw ValidationError("replace requires --old and --new")
        }
        let processedNew = FileEditor.processMultilineContent(new)

        return try FileEditor.edit(
            file: op.file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            source = source.replacingOccurrences(of: old, with: processedNew)
            return ""
        }
    }

    private func executeAppend(_ op: BatchOperation) throws -> EditResult {
        guard let content = op.content else {
            throw ValidationError("append requires --content")
        }
        let processedContent = FileEditor.processMultilineContent(content)

        return try FileEditor.edit(
            file: op.file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            let trimmed = source.hasSuffix("\n") ? String(source.dropLast()) : source
            source = trimmed + "\n" + processedContent + "\n"
            return ""
        }
    }

    private func executePrepend(_ op: BatchOperation) throws -> EditResult {
        guard let content = op.content else {
            throw ValidationError("prepend requires --content")
        }
        let processedContent = FileEditor.processMultilineContent(content)

        return try FileEditor.edit(
            file: op.file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            if op.afterImports == true {
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
    }

    private func executeDelete(_ op: BatchOperation) throws -> EditResult {
        // Reuse the existing DeleteCommand logic by calling FileEditor.edit
        return try FileEditor.edit(
            file: op.file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            let lines = source.components(separatedBy: "\n")
            var newLines = lines

            if let pattern = op.pattern {
                newLines.removeAll { $0.contains(pattern) }
            } else if let startLine = op.startLine, let endLine = op.endLine {
                let start = max(0, startLine - 1)
                let end = min(lines.count, endLine)
                if start < end {
                    newLines.removeSubrange(start..<end)
                }
            } else if let symbol = op.symbol {
                // Simple line-based removal by symbol name
                newLines.removeAll { $0.contains(symbol) && !$0.hasPrefix("//") }
            }

            source = newLines.joined(separator: "\n")
            return ""
        }
    }

    private func executeAddMember(_ op: BatchOperation) throws -> EditResult {
        guard let typeName = op.typeName else {
            throw ValidationError("add-member requires --type")
        }
        let memberOption: String? = op.property ?? op.method ?? op.caseName
        guard let chosenMember = memberOption else {
            throw ValidationError("add-member requires one of --property, --method, --case")
        }

        let memberDecl: String
        if let prop = op.property {
            let accessMod = op.access.map { "\($0) " } ?? ""
            let defaultVal = op.defaultValue.map { " = \($0)" } ?? ""
            memberDecl = "\(accessMod)\(prop)\(defaultVal)"
        } else if let meth = op.method {
            let accessMod = op.access.map { "\($0) " } ?? ""
            let bodyContent = FileEditor.processMultilineContent(op.body ?? "")
            if bodyContent.isEmpty {
                memberDecl = "\(accessMod)\(meth)"
            } else {
                let indentedBody = bodyContent.components(separatedBy: "\n").map { "    \($0)" }.joined(separator: "\n")
                memberDecl = "\(accessMod)\(meth) {\n\(indentedBody)\n}"
            }
        } else if let cn = op.caseName {
            let accessMod = op.access.map { "\($0) " } ?? ""
            if let assoc = op.associated {
                let types = assoc.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
                memberDecl = "\(accessMod)case \(cn)(\(types))"
            } else {
                memberDecl = "\(accessMod)case \(cn)"
            }
        } else {
            throw ValidationError("add-member requires a member declaration")
        }

        return try FileEditor.edit(
            file: op.file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force
        ) { source in
            let lines = source.components(separatedBy: "\n")
            guard let typeIdx = lines.firstIndex(where: { $0.contains("\(typeName):") || $0.contains("\(typeName) {") }) else {
                return "type '\(typeName)' not found"
            }

            // Find the closing brace of the type
            var braceDepth = 0
            var insertIdx = lines.count
            for i in typeIdx..<lines.count {
                let line = lines[i]
                braceDepth += line.filter { $0 == "{" }.count
                braceDepth -= line.filter { $0 == "}" }.count
                if braceDepth <= 0 && line.contains("}") {
                    insertIdx = i
                    break
                }
            }

            var newLines = lines
            newLines.insert(memberDecl, at: insertIdx)
            source = newLines.joined(separator: "\n")
            return ""
        }
    }

    private func executeAddConformance(_ op: BatchOperation) throws -> EditResult {
        guard let typeName = op.typeName, let protocolName = op.protocolName else {
            throw ValidationError("add-conformance requires --type and --protocol")
        }

        let resolved = NSString(string: op.file).standardizingPath
        let source = try String(contentsOfFile: resolved, encoding: .utf8)
        let tree = Parser.parse(source: source)

        let rewriter = AddConformanceRewriter(targetName: typeName, protocolName: protocolName)
        let modifiedTree = rewriter.rewrite(tree)

        guard rewriter.didModify else {
            let warning = rewriter.alreadyConforms
                ? "'\(typeName)' already conforms to '\(protocolName)'"
                : "no type '\(typeName)' found"
            return EditResult(file: resolved, modified: false, diff: nil, verified: true, warning: warning)
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
            return EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: warning)
        }

        // block the write when verification fails unless --force is set
        guard verified || force else {
            return EditResult(file: resolved, modified: false, diff: diff, verified: false, warning: warning)
        }

        if backup {
            try FileManager.default.copyItem(atPath: resolved, toPath: resolved + ".bak")
        }

        let target = outputPath.isEmpty ? resolved : outputPath
        try modified.write(toFile: target, atomically: true, encoding: .utf8)

        return EditResult(file: resolved, modified: true, diff: diff, verified: verified, warning: warning)
    }
}

// MARK: - Batch plan model

struct BatchPlan: Codable, Sendable {
    let operations: [BatchOperation]
}

struct BatchOperation: Codable, Sendable {
    let command: String
    let file: String

    // add-import
    let module: String?

    // insert
    let content: String?
    let after: String?
    let before: String?
    let atLine: Int?

    // replace
    let old: String?
    let new: String?

    // delete
    let pattern: String?
    let startLine: Int?
    let endLine: Int?
    let symbol: String?

    // add-member
    let typeName: String?
    let property: String?
    let method: String?
    let body: String?
    let caseName: String?
    let associated: String?
    let defaultValue: String?
    let access: String?

    // add-conformance
    let protocolName: String?

    // prepend
    let afterImports: Bool?
}

struct BatchResult: Codable, Sendable {
    let results: [EditResult]

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "BatchResult",
      "type": "object",
      "properties": {
        "results": {
          "type": "array",
          "items": { "$ref": "EditResult" },
          "description": "Per-operation results in plan order"
        }
      },
      "required": ["results"]
    }
    """
}

/// human-readable summary of a JSON decoding failure in a batch plan.
func batchDecodingMessage(_ error: DecodingError) -> String {
    switch error {
    case .dataCorrupted(let ctx):
        return "data corrupted: \(ctx.debugDescription)"
    case .keyNotFound(let key, let ctx):
        let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
        return "missing key '\(key.stringValue)' at \(path.isEmpty ? "root" : path)"
    case .typeMismatch(let type, let ctx):
        return "type mismatch (expected \(type)) for key '\(ctx.codingPath.last?.stringValue ?? "?")'"
    case .valueNotFound(let type, let ctx):
        return "missing value (expected \(type)) for key '\(ctx.codingPath.last?.stringValue ?? "?")'"
    @unknown default:
        return "\(error)"
    }
}

/// format-aware emitter for a BatchResult (honors --output-format).
func emitBatchResult(_ result: BatchResult, format: OutputFormat) throws {
    switch format {
    case .json:
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(data: try enc.encode(result), encoding: .utf8)!)
    case .compact:
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        print(String(data: try enc.encode(result), encoding: .utf8)!)
    case .csv, .short:
        for r in result.results {
            let w = r.warning.map { " warning: \($0)" } ?? ""
            print("\(r.file): modified=\(r.modified) verified=\(r.verified)\(w)")
        }
    case .jsonl:
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        for r in result.results {
            print(String(data: try enc.encode(r), encoding: .utf8)!)
        }
    }
}
