import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// list declarations (functions, types, etc.) from one or more Swift source files.
struct QueryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "query",
        abstract: "List declarations from Swift source files."
    )

    @Argument(help: "Files or directories to query.")
    var paths: [String] = []

    @Flag(name: .long, inversion: .prefixedNo, help: "Include functions.")
    var functions = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include structs.")
    var structs = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include classes.")
    var classes = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include enums.")
    var enums = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include protocols.")
    var protocols = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include typealiases.")
    var typealiases = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include variables.")
    var variables = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include extensions.")
    var extensions = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Include all declaration kinds.")
    var all = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Output format: JSON array (default).")
    var json = false

    @Flag(name: .long, inversion: .prefixedNo, help: "Output format: human-readable text.")
    var text = false

    @Option(name: .long, help: "Output format: json, compact, csv, short.")
    var outputFormat: OutputFormat?

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output (overrides --output-format).")
    var prettyPrint = false

    @Option(name: .long, help: "Only include declarations matching this name (substring).")
    var name: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Only print the count of matching declarations.")
    var count = false

    @Option(name: .long, help: "Sort results by: name, kind, file, line.")
    var sort: String?

    @Option(name: .long, help: "Maximum number of declarations to return.")
    var limit: Int?

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
        var exclude: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    mutating func run() throws {
        if schema {
            print(DeclarationInfo.jsonSchema)
            return
        }
        // determine which kinds to collect
        let kinds: Set<String>
        if all {
            kinds = Set(["function", "struct", "class", "enum", "protocol",
                         "typealias", "associatedtype", "variable",
                         "extension", "initializer", "subscript",
                         "operator", "precedencegroup", "macro", "import"])
        } else {
            var selected = Set<String>()
            if functions    { selected.insert("function") }
            if structs      { selected.insert("struct") }
            if classes      { selected.insert("class") }
            if enums        { selected.insert("enum") }
            if protocols    { selected.insert("protocol") }
            if typealiases  { selected.insert("typealias") }
            if variables    { selected.insert("variable") }
            if extensions   { selected.insert("extension") }
            if selected.isEmpty {
                // if --name is specified, default to all kinds (user doesn't know what they're looking for)
                if name != nil {
                    selected = Set(["function", "struct", "class", "enum", "protocol",
                                    "typealias", "associatedtype", "variable",
                                    "extension", "initializer", "subscript",
                                    "operator", "precedencegroup", "macro", "import"])
                } else {
                    selected.insert("function") // default
                    // a bare `query` that silently returns only functions gives
                    // an LLM a distorted picture of a codebase — surface the
                    // default so the caller knows to pass --all when needed
                    FileHandle.standardError.write(Data(
                        "swift-package-tool: note: no declaration-kind flags given; querying functions only. pass --all for every kind.\n".utf8
                    ))
                }
            }
            kinds = selected
        }

        let files = collectSwiftFiles(
            from: paths.isEmpty ? ["."] : paths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )
        try validateInputPathsExist(paths.isEmpty ? ["."] : paths)

        // stdin mode: pipe source through `-` (like find/inspect/format)
        if paths.contains(where: isStdinPath) {
            let source = readSourceFromStdin()
            let tree = Parser.parse(source: source)
            let collector = DeclarationCollector(filePath: "<stdin>", source: source, kinds: kinds)
            collector.walk(tree)
            let matches = name.map { n in
                collector.declarations.filter { $0.name.localizedCaseInsensitiveContains(n) }
            } ?? collector.declarations

            if count {
                print(matches.count)
                return
            }
            let fmt: OutputFormat = prettyPrint ? .json : (outputFormat ?? (text ? .short : (json ? .compact : .compact)))
            let outputStr = try formatOutput(matches, format: fmt)
            try writeOutput(outputStr, to: outputPath)
            return
        }

        var allDecls: [DeclarationInfo] = []

        for filePath in files {
            guard let source = readSwiftSource(filePath) else { continue }
            let tree = Parser.parse(source: source)
            let collector = DeclarationCollector(filePath: filePath, source: source, kinds: kinds)
            collector.walk(tree)

            if let nameFilter = name {
                allDecls.append(contentsOf: collector.declarations.filter {
                    $0.name.localizedCaseInsensitiveContains(nameFilter)
                })
            } else {
                allDecls.append(contentsOf: collector.declarations)
            }
        }

        // sort
        if let sortBy = sort {
            switch sortBy {
            case "name": allDecls.sort { $0.name < $1.name }
            case "kind": allDecls.sort { $0.kind < $1.kind || ($0.kind == $1.kind && $0.name < $1.name) }
            case "file": allDecls.sort { $0.file < $1.file || ($0.file == $1.file && $0.line < $1.line) }
            case "line": allDecls.sort { $0.line < $1.line || ($0.line == $1.line && $0.column < $1.column) }
            default: break
            }
        }

        // limit
        if let limit = limit, allDecls.count > limit {
            allDecls = Array(allDecls.prefix(limit))
        }

        // count-only mode
        if count {
            print(allDecls.count)
            return
        }

        // determine format: --pretty-print > --output-format > --text > compact.
        // `--json` is a legacy no-op alias (JSON output is already the default) and
        // `--text` an alias for `--output-format short`; an explicit --output-format
        // wins so the flags never silently contradict each other.
        let fmt: OutputFormat
        if prettyPrint {
            fmt = .json
        } else if let f = outputFormat {
            fmt = f
        } else if text {
            fmt = .short
        } else {
            fmt = .compact
        }

        if fmt == .short || text {
            print("found \(allDecls.count) declaration(s):\n")
            for decl in allDecls {
                let mods = decl.modifiers.isEmpty ? "" : "\(decl.modifiers.joined(separator: " ")) "
                print("  \(mods)\(decl.signature)")
                print("      at \(decl.file):\(decl.line):\(decl.column)")
                if !decl.docComment.isEmpty {
                    print("      doc: \(decl.docComment.prefix(80))")
                }
                print("")
            }
        } else {
            let outputStr = try formatOutput(allDecls, format: fmt)
            try writeOutput(outputStr, to: outputPath)
        }
    }
}
