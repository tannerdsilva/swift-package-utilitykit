import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// scan Swift source files for force-unwrap `!` usage, classified by subkind.
///
/// uses a dedicated swift-syntax walker to identify every `!` operator and
/// classify it as a plain force-unwrap, a forced try (`try!`), or a forced
/// cast (`as!`).  this is more accurate than regex because swift-syntax
/// understands the AST context of each `!` token.
struct ForceUnwrapsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "force-unwraps",
        abstract: "Find force-unwrap ! usage, classified by subkind."
    )

    @Argument(help: "Files or directories to scan.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: json, compact, csv, short.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Option(name: .long, help: "Maximum number of findings to return.")
    var limit: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(ForceUnwrapItem.jsonSchema)
            return
        }

        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        try validateInputPathsExist(paths)

        var items: [ForceUnwrapItem] = []

        for filePath in files {
            guard let source = readSwiftSource(filePath) else { continue }
            let tree = Parser.parse(source: source)
            let collector = ForceUnwrapCollector(filePath: filePath, source: source)
            collector.walk(tree)
            items.append(contentsOf: collector.items)
        }

        items.sort { ($0.file, $0.line) < ($1.file, $1.line) }

        if let limit = limit, items.count > limit {
            items = Array(items.prefix(limit))
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput(items, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }
}

struct ForceUnwrapItem: Codable, Sendable, CustomStringConvertible {
    let file: String
    let line: Int
    let column: Int
    let kind: String       // "force_unwrap", "try_force", "as_cast"
    let context: String    // surrounding source text snippet

    var description: String {
        return "\(file):\(line):\(column)  [\(kind)]"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "ForceUnwrapItem",
      "type": "object",
      "properties": {
        "file":    { "type": "string", "description": "Source file path" },
        "line":    { "type": "integer", "description": "1-based line number" },
        "column":  { "type": "integer", "description": "1-based column number" },
        "kind":    { "type": "string", "description": "force_unwrap, try_force, or as_cast" },
        "context": { "type": "string", "description": "Surrounding source text snippet" }
      },
      "required": ["file", "line", "column", "kind", "context"]
    }
    """
}

/// walk a syntax tree looking for force-unwrap `!` operators and classifying
/// them by context.  swift-syntax gives us the exact AST node for each `!`,
/// so we can distinguish `try!`, `as!`, and plain `!` without regex.
class ForceUnwrapCollector: SyntaxVisitor {
    let filePath: String
    let source: String
    var items: [ForceUnwrapItem] = []

    init(filePath: String, source: String) {
        self.filePath = filePath
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    /// forced unwrap: `x!`
    override func visit(_ node: ForceUnwrapExprSyntax) -> SyntaxVisitorContinueKind {
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let snippet = extractSnippet(at: pos)
        items.append(ForceUnwrapItem(
            file: filePath, line: line, column: col,
            kind: "force_unwrap", context: snippet
        ))
        return .visitChildren
    }

    /// forced try: `try! expr`
    override func visit(_ node: TryExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.questionOrExclamationMark?.text == "!" else { return .visitChildren }
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let snippet = extractSnippet(at: pos)
        items.append(ForceUnwrapItem(
            file: filePath, line: line, column: col,
            kind: "try_force", context: snippet
        ))
        return .visitChildren
    }

    /// forced cast: `expr as! Type`
    override func visit(_ node: AsExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.questionOrExclamationMark?.text == "!" else { return .visitChildren }
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let snippet = extractSnippet(at: pos)
        items.append(ForceUnwrapItem(
            file: filePath, line: line, column: col,
            kind: "as_cast", context: snippet
        ))
        return .visitChildren
    }

    /// forced cast via unresolved as-expression (initial parse form)
    override func visit(_ node: UnresolvedAsExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.questionOrExclamationMark?.text == "!" else { return .visitChildren }
        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        let snippet = extractSnippet(at: pos)
        items.append(ForceUnwrapItem(
            file: filePath, line: line, column: col,
            kind: "as_cast", context: snippet
        ))
        return .visitChildren
    }

    /// extract a 120-char snippet of source text around the given offset.
    private func extractSnippet(at offset: Int) -> String {
        let start = source.index(source.startIndex, offsetBy: max(0, offset - 20))
        let end = source.index(source.startIndex, offsetBy: min(source.count, offset + 100))
        return String(source[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
