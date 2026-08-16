import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// measure cyclomatic complexity per function.
struct ComplexityCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "complexity",
        abstract: "Measure cyclomatic complexity per function."
    )

    @Argument(help: "Files or directories to analyze.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: json, compact, csv, short, jsonl.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .long, help: "Maximum number of results.")
    var limit: Int?

    @Option(name: .long, help: "Minimum complexity threshold (omit for all).")
    var minComplexity: Int?

    @Flag(name: .long, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(ComplexityItem.jsonSchema)
            return
        }

        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        guard !files.isEmpty else {
            throw ValidationError("no matching source files found")
        }

        var items: [ComplexityItem] = []

        for filePath in files {
            do {
                let source = try String(contentsOfFile: filePath, encoding: .utf8)
                let tree = Parser.parse(source: source)
                let collector = ComplexityCollector(filePath: filePath, source: source)
                collector.walk(tree)
                items.append(contentsOf: collector.items)
            } catch {
                continue
            }
        }

        if let min = minComplexity {
            items = items.filter { $0.complexity >= min }
        }

        items.sort { ($0.complexity, $0.name) > ($1.complexity, $1.name) }

        if let limit = limit, items.count > limit {
            items = Array(items.prefix(limit))
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput(items, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }
}

struct ComplexityItem: Codable, Sendable {
    let name: String
    let file: String
    let line: Int
    let column: Int
    let complexity: Int
    let rating: String

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "ComplexityItem",
      "type": "object",
      "properties": {
        "name":       { "type": "string", "description": "Function name" },
        "file":       { "type": "string", "description": "Source file path" },
        "line":       { "type": "integer", "description": "1-based line number" },
        "column":     { "type": "integer", "description": "1-based column number" },
        "complexity": { "type": "integer", "description": "Cyclomatic complexity score" },
        "rating":     { "type": "string", "description": "simple (1-5), moderate (6-10), complex (11-20), very_complex (21+)" }
      },
      "required": ["name", "file", "line", "column", "complexity", "rating"]
    }
    """
}

/// walk a function body counting decision points inline during the single walk.
/// uses a stack to correctly handle nested functions — inner function complexity
/// does not bleed into the outer function's score.
class ComplexityCollector: SyntaxVisitor {
    let filePath: String
    let source: String
    var items: [ComplexityItem] = []
    /// stack of (name, score) pairs for tracking nested functions
    var functionStack: [(name: String, score: Int)] = []

    init(filePath: String, source: String) {
        self.filePath = filePath
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    /// true when we are inside any function on the stack
    var inFunction: Bool { !functionStack.isEmpty }
    /// the current function's score (top of stack)
    var currentScore: Int {
        get { functionStack.last?.score ?? 0 }
        set { if !functionStack.isEmpty { functionStack[functionStack.count - 1].score = newValue } }
    }
    /// the current function's name (top of stack)
    var currentName: String {
        get { functionStack.last?.name ?? "" }
        set { if !functionStack.isEmpty { functionStack[functionStack.count - 1].name = newValue } }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functionStack.append((name: node.name.text, score: 1))
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        functionStack.append((name: "init", score: 1))
        return .visitChildren
    }

    override func visit(_ node: IfExprSyntax) -> SyntaxVisitorContinueKind {
        guard inFunction else { return .visitChildren }
        currentScore += 1
        if node.elseBody != nil { currentScore += 1 }
        return .visitChildren
    }

    override func visit(_ node: GuardStmtSyntax) -> SyntaxVisitorContinueKind {
        guard inFunction else { return .visitChildren }
        currentScore += 1
        return .visitChildren
    }

    override func visit(_ node: ForStmtSyntax) -> SyntaxVisitorContinueKind {
        guard inFunction else { return .visitChildren }
        currentScore += 1
        return .visitChildren
    }

    override func visit(_ node: WhileStmtSyntax) -> SyntaxVisitorContinueKind {
        guard inFunction else { return .visitChildren }
        currentScore += 1
        return .visitChildren
    }

    override func visit(_ node: SwitchExprSyntax) -> SyntaxVisitorContinueKind {
        guard inFunction else { return .visitChildren }
        currentScore += node.cases.count
        return .visitChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        guard inFunction else { return .visitChildren }
        currentScore += 1
        return .visitChildren
    }

    override func visit(_ node: BinaryOperatorExprSyntax) -> SyntaxVisitorContinueKind {
        guard inFunction else { return .visitChildren }
        if node.operator.text == "&&" || node.operator.text == "||" {
            currentScore += 1
        }
        return .visitChildren
    }

    override func visitPost(_ node: FunctionDeclSyntax) {
        // called after visiting all children — record the complexity and pop
        guard inFunction else { return }
        let rating: String
        if currentScore <= 5 { rating = "simple" }
        else if currentScore <= 10 { rating = "moderate" }
        else if currentScore <= 20 { rating = "complex" }
        else { rating = "very_complex" }

        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        items.append(ComplexityItem(
            name: currentName, file: filePath, line: line, column: col,
            complexity: currentScore, rating: rating
        ))
        functionStack.removeLast()
    }

    override func visitPost(_ node: InitializerDeclSyntax) {
        guard inFunction else { return }
        let rating: String
        if currentScore <= 5 { rating = "simple" }
        else if currentScore <= 10 { rating = "moderate" }
        else if currentScore <= 20 { rating = "complex" }
        else { rating = "very_complex" }

        let pos = node.position.utf8Offset
        let (line, col) = lineColumn(at: pos, in: source)
        items.append(ComplexityItem(
            name: currentName, file: filePath, line: line, column: col,
            complexity: currentScore, rating: rating
        ))
        functionStack.removeLast()
    }
}
