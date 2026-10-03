import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// validate docc documentation comments by checking that symbol references
/// in `///` and `/** */` comments point to declarations that actually exist
/// in the project.
///
/// this is a best-effort check — it parses docc comments for text between
/// double backticks (`` `TypeName` ``) and cross-references them against
/// all known declarations. it does not resolve qualified names, module
/// references, or external symbols.
struct DoccCheckCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "docc-check",
        abstract: "Validate docc documentation symbol references."
    )

    @Argument(help: "Files or directories to check.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Output format: json, compact, short.")
    var outputFormat: OutputFormat = .compact

    @Flag(name: .long, help: "Pretty-print JSON output.")
    var prettyPrint = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Option(name: .long, help: "Maximum number of warnings to return.")
    var limit: Int?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(DoccWarning.jsonSchema)
            return
        }
        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        try validateInputPathsExist(paths)

        // first pass: collect all known declaration names, every file's source
        // (needed to locate references), and the docc comments themselves
        var knownSymbols = Set<String>()
        var sourcesByFile: [String: String] = [:]
        var fileDoccComments: [(file: String, utf8Offset: Int, comment: String)] = []

        for filePath in files.sorted() {
            guard let source = readSwiftSource(filePath) else { continue }
            sourcesByFile[filePath] = source
            let tree = Parser.parse(source: source)

            // Collect all declaration names
            let nameCollector = DeclarationNameCollector()
            nameCollector.walk(tree)
            for name in nameCollector.names {
                knownSymbols.insert(name)
            }

            // Collect docc comments from the source file's trivia
            let doccCollector = DoccCommentCollector(filePath: filePath)
            doccCollector.walk(tree)
            fileDoccComments.append(contentsOf: doccCollector.comments)
        }

        // second pass: check each docc comment for invalid symbol references.
        // the warning points at the reference itself — its own line and column
        // — not at the declaration the comment is attached to.
        var warnings: [DoccWarning] = []

        for (file, pieceOffset, comment) in fileDoccComments {
            guard let source = sourcesByFile[file] else { continue }
            for ref in extractSymbolReferences(from: comment) {
                if knownSymbols.contains(ref) { continue }
                let (line, column) = lineColumn(at: pieceOffset + utf8Offset(of: ref, in: comment), in: source)
                warnings.append(DoccWarning(
                    file: file,
                    line: line,
                    column: column,
                    severity: "warning",
                    message: "Invalid docc symbol reference '\(ref)' — no matching declaration found in project",
                    referencedSymbol: ref
                ))
            }
        }

        warnings.sort { ($0.file, $0.line) < ($1.file, $1.line) }

        if let limit = limit, warnings.count > limit {
            warnings = Array(warnings.prefix(limit))
        }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput(warnings, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }
}

struct DoccWarning: Codable, Sendable, CustomStringConvertible {
    let file: String
    let line: Int
    let column: Int
    let severity: String
    let message: String
    let referencedSymbol: String

    var description: String {
        return "\(file):\(line):\(column)  [\(severity)]  \(message)"
    }

    static let jsonSchema = """
    {
      "$schema": "https://json-schema.org/draft-07/schema#",
      "title": "DoccWarning",
      "type": "object",
      "properties": {
        "file":             { "type": "string", "description": "Source file path" },
        "line":             { "type": "integer", "description": "1-based line number" },
        "column":           { "type": "integer", "description": "1-based column number" },
        "severity":         { "type": "string", "description": "warning" },
        "message":          { "type": "string", "description": "The docc validation message" },
        "referencedSymbol": { "type": "string", "description": "The backticked symbol reference" }
      },
      "required": ["file", "line", "column", "severity", "message", "referencedSymbol"]
    }
    """
}

/// extract symbol references from a docc comment.
/// looks for text between double backticks (`` `TypeName` ``) and
/// single backtick references (`TypeName`).
private func extractSymbolReferences(from comment: String) -> [String] {
    var refs: [String] = []
    var searchRange = comment.startIndex..<comment.endIndex

    while true {
        // Look for double backticks first (docc link syntax: ``TypeName``)
        if let openRange = comment[searchRange].range(of: "``") {
            let afterOpen = openRange.upperBound
            if let closeRange = comment[afterOpen...].range(of: "``") {
                let symbol = String(comment[afterOpen..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                if !symbol.isEmpty && !symbol.contains(" ") && !symbol.contains("\n") {
                    refs.append(symbol)
                }
                searchRange = closeRange.upperBound..<comment.endIndex
                continue
            }
        }
        break
    }

    // Also check single backtick references that look like types
    searchRange = comment.startIndex..<comment.endIndex
    while true {
        if let openRange = comment[searchRange].range(of: "`") {
            let afterOpen = openRange.upperBound
            if let closeRange = comment[afterOpen...].range(of: "`") {
                let symbol = String(comment[afterOpen..<closeRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                // Skip if it's part of a double-backtick reference (already handled)
                // or if it contains spaces (code snippet, not a symbol reference)
                if !symbol.isEmpty && !symbol.contains(" ") && !symbol.contains("\n") {
                    // Check it's not a double-backtick by looking at the character before open
                    let beforeOpen = openRange.lowerBound > comment.startIndex
                        ? comment[comment.index(before: openRange.lowerBound)]
                        : " "
                    if beforeOpen != "`" {
                        // Filter out comment markers and operators
                        if !symbol.hasPrefix("///") && !symbol.hasPrefix("//") && !symbol.hasPrefix("/*") {
                            refs.append(symbol)
                        }
                    }
                }
                searchRange = closeRange.upperBound..<comment.endIndex
                continue
            }
        }
        break
    }

    return Array(Set(refs)).sorted()
}

/// collect all declaration names from a syntax tree.
class DeclarationNameCollector: SyntaxVisitor {
    var names: Set<String> = []

    init() {
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: AssociatedTypeDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            if let pattern = binding.pattern.as(IdentifierPatternSyntax.self) {
                names.insert(pattern.identifier.text)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: EnumCaseElementSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: MacroDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: OperatorDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }

    override func visit(_ node: PrecedenceGroupDeclSyntax) -> SyntaxVisitorContinueKind {
        names.insert(node.name.text)
        return .visitChildren
    }
}

/// collect docc comments from a syntax tree. each entry carries the byte
/// offset where its piece starts: a token's `position` includes leading
/// trivia, so the first piece starts exactly there and every following piece
/// advances by its own source length.
class DoccCommentCollector: SyntaxVisitor {
    let filePath: String
    var comments: [(file: String, utf8Offset: Int, comment: String)] = []

    init(filePath: String) {
        self.filePath = filePath
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: TokenSyntax) -> SyntaxVisitorContinueKind {
        var cursor = node.position.utf8Offset
        for piece in node.leadingTrivia {
            switch piece {
            case .docLineComment(let text),
                 .docBlockComment(let text):
                comments.append((file: filePath, utf8Offset: cursor, comment: text))
            default:
                break
            }
            cursor += piece.sourceLength.utf8Length
        }
        return .visitChildren
    }
}

/// byte offset of the first occurrence of `ref` inside `comment`.
private func utf8Offset(of ref: String, in comment: String) -> Int {
    guard let range = comment.range(of: ref) else { return 0 }
    return comment.utf8.distance(from: comment.startIndex, to: range.lowerBound)
}
