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

    mutating func run() throws {
        let files = collectSwiftFiles(
            from: paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        guard !files.isEmpty else {
            throw ValidationError("no matching source files found")
        }

        // First pass: collect all known declaration names
        var knownSymbols = Set<String>()
        // Also collect file-level docc comments (not attached to a specific decl)
        var fileDoccComments: [(file: String, line: Int, comment: String)] = []

        for filePath in files.sorted() {
            do {
                let source = try String(contentsOfFile: filePath, encoding: .utf8)
                let tree = Parser.parse(source: source)

                // Collect all declaration names
                let nameCollector = DeclarationNameCollector()
                nameCollector.walk(tree)
                for name in nameCollector.names {
                    knownSymbols.insert(name)
                }

                // Collect docc comments from the source file's trivia
                let doccCollector = DoccCommentCollector(filePath: filePath, source: source)
                doccCollector.walk(tree)
                fileDoccComments.append(contentsOf: doccCollector.comments)
            } catch {
                continue
            }
        }

        // Second pass: check each docc comment for invalid symbol references
        var warnings: [DoccWarning] = []

        for (file, line, comment) in fileDoccComments {
            let refs = extractSymbolReferences(from: comment)
            for ref in refs {
                if !knownSymbols.contains(ref) {
                    warnings.append(DoccWarning(
                        file: file,
                        line: line,
                        column: comment.distance(from: comment.startIndex, to: comment.range(of: ref)?.lowerBound ?? comment.startIndex) + 1,
                        severity: "warning",
                        message: "Invalid docc symbol reference '\(ref)' — no matching declaration found in project",
                        referencedSymbol: ref
                    ))
                }
            }
        }

        warnings.sort { ($0.file, $0.line) < ($1.file, $1.line) }

        let fmt: OutputFormat = prettyPrint ? .json : outputFormat
        let outputStr = try formatOutput(warnings, format: fmt)
        try writeOutput(outputStr, to: outputPath)
    }
}

struct DoccWarning: Codable, Sendable {
    let file: String
    let line: Int
    let column: Int
    let severity: String
    let message: String
    let referencedSymbol: String
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

/// collect docc comments from a syntax tree, tracking their file and line.
class DoccCommentCollector: SyntaxVisitor {
    let filePath: String
    let source: String
    var comments: [(file: String, line: Int, comment: String)] = []

    init(filePath: String, source: String) {
        self.filePath = filePath
        self.source = source
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: TokenSyntax) -> SyntaxVisitorContinueKind {
        let trivia = node.leadingTrivia
        for piece in trivia {
            switch piece {
            case .docLineComment(let text),
                 .docBlockComment(let text):
                let pos = node.position.utf8Offset
                let (line, _) = lineColumn(at: pos, in: source)
                comments.append((file: filePath, line: line, comment: text))
            default:
                break
            }
        }
        return .visitChildren
    }
}
