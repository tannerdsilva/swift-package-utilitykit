import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// build a call graph: for each function, list the functions it calls.
/// gives an agent control-flow understanding without running the code.
struct CallgraphCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "callgraph",
        abstract: "Build a call graph from function bodies."
    )

    @Argument(help: "Files or directories to analyze.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: json, compact, csv, short, jsonl.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Flag(name: .long, help: "Include calls to unknown/undeclared functions.")
    var includeUnknown = false

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .long, help: "Maximum number of edges.")
    var limit: Int?

    @Flag(name: .long, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    mutating func run() throws {
        if schema {
            print(CallEdge.jsonSchema)
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

        // first pass: collect all known function names from all files
        var knownFunctions: Set<String> = []
        for filePath in files {
            do {
                let source = try String(contentsOfFile: filePath, encoding: .utf8)
                let tree = Parser.parse(source: source)
                let funcCollector = FunctionNameCollector()
                funcCollector.walk(tree)
                for name in funcCollector.functions {
                    knownFunctions.insert(name)
                }
            } catch {
                continue
            }
        }

        // second pass: collect call edges using the complete knownFunctions set
        var allEdges: [CallEdge] = []
        for filePath in files {
            do {
                let source = try String(contentsOfFile: filePath, encoding: .utf8)
                let tree = Parser.parse(source: source)
                let edgeCollector = CallEdgeCollector(
                    filePath: filePath, source: source,
                    knownFunctions: knownFunctions,
                    includeUnknown: includeUnknown
                )
                edgeCollector.walk(tree)
                allEdges.append(contentsOf: edgeCollector.edges)
            } catch {
                continue
            }
        }

        allEdges.sort { ($0.caller, $0.callee, $0.line) < ($1.caller, $1.callee, $1.line) }

        if let limit = limit, allEdges.count > limit {
            allEdges = Array(allEdges.prefix(limit))
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput(allEdges, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }
}

struct CallEdge: Codable, Sendable {
    let caller: String
    let callee: String
    let file: String
    let line: Int
    let column: Int
    let resolved: Bool     // true if callee is a known function in the project

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "CallEdge",
      "type": "object",
      "properties": {
        "caller":   { "type": "string", "description": "Calling function name" },
        "callee":   { "type": "string", "description": "Called function/method name" },
        "file":     { "type": "string", "description": "Source file path" },
        "line":     { "type": "integer", "description": "1-based line number" },
        "column":   { "type": "integer", "description": "1-based column number" },
        "resolved": { "type": "boolean", "description": "True if callee is a known function in the project" }
      },
      "required": ["caller", "callee", "file", "line", "column", "resolved"]
    }
    """
}

/// collect all function/method/init names in a file.
class FunctionNameCollector: SyntaxVisitor {
    var functions: [String] = []

    override init(viewMode: SyntaxTreeViewMode = .sourceAccurate) {
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        // include parameter types to distinguish overloads
        let params = node.signature.parameterClause.parameters.map { $0.type.description }.joined(separator: ":")
        functions.append("init(\(params))")
        return .visitChildren
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        functions.append("deinit")
        return .visitChildren
    }
}

/// collect all function call edges in a file.
class CallEdgeCollector: SyntaxVisitor {
    let filePath: String
    let source: String
    let knownFunctions: Set<String>
    let includeUnknown: Bool
    var edges: [CallEdge] = []
    var currentFunction: String = "<top-level>"

    init(filePath: String, source: String, knownFunctions: Set<String>, includeUnknown: Bool) {
        self.filePath = filePath
        self.source = source
        self.knownFunctions = knownFunctions
        self.includeUnknown = includeUnknown
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let previous = currentFunction
        currentFunction = node.name.text
        // walk the body for calls
        if let body = node.body {
            for stmt in body.statements {
                walkCallExprs(in: stmt)
            }
        }
        currentFunction = previous
        return .skipChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        let previous = currentFunction
        let params = node.signature.parameterClause.parameters.map { $0.type.description }.joined(separator: ":")
        currentFunction = "init(\(params))"
        if let body = node.body {
            for stmt in body.statements {
                walkCallExprs(in: stmt)
            }
        }
        currentFunction = previous
        return .skipChildren
    }

    /// recursively walk a statement tree looking for function call expressions.
    private func walkCallExprs(in node: some SyntaxProtocol) {
        for child in node.children(viewMode: .sourceAccurate) {
            if let call = child.as(FunctionCallExprSyntax.self) {
                let calleeName = extractCalleeName(from: call.calledExpression)
                if !calleeName.isEmpty {
                    let resolved = knownFunctions.contains(calleeName)
                    if resolved || includeUnknown {
                        let pos = call.position.utf8Offset
                        let (line, col) = lineColumn(at: pos, in: source)
                        edges.append(CallEdge(
                            caller: currentFunction,
                            callee: calleeName,
                            file: filePath,
                            line: line,
                            column: col,
                            resolved: resolved
                        ))
                    }
                }
                // recurse into arguments (closures may contain more calls)
                for arg in call.arguments {
                    walkCallExprs(in: arg)
                }
            } else {
                walkCallExprs(in: child)
            }
        }
    }
}

/// extract the callee name from a called expression.
private func extractCalleeName(from expr: ExprSyntax) -> String {
    if let ident = expr.as(IdentifierExprSyntax.self) {
        return ident.baseName.text
    }
    if let member = expr.as(MemberAccessExprSyntax.self) {
        return member.declName.baseName.text
    }
    // handle optional chaining: foo?.bar()
    if let optChain = expr.as(OptionalChainingExprSyntax.self) {
        return extractCalleeName(from: optChain.expression)
    }
    // handle force unwrap: foo!.bar()
    if let forceUnwrap = expr.as(ForceUnwrapExprSyntax.self) {
        return extractCalleeName(from: forceUnwrap.expression)
    }
    return ""
}
