import Foundation
import ArgumentParser
import SwiftSyntax
import SwiftParser

/// inspect a specific symbol in a Swift source file or directory.
struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Show detailed information about a symbol in Swift source files."
    )

    @Argument(help: "Files or directories to search.")
    var paths: [String] = ["."]

    @Option(name: .long, help: "Symbol name to find.")
    var symbol: String

    @Option(name: .long, help: "Only include files with these extensions (comma-separated).")
    var include: String?

    @Option(name: .long, help: "Skip files with these extensions (comma-separated).")
    var exclude: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "Output as human-readable text.")
    var text = false

    @Option(name: .long, help: "Output format: json, compact, short, jsonl.")
    var outputFormat: OutputFormat?

    @Flag(name: .long, inversion: .prefixedNo, help: "Pretty-print JSON output (overrides --output-format).")
    var prettyPrint = false

    @Option(name: .customLong("output"), help: "Write output to file instead of stdout.")
    var outputPath: String = ""

    @Flag(name: .long, inversion: .prefixedNo, help: "Print JSON Schema for the output type and exit.")
    var schema = false

    mutating func run() throws {
        if schema {
            print(SymbolDetail.jsonSchema)
            return
        }
        // check for stdin path
        let stdinPaths = paths.filter(isStdinPath)
        let filePaths = paths.filter { !isStdinPath($0) }

        // handle stdin input
        if !stdinPaths.isEmpty {
            let source = readSourceFromStdin()
            let tree = Parser.parse(source: source)
            let finder = SymbolFinder(targetName: symbol, filePath: "<stdin>", source: source)
            finder.walk(tree)

            if let detail = finder.found {
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
                    print("symbol: \(detail.name)")
                    print("kind:   \(detail.kind)")
                    print("file:   <stdin>:\(detail.line):\(detail.column)")
                    if !detail.modifiers.isEmpty {
                        print("modifiers: \(detail.modifiers.joined(separator: " "))")
                    }
                    print("signature: \(detail.signature)")
                    if !detail.docComment.isEmpty {
                        print("doc comment:")
                        print(detail.docComment)
                    }
                    print("")
                    print("--- source ---")
                    print(detail.sourceText)
                    if !detail.children.isEmpty {
                        print("")
                        print("children (\(detail.children.count)):")
                        for child in detail.children {
                            print("  \(child.signature) at \(child.line):\(child.column)")
                        }
                    }
                } else {
                    let enc = JSONEncoder()
                    if fmt == .json {
                        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    }
                    let data = try enc.encode(detail)
                    let outputStr = String(data: data, encoding: .utf8)!
                    try writeOutput(outputStr, to: outputPath)
                }
                return
            }
            throw ValidationError("symbol '\(symbol)' not found in stdin")
        }

        let files = collectSwiftFiles(
            from: filePaths,
            include: include?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            exclude: exclude?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )

        try validateInputPathsExist(filePaths)

        // search for the symbol across all files
        for filePath in files {
            guard let source = readSwiftSource(filePath) else { continue }
            let tree = Parser.parse(source: source)
            let finder = SymbolFinder(targetName: symbol, filePath: filePath, source: source)
            finder.walk(tree)

            if let detail = finder.found {
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
                    print("symbol: \(detail.name)")
                    print("kind:   \(detail.kind)")
                    print("file:   \(detail.file):\(detail.line):\(detail.column)")
                    if !detail.modifiers.isEmpty {
                        print("modifiers: \(detail.modifiers.joined(separator: " "))")
                    }
                    print("signature: \(detail.signature)")
                    if !detail.docComment.isEmpty {
                        print("doc comment:")
                        print(detail.docComment)
                    }
                    print("")
                    print("--- source ---")
                    print(detail.sourceText)
                    if !detail.children.isEmpty {
                        print("")
                        print("children (\(detail.children.count)):")
                        for child in detail.children {
                            print("  \(child.signature) at \(child.line):\(child.column)")
                        }
                    }
                } else {
                    let enc = JSONEncoder()
                    if fmt == .json {
                        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                    }
                    let data = try enc.encode(detail)
                    let outputStr = String(data: data, encoding: .utf8)!
                    try writeOutput(outputStr, to: outputPath)
                }
                return
            }
        }

        throw ValidationError("symbol '\(symbol)' not found in the given paths")
    }
}
