import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser
import SwiftParserDiagnostics

/// Execute multiple edit operations from one plan.
///
/// The plan is a JSON object `{"operations": [...]}`, given either as a plan
/// file (the positional argument — the human/CI route) or inline with `--plan`
/// (exactly one of the two). Each operation specifies a command, file, and
/// command-specific arguments. Operations are applied in order; if one fails,
/// the remaining operations are still attempted unless `--fail-fast` is set.
///
/// `--atomic` changes the landing, not the plan: every operation is staged in
/// memory and the touched files are written only if every operation applied,
/// so a plan that fails partway changes nothing. Without the flag a failed
/// operation leaves its predecessors' writes in place — the 3.0 contract,
/// pinned by `EditContractTests`, and unchanged.
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
///
/// ## Fields per command
///
/// - `add-import`: `module`
/// - `insert`: `content`, and exactly one anchor — `after`, `before`, `atLine`
/// - `replace`: `old`, `new`
/// - `append` / `prepend`: `content`; `afterImports` for `prepend`
/// - `delete`: exactly one selector — `pattern`, `startLine` + `endLine`, `symbol`
/// - `add-member`: `typeName`, and one of `property` / `method` / `caseName`
///   (plus `body`, `associated`, `defaultValue`, `access` where they apply)
/// - `add-conformance`: `typeName`, `protocolName`
///
/// These keys are the plan's own vocabulary and do not always match the
/// edit verb's flags: the plan spells `--type` as `typeName`, because
/// `type` is reserved. An unrecognized key decodes to nil rather than failing,
/// so a mistyped field surfaces as that command's "requires ..." error — read
/// the field list above before assuming a command is broken.
struct BatchCommand: ParsableCommand, EditCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Execute multiple edit operations from a JSON plan file."
    )

    @Argument(help: "Path to JSON plan file.")
    var plan: String?

    @Option(name: .customLong("plan"), help: "Inline JSON plan instead of a plan file: {\"operations\": [...]}. Exactly one of the two.")
    var inlinePlan: String?

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

    @Flag(name: .customLong("literal-content"), help: "Take the plan's content fields literally: skip the \\n and \\\\ escape expansion.")
    var literalContent = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .long, help: "Output format: json, compact, short, csv, jsonl.")
    var outputFormat: OutputFormat?

    @Flag(name: .customLong("fail-fast"), help: "Stop on first operation failure.")
    var failFast = false

    @Flag(name: .customLong("atomic"), help: "Apply every operation or none: stage each change in memory and write only if every operation applied.")
    var atomic = false

    mutating func run() throws {
        if printSchemaIfRequested() { return }
        // the plan arrives one of two ways and never both: a plan file (the
        // human/CI route) or `--plan <json>` (the route an agent can actually
        // take — nothing on either surface can create a file, so a plan that
        // must exist on disk first was unreachable in practice).
        let data: Data
        switch (plan, inlinePlan) {
        case let (file?, nil):
            data = try Data(contentsOf: URL(fileURLWithPath: NSString(string: file).standardizingPath))
        case let (nil, json?):
            data = Data(json.utf8)
        case (nil, nil):
            throw ValidationError("provide a plan: a plan file path, or an inline plan with --plan")
        default:
            throw ValidationError("provide exactly one of a plan file path or --plan")
        }
        do {
            let decoded = try JSONDecoder().decode(BatchPlan.self, from: data)
            if atomic {
                try executePlanAtomic(decoded)
            } else {
                try executePlan(decoded)
            }
        } catch let error as DecodingError {
            // a malformed plan must be a readable validation error, not a raw
            // Swift DecodingError dump on stderr — and an inline plan names its
            // location exactly as a plan file does (`operations[2]`, never `?`).
            throw ValidationError("invalid batch plan: \(batchDecodingMessage(error))")
        }
    }

    private func executePlan(_ planData: BatchPlan) throws {
        var results: [EditResult] = []

        for (index, op) in planData.operations.enumerated() {
            do {
                let result = try executeOperation(op)
                results.append(result)
                if failFast, result.status.isFailure {
                    // stop at the first operation that could not apply
                    break
                }
            } catch {
                results.append(EditResult(
                    file: op.file,
                    modified: false,
                    diff: nil,
                    verified: false,
                    warning: "operation \(index + 1) failed: \(readableError(error))",
                    status: .failed,
                    dryRun: dryRun
                ))
                if failFast { break }
            }
        }

        let output = BatchResult(results: results)
        try emitBatchResult(output, format: outputFormat ?? .json)

        // print-then-throw: the process exit code mirrors the per-op statuses,
        // so a batch whose operations missed or failed cannot exit 0
        if results.contains(where: { $0.status.isFailure }) {
            throw ExitCode(1)
        }
    }

private func executeOperation(_ op: BatchOperation) throws -> EditResult {
        // the transform is built — and its fields validated — before anything
        // is read, so a malformed operation fails exactly where it used to.
        let transform = try transform(for: op)
        return try FileEditor.edit(
            file: op.file, dryRun: dryRun, backup: backup, verify: verify, showDiff: showDiff, outputPath: outputPath, force: force,
            transform: transform
        )
    }

    /// the transform an operation describes, with its own fields validated.
    ///
    /// this is the same edit each standalone verb performs — expressed as a
    /// text transform rather than a read-verify-write, which is what lets
    /// `--atomic` apply an operation to an in-memory copy instead of to disk.
    /// a missing field throws here, before any file is touched.
    private func transform(for op: BatchOperation) throws -> (inout String) throws -> FileEditor.NoChange? {
        switch op.command {
        case "add-import":
            guard let module = op.module else {
                throw ValidationError("add-import requires the plan's 'module' field")
            }
            return { source in
                let lines = source.components(separatedBy: "\n")
                let importLine = "import \(module)"

                if lines.contains(where: { $0 == importLine || $0.hasPrefix(importLine + " ") }) {
                    return FileEditor.alreadyImported(module)
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
                    return nil
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
                return nil
            }

        case "insert":
            guard let content = op.content else {
                throw ValidationError("insert requires the plan's 'content' field")
            }
            let processedContent = FileEditor.content(content, literal: literalContent)

            return { source in
                let lines = source.components(separatedBy: "\n")
                var newLines = lines

                if let pattern = op.after {
                    guard let idx = lines.firstIndex(where: { $0.contains(pattern) }) else {
                        return FileEditor.noLineContaining(pattern)
                    }
                    let indent = FileEditor.detectIndent(lines[idx])
                    let indented = processedContent.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
                    newLines.insert(contentsOf: [indented], at: idx + 1)
                } else if let pattern = op.before {
                    guard let idx = lines.firstIndex(where: { $0.contains(pattern) }) else {
                        return FileEditor.noLineContaining(pattern)
                    }
                    let indent = FileEditor.detectIndent(lines[idx])
                    let indented = processedContent.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
                    newLines.insert(contentsOf: [indented], at: idx)
                } else if let line = op.atLine {
                    let idx = max(0, min(line - 1, lines.count))
                    let indent = idx > 0 ? FileEditor.detectIndent(lines[idx - 1]) : ""
                    let indented = processedContent.components(separatedBy: "\n").map { indent + $0 }.joined(separator: "\n")
                    newLines.insert(contentsOf: [indented], at: idx)
                }

                source = newLines.joined(separator: "\n")
                return nil
            }

        case "replace":
            guard let old = op.old, let new = op.new else {
                throw ValidationError("replace requires the plan's 'old' and 'new' fields")
            }
            let processedNew = FileEditor.content(new, literal: literalContent)

            return { source in
                guard source.contains(old) else { return FileEditor.noOccurrenceOf(old) }
                source = source.replacingOccurrences(of: old, with: processedNew)
                return nil
            }

        case "append":
            guard let content = op.content else {
                throw ValidationError("append requires the plan's 'content' field")
            }
            // `afterImports` has meaning for prepend only — the CLI's append has no
            // such flag. a plan that sets it here is asking for something append
            // cannot do, so refuse rather than silently writing at the end anyway.
            guard op.afterImports != true else {
                throw ValidationError("'afterImports' applies to prepend only; append always writes at the end of the file")
            }
            let processedContent = FileEditor.content(content, literal: literalContent)

            return { source in
                let trimmed = source.hasSuffix("\n") ? String(source.dropLast()) : source
                source = trimmed + "\n" + processedContent + "\n"
                return nil
            }

        case "prepend":
            guard let content = op.content else {
                throw ValidationError("prepend requires the plan's 'content' field")
            }
            let processedContent = FileEditor.content(content, literal: literalContent)

            return { source in
                if op.afterImports == true {
                    let lines = source.components(separatedBy: "\n")
                    if let lastImport = lines.lastIndex(where: { $0.hasPrefix("import ") }) {
                        var newLines = lines
                        newLines.insert("", at: lastImport + 1)
                        newLines.insert(contentsOf: processedContent.components(separatedBy: "\n"), at: lastImport + 2)
                        source = newLines.joined(separator: "\n")
                        return nil
                    }
                }
                source = processedContent + "\n" + source
                return nil
            }

        case "delete":
            // the symbol form is AST-aware and shared with `delete --symbol`; the
            // line-range and pattern forms are line-based by definition. they used
            // to be one line-based branch, so a plan's symbol delete removed every
            // line MENTIONING the name instead of the declaration.
            if let symbol = op.symbol {
                return { source in
                    removeDeclaration(named: symbol, in: &source)
                }
            }

            return { source in
                let lines = source.components(separatedBy: "\n")
                var newLines = lines

                if let pattern = op.pattern {
                    let kept = newLines.filter { !$0.contains(pattern) }
                    guard kept.count != newLines.count else {
                        return FileEditor.noLineContaining(pattern)
                    }
                    newLines = kept
                } else if let startLine = op.startLine, let endLine = op.endLine {
                    let start = max(0, startLine - 1)
                    let end = min(lines.count, endLine)
                    guard start < end else {
                        return FileEditor.rangeSelectsNoLines("\(startLine)-\(endLine)")
                    }
                    newLines.removeSubrange(start..<end)
                }

                source = newLines.joined(separator: "\n")
                return nil
            }

        case "add-member":
            guard let typeName = op.typeName else {
                throw ValidationError("add-member requires the plan's 'typeName' field")
            }
            let memberOption: String? = op.property ?? op.method ?? op.caseName
            guard memberOption != nil else {
                throw ValidationError("add-member requires one of the plan's 'property', 'method', or 'caseName' fields")
            }

            let memberDecl: String
            if let prop = op.property {
                let accessMod = op.access.map { "\($0) " } ?? ""
                let defaultVal = op.defaultValue.map { " = \($0)" } ?? ""
                memberDecl = "\(accessMod)\(prop)\(defaultVal)"
            } else if let meth = op.method {
                let accessMod = op.access.map { "\($0) " } ?? ""
                let bodyContent = FileEditor.content(op.body ?? "", literal: literalContent)
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

            return { source in
                insertMember(memberDecl, intoType: typeName, in: &source)
            }

        case "add-conformance":
            guard let typeName = op.typeName, let protocolName = op.protocolName else {
                throw ValidationError("add-conformance requires the plan's 'typeName' and 'protocolName' fields")
            }

            return { source in
                let tree = Parser.parse(source: source)
                let rewriter = AddConformanceRewriter(targetName: typeName, protocolName: protocolName)
                let modifiedTree = rewriter.rewrite(tree)

                guard rewriter.didModify else {
                    if rewriter.alreadyConforms {
                        return .alreadyCurrent("'\(typeName)' already conforms to '\(protocolName)'")
                    }
                    // no selector: a type name is not source text, so the
                    // near-miss suggestion list would be noise here.
                    return .missed("no type '\(typeName)' found", selector: nil)
                }

                source = modifiedTree.description
                return nil
            }

        default:
            throw ValidationError("unknown command: '\(op.command)'")
        }
    }

    /// `--atomic`: apply every operation to in-memory copies of the files it
    /// touches (operation N sees operation N-1's staged result), then write
    /// every touched file only if EVERY operation applied.
    ///
    /// a failure anywhere writes nothing. that is the whole point: the damage
    /// this answers was a `delete` that landed while its re-insert died at the
    /// turn cap — the destructive partial edit, measured at 4 of run 019's 7
    /// danger draws.
    ///
    /// the honest limit: this is atomicity against OPERATION failure, not
    /// cross-file crash atomicity — POSIX offers no way to write two files as
    /// one. a single-file plan (the measured case) is also crash-atomic, since
    /// its one write goes through the same atomic-write path every verb uses.
    private func executePlanAtomic(_ planData: BatchPlan) throws {
        var results: [EditResult] = []
        var staged: [String: FileEditor.Staged] = [:]
        var touched: [String] = []

        for (index, op) in planData.operations.enumerated() {
            let resolved = NSString(string: op.file).standardizingPath
            do {
                let transform = try transform(for: op)
                let step = try FileEditor.stage(
                    file: op.file, verify: verify, showDiff: showDiff, dryRun: dryRun,
                    over: staged[resolved]?.result, transform: transform)
                if staged[resolved] == nil { touched.append(resolved) }
                staged[resolved] = step
                let result = FileEditor.verdict(step, dryRun: dryRun, force: force)
                results.append(result)
                if failFast, result.status.isFailure {
                    break
                }
            } catch {
                results.append(EditResult(
                    file: op.file,
                    modified: false,
                    diff: nil,
                    verified: false,
                    warning: "operation \(index + 1) failed: \(readableError(error))",
                    status: .failed,
                    dryRun: dryRun
                ))
                if failFast { break }
            }
        }

        // the commit gate: anything less than every operation applying means
        // nothing is written — and every operation's result is still reported.
        let failed = results.contains { $0.status.isFailure }
        if !failed && !dryRun {
            for path in touched {
                guard let step = staged[path], step.result != step.onDisk else { continue }
                try FileEditor.commit(step, backup: backup, outputPath: outputPath)
            }
        }

        let output = BatchResult(results: results)
        try emitBatchResult(output, format: outputFormat ?? .json)

        // print-then-throw: the exit code mirrors the per-op statuses, so an
        // atomic plan that staged nothing cannot exit 0
        if failed {
            throw ExitCode(1)
        }
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
///
/// the location is rendered in the plan's own vocabulary — `root`,
/// `operations`, `operations[0].command` — never a bare `?` and never Swift's
/// `Index 0` description: whoever reads the message has to see the JSON they
/// wrote, and a positional array element is not a key.
func batchDecodingMessage(_ error: DecodingError) -> String {
    switch error {
    case .dataCorrupted(let ctx):
        return "data corrupted: \(ctx.debugDescription)"
    case .keyNotFound(let key, let ctx):
        return "missing key '\(key.stringValue)' at \(batchPlanLocation(ctx.codingPath))"
    case .typeMismatch(let type, let ctx):
        let shape = batchJSONShape(type)
        // an empty coding path is the document root, and the root has exactly
        // one legal shape — say what it is instead of naming a key that is not
        // there (a top-level array decoded to the cryptic `key '?'` before).
        // the decoder reports the shape it EXPECTED, so the message states that
        // and never guesses at what the document actually held.
        if ctx.codingPath.isEmpty {
            return "expected an object like {\"operations\": [...]} at root"
        }
        return "expected \(shape) at \(batchPlanLocation(ctx.codingPath))"
    case .valueNotFound(let type, let ctx):
        return "expected \(batchJSONShape(type)) at \(batchPlanLocation(ctx.codingPath)), found null"
    @unknown default:
        return "\(error)"
    }
}

/// render a decoder coding path as the JSON location the plan author wrote:
/// `root`, `operations`, `operations[0]`, `operations[0].command`.
func batchPlanLocation(_ path: [CodingKey]) -> String {
    var location = ""
    for key in path {
        if let index = key.intValue {
            location += "[\(index)]"
        } else {
            location += location.isEmpty ? key.stringValue : ".\(key.stringValue)"
        }
    }
    return location.isEmpty ? "root" : location
}

/// the JSON shape a decoder expected, named the way a JSON author would.
/// `DecodingError` carries a Swift metatype (`Dictionary<String, Any>`,
/// `Array<Any>`), which names neither JSON nor the plan's vocabulary.
func batchJSONShape(_ type: Any.Type) -> String {
    if type == [String: Any].self { return "object" }
    if type == [Any].self { return "array" }
    if type == String.self { return "string" }
    if type == Bool.self { return "boolean" }
    if type == Int.self || type == Double.self { return "number" }
    return "\(type)"
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
